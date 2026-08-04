const std = @import("std");
const address = @import("address.zig");
const bencode = @import("bencode.zig");
const dns = @import("dns.zig");
const encryption = @import("encryption.zig");
const log = @import("log.zig");
const tcp = @import("tcp.zig");
const torrent = @import("torrent.zig");

const net = std.Io.net;

pub const Ip = address.Ip;

/// A dual-stack peer candidate learned from a Tracker, DHT, PEX, or LSD.
pub const Peer = struct {
    ip: address.Ip,
    port: u16,
    crypto_required: bool = false,

    pub fn v4(bytes: [4]u8, port: u16) Peer {
        return .{ .ip = .{ .v4 = bytes }, .port = port };
    }

    pub fn v6(bytes: [16]u8, port: u16) Peer {
        return .{ .ip = .{ .v6 = bytes }, .port = port };
    }

    pub fn addr(self: Peer) address.Address {
        return .{ .ip = self.ip, .port = self.port };
    }
};
pub const Announce = struct {
    interval: u64,
    peers: []Peer,
    failure_reason: ?[]const u8 = null,
    crypto_flags: ?[]u8 = null,

    pub fn deinit(self: Announce, allocator: std.mem.Allocator) void {
        allocator.free(self.peers);
        if (self.failure_reason) |s| allocator.free(s);
        if (self.crypto_flags) |flags| allocator.free(flags);
    }
};

pub const Event = enum { none, started, stopped, completed };

pub const Scheme = enum { http, https, udp };

pub const AnnounceUrl = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
    path: []const u8,
    has_query: bool,

    pub fn deinit(self: AnnounceUrl, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

pub const UdpSession = struct {
    connection_id: i64 = 0,
    connection_expires_ms: i64 = 0,
};

pub const TrackerState = struct {
    next_announce_ms: i64 = 0,
    interval_ms: i64 = 60_000,
    last_error: ?[]const u8 = null,
    retry_min_ms: i64 = 30_000,
    retry_max_ms: i64 = 300_000,
    retry_ms: i64 = 30_000,
    started_sent: bool = false,
    /// Failures since last success. Failover advances only after a retry
    /// (consecutive_failures >= 2), per V3 Tracker Tier policy.
    consecutive_failures: u32 = 0,

    pub fn deinit(self: *TrackerState, allocator: std.mem.Allocator) void {
        if (self.last_error) |s| allocator.free(s);
    }

    pub fn scheduleSuccess(self: *TrackerState, now_ms: i64, interval_sec: u64) void {
        self.interval_ms = @max(@as(i64, @intCast(interval_sec)) * 1000, 1000);
        self.next_announce_ms = now_ms + self.interval_ms;
        self.retry_ms = self.retry_min_ms;
        self.consecutive_failures = 0;
    }

    pub fn scheduleFailure(self: *TrackerState, now_ms: i64, message: []const u8, allocator: std.mem.Allocator) !void {
        if (self.last_error) |old| allocator.free(old);
        self.last_error = try allocator.dupe(u8, message);
        self.next_announce_ms = now_ms + self.retry_ms;
        self.retry_ms = @min(self.retry_ms * 2, self.retry_max_ms);
        self.consecutive_failures += 1;
    }

    pub fn due(self: TrackerState, now_ms: i64) bool {
        return now_ms >= self.next_announce_ms;
    }
};

pub fn isSupportedTrackerScheme(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://") or
        std.mem.startsWith(u8, url, "https://") or
        std.mem.startsWith(u8, url, "udp://");
}

pub fn parseAnnounceUrl(allocator: std.mem.Allocator, url: []const u8) !AnnounceUrl {
    const scheme: Scheme = if (std.mem.startsWith(u8, url, "https://"))
        .https
    else if (std.mem.startsWith(u8, url, "http://"))
        .http
    else if (std.mem.startsWith(u8, url, "udp://"))
        .udp
    else
        return error.UnsupportedTrackerScheme;
    const is_http = scheme == .http or scheme == .https;
    const prefix_len: usize = switch (scheme) {
        .https => 8,
        .http => 7,
        .udp => 6,
    };
    const rest = url[prefix_len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse if (scheme == .udp) rest.len else return error.InvalidTrackerUrl;
    const authority = rest[0..slash];
    const path_part = if (slash < rest.len) rest[slash..] else "/";
    const colon = std.mem.indexOfScalar(u8, authority, ':');
    const host: []const u8 = if (colon) |c| authority[0..c] else authority;
    if (host.len == 0) return error.InvalidTrackerUrl;
    const default_port: u16 = switch (scheme) {
        .https => 443,
        else => 80,
    };
    const port: u16 = if (colon) |c| std.fmt.parseInt(u16, authority[c + 1 ..], 10) catch return error.InvalidTrackerUrl else default_port;
    const q = std.mem.indexOfScalar(u8, path_part, '?');
    const path = if (is_http) path_part else if (q) |qi| path_part[0..qi] else path_part;
    if (is_http and path.len == 0) return error.InvalidTrackerUrl;
    return .{
        .scheme = scheme,
        .host = try allocator.dupe(u8, host),
        .port = port,
        .path = try allocator.dupe(u8, if (path.len == 0) "/" else path),
        .has_query = q != null,
    };
}

/// Stable product identity for HTTP(S) tracker announces (BEP 3 clients identify themselves).
pub const http_user_agent = "nix-torrent/0.3.0";

/// Default peers requested per announce — matches the UDP `num_want` field.
pub const default_numwant: u32 = 50;

/// Stable opaque key for tracker announces (BEP 3 / BEP 15), derived from peer_id.
pub fn announceKeyFromPeerId(peer_id: [20]u8) u32 {
    return std.mem.readInt(u32, peer_id[0..4], .big);
}

pub fn buildAnnouncePath(
    allocator: std.mem.Allocator,
    base_path: []const u8,
    has_query: bool,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    event: Event,
    enc_policy: encryption.Policy,
) ![]u8 {
    const ih = try percentEncode(allocator, &info_hash);
    defer allocator.free(ih);
    const pid = try percentEncode(allocator, &peer_id);
    defer allocator.free(pid);
    const sep: u8 = if (has_query) '&' else '?';
    const event_param = switch (event) {
        .none => "",
        .started => "&event=started",
        .stopped => "&event=stopped",
        .completed => "&event=completed",
    };
    const crypto_param = switch (enc_policy) {
        .disable => "",
        .prefer => "&supportcrypto=1",
        .require => "&supportcrypto=1&requirecrypto=1",
    };
    // BEP 3 optional but widely expected: `numwant` + opaque `key` for multi-client NATs.
    const key = announceKeyFromPeerId(peer_id);
    return std.fmt.allocPrint(allocator, "{s}{c}info_hash={s}&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}&compact=1&numwant={d}&key={d}{s}{s}", .{ base_path, sep, ih, pid, port, uploaded, downloaded, left, default_numwant, key, event_param, crypto_param });
}

/// Formats the HTTP/1.1 announce request line + headers (Host, User-Agent, Connection).
pub fn formatAnnounceHttpRequest(buf: []u8, request_path: []const u8, host: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: {s}\r\nConnection: close\r\n\r\n", .{ request_path, host, http_user_agent });
}

pub fn buildAnnouncePathLegacy(allocator: std.mem.Allocator, base_path: []const u8, info_hash: torrent.InfoHash, peer_id: [20]u8, port: u16, uploaded: u64, downloaded: u64, left: u64) ![]u8 {
    return buildAnnouncePath(allocator, base_path, false, info_hash, peer_id, port, uploaded, downloaded, left, .started, .disable);
}

pub fn announceGet(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    request_path: []const u8,
    timeout_ms: u64,
) !Announce {
    const addr = net.IpAddress{ .ip4 = .{
        .bytes = try resolveHost(io, parsed.host),
        .port = parsed.port,
    } };
    var stream = try tcp.connectStream(io, addr.ip4.bytes, addr.ip4.port, timeout_ms);
    defer stream.close(io);

    var req_buf: [4096]u8 = undefined;
    const req = try formatAnnounceHttpRequest(&req_buf, request_path, parsed.host);

    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(req);
    try writer.interface.flush();

    const body = try tcp.readHttpResponse(io, stream.socket.handle, allocator, timeout_ms);
    defer allocator.free(body);
    return parseAnnounceResponse(allocator, body) catch |err| {
        const preview_len = @min(body.len, 48);
        log.debug("tracker", "HTTP announce parse failed for {s}:{d}: {s} (body_len={d}, prefix={s})", .{
            parsed.host,
            parsed.port,
            @errorName(err),
            body.len,
            body[0..preview_len],
        });
        return err;
    };
}

/// HTTPS announce over TLS 1.2/1.3 using `std.crypto.tls.Client`. Server
/// certificates are verified against the system CA bundle plus an optional
/// extra PEM file (`tracker_ca_file`). There is no insecure verification path.
pub fn announceGetTls(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    request_path: []const u8,
    tracker_ca_file: ?[]const u8,
    timeout_ms: u64,
) !Announce {
    const tls = std.crypto.tls;
    const now = std.Io.Timestamp.now(io, .real);

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(allocator);
    try bundle.rescan(allocator, io, now);
    if (tracker_ca_file) |path| {
        if (std.fs.path.isAbsolute(path))
            try bundle.addCertsFromFilePathAbsolute(allocator, io, now, path)
        else
            try bundle.addCertsFromFilePath(allocator, io, now, std.Io.Dir.cwd(), path);
    }
    var ca_lock: std.Io.RwLock = .init;

    const addr = net.IpAddress{ .ip4 = .{
        .bytes = try resolveHost(io, parsed.host),
        .port = parsed.port,
    } };
    var stream = try tcp.connectStream(io, addr.ip4.bytes, addr.ip4.port, timeout_ms);
    defer stream.close(io);

    const N = tls.Client.min_buffer_len;
    const socket_read = try allocator.alloc(u8, N);
    defer allocator.free(socket_read);
    const socket_write = try allocator.alloc(u8, N);
    defer allocator.free(socket_write);
    const plaintext_read = try allocator.alloc(u8, N + 16 * 1024);
    defer allocator.free(plaintext_read);
    const plaintext_write = try allocator.alloc(u8, N);
    defer allocator.free(plaintext_write);

    var sw = stream.writer(io, socket_write);
    var sr = stream.reader(io, socket_read);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    var client = tls.Client.init(&sr.interface, &sw.interface, .{
        .host = .{ .explicit = parsed.host },
        .ca = .{ .bundle = .{
            .gpa = allocator,
            .io = io,
            .lock = &ca_lock,
            .bundle = &bundle,
        } },
        .read_buffer = plaintext_read,
        .write_buffer = plaintext_write,
        .entropy = &entropy,
        .realtime_now = now,
        // Safe: tracker responses carry Content-Length / chunked framing.
        .allow_truncation_attacks = true,
    }) catch |err| switch (err) {
        error.WriteFailed => return sw.err orelse error.TlsHandshakeFailed,
        error.ReadFailed => return sr.err orelse error.TlsHandshakeFailed,
        else => |e| return e,
    };

    var req_buf: [4096]u8 = undefined;
    const req = try formatAnnounceHttpRequest(&req_buf, request_path, parsed.host);
    try client.writer.writeAll(req);
    try client.writer.flush();
    try sw.interface.flush();

    const raw = client.reader.allocRemaining(allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return sr.err orelse error.TlsReadFailed,
        else => |e| return e,
    };
    defer allocator.free(raw);

    const body = try tcp.extractHttpBody(allocator, raw);
    defer allocator.free(body);
    return parseAnnounceResponse(allocator, body) catch |err| {
        log.debug("tracker", "HTTPS announce parse failed for {s}:{d}: {s} (body_len={d})", .{ parsed.host, parsed.port, @errorName(err), body.len });
        return err;
    };
}

const udp_connect_magic: i64 = 0x0000041727101980;
const udp_connection_ttl_ms: i64 = 50_000;

var udp_tx_seed: u32 = 1;
fn nextTransactionId() u32 {
    udp_tx_seed +%= 1;
    return udp_tx_seed;
}

pub fn announce(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    udp_session: *UdpSession,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    event: Event,
    enc_policy: encryption.Policy,
    tracker_ca_file: ?[]const u8,
    timeout_ms: u64,
    now_ms: i64,
) !Announce {
    return switch (parsed.scheme) {
        .http => {
            const path = try buildAnnouncePath(allocator, parsed.path, parsed.has_query, info_hash, peer_id, port, uploaded, downloaded, left, event, enc_policy);
            defer allocator.free(path);
            return announceGet(io, allocator, parsed, path, timeout_ms);
        },
        .https => {
            const path = try buildAnnouncePath(allocator, parsed.path, parsed.has_query, info_hash, peer_id, port, uploaded, downloaded, left, event, enc_policy);
            defer allocator.free(path);
            return announceGetTls(io, allocator, parsed, path, tracker_ca_file, timeout_ms);
        },
        .udp => announceUdp(io, allocator, parsed, udp_session, info_hash, peer_id, port, uploaded, downloaded, left, event, timeout_ms, now_ms),
    };
}

fn ensureUdpConnection(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    udp_session: *UdpSession,
    timeout_ms: u64,
    now_ms: i64,
) !void {
    if (udp_session.connection_id != 0 and now_ms < udp_session.connection_expires_ms) return;
    const conn_id = try udpConnect(io, allocator, parsed, timeout_ms);
    udp_session.connection_id = conn_id;
    udp_session.connection_expires_ms = now_ms + udp_connection_ttl_ms;
}

pub fn invalidateUdpSession(udp_session: *UdpSession) void {
    udp_session.connection_id = 0;
    udp_session.connection_expires_ms = 0;
}

fn announceUdp(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    udp_session: *UdpSession,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    event: Event,
    timeout_ms: u64,
    now_ms: i64,
) !Announce {
    try ensureUdpConnection(io, allocator, parsed, udp_session, timeout_ms, now_ms);
    var result = try udpAnnounce(io, allocator, parsed, udp_session.connection_id, info_hash, peer_id, port, uploaded, downloaded, left, event, timeout_ms);
    if (result.failure_reason == null) return result;
    // Tracker-side connection_id expiry often surfaces as action=3 ("bad request").
    // Reconnect once before surfacing the failure to the caller.
    result.deinit(allocator);
    invalidateUdpSession(udp_session);
    try ensureUdpConnection(io, allocator, parsed, udp_session, timeout_ms, now_ms);
    return try udpAnnounce(io, allocator, parsed, udp_session.connection_id, info_hash, peer_id, port, uploaded, downloaded, left, event, timeout_ms);
}

fn udpConnect(io: std.Io, allocator: std.mem.Allocator, parsed: AnnounceUrl, timeout_ms: u64) !i64 {
    const transaction_id: u32 = nextTransactionId();
    var req: [16]u8 = undefined;
    std.mem.writeInt(i64, req[0..8], udp_connect_magic, .big);
    std.mem.writeInt(u32, req[8..12], 0, .big);
    std.mem.writeInt(u32, req[12..16], transaction_id, .big);
    const resp = try udpTransact(io, allocator, parsed, &req, timeout_ms);
    defer resp.deinit();
    if (resp.bytes.len < 16) return error.InvalidTrackerResponse;
    const action = std.mem.readInt(u32, resp.bytes[0..4], .big);
    const tx = std.mem.readInt(u32, resp.bytes[4..8], .big);
    if (action == 3) {
        const reason = if (resp.bytes.len > 8) resp.bytes[8..] else "tracker error";
        log.debug("tracker", "UDP connect rejected for {s}:{d}: {s}", .{ parsed.host, parsed.port, reason });
        return error.TrackerFailure;
    }
    if (action != 0 or tx != transaction_id) return error.InvalidTrackerResponse;
    return std.mem.readInt(i64, resp.bytes[8..16], .big);
}

/// Packs a BEP 15 UDP announce request into `buf` (must be at least 98 bytes).
/// Returns the transaction id embedded in the request.
pub fn packUdpAnnounceRequest(
    buf: []u8,
    connection_id: i64,
    transaction_id: u32,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    event: Event,
) u32 {
    std.debug.assert(buf.len >= 98);
    const event_code: u32 = switch (event) {
        .none => 0,
        .completed => 1,
        .started => 2,
        .stopped => 3,
    };
    std.mem.writeInt(i64, buf[0..8], connection_id, .big);
    std.mem.writeInt(u32, buf[8..12], 1, .big);
    std.mem.writeInt(u32, buf[12..16], transaction_id, .big);
    @memcpy(buf[16..36], &info_hash);
    @memcpy(buf[36..56], &peer_id);
    std.mem.writeInt(u64, buf[56..64], downloaded, .big);
    std.mem.writeInt(u64, buf[64..72], left, .big);
    std.mem.writeInt(u64, buf[72..80], uploaded, .big);
    std.mem.writeInt(u32, buf[80..84], event_code, .big);
    std.mem.writeInt(u32, buf[84..88], 0, .big);
    std.mem.writeInt(u32, buf[88..92], announceKeyFromPeerId(peer_id), .big);
    std.mem.writeInt(u32, buf[92..96], default_numwant, .big);
    std.mem.writeInt(u16, buf[96..98], port, .big);
    return transaction_id;
}

fn udpAnnounce(
    io: std.Io,
    allocator: std.mem.Allocator,
    parsed: AnnounceUrl,
    connection_id: i64,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64,
    downloaded: u64,
    left: u64,
    event: Event,
    timeout_ms: u64,
) !Announce {
    const transaction_id: u32 = nextTransactionId();
    var req: [98]u8 = undefined;
    _ = packUdpAnnounceRequest(&req, connection_id, transaction_id, info_hash, peer_id, port, uploaded, downloaded, left, event);
    const resp = try udpTransact(io, allocator, parsed, &req, timeout_ms);
    defer resp.deinit();
    return parseUdpAnnounceResponse(allocator, resp.bytes, transaction_id);
}

const UdpResponse = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    fn deinit(self: UdpResponse) void {
        self.allocator.free(self.bytes);
    }
};

fn udpTransact(io: std.Io, allocator: std.mem.Allocator, parsed: AnnounceUrl, request: []const u8, timeout_ms: u64) !UdpResponse {
    const addr = net.IpAddress{ .ip4 = .{
        .bytes = try resolveHost(io, parsed.host),
        .port = parsed.port,
    } };
    const bind_addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } };
    var socket = try net.IpAddress.bind(&bind_addr, io, .{ .mode = .dgram });
    defer socket.close(io);
    try socket.send(io, &addr, request);
    var buf: [1500]u8 = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromNanoseconds(timeout_ms * std.time.ns_per_ms),
    } };
    const message = try socket.receiveTimeout(io, &buf, timeout);
    const data = try allocator.dupe(u8, message.data);
    return .{ .bytes = data, .allocator = allocator };
}

pub fn parseUdpAnnounceResponse(allocator: std.mem.Allocator, bytes: []const u8, transaction_id: u32) !Announce {
    if (bytes.len < 8) return error.InvalidTrackerResponse;
    const action = std.mem.readInt(u32, bytes[0..4], .big);
    const tx = std.mem.readInt(u32, bytes[4..8], .big);
    if (action == 3) {
        const reason = if (bytes.len > 8) bytes[8..] else "tracker error";
        return .{
            .interval = 0,
            .peers = try allocator.alloc(Peer, 0),
            .failure_reason = try allocator.dupe(u8, reason),
        };
    }
    if (action != 1 or tx != transaction_id or bytes.len < 20) return error.InvalidTrackerResponse;
    const interval = std.mem.readInt(u32, bytes[8..12], .big);
    const peers_bytes = bytes[20..];
    const peers = try parseCompactPeers(allocator, peers_bytes, null);
    return .{ .interval = interval, .peers = peers };
}

pub fn trackerShowStatus(tr: TrackerState) []const u8 {
    if (tr.last_error != null) return "error";
    if (tr.started_sent) return "ok";
    return "pending";
}

fn resolveHost(io: std.Io, host: []const u8) ![4]u8 {
    return dns.resolveIpv4(io, host);
}

pub fn parseAnnounceResponse(allocator: std.mem.Allocator, bytes: []const u8) !Announce {
    const root = try bencode.parse(allocator, bytes);
    defer root.deinit(allocator);
    if (root != .dict) return error.InvalidTrackerResponse;

    if (root.dictGet("failure reason")) |value| {
        if (value == .string) {
            return .{
                .interval = 0,
                .peers = try allocator.alloc(Peer, 0),
                .failure_reason = try allocator.dupe(u8, value.string),
            };
        }
    }

    const interval_v = root.dictGet("interval") orelse return error.InvalidTrackerResponse;
    const interval: u64 = switch (interval_v) {
        .int => |i| if (i > 0) @intCast(i) else return error.InvalidTrackerResponse,
        else => return error.InvalidTrackerResponse,
    };
    const peers_v = root.dictGet("peers") orelse return error.InvalidTrackerResponse;
    const peers4 = switch (peers_v) {
        .string => |compact| try parseCompactPeers(allocator, compact, root.dictGet("crypto_flags")),
        .list => |list| try parseDictionaryPeers(allocator, list),
        else => return error.InvalidTrackerResponse,
    };
    defer allocator.free(peers4);

    // BEP 7: optional compact `peers6` alongside IPv4 peers.
    const peers6: []Peer = if (root.dictGet("peers6")) |v6| switch (v6) {
        .string => |compact6| parseCompactPeers6(allocator, compact6) catch try allocator.alloc(Peer, 0),
        else => try allocator.alloc(Peer, 0),
    } else try allocator.alloc(Peer, 0);
    defer allocator.free(peers6);

    const peers = try allocator.alloc(Peer, peers4.len + peers6.len);
    @memcpy(peers[0..peers4.len], peers4);
    @memcpy(peers[peers4.len..], peers6);

    const crypto_flags = if (peers_v == .string) blk: {
        if (root.dictGet("crypto_flags")) |flags_v| {
            if (flags_v == .string) break :blk try allocator.dupe(u8, flags_v.string);
        }
        break :blk null;
    } else null;
    return .{ .interval = interval, .peers = peers, .crypto_flags = crypto_flags };
}

pub fn peerAllowedForEncryption(peer: Peer, policy: encryption.Policy) bool {
    return switch (policy) {
        .require => peer.crypto_required,
        else => true,
    };
}

pub fn peerConnectPriority(peer: Peer) u8 {
    return if (peer.crypto_required) 0 else 1;
}

pub fn sortPeersForEncryption(allocator: std.mem.Allocator, peers: []const Peer, policy: encryption.Policy) ![]Peer {
    if (policy != .prefer or peers.len <= 1) return allocator.dupe(Peer, peers);
    const sorted = try allocator.dupe(Peer, peers);
    const Context = struct {
        fn less(_: void, a: Peer, b: Peer) bool {
            return peerConnectPriority(a) < peerConnectPriority(b);
        }
    };
    std.mem.sort(Peer, sorted, {}, Context.less);
    return sorted;
}

pub fn parseCompactPeers(allocator: std.mem.Allocator, bytes: []const u8, crypto_flags_v: ?bencode.Value) ![]Peer {
    if (bytes.len % 6 != 0) return error.InvalidCompactPeers;
    const peers = try allocator.alloc(Peer, bytes.len / 6);
    const flag_bytes = if (crypto_flags_v) |v| switch (v) {
        .string => |s| s,
        else => &[_]u8{},
    } else &[_]u8{};
    for (peers, 0..) |*peer, i| {
        const off = i * 6;
        peer.* = .{
            .ip = .{ .v4 = .{ bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3] } },
            .port = std.mem.readInt(u16, bytes[off + 4 .. off + 6][0..2], .big),
            .crypto_required = i < flag_bytes.len and flag_bytes[i] != 0,
        };
    }
    return peers;
}

/// Parses BEP 7 compact `peers6` (18-byte entries: 16-byte IPv6 + 2-byte port).
pub fn parseCompactPeers6(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 18 != 0) return error.InvalidCompactPeers;
    const peers = try allocator.alloc(Peer, bytes.len / 18);
    for (peers, 0..) |*peer, i| {
        const off = i * 18;
        var v6: [16]u8 = undefined;
        @memcpy(&v6, bytes[off .. off + 16]);
        peer.* = .{
            .ip = .{ .v6 = v6 },
            .port = std.mem.readInt(u16, bytes[off + 16 .. off + 18][0..2], .big),
        };
    }
    return peers;
}

fn parseDictionaryPeers(allocator: std.mem.Allocator, list: []bencode.Value) ![]Peer {
    var peers = try allocator.alloc(Peer, list.len);
    errdefer allocator.free(peers);
    for (list, 0..) |value, i| {
        if (value != .dict) return error.InvalidTrackerResponse;
        const ip_s = switch (value.dictGet("ip") orelse return error.InvalidTrackerResponse) { .string => |s| s, else => return error.InvalidTrackerResponse };
        const port_i = switch (value.dictGet("port") orelse return error.InvalidTrackerResponse) { .int => |p| p, else => return error.InvalidTrackerResponse };
        if (port_i <= 0 or port_i > 65535) return error.InvalidTrackerResponse;
        const port: u16 = @intCast(port_i);
        if (std.mem.indexOfScalar(u8, ip_s, ':') != null) {
            // IPv6 literal.
            const parsed = net.Ip6Address.parse(ip_s, port) catch return error.InvalidTrackerResponse;
            peers[i] = .{ .ip = .{ .v6 = parsed.bytes }, .port = port };
        } else {
            var parts = std.mem.splitScalar(u8, ip_s, '.');
            var ip: [4]u8 = undefined;
            var n: usize = 0;
            while (parts.next()) |part| : (n += 1) {
                if (n >= 4) return error.InvalidTrackerResponse;
                ip[n] = try std.fmt.parseInt(u8, part, 10);
            }
            if (n != 4) return error.InvalidTrackerResponse;
            peers[i] = .{ .ip = .{ .v4 = ip }, .port = port };
        }
    }
    return peers;
}

fn percentEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (bytes) |byte| {
        if ((byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '.' or byte == '-' or byte == '_' or byte == '~') {
            try out.append(allocator, byte);
        } else {
            const encoded = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{byte});
            defer allocator.free(encoded);
            try out.appendSlice(allocator, encoded);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "parses compact tracker peers" {
    const peers = try parseCompactPeers(std.testing.allocator, &.{ 127, 0, 0, 1, 0x1A, 0xE1 }, null);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].port);
}

test "parses announce interval and compact peers" {
    const response = "d8:intervali1800e5:peers6:\x7f\x00\x00\x01\x1a\xe1e";
    const result = try parseAnnounceResponse(std.testing.allocator, response);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1800), result.interval);
    try std.testing.expectEqual(@as(u8, 127), result.peers[0].ip.v4[0]);
}

test "parses announce peers6 alongside peers" {
    // peers6 with a single ::1-style entry (16 bytes + 2 port).
    const response = "d8:intervali1800e5:peers6:\x7f\x00\x00\x01\x1a\xe16:peers618:\x20\x01\x0d\xb8\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x1a\xe1e";
    const result = try parseAnnounceResponse(std.testing.allocator, response);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.peers.len);
    try std.testing.expect(result.peers[0].ip == .v4);
    try std.testing.expect(result.peers[1].ip == .v6);
}

test "builds announce path with and without existing query parameters" {
    const ih: torrent.InfoHash = [_]u8{1} ** 20;
    const pid: [20]u8 = [_]u8{2} ** 20;
    const plain = try buildAnnouncePath(std.testing.allocator, "/announce", false, ih, pid, 6881, 0, 0, 100, .started, .prefer);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.startsWith(u8, plain, "/announce?info_hash="));
    try std.testing.expect(std.mem.indexOf(u8, plain, "&event=started") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "&supportcrypto=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "&numwant=50") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "&key=") != null);

    const with_query = try buildAnnouncePath(std.testing.allocator, "/announce?pass=key", true, ih, pid, 6881, 0, 0, 100, .none, .require);
    defer std.testing.allocator.free(with_query);
    try std.testing.expect(std.mem.startsWith(u8, with_query, "/announce?pass=key&info_hash="));
    try std.testing.expect(std.mem.indexOf(u8, with_query, "&event=") == null);
}

test "HTTP announce request includes User-Agent" {
    var buf: [512]u8 = undefined;
    const req = try formatAnnounceHttpRequest(&buf, "/announce?info_hash=ab", "tracker.example");
    try std.testing.expect(std.mem.indexOf(u8, req, "User-Agent: nix-torrent/0.3.0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: tracker.example\r\n") != null);
    try std.testing.expect(std.mem.startsWith(u8, req, "GET /announce?info_hash=ab HTTP/1.1\r\n"));
}

test "parses http tracker announce url" {
    const parsed = try parseAnnounceUrl(std.testing.allocator, "http://tracker.example:8080/path/announce?pass=abc");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("tracker.example", parsed.host);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port);
    try std.testing.expect(parsed.has_query);
    try std.testing.expectEqualStrings("/path/announce?pass=abc", parsed.path);
}

test "parses dictionary ipv4 peer responses" {
    const response = "d8:intervali60e5:peersld2:ip13:192.168.0.1004:porti6881eeee";
    const dict_result = try parseAnnounceResponse(std.testing.allocator, response);
    defer dict_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), dict_result.peers.len);
    try std.testing.expectEqual(@as(u8, 192), dict_result.peers[0].ip.v4[0]);
    try std.testing.expectEqual(@as(u16, 6881), dict_result.peers[0].port);
}

test "parses https tracker announce url with default port 443" {
    const parsed = try parseAnnounceUrl(std.testing.allocator, "https://tracker.example/announce");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Scheme.https, parsed.scheme);
    try std.testing.expectEqualStrings("tracker.example", parsed.host);
    try std.testing.expectEqual(@as(u16, 443), parsed.port);
    try std.testing.expectEqualStrings("/announce", parsed.path);
}

test "https and http and udp are supported schemes" {
    try std.testing.expect(isSupportedTrackerScheme("https://t.example/announce"));
    try std.testing.expect(isSupportedTrackerScheme("http://t.example/announce"));
    try std.testing.expect(isSupportedTrackerScheme("udp://t.example:6969"));
    try std.testing.expect(!isSupportedTrackerScheme("wss://t.example"));
}

test "parses udp tracker announce url" {
    const parsed = try parseAnnounceUrl(std.testing.allocator, "udp://tracker.example:6969/announce");
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Scheme.udp, parsed.scheme);
    try std.testing.expectEqualStrings("tracker.example", parsed.host);
    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
    try std.testing.expectEqualStrings("/announce", parsed.path);
}

test "parses udp announce response" {
    var buf: [26]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .big);
    std.mem.writeInt(u32, buf[4..8], 42, .big);
    std.mem.writeInt(u32, buf[8..12], 1800, .big);
    std.mem.writeInt(u32, buf[12..16], 0, .big);
    std.mem.writeInt(u32, buf[16..20], 0, .big);
    @memcpy(buf[20..26], &[_]u8{ 127, 0, 0, 1, 0x1A, 0xE1 });
    const udp_result = try parseUdpAnnounceResponse(std.testing.allocator, &buf, 42);
    defer udp_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1800), udp_result.interval);
    try std.testing.expectEqual(@as(usize, 1), udp_result.peers.len);
    try std.testing.expectEqual(@as(u16, 6881), udp_result.peers[0].port);
}

test "parses udp announce action=3 error with reason" {
    const err_msg = "bad request";
    var buf: [8 + err_msg.len]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 3, .big);
    std.mem.writeInt(u32, buf[4..8], 99, .big);
    @memcpy(buf[8..], err_msg);
    const result = try parseUdpAnnounceResponse(std.testing.allocator, &buf, 99);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.failure_reason != null);
    try std.testing.expectEqualStrings("bad request", result.failure_reason.?);
    try std.testing.expectEqual(@as(usize, 0), result.peers.len);
}

test "packUdpAnnounceRequest uses stable key from peer_id" {
    const ih: torrent.InfoHash = [_]u8{0xAA} ** 20;
    const pid: [20]u8 = .{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14 };
    var buf: [98]u8 = undefined;
    _ = packUdpAnnounceRequest(&buf, 0x1234567890ABCDEF, 42, ih, pid, 6881, 100, 200, 300, .started);
    try std.testing.expectEqual(@as(i64, 0x1234567890ABCDEF), std.mem.readInt(i64, buf[0..8], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, buf[8..12], .big));
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, buf[12..16], .big));
    try std.testing.expectEqualSlices(u8, &ih, buf[16..36]);
    try std.testing.expectEqualSlices(u8, &pid, buf[36..56]);
    try std.testing.expectEqual(@as(u64, 200), std.mem.readInt(u64, buf[56..64], .big));
    try std.testing.expectEqual(@as(u64, 300), std.mem.readInt(u64, buf[64..72], .big));
    try std.testing.expectEqual(@as(u64, 100), std.mem.readInt(u64, buf[72..80], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[80..84], .big)); // started
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[84..88], .big)); // IP default
    try std.testing.expectEqual(announceKeyFromPeerId(pid), std.mem.readInt(u32, buf[88..92], .big));
    try std.testing.expectEqual(default_numwant, std.mem.readInt(u32, buf[92..96], .big));
    try std.testing.expectEqual(@as(u16, 6881), std.mem.readInt(u16, buf[96..98], .big));
}

test "announceKeyFromPeerId matches HTTP key" {
    const pid: [20]u8 = .{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), announceKeyFromPeerId(pid));
}

test "invalidateUdpSession clears connection state" {
    var session: UdpSession = .{ .connection_id = 99, .connection_expires_ms = 12345 };
    invalidateUdpSession(&session);
    try std.testing.expectEqual(@as(i64, 0), session.connection_id);
    try std.testing.expectEqual(@as(i64, 0), session.connection_expires_ms);
}
