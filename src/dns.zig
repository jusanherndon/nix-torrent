const std = @import("std");
const address = @import("address.zig");

const net = std.Io.net;
const c = std.c;

pub const ResolveError = error{
    InvalidHostName,
    UnknownHostName,
    NoIpv4Address,
    NoIpv6Address,
    NoAddress,
};

/// Resolves a hostname or IPv4 literal to four address bytes.
pub fn resolveIpv4(io: std.Io, host: []const u8) ResolveError![4]u8 {
    _ = io;
    if (net.Ip4Address.parse(host, 0)) |ip4| return ip4.bytes else |_| {}

    if (host.len == 0 or host.len > net.HostName.max_len) return error.InvalidHostName;
    var host_buf: [net.HostName.max_len:0]u8 = undefined;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    const hints = c.addrinfo{
        .flags = .{},
        .family = c.AF.INET,
        .socktype = c.SOCK.DGRAM,
        .protocol = c.IPPROTO.UDP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };

    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_buf[0..host.len :0].ptr, null, &hints, &res);
    if (@intFromEnum(rc) != 0) return error.UnknownHostName;
    defer if (res) |first| c.freeaddrinfo(first);

    var node = res;
    while (node) |entry| : (node = entry.next) {
        if (entry.family != c.AF.INET) continue;
        const addr: *const c.sockaddr.in = @ptrCast(@alignCast(entry.addr));
        const bytes = @as(*const [4]u8, @ptrCast(&addr.addr));
        return bytes.*;
    }
    return error.NoIpv4Address;
}

/// Resolves a hostname or IPv6 literal to sixteen address bytes (AAAA).
pub fn resolveIpv6(io: std.Io, host: []const u8) ResolveError![16]u8 {
    _ = io;
    if (net.Ip6Address.parse(host, 0)) |ip6| return ip6.bytes else |_| {}

    if (host.len == 0 or host.len > net.HostName.max_len) return error.InvalidHostName;
    var host_buf: [net.HostName.max_len:0]u8 = undefined;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    const hints = c.addrinfo{
        .flags = .{},
        .family = c.AF.INET6,
        .socktype = c.SOCK.DGRAM,
        .protocol = c.IPPROTO.UDP,
        .addrlen = 0,
        .canonname = null,
        .addr = null,
        .next = null,
    };

    var res: ?*c.addrinfo = null;
    const rc = c.getaddrinfo(host_buf[0..host.len :0].ptr, null, &hints, &res);
    if (@intFromEnum(rc) != 0) return error.UnknownHostName;
    defer if (res) |first| c.freeaddrinfo(first);

    var node = res;
    while (node) |entry| : (node = entry.next) {
        if (entry.family != c.AF.INET6) continue;
        const addr: *const c.sockaddr.in6 = @ptrCast(@alignCast(entry.addr));
        return addr.addr;
    }
    return error.NoIpv6Address;
}

/// Resolves a host to a dual-stack IP, preferring IPv4 then falling back to IPv6.
/// Trackers and DHT bootstrap use this so hostnames with only AAAA records still work.
pub fn resolveAddress(io: std.Io, host: []const u8, port: u16) ResolveError!address.Address {
    if (resolveIpv4(io, host)) |v4| {
        return address.Address.v4(v4, port);
    } else |_| {}
    if (resolveIpv6(io, host)) |v6| {
        return address.Address.v6(v6, port);
    } else |_| {}
    return error.NoAddress;
}

test "resolves ipv4 literals without dns" {
    const ip = try resolveIpv4(std.testing.io, "127.0.0.1");
    try std.testing.expectEqual(@as(u8, 127), ip[0]);
    try std.testing.expectEqual(@as(u8, 1), ip[3]);
}

test "resolves public tracker hostnames" {
    const ip = resolveIpv4(std.testing.io, "tracker.opentrackr.org") catch return error.SkipZigTest;
    _ = ip;
}

test "resolves ipv6 literals without dns" {
    const ip = try resolveIpv6(std.testing.io, "2001:db8::1");
    try std.testing.expectEqual(@as(u8, 0x20), ip[0]);
    try std.testing.expectEqual(@as(u8, 0x01), ip[1]);
    try std.testing.expectEqual(@as(u8, 1), ip[15]);
}

test "resolveAddress prefers ipv4 literal" {
    const addr = try resolveAddress(std.testing.io, "127.0.0.1", 6881);
    try std.testing.expect(addr.ip == .v4);
    try std.testing.expectEqual(@as(u16, 6881), addr.port);
}
