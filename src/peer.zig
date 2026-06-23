const std = @import("std");
const torrent = @import("torrent.zig");

pub const MessageId = enum(u8) { choke = 0, unchoke = 1, interested = 2, not_interested = 3, have = 4, bitfield = 5, request = 6, piece = 7, cancel = 8 };

pub const Message = union(enum) {
    keepalive,
    choke,
    unchoke,
    interested,
    not_interested,
    have: u32,
    bitfield: []const u8,
    request: BlockRef,
    piece: PieceBlock,
    cancel: BlockRef,
};

pub const BlockRef = struct { index: u32, begin: u32, length: u32 };
pub const PieceBlock = struct { index: u32, begin: u32, block: []const u8 };

pub const PeerState = struct {
    choking: bool = true,
    interested: bool = false,
    peer_choking: bool = true,
    peer_interested: bool = false,

    pub fn apply(self: *PeerState, message: Message) void {
        switch (message) {
            .choke => self.peer_choking = true,
            .unchoke => self.peer_choking = false,
            .interested => self.peer_interested = true,
            .not_interested => self.peer_interested = false,
            else => {},
        }
    }
};

pub fn encodeHandshake(out: *[68]u8, info_hash: torrent.InfoHash, peer_id: [20]u8) void {
    out[0] = 19;
    @memcpy(out[1..20], "BitTorrent protocol");
    @memset(out[20..28], 0);
    @memcpy(out[28..48], &info_hash);
    @memcpy(out[48..68], &peer_id);
}

pub fn decodeHandshake(bytes: []const u8) !struct { info_hash: torrent.InfoHash, peer_id: [20]u8 } {
    if (bytes.len != 68 or bytes[0] != 19 or !std.mem.eql(u8, bytes[1..20], "BitTorrent protocol")) return error.InvalidHandshake;
    return .{ .info_hash = bytes[28..48].*, .peer_id = bytes[48..68].* };
}

pub fn encodeMessage(allocator: std.mem.Allocator, msg: Message) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (msg) {
        .keepalive => try writeLen(&out, allocator, 0),
        .choke, .unchoke, .interested, .not_interested => {
            try writeLen(&out, allocator, 1);
            try out.append(allocator, @intFromEnum(simpleId(msg)));
        },
        .have => |index| {
            try writeLen(&out, allocator, 5);
            try out.append(allocator, @intFromEnum(MessageId.have));
            try writeU32(&out, allocator, index);
        },
        .bitfield => |bits| {
            try writeLen(&out, allocator, @intCast(1 + bits.len));
            try out.append(allocator, @intFromEnum(MessageId.bitfield));
            try out.appendSlice(allocator, bits);
        },
        .request => |r| try encodeBlockRef(&out, allocator, .request, r),
        .cancel => |r| try encodeBlockRef(&out, allocator, .cancel, r),
        .piece => |p| {
            try writeLen(&out, allocator, @intCast(9 + p.block.len));
            try out.append(allocator, @intFromEnum(MessageId.piece));
            try writeU32(&out, allocator, p.index);
            try writeU32(&out, allocator, p.begin);
            try out.appendSlice(allocator, p.block);
        },
    }
    return out.toOwnedSlice(allocator);
}

pub fn decodeMessage(bytes: []const u8) !Message {
    if (bytes.len < 4) return error.ShortMessage;
    const len = std.mem.readInt(u32, bytes[0..4], .big);
    if (len == 0) return .keepalive;
    if (bytes.len != 4 + len) return error.ShortMessage;
    const id: MessageId = @enumFromInt(bytes[4]);
    const payload = bytes[5..];
    return switch (id) {
        .choke => .choke,
        .unchoke => .unchoke,
        .interested => .interested,
        .not_interested => .not_interested,
        .have => .{ .have = std.mem.readInt(u32, payload[0..4], .big) },
        .bitfield => .{ .bitfield = payload },
        .request => .{ .request = parseBlockRef(payload) },
        .cancel => .{ .cancel = parseBlockRef(payload) },
        .piece => .{ .piece = .{ .index = std.mem.readInt(u32, payload[0..4], .big), .begin = std.mem.readInt(u32, payload[4..8], .big), .block = payload[8..] } },
    };
}

fn simpleId(msg: Message) MessageId {
    return switch (msg) { .choke => .choke, .unchoke => .unchoke, .interested => .interested, .not_interested => .not_interested, else => unreachable };
}
fn encodeBlockRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: MessageId, r: BlockRef) !void {
    try writeLen(out, allocator, 13);
    try out.append(allocator, @intFromEnum(id));
    try writeU32(out, allocator, r.index);
    try writeU32(out, allocator, r.begin);
    try writeU32(out, allocator, r.length);
}
fn parseBlockRef(payload: []const u8) BlockRef { return .{ .index = std.mem.readInt(u32, payload[0..4], .big), .begin = std.mem.readInt(u32, payload[4..8], .big), .length = std.mem.readInt(u32, payload[8..12], .big) }; }
fn writeLen(out: *std.ArrayList(u8), allocator: std.mem.Allocator, len: u32) !void { try writeU32(out, allocator, len); }
fn writeU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void { var b: [4]u8 = undefined; std.mem.writeInt(u32, &b, value, .big); try out.appendSlice(allocator, &b); }

test "encodes and decodes handshake" {
    var ih: torrent.InfoHash = [_]u8{1} ** 20;
    var pid: [20]u8 = [_]u8{2} ** 20;
    var buf: [68]u8 = undefined;
    encodeHandshake(&buf, ih, pid);
    const decoded = try decodeHandshake(&buf);
    try std.testing.expectEqualSlices(u8, &ih, &decoded.info_hash);
    try std.testing.expectEqualSlices(u8, &pid, &decoded.peer_id);
}

test "encodes and decodes core messages" {
    const encoded = try encodeMessage(std.testing.allocator, .{ .request = .{ .index = 7, .begin = 16, .length = 16384 } });
    defer std.testing.allocator.free(encoded);
    const decoded = try decodeMessage(encoded);
    try std.testing.expectEqual(@as(u32, 7), decoded.request.index);
}
