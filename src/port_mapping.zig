//! IPv4 port mapping for the Listen Socket and DHT Ports.
//!
//! NAT-PMP / PCP (RFC 6886 / RFC 6887) is attempted first, then UPnP IGD as a
//! fallback. All gateway I/O is strictly best-effort: a failure records a state
//! and never propagates an error that could crash the daemon.

const std = @import("std");
const log = @import("log.zig");

const net = std.Io.net;

pub const Proto = enum {
    tcp,
    udp,

    /// NAT-PMP opcode for a mapping request of this protocol.
    fn natpmpOpcode(self: Proto) u8 {
        return switch (self) {
            .udp => 1,
            .tcp => 2,
        };
    }

    /// IANA protocol number used by PCP.
    fn ianaNumber(self: Proto) u8 {
        return switch (self) {
            .tcp => 6,
            .udp => 17,
        };
    }
};

pub const MappingState = enum {
    disabled,
    pending,
    mapped,
    failed,

    pub fn label(self: MappingState) []const u8 {
        return switch (self) {
            .disabled => "disabled",
            .pending => "pending",
            .mapped => "mapped",
            .failed => "failed",
        };
    }
};

/// NAT-PMP gateway port (RFC 6886).
pub const natpmp_port: u16 = 5351;
/// PCP shares the NAT-PMP gateway port.
pub const pcp_port: u16 = 5351;
/// Default mapping lifetime; renew before this elapses.
pub const default_lifetime_s: u32 = 3600;

// --- NAT-PMP codecs (RFC 6886) ---------------------------------------------

/// Encode a NAT-PMP mapping request (12 bytes).
pub fn encodeNatpmpMap(proto: Proto, internal_port: u16, external_port: u16, lifetime_s: u32) [12]u8 {
    var out: [12]u8 = undefined;
    out[0] = 0; // version
    out[1] = proto.natpmpOpcode();
    out[2] = 0; // reserved
    out[3] = 0;
    std.mem.writeInt(u16, out[4..6], internal_port, .big);
    std.mem.writeInt(u16, out[6..8], external_port, .big);
    std.mem.writeInt(u32, out[8..12], lifetime_s, .big);
    return out;
}

/// Encode a NAT-PMP external-address request (2 bytes).
pub fn encodeNatpmpExternalRequest() [2]u8 {
    return .{ 0, 0 };
}

pub const NatpmpMapResponse = struct {
    result_code: u16,
    internal_port: u16,
    external_port: u16,
    lifetime_s: u32,

    pub fn ok(self: NatpmpMapResponse) bool {
        return self.result_code == 0;
    }
};

pub const NatpmpError = error{ ShortResponse, BadVersion, NotMappingResponse };

/// Parse a NAT-PMP mapping response (16 bytes) for the given protocol.
pub fn parseNatpmpMapResponse(proto: Proto, bytes: []const u8) NatpmpError!NatpmpMapResponse {
    if (bytes.len < 16) return NatpmpError.ShortResponse;
    if (bytes[0] != 0) return NatpmpError.BadVersion;
    if (bytes[1] != 128 + proto.natpmpOpcode()) return NatpmpError.NotMappingResponse;
    return .{
        .result_code = std.mem.readInt(u16, bytes[2..4], .big),
        .internal_port = std.mem.readInt(u16, bytes[8..10], .big),
        .external_port = std.mem.readInt(u16, bytes[10..12], .big),
        .lifetime_s = std.mem.readInt(u32, bytes[12..16], .big),
    };
}

// --- PCP codec (RFC 6887, MAP opcode) --------------------------------------

/// Encode a PCP MAP request (60 bytes). `client_v4` is the daemon's LAN IPv4
/// address, embedded as an IPv4-mapped IPv6 address per the spec.
pub fn encodePcpMap(
    proto: Proto,
    client_v4: [4]u8,
    nonce: [12]u8,
    internal_port: u16,
    external_port: u16,
    lifetime_s: u32,
) [60]u8 {
    var out: [60]u8 = [_]u8{0} ** 60;
    out[0] = 2; // version
    out[1] = 1; // R=0 (request), opcode=1 (MAP)
    std.mem.writeInt(u32, out[4..8], lifetime_s, .big);
    // Client address: ::ffff:a.b.c.d
    out[18] = 0xff;
    out[19] = 0xff;
    @memcpy(out[20..24], &client_v4);
    // MAP opcode payload starts at byte 24.
    @memcpy(out[24..36], &nonce);
    out[36] = proto.ianaNumber();
    std.mem.writeInt(u16, out[40..42], internal_port, .big);
    std.mem.writeInt(u16, out[42..44], external_port, .big);
    // Suggested external IP left as all-zero (any).
    return out;
}

// --- UPnP IGD (SSDP + SOAP) ------------------------------------------------

/// SSDP multicast group address for UPnP discovery.
pub const ssdp_group: [4]u8 = .{ 239, 255, 255, 250 };
pub const ssdp_port: u16 = 1900;

/// Build an SSDP M-SEARCH datagram for InternetGatewayDevice discovery.
pub fn buildSsdpSearch(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        "M-SEARCH * HTTP/1.1\r\n" ++
        "HOST: 239.255.255.250:1900\r\n" ++
        "MAN: \"ssdp:discover\"\r\n" ++
        "MX: 2\r\n" ++
        "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n" ++
        "\r\n");
}

/// Extract the `LOCATION` header value from an SSDP response.
pub fn parseSsdpLocation(response: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, response, "\r\n");
    while (lines.next()) |line| {
        if (line.len < 9) continue;
        if (std.ascii.eqlIgnoreCase(line[0..9], "LOCATION:")) {
            return std.mem.trim(u8, line[9..], " \t");
        }
    }
    return null;
}

/// Build a UPnP `AddPortMapping` SOAP body.
pub fn buildAddPortMappingSoap(
    allocator: std.mem.Allocator,
    proto: Proto,
    external_port: u16,
    internal_port: u16,
    internal_client_v4: [4]u8,
    lifetime_s: u32,
) ![]u8 {
    const proto_str = switch (proto) {
        .tcp => "TCP",
        .udp => "UDP",
    };
    return std.fmt.allocPrint(allocator,
        "<?xml version=\"1.0\"?>" ++
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " ++
        "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">" ++
        "<s:Body>" ++
        "<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\">" ++
        "<NewRemoteHost></NewRemoteHost>" ++
        "<NewExternalPort>{d}</NewExternalPort>" ++
        "<NewProtocol>{s}</NewProtocol>" ++
        "<NewInternalPort>{d}</NewInternalPort>" ++
        "<NewInternalClient>{d}.{d}.{d}.{d}</NewInternalClient>" ++
        "<NewEnabled>1</NewEnabled>" ++
        "<NewPortMappingDescription>nix-torrent</NewPortMappingDescription>" ++
        "<NewLeaseDuration>{d}</NewLeaseDuration>" ++
        "</u:AddPortMapping>" ++
        "</s:Body></s:Envelope>",
        .{ external_port, proto_str, internal_port, internal_client_v4[0], internal_client_v4[1], internal_client_v4[2], internal_client_v4[3], lifetime_s },
    );
}

// --- Linux default gateway detection ---------------------------------------

/// Parse the IPv4 default gateway from `/proc/net/route` contents.
/// The gateway is stored little-endian hex in the `Gateway` column of the
/// row whose `Destination` is `00000000`.
pub fn parseDefaultGatewayV4(contents: []const u8) ?[4]u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    _ = lines.next(); // header row
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        _ = fields.next() orelse continue; // Iface
        const dest = fields.next() orelse continue; // Destination
        const gateway = fields.next() orelse continue; // Gateway
        if (!std.mem.eql(u8, dest, "00000000")) continue;
        const raw = std.fmt.parseInt(u32, gateway, 16) catch continue;
        if (raw == 0) continue;
        // Stored little-endian: byte 0 is the low-order octet.
        return .{
            @truncate(raw),
            @truncate(raw >> 8),
            @truncate(raw >> 16),
            @truncate(raw >> 24),
        };
    }
    return null;
}

/// Best-effort read of the Linux IPv4 default gateway. Returns null off Linux
/// or when the routing table is unavailable.
pub fn detectGatewayV4(io: std.Io) ?[4]u8 {
    if (@import("builtin").os.tag != .linux) return null;
    var file = std.Io.Dir.cwd().openFile(io, "/proc/net/route", .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    // procfs reports size 0, so read the stream sequentially rather than by size.
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    var contents: [16384]u8 = undefined;
    var total: usize = 0;
    while (total < contents.len) {
        const n = reader.interface.readSliceShort(contents[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return parseDefaultGatewayV4(contents[0..total]);
}

// --- Best-effort NAT-PMP mapper --------------------------------------------

pub const MapOutcome = struct {
    state: MappingState,
    external_port: u16 = 0,
    lifetime_s: u32 = 0,
};

/// Attempt a single NAT-PMP mapping against `gateway`. Returns an error only
/// on transport failure; callers translate that into a `failed` state.
pub fn requestNatpmp(
    io: std.Io,
    gateway: [4]u8,
    proto: Proto,
    internal_port: u16,
    lifetime_s: u32,
    timeout_ms: u64,
) !NatpmpMapResponse {
    const bind_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
    var socket = try net.IpAddress.bind(&bind_addr, io, .{ .mode = .dgram });
    defer socket.close(io);

    const req = encodeNatpmpMap(proto, internal_port, internal_port, lifetime_s);
    const dest = net.IpAddress{ .ip4 = .{ .bytes = gateway, .port = natpmp_port } };
    try socket.send(io, &dest, &req);

    var buf: [64]u8 = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromNanoseconds(timeout_ms * std.time.ns_per_ms),
    } };
    const message = try socket.receiveTimeout(io, &buf, timeout);
    return parseNatpmpMapResponse(proto, message.data);
}

/// A tracked mapping for the Listen Port (and, optionally, DHT ports).
pub const PortMapper = struct {
    enabled: bool,
    gateway: ?[4]u8 = null,
    listen_state: MappingState = .disabled,
    listen_external_port: u16 = 0,
    timeout_ms: u64 = 3000,

    pub fn init(enabled: bool) PortMapper {
        return .{ .enabled = enabled, .listen_state = if (enabled) .pending else .disabled };
    }

    /// Map the Listen Port over TCP, trying NAT-PMP first. Never fails; state
    /// is recorded on the mapper and returned for logging.
    pub fn mapListenPort(self: *PortMapper, io: std.Io, listen_port: u16) MappingState {
        if (!self.enabled) {
            self.listen_state = .disabled;
            return self.listen_state;
        }
        const gw = self.gateway orelse detectGatewayV4(io);
        self.gateway = gw;
        if (gw == null) {
            self.listen_state = .failed;
            log.warn("port_mapping", "no IPv4 gateway found; listen port not mapped", .{});
            return self.listen_state;
        }
        const resp = requestNatpmp(io, gw.?, .tcp, listen_port, default_lifetime_s, self.timeout_ms) catch |err| {
            self.listen_state = .failed;
            log.warn("port_mapping", "NAT-PMP mapping failed: {s}", .{@errorName(err)});
            return self.listen_state;
        };
        if (!resp.ok()) {
            self.listen_state = .failed;
            log.warn("port_mapping", "gateway rejected mapping (result={d})", .{resp.result_code});
            return self.listen_state;
        }
        self.listen_state = .mapped;
        self.listen_external_port = resp.external_port;
        log.info("port_mapping", "mapped listen port {d} -> external {d}", .{ listen_port, resp.external_port });
        return self.listen_state;
    }
};

// --- Tests -----------------------------------------------------------------

test "natpmp map request round-trips through response parser" {
    const req = encodeNatpmpMap(.tcp, 6881, 6881, 3600);
    try std.testing.expectEqual(@as(u8, 0), req[0]);
    try std.testing.expectEqual(@as(u8, 2), req[1]); // TCP opcode
    try std.testing.expectEqual(@as(u16, 6881), std.mem.readInt(u16, req[4..6], .big));
    try std.testing.expectEqual(@as(u32, 3600), std.mem.readInt(u32, req[8..12], .big));

    var resp: [16]u8 = [_]u8{0} ** 16;
    resp[0] = 0;
    resp[1] = 128 + 2; // TCP mapping response
    std.mem.writeInt(u16, resp[2..4], 0, .big); // success
    std.mem.writeInt(u16, resp[8..10], 6881, .big);
    std.mem.writeInt(u16, resp[10..12], 40001, .big);
    std.mem.writeInt(u32, resp[12..16], 3600, .big);
    const parsed = try parseNatpmpMapResponse(.tcp, &resp);
    try std.testing.expect(parsed.ok());
    try std.testing.expectEqual(@as(u16, 40001), parsed.external_port);
    try std.testing.expectEqual(@as(u32, 3600), parsed.lifetime_s);
}

test "natpmp response rejects wrong opcode and short buffers" {
    var resp: [16]u8 = [_]u8{0} ** 16;
    resp[1] = 128 + 1; // UDP response
    try std.testing.expectError(NatpmpError.NotMappingResponse, parseNatpmpMapResponse(.tcp, &resp));
    try std.testing.expectError(NatpmpError.ShortResponse, parseNatpmpMapResponse(.tcp, resp[0..4]));
}

test "pcp map request has expected header fields" {
    const nonce = [_]u8{7} ** 12;
    const req = encodePcpMap(.udp, .{ 192, 168, 1, 2 }, nonce, 6881, 6881, 3600);
    try std.testing.expectEqual(@as(u8, 2), req[0]); // version
    try std.testing.expectEqual(@as(u8, 1), req[1]); // MAP request
    try std.testing.expectEqual(@as(u32, 3600), std.mem.readInt(u32, req[4..8], .big));
    // IPv4-mapped client address.
    try std.testing.expectEqual(@as(u8, 0xff), req[18]);
    try std.testing.expectEqual(@as(u8, 0xff), req[19]);
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 2 }, req[20..24]);
    try std.testing.expectEqual(@as(u8, 17), req[36]); // UDP
    try std.testing.expectEqual(@as(u16, 6881), std.mem.readInt(u16, req[40..42], .big));
}

test "ssdp location header is extracted case-insensitively" {
    const resp = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=120\r\nlocation: http://192.168.1.1:5000/rootDesc.xml\r\n\r\n";
    const loc = parseSsdpLocation(resp) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("http://192.168.1.1:5000/rootDesc.xml", loc);
}

test "soap add-port-mapping body contains ports and client" {
    const body = try buildAddPortMappingSoap(std.testing.allocator, .tcp, 6881, 6881, .{ 10, 0, 0, 5 }, 3600);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "<NewExternalPort>6881</NewExternalPort>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<NewProtocol>TCP</NewProtocol>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "<NewInternalClient>10.0.0.5</NewInternalClient>") != null);
}

test "default gateway parsed from proc net route" {
    // Gateway 192.168.1.1 => little-endian hex 0101A8C0.
    const contents =
        "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" ++
        "eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\n" ++
        "eth0\t0000A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\n";
    const gw = parseDefaultGatewayV4(contents) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, &.{ 192, 168, 1, 1 }, &gw);
}

test "no default route yields null gateway" {
    const contents =
        "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n" ++
        "eth0\t0000A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\n";
    try std.testing.expect(parseDefaultGatewayV4(contents) == null);
}

test "disabled mapper stays disabled" {
    var mapper = PortMapper.init(false);
    const st = mapper.mapListenPort(std.testing.io, 6881);
    try std.testing.expectEqual(MappingState.disabled, st);
}
