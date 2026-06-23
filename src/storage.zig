const std = @import("std");
const torrent = @import("torrent.zig");

pub const PieceState = enum { missing, in_progress, verified };

pub const Segment = struct {
    file_index: usize,
    file_offset: u64,
    piece_offset: u64,
    length: usize,
};

pub const Layout = struct {
    allocator: std.mem.Allocator,
    file_lengths: []u64,
    piece_length: u64,
    total_length: u64,
    piece_states: []PieceState,

    pub fn init(allocator: std.mem.Allocator, meta: torrent.Metadata) !Layout {
        const lengths = switch (meta.mode) {
            .single_file => |length| blk: {
                const out = try allocator.alloc(u64, 1);
                out[0] = length;
                break :blk out;
            },
            .multi_file => |files| blk: {
                const out = try allocator.alloc(u64, files.len);
                for (files, 0..) |file, i| out[i] = file.length;
                break :blk out;
            },
        };
        errdefer allocator.free(lengths);

        var total: u64 = 0;
        for (lengths) |len| total += len;
        const pieces = try allocator.alloc(PieceState, meta.pieces.len / 20);
        @memset(pieces, .missing);
        return .{ .allocator = allocator, .file_lengths = lengths, .piece_length = meta.piece_length, .total_length = total, .piece_states = pieces };
    }

    pub fn deinit(self: Layout) void {
        self.allocator.free(self.file_lengths);
        self.allocator.free(self.piece_states);
    }

    pub fn pieceSpan(self: Layout, piece_index: usize) struct { offset: u64, length: usize } {
        const offset = @as(u64, @intCast(piece_index)) * self.piece_length;
        const remaining = self.total_length - offset;
        return .{ .offset = offset, .length = @intCast(@min(self.piece_length, remaining)) };
    }

    pub fn mapPiece(self: Layout, allocator: std.mem.Allocator, piece_index: usize) ![]Segment {
        const span = self.pieceSpan(piece_index);
        var wanted_start = span.offset;
        var remaining = span.length;
        var file_start: u64 = 0;
        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(allocator);

        for (self.file_lengths, 0..) |file_len, file_index| {
            const file_end = file_start + file_len;
            if (wanted_start < file_end and remaining > 0) {
                const within = wanted_start - file_start;
                const available = file_len - within;
                const take: usize = @intCast(@min(available, remaining));
                try segments.append(allocator, .{ .file_index = file_index, .file_offset = within, .piece_offset = span.length - remaining, .length = take });
                wanted_start += take;
                remaining -= take;
            }
            file_start = file_end;
            if (remaining == 0) break;
        }
        return segments.toOwnedSlice(allocator);
    }

    pub fn mark(self: *Layout, piece_index: usize, state: PieceState) void {
        self.piece_states[piece_index] = state;
    }

    pub fn complete(self: Layout) bool {
        for (self.piece_states) |state| if (state != .verified) return false;
        return true;
    }
};

pub fn stagingTorrentDir(allocator: std.mem.Allocator, staging_root: []const u8, info_hash: torrent.InfoHash) ![]u8 {
    const hex = std.fmt.bytesToHex(info_hash, .lower);
    return std.fs.path.join(allocator, &.{ staging_root, &hex });
}

test "maps multi-file piece spans across file boundaries" {
    const meta_bytes = "d4:infod5:filesld6:lengthi3e4:pathl5:a.txteed6:lengthi5e4:pathl5:b.txteee4:name6:bundle12:piece lengthi4e6:pieces20:aaaaaaaaaaaaaaaaaaaaee";
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    var layout = try Layout.init(std.testing.allocator, meta);
    defer layout.deinit();

    const segments = try layout.mapPiece(std.testing.allocator, 0);
    defer std.testing.allocator.free(segments);
    try std.testing.expectEqual(@as(usize, 2), segments.len);
    try std.testing.expectEqual(@as(usize, 3), segments[0].length);
    try std.testing.expectEqual(@as(usize, 1), segments[1].length);
}

test "tracks verified missing and in-progress pieces in memory" {
    const meta_bytes = "d4:infod6:lengthi8e4:name4:file12:piece lengthi4e6:pieces40:aaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbee";
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    var layout = try Layout.init(std.testing.allocator, meta);
    defer layout.deinit();

    try std.testing.expectEqual(PieceState.missing, layout.piece_states[0]);
    layout.mark(0, .in_progress);
    layout.mark(0, .verified);
    layout.mark(1, .verified);
    try std.testing.expect(layout.complete());
}
