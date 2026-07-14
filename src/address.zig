const std = @import("std");

const net = std.Io.net;

/// Dual-stack peer/node IP: either a 4-byte IPv4 or a 16-byte IPv6 address.
pub const Ip = union(enum) {
    v4: [4]u8,
    v6: [16]u8,

    pub fn eql(a: Ip, b: Ip) bool {
        return switch (a) {
            .v4 => |av| switch (b) {
                .v4 => |bv| std.mem.eql(u8, &av, &bv),
                .v6 => false,
            },
            .v6 => |av| switch (b) {
                .v6 => |bv| std.mem.eql(u8, &av, &bv),
                .v4 => false,
            },
        };
    }

    pub fn family(self: Ip) []const u8 {
        return switch (self) {
            .v4 => "ipv4",
            .v6 => "ipv6",
        };
    }
};

/// A dual-stack peer endpoint (IP + TCP/UDP port).
pub const Address = struct {
    ip: Ip,
    port: u16,

    pub fn v4(bytes: [4]u8, port: u16) Address {
        return .{ .ip = .{ .v4 = bytes }, .port = port };
    }

    pub fn v6(bytes: [16]u8, port: u16) Address {
        return .{ .ip = .{ .v6 = bytes }, .port = port };
    }

    pub fn eql(a: Address, b: Address) bool {
        return a.port == b.port and Ip.eql(a.ip, b.ip);
    }

    pub fn toIpAddress(self: Address) net.IpAddress {
        return switch (self.ip) {
            .v4 => |bytes| .{ .ip4 = .{ .bytes = bytes, .port = self.port } },
            .v6 => |bytes| .{ .ip6 = .{ .bytes = bytes, .port = self.port } },
        };
    }

    pub fn fromIpAddress(addr: net.IpAddress) Address {
        return switch (addr) {
            .ip4 => |ip4| .{ .ip = .{ .v4 = ip4.bytes }, .port = ip4.port },
            .ip6 => |ip6| .{ .ip = .{ .v6 = ip6.bytes }, .port = ip6.port },
        };
    }

    /// Renders the address for logs, e.g. "1.2.3.4:6881" or "[2001:db8::1]:6881".
    pub fn render(self: Address, buf: []u8) []const u8 {
        const ip_addr = self.toIpAddress();
        return std.fmt.bufPrint(buf, "{f}", .{ip_addr}) catch buf[0..0];
    }
};

/// Rejects unroutable / garbage compact-peer entries for both families.
pub fn isRoutable(addr: Address) bool {
    if (addr.port == 0) return false;
    return switch (addr.ip) {
        .v4 => |ip| routableV4(ip),
        .v6 => |ip| routableV6(ip),
    };
}

fn routableV4(ip: [4]u8) bool {
    if (ip[0] == 0) return false; // 0.0.0.0/8
    if (ip[0] == 127) return false; // 127.0.0.0/8 loopback
    if (ip[0] == 255 and ip[1] == 255 and ip[2] == 255 and ip[3] == 255) return false; // broadcast
    return true;
}

fn routableV6(ip: [16]u8) bool {
    // Unspecified ::
    if (std.mem.allEqual(u8, &ip, 0)) return false;
    // Loopback ::1
    var loopback = true;
    for (ip[0..15]) |b| {
        if (b != 0) {
            loopback = false;
            break;
        }
    }
    if (loopback and ip[15] == 1) return false;
    // IPv4-mapped that maps to an unroutable v4
    if (std.mem.eql(u8, ip[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        return routableV4(ip[12..16].*);
    }
    return true;
}

test "isRoutable rejects garbage for both families" {
    try std.testing.expect(!isRoutable(Address.v4(.{ 127, 0, 0, 1 }, 6881)));
    try std.testing.expect(!isRoutable(Address.v4(.{ 0, 0, 0, 0 }, 6881)));
    try std.testing.expect(!isRoutable(Address.v4(.{ 255, 255, 255, 255 }, 45353)));
    try std.testing.expect(!isRoutable(Address.v4(.{ 1, 2, 3, 4 }, 0)));
    try std.testing.expect(isRoutable(Address.v4(.{ 1, 2, 3, 4 }, 6881)));

    const unspecified = [_]u8{0} ** 16;
    try std.testing.expect(!isRoutable(Address.v6(unspecified, 6881)));
    var loopback = [_]u8{0} ** 16;
    loopback[15] = 1;
    try std.testing.expect(!isRoutable(Address.v6(loopback, 6881)));
    var global = [_]u8{0} ** 16;
    global[0] = 0x20;
    global[1] = 0x01;
    global[15] = 1;
    try std.testing.expect(isRoutable(Address.v6(global, 6881)));
}

test "address round trips through net.IpAddress" {
    const a = Address.v4(.{ 10, 0, 0, 5 }, 51413);
    const round = Address.fromIpAddress(a.toIpAddress());
    try std.testing.expect(Address.eql(a, round));

    var b6 = [_]u8{0} ** 16;
    b6[0] = 0x20;
    b6[15] = 9;
    const b = Address.v6(b6, 6881);
    const roundb = Address.fromIpAddress(b.toIpAddress());
    try std.testing.expect(Address.eql(b, roundb));
}

test "format renders both families" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1.2.3.4:6881", Address.v4(.{ 1, 2, 3, 4 }, 6881).render(&buf));
}
