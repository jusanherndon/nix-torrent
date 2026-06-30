const std = @import("std");
const torrent = @import("torrent.zig");

const net = std.Io.net;

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
    available: std.DynamicBitSetUnmanaged = .{},

    pub fn deinit(self: *PeerState, allocator: std.mem.Allocator) void {
        self.available.deinit(allocator);
    }

    pub fn setBitfield(self: *PeerState, allocator: std.mem.Allocator, piece_count: usize, bits: []const u8) !void {
        try self.available.resize(allocator, piece_count, false);
        for (0..piece_count) |i| {
            const byte = bits[i / 8];
            const mask: u8 = @as(u8, 1) << @intCast(7 - (i % 8));
            if (byte & mask != 0) self.available.set(i);
        }
    }

    pub fn setHave(self: *PeerState, allocator: std.mem.Allocator, piece_count: usize, index: u32) !void {
        if (@as(usize, @intCast(index)) >= piece_count) return;
        if (self.available.bit_length < piece_count) try self.available.resize(allocator, piece_count, false);
        self.available.set(@intCast(index));
    }

    pub fn hasPiece(self: PeerState, index: usize) bool {
        return index < self.available.bit_length and self.available.isSet(index);
    }

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

pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,
    peer_ip: [4]u8,
    peer_port: u16,
    state: PeerState,
    recv_buffer: std.ArrayList(u8),
    handshake_done: bool = false,
    closed: bool = false,

    pub fn connect(io: std.Io, allocator: std.mem.Allocator, ip: [4]u8, port: u16, timeout_ms: u64) !Connection {
        const addr = net.IpAddress{ .ip4 = .{ .bytes = ip, .port = port } };
        const stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream });
        _ = timeout_ms;
        return .{
            .allocator = allocator,
            .stream = stream,
            .peer_ip = ip,
            .peer_port = port,
            .state = .{},
            .recv_buffer = .empty,
        };
    }

    pub fn deinit(self: *Connection, io: std.Io) void {
        if (!self.closed) self.stream.close(io);
        self.state.deinit(self.allocator);
        self.recv_buffer.deinit(self.allocator);
    }

    pub fn close(self: *Connection, io: std.Io) void {
        if (!self.closed) {
            self.stream.close(io);
            self.closed = true;
        }
    }

    pub fn performHandshake(self: *Connection, io: std.Io, info_hash: torrent.InfoHash, peer_id: [20]u8) !void {
        var out: [68]u8 = undefined;
        encodeHandshake(&out, info_hash, peer_id);
        try self.sendRaw(io, &out);

        var in: [68]u8 = undefined;
        try readExact(io, self.stream, &in);
        const decoded = try decodeHandshake(&in);
        if (!std.mem.eql(u8, &decoded.info_hash, &info_hash)) return error.InfoHashMismatch;
        self.handshake_done = true;
    }

    pub fn sendInterested(self: *Connection, io: std.Io) !void {
        const msg = try encodeMessage(self.allocator, .interested);
        defer self.allocator.free(msg);
        try self.sendRaw(io, msg);
    }

    pub fn sendRequest(self: *Connection, io: std.Io, block: BlockRef) !void {
        const msg = try encodeMessage(self.allocator, .{ .request = block });
        defer self.allocator.free(msg);
        try self.sendRaw(io, msg);
    }

    pub fn sendRaw(self: *Connection, io: std.Io, bytes: []const u8) !void {
        var write_buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(io, &write_buffer);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    pub fn readMessage(self: *Connection, io: std.Io, max_message_bytes: u64) !?Message {
        while (true) {
            if (try self.tryDecodeMessage(max_message_bytes)) |msg| return msg;
            const n = try self.readMore(io);
            if (n == 0) return null;
        }
    }

    fn readMore(self: *Connection, io: std.Io) !usize {
        var buf: [4096]u8 = undefined;
        var reader = self.stream.reader(io, &buf);
        const n = try reader.interface.readSliceShort(&buf);
        if (n == 0) return 0;
        try self.recv_buffer.appendSlice(self.allocator, buf[0..n]);
        return n;
    }

    fn tryDecodeMessage(self: *Connection, max_message_bytes: u64) !?Message {
        const data = self.recv_buffer.items;
        if (data.len < 4) return null;
        const len = std.mem.readInt(u32, data[0..4], .big);
        if (len > max_message_bytes) return error.OversizedMessage;
        const frame_len = 4 + @as(usize, @intCast(len));
        if (data.len < frame_len) return null;
        const frame = data[0..frame_len];
        const msg = decodeMessage(frame) catch return error.MalformedMessage;
        if (msg == .request) return error.PeerSentRequest;
        try self.recv_buffer.replaceRange(self.allocator, 0, frame_len, &.{});
        return msg;
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

fn readExact(io: std.Io, stream: net.Stream, buf: []u8) !void {
    var got: usize = 0;
    var read_buffer: [256]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    while (got < buf.len) {
        const n = reader.interface.readSliceShort(buf[got..]) catch return error.ShortMessage;
        if (n == 0) return error.ShortMessage;
        got += n;
    }
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

test "tracks peer bitfield and have updates" {
    var ps: PeerState = .{};
    defer ps.deinit(std.testing.allocator);
    try ps.setBitfield(std.testing.allocator, 8, &[_]u8{ 0b1000_0000, 0 });
    try std.testing.expect(ps.hasPiece(0));
    try std.testing.expect(!ps.hasPiece(1));
    try ps.setHave(std.testing.allocator, 8, 3);
    try std.testing.expect(ps.hasPiece(3));
}

test "rejects oversized peer messages" {
    var conn = Connection{
        .allocator = std.testing.allocator,
        .stream = undefined,
        .peer_ip = .{ 127, 0, 0, 1 },
        .peer_port = 6881,
        .state = .{},
        .recv_buffer = .empty,
    };
    defer conn.recv_buffer.deinit(std.testing.allocator);
    defer conn.state.deinit(std.testing.allocator);
    var frame: [8]u8 = undefined;
    std.mem.writeInt(u32, frame[0..4], 2_000_000, .big);
    try conn.recv_buffer.appendSlice(std.testing.allocator, &frame);
    try std.testing.expectError(error.OversizedMessage, conn.tryDecodeMessage(1_048_576));
}

test "closes peer connection when peer sends request" {
    var conn = Connection{
        .allocator = std.testing.allocator,
        .stream = undefined,
        .peer_ip = .{ 127, 0, 0, 1 },
        .peer_port = 6881,
        .state = .{},
        .recv_buffer = .empty,
    };
    defer conn.recv_buffer.deinit(std.testing.allocator);
    defer conn.state.deinit(std.testing.allocator);
    const encoded = try encodeMessage(std.testing.allocator, .{ .request = .{ .index = 0, .begin = 0, .length = 16384 } });
    defer std.testing.allocator.free(encoded);
    try conn.recv_buffer.appendSlice(std.testing.allocator, encoded);
    try std.testing.expectError(error.PeerSentRequest, conn.tryDecodeMessage(15_728_640));
}
