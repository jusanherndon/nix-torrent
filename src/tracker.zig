const std = @import("std");
const bencode = @import("bencode.zig");
const torrent = @import("torrent.zig");

pub const Peer = struct { ip: [4]u8, port: u16 };
pub const Announce = struct {
    interval: u64,
    peers: []Peer,
    failure_reason: ?[]const u8 = null,

    pub fn deinit(self: Announce, allocator: std.mem.Allocator) void {
        allocator.free(self.peers);
    }
};

pub fn buildAnnouncePath(allocator: std.mem.Allocator, base_path: []const u8, info_hash: torrent.InfoHash, peer_id: [20]u8, port: u16, uploaded: u64, downloaded: u64, left: u64) ![]u8 {
    const ih = try percentEncode(allocator, &info_hash);
    defer allocator.free(ih);
    const pid = try percentEncode(allocator, &peer_id);
    defer allocator.free(pid);
    return std.fmt.allocPrint(allocator, "{s}?info_hash={s}&peer_id={s}&port={d}&uploaded={d}&downloaded={d}&left={d}&compact=1&event=started", .{ base_path, ih, pid, port, uploaded, downloaded, left });
}

pub fn parseAnnounceResponse(allocator: std.mem.Allocator, bytes: []const u8) !Announce {
    const root = try bencode.parse(allocator, bytes);
    defer root.deinit(allocator);
    if (root != .dict) return error.InvalidTrackerResponse;

    if (root.dictGet("failure reason")) |value| {
        if (value == .string) return .{ .interval = 0, .peers = try allocator.alloc(Peer, 0), .failure_reason = value.string };
    }

    const interval_v = root.dictGet("interval") orelse return error.InvalidTrackerResponse;
    const interval: u64 = switch (interval_v) { .int => |i| if (i > 0) @intCast(i) else return error.InvalidTrackerResponse, else => return error.InvalidTrackerResponse };
    const peers_v = root.dictGet("peers") orelse return error.InvalidTrackerResponse;
    const peers = switch (peers_v) {
        .string => |compact| try parseCompactPeers(allocator, compact),
        .list => |list| try parseDictionaryPeers(allocator, list),
        else => return error.InvalidTrackerResponse,
    };
    return .{ .interval = interval, .peers = peers };
}

pub fn parseCompactPeers(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 6 != 0) return error.InvalidCompactPeers;
    const peers = try allocator.alloc(Peer, bytes.len / 6);
    for (peers, 0..) |*peer, i| {
        const off = i * 6;
        peer.* = .{ .ip = .{ bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3] }, .port = std.mem.readInt(u16, bytes[off + 4 .. off + 6][0..2], .big) };
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
        var parts = std.mem.splitScalar(u8, ip_s, '.');
        var ip: [4]u8 = undefined;
        var n: usize = 0;
        while (parts.next()) |part| : (n += 1) {
            if (n >= 4) return error.InvalidTrackerResponse;
            ip[n] = try std.fmt.parseInt(u8, part, 10);
        }
        if (n != 4 or port_i <= 0 or port_i > 65535) return error.InvalidTrackerResponse;
        peers[i] = .{ .ip = ip, .port = @intCast(port_i) };
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
            try out.writer(allocator).print("%{X:0>2}", .{byte});
        }
    }
    return out.toOwnedSlice(allocator);
}

test "parses compact tracker peers" {
    const peers = try parseCompactPeers(std.testing.allocator, &.{ 127, 0, 0, 1, 0x1A, 0xE1 });
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].port);
}

test "parses announce interval and compact peers" {
    const response = "d8:intervali1800e5:peers6:\x7f\x00\x00\x01\x1a\xe1e";
    const announce = try parseAnnounceResponse(std.testing.allocator, response);
    defer announce.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1800), announce.interval);
    try std.testing.expectEqual(@as(u8, 127), announce.peers[0].ip[0]);
}
