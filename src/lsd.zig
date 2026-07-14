//! Local Service Discovery (BEP 14).
//!
//! Non-private torrents multicast a `BT-SEARCH` announce on the LAN and listen
//! for announces from other clients, merging discovered peers into the
//! candidate set. Private torrents never announce or listen.

const std = @import("std");

/// IPv4 LSD multicast group and port (BEP 14).
pub const group_v4: [4]u8 = .{ 239, 192, 152, 143 };
pub const port: u16 = 6771;

/// Build a `BT-SEARCH` announce datagram for a single info hash (lowercase hex).
pub fn buildAnnounce(allocator: std.mem.Allocator, info_hash_hex: []const u8, listen_port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "BT-SEARCH * HTTP/1.1\r\n" ++
        "Host: 239.192.152.143:6771\r\n" ++
        "Port: {d}\r\n" ++
        "Infohash: {s}\r\n" ++
        "\r\n\r\n",
        .{ listen_port, info_hash_hex },
    );
}

pub const Announce = struct {
    port: u16,
    /// First info hash found in the announce (lowercase hex, 40 chars).
    info_hash_hex: [40]u8,
};

/// Parse a received `BT-SEARCH` announce. Returns null if it is not a valid
/// LSD announce (wrong verb, missing port/infohash, malformed hash).
pub fn parseAnnounce(msg: []const u8) ?Announce {
    if (!std.mem.startsWith(u8, msg, "BT-SEARCH")) return null;
    var found_port: ?u16 = null;
    var found_hash: ?[40]u8 = null;
    var lines = std.mem.splitSequence(u8, msg, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "Port")) {
            found_port = std.fmt.parseInt(u16, value, 10) catch continue;
        } else if (std.ascii.eqlIgnoreCase(key, "Infohash")) {
            if (value.len == 40 and isHex(value)) {
                var h: [40]u8 = undefined;
                for (value, 0..) |ch, i| h[i] = std.ascii.toLower(ch);
                found_hash = h;
            }
        }
    }
    const p = found_port orelse return null;
    const h = found_hash orelse return null;
    return .{ .port = p, .info_hash_hex = h };
}

fn isHex(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

test "builds and parses an lsd announce" {
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const msg = try buildAnnounce(std.testing.allocator, hex, 6881);
    defer std.testing.allocator.free(msg);
    const parsed = parseAnnounce(msg) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 6881), parsed.port);
    try std.testing.expectEqualStrings(hex, &parsed.info_hash_hex);
}

test "rejects non-bt-search datagrams" {
    try std.testing.expect(parseAnnounce("GET / HTTP/1.1\r\n\r\n") == null);
}

test "rejects announce missing infohash" {
    try std.testing.expect(parseAnnounce("BT-SEARCH * HTTP/1.1\r\nPort: 6881\r\n\r\n") == null);
}

test "uppercase hex infohash is normalized to lowercase" {
    const msg = "BT-SEARCH * HTTP/1.1\r\nPort: 51413\r\nInfohash: ABCDEF0123456789ABCDEF0123456789ABCDEF01\r\n\r\n";
    const parsed = parseAnnounce(msg) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", &parsed.info_hash_hex);
}
