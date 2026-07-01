const std = @import("std");
const tracker = @import("tracker.zig");

pub const Magnet = struct {
    info_hash_hex: [40]u8,
    display_name: ?[]const u8,
    tracker_urls: []const []const u8,
    unsupported_urls: []const []const u8,
};

pub const ParseError = error{
    InvalidMagnet,
    InvalidInfoHash,
    UnsupportedTrackerScheme,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, uri: []const u8) ParseError!Magnet {
    if (!std.mem.startsWith(u8, uri, "magnet:?")) return ParseError.InvalidMagnet;
    const query = uri["magnet:?".len..];
    var display_name: ?[]const u8 = null;
    var trackers: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (trackers.items) |u| allocator.free(u);
        trackers.deinit(allocator);
    }
    var unsupported: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unsupported.items) |u| allocator.free(u);
        unsupported.deinit(allocator);
    }
    var info_hash_hex: ?[40]u8 = null;

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |param| {
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        const raw_val = param[eq + 1 ..];
        const val = percentDecode(allocator, raw_val) catch continue;
        defer allocator.free(val);
        if (std.mem.eql(u8, key, "xt")) {
            const prefix = "urn:btih:";
            if (!std.mem.startsWith(u8, val, prefix)) return ParseError.InvalidInfoHash;
            const hash_part = val[prefix.len..];
            info_hash_hex = normalizeInfoHash(hash_part) catch return ParseError.InvalidInfoHash;
        } else if (std.mem.eql(u8, key, "dn")) {
            if (display_name) |old| allocator.free(old);
            display_name = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "tr")) {
            if (tracker.isSupportedTrackerScheme(val)) {
                try trackers.append(allocator, try allocator.dupe(u8, val));
            } else {
                try unsupported.append(allocator, try allocator.dupe(u8, val));
            }
        } else if (std.mem.eql(u8, key, "xs")) {
            try unsupported.append(allocator, try allocator.dupe(u8, val));
        }
    }

    const hex = info_hash_hex orelse return ParseError.InvalidInfoHash;
    return .{
        .info_hash_hex = hex,
        .display_name = display_name,
        .tracker_urls = try trackers.toOwnedSlice(allocator),
        .unsupported_urls = try unsupported.toOwnedSlice(allocator),
    };
}

pub fn deinit(m: Magnet, allocator: std.mem.Allocator) void {
    if (m.display_name) |n| allocator.free(n);
    for (m.tracker_urls) |u| allocator.free(u);
    allocator.free(m.tracker_urls);
    for (m.unsupported_urls) |u| allocator.free(u);
    allocator.free(m.unsupported_urls);
}

pub fn normalizeInfoHash(input: []const u8) ! [40]u8 {
    if (input.len == 40) {
        var out: [40]u8 = undefined;
        for (input, 0..) |c, i| {
            out[i] = std.ascii.toLower(c);
            if (!std.ascii.isHex(out[i])) return error.InvalidInfoHash;
        }
        return out;
    }
    if (input.len == 32) {
        var raw: [20]u8 = undefined;
        try decodeBase32(input, &raw);
        return std.fmt.bytesToHex(raw, .lower);
    }
    return error.InvalidInfoHash;
}

pub fn infoHashBytes(hex: []const u8) ![20]u8 {
    if (hex.len != 40) return error.InvalidInfoHash;
    var out: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);
    return out;
}

fn percentDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const byte = std.fmt.parseInt(u8, input[i + 1 .. i + 3], 16) catch return error.InvalidEncoding;
            try out.append(allocator, byte);
            i += 3;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

const base32_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

fn decodeBase32(input: []const u8, out: *[20]u8) !void {
    var buffer: u64 = 0;
    var bits: u6 = 0;
    var written: usize = 0;
    for (input) |c| {
        const upper = std.ascii.toUpper(c);
        const val = std.mem.indexOfScalar(u8, base32_alphabet, upper) orelse return error.InvalidBase32;
        buffer = (buffer << 5) | @as(u64, @intCast(val));
        bits += 5;
        while (bits >= 8 and written < 20) {
            bits -= 8;
            out[written] = @intCast((buffer >> @intCast(bits)) & 0xFF);
            written += 1;
        }
    }
    if (written != 20) return error.InvalidBase32;
}

test "normalizes hex info hash" {
    const hex = try normalizeInfoHash("78FC7061455539A27D6CCC8241E09D325850D9E5");
    try std.testing.expectEqualStrings("78fc7061455539a27d6ccc8241e09d325850d9e5", &hex);
}

test "parses magnet uri trackers and display name" {
    const m = try parse(std.testing.allocator, "magnet:?xt=urn:btih:78fc7061455539a27d6ccc8241e09d325850d9e5&dn=tiny&tr=udp%3A%2F%2F127.0.0.1%3A6969%2Fannounce");
    defer deinit(m, std.testing.allocator);
    try std.testing.expectEqualStrings("78fc7061455539a27d6ccc8241e09d325850d9e5", &m.info_hash_hex);
    try std.testing.expectEqualStrings("tiny", m.display_name.?);
    try std.testing.expectEqual(@as(usize, 1), m.tracker_urls.len);
}
