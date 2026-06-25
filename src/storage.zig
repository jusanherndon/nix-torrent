const std = @import("std");
const torrent = @import("torrent.zig");

pub const PieceState = enum { missing, in_progress, verified };

pub const Segment = struct {
    file_index: usize,
    file_offset: u64,
    piece_offset: u64,
    length: usize,
};

pub const PathError = error{
    ZeroLengthFile,
    UnsafePath,
    DuplicatePath,
    PathCollision,
};

pub const IOError = error{
    PieceHashMismatch,
    ShortRead,
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

pub fn validatePaths(allocator: std.mem.Allocator, meta: torrent.Metadata) !void {
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |p| allocator.free(p);
        dirs.deinit(allocator);
    }

    switch (meta.mode) {
        .single_file => |length| {
            if (length == 0) return PathError.ZeroLengthFile;
            try validateComponent(meta.name);
            if (std.fs.path.isAbsolute(meta.name)) return PathError.UnsafePath;
        },
        .multi_file => |items| {
            for (items) |file| {
                if (file.length == 0) return PathError.ZeroLengthFile;
                if (file.path.len == 0) return PathError.UnsafePath;
                var partial: std.ArrayList([]const u8) = .empty;
                defer partial.deinit(allocator);
                for (file.path, 0..) |component, i| {
                    try validateComponent(component);
                    try partial.append(allocator, component);
                    const joined = try std.fs.path.join(allocator, partial.items);
                    if (i + 1 == file.path.len) {
                        if (containsPath(dirs.items, joined)) {
                            allocator.free(joined);
                            return PathError.PathCollision;
                        }
                        if (containsPath(files.items, joined)) {
                            allocator.free(joined);
                            return PathError.DuplicatePath;
                        }
                        try files.append(allocator, joined);
                    } else {
                        if (containsPath(files.items, joined)) {
                            allocator.free(joined);
                            return PathError.PathCollision;
                        }
                        if (!containsPath(dirs.items, joined)) try dirs.append(allocator, joined) else allocator.free(joined);
                    }
                }
            }
        },
    }
}

fn containsPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |path| if (std.mem.eql(u8, path, needle)) return true;
    return false;
}

fn validateComponent(component: []const u8) !void {
    if (component.len == 0) return PathError.UnsafePath;
    if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return PathError.UnsafePath;
    if (std.mem.indexOfScalar(u8, component, '/') != null) return PathError.UnsafePath;
    if (std.mem.indexOfScalar(u8, component, '\\') != null) return PathError.UnsafePath;
}

pub fn createStagedFiles(io: std.Io, allocator: std.mem.Allocator, content_root: []const u8, meta: torrent.Metadata) !void {
    try validatePaths(allocator, meta);
    try std.Io.Dir.cwd().createDirPath(io, content_root);
    switch (meta.mode) {
        .single_file => |length| {
            const path = try std.fs.path.join(allocator, &.{ content_root, meta.name });
            defer allocator.free(path);
            try createSizedFile(io, path, length);
        },
        .multi_file => |files| {
            for (files) |file| {
                const rel = try relativePath(allocator, file.path);
                defer allocator.free(rel);
                const full = try std.fs.path.join(allocator, &.{ content_root, rel });
                defer allocator.free(full);
                if (std.fs.path.dirname(full)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
                try createSizedFile(io, full, file.length);
            }
        },
    }
}

pub fn writeVerifiedPiece(io: std.Io, allocator: std.mem.Allocator, content_root: []const u8, meta: torrent.Metadata, layout: *Layout, piece_index: usize, data: []const u8) !void {
    const span = layout.pieceSpan(piece_index);
    if (data.len != span.length) return IOError.ShortRead;
    if (!pieceHashMatches(meta, piece_index, data)) return IOError.PieceHashMismatch;

    const segments = try layout.mapPiece(allocator, piece_index);
    defer allocator.free(segments);
    for (segments) |segment| {
        const path = try filePathForIndex(allocator, content_root, meta, segment.file_index);
        defer allocator.free(path);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write, .allow_directory = false });
        defer file.close(io);
        try file.writePositionalAll(io, data[segment.piece_offset..][0..segment.length], segment.file_offset);
    }
    layout.mark(piece_index, .verified);
}

pub fn readPiece(io: std.Io, allocator: std.mem.Allocator, content_root: []const u8, meta: torrent.Metadata, layout: Layout, piece_index: usize) ![]u8 {
    const span = layout.pieceSpan(piece_index);
    const out = try allocator.alloc(u8, span.length);
    errdefer allocator.free(out);
    const segments = try layout.mapPiece(allocator, piece_index);
    defer allocator.free(segments);
    for (segments) |segment| {
        const path = try filePathForIndex(allocator, content_root, meta, segment.file_index);
        defer allocator.free(path);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false });
        defer file.close(io);
        const got = try file.readPositionalAll(io, out[segment.piece_offset..][0..segment.length], segment.file_offset);
        if (got != segment.length) return IOError.ShortRead;
    }
    return out;
}

pub fn recheck(io: std.Io, allocator: std.mem.Allocator, content_root: []const u8, meta: torrent.Metadata, layout: *Layout) !void {
    for (layout.piece_states, 0..) |_, i| {
        const bytes = readPiece(io, allocator, content_root, meta, layout.*, i) catch |err| switch (err) {
            error.FileNotFound, IOError.ShortRead => {
                layout.mark(i, .missing);
                continue;
            },
            else => return err,
        };
        defer allocator.free(bytes);
        layout.mark(i, if (pieceHashMatches(meta, i, bytes)) .verified else .missing);
    }
}

fn createSizedFile(io: std.Io, path: []const u8, length: u64) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size == length) return;
    if (length == 0) return PathError.ZeroLengthFile;
    if (length > 0) {
        try file.writePositionalAll(io, &.{0}, length - 1);
    }
}

fn filePathForIndex(allocator: std.mem.Allocator, content_root: []const u8, meta: torrent.Metadata, file_index: usize) ![]u8 {
    switch (meta.mode) {
        .single_file => return std.fs.path.join(allocator, &.{ content_root, meta.name }),
        .multi_file => |files| {
            const rel = try relativePath(allocator, files[file_index].path);
            defer allocator.free(rel);
            return std.fs.path.join(allocator, &.{ content_root, rel });
        },
    }
}

fn relativePath(allocator: std.mem.Allocator, components: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, components);
}

fn pieceHashMatches(meta: torrent.Metadata, piece_index: usize, data: []const u8) bool {
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &digest, .{});
    const expected = meta.pieces[piece_index * 20 ..][0..20];
    return std.mem.eql(u8, &digest, expected);
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

test "rejects unsafe storage paths" {
    const meta_bytes = "d4:infod5:filesld6:lengthi1e4:pathl2:..5:a.txteee4:name6:bundle12:piece lengthi1e6:pieces20:aaaaaaaaaaaaaaaaaaaaee";
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    try std.testing.expectError(PathError.UnsafePath, validatePaths(std.testing.allocator, meta));
}

test "rejects duplicate storage paths" {
    const meta_bytes = "d4:infod5:filesld6:lengthi1e4:pathl5:a.txteed6:lengthi1e4:pathl5:a.txteee4:name6:bundle12:piece lengthi1e6:pieces20:aaaaaaaaaaaaaaaaaaaaee";
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    try std.testing.expectError(PathError.DuplicatePath, validatePaths(std.testing.allocator, meta));
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

fn testTorrentBytes(allocator: std.mem.Allocator, name: []const u8, piece_length: u64, length: u64, content: []const u8) ![]u8 {
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(content, &hash, .{});
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const prefix = try std.fmt.allocPrint(allocator, "d4:infod6:lengthi{d}e4:name{d}:{s}12:piece lengthi{d}e6:pieces20:", .{ length, name.len, name, piece_length });
    defer allocator.free(prefix);
    try bytes.appendSlice(allocator, prefix);
    try bytes.appendSlice(allocator, &hash);
    try bytes.appendSlice(allocator, "ee");
    return bytes.toOwnedSlice(allocator);
}

fn tmpContentRoot(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
}

test "creates staged single-file tree and writes verified piece" {
    const meta_bytes = try testTorrentBytes(std.testing.allocator, "tiny.txt", 4, 4, "abcd");
    defer std.testing.allocator.free(meta_bytes);
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    var layout = try Layout.init(std.testing.allocator, meta);
    defer layout.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpContentRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);

    try createStagedFiles(std.testing.io, std.testing.allocator, root, meta);
    try writeVerifiedPiece(std.testing.io, std.testing.allocator, root, meta, &layout, 0, "abcd");
    const piece = try readPiece(std.testing.io, std.testing.allocator, root, meta, layout, 0);
    defer std.testing.allocator.free(piece);

    try std.testing.expectEqualStrings("abcd", piece);
    try std.testing.expectEqual(PieceState.verified, layout.piece_states[0]);
}

test "recheck detects corrupt staged data" {
    const meta_bytes = try testTorrentBytes(std.testing.allocator, "tiny.txt", 4, 4, "abcd");
    defer std.testing.allocator.free(meta_bytes);
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    var layout = try Layout.init(std.testing.allocator, meta);
    defer layout.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpContentRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);

    try createStagedFiles(std.testing.io, std.testing.allocator, root, meta);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "tiny.txt" });
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "wxyz", .flags = .{ .truncate = true } });

    try recheck(std.testing.io, std.testing.allocator, root, meta, &layout);
    try std.testing.expectEqual(PieceState.missing, layout.piece_states[0]);
}
