const std = @import("std");
const bencode = @import("bencode.zig");
const config = @import("config.zig");

pub const InfoHash = [20]u8;

pub const File = struct {
    length: u64,
    path: []const []const u8,
};

pub const Mode = union(enum) {
    single_file: u64,
    multi_file: []File,
};

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    root: bencode.Value,
    announce: ?[]const u8,
    private_torrent: bool = false,
    name: []const u8,
    piece_length: u64,
    pieces: []const u8,
    info_hash: InfoHash,
    mode: Mode,

    pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Metadata {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
        errdefer allocator.free(bytes);
        return parseOwnedBytes(allocator, bytes);
    }

    pub fn parseBytes(allocator: std.mem.Allocator, input: []const u8) !Metadata {
        const bytes = try allocator.dupe(u8, input);
        errdefer allocator.free(bytes);
        return parseOwnedBytes(allocator, bytes);
    }

    pub fn deinit(self: Metadata) void {
        switch (self.mode) {
            .multi_file => |files| {
                for (files) |file| self.allocator.free(file.path);
                self.allocator.free(files);
            },
            else => {},
        }
        self.root.deinit(self.allocator);
        self.allocator.free(self.bytes);
    }
};

pub const Error = error{
    RootMustBeDictionary,
    MissingInfo,
    InfoMustBeDictionary,
    MissingName,
    MissingPieceLength,
    MissingPieces,
    InvalidName,
    InvalidPieceLength,
    InvalidPieces,
    InvalidLength,
    InvalidFiles,
    InvalidFilePath,
    AmbiguousFileMode,
};

pub const LimitError = error{
    TorrentFileTooLarge,
    ContentTooLarge,
    TooManyFiles,
    PathTooDeep,
    PathComponentTooLong,
    PieceTooLarge,
    TooManyPieces,
};

pub fn contentBytes(meta: Metadata) u64 {
    return switch (meta.mode) {
        .single_file => |len| len,
        .multi_file => |files| blk: {
            var total: u64 = 0;
            for (files) |file| total += file.length;
            break :blk total;
        },
    };
}

pub fn validateLimits(meta: Metadata, limits: config.Limits, torrent_file_bytes: usize) LimitError!void {
    if (torrent_file_bytes > limits.max_torrent_file_bytes) return LimitError.TorrentFileTooLarge;
    const total = contentBytes(meta);
    if (total > limits.max_content_bytes) return LimitError.ContentTooLarge;
    if (meta.piece_length > limits.max_piece_bytes) return LimitError.PieceTooLarge;
    const piece_count = meta.pieces.len / 20;
    if (piece_count > limits.max_piece_count) return LimitError.TooManyPieces;
    switch (meta.mode) {
        .single_file => {
            if (meta.name.len > limits.max_path_component_bytes) return LimitError.PathComponentTooLong;
        },
        .multi_file => |files| {
            if (files.len > limits.max_files_per_torrent) return LimitError.TooManyFiles;
            for (files) |file| {
                if (file.path.len > limits.max_path_depth) return LimitError.PathTooDeep;
                for (file.path) |component| {
                    if (component.len > limits.max_path_component_bytes) return LimitError.PathComponentTooLong;
                }
            }
        },
    }
}

fn parseOwnedBytes(allocator: std.mem.Allocator, bytes: []const u8) !Metadata {
    const root = try bencode.parse(allocator, bytes);
    errdefer root.deinit(allocator);

    if (root != .dict) return Error.RootMustBeDictionary;
    const info = root.dictGet("info") orelse return Error.MissingInfo;
    if (info != .dict) return Error.InfoMustBeDictionary;

    const name = requiredString(info, "name", Error.MissingName, Error.InvalidName) catch |err| return err;
    if (name.len == 0) return Error.InvalidName;

    const piece_length = requiredPositiveInt(info, "piece length", Error.MissingPieceLength, Error.InvalidPieceLength) catch |err| return err;
    const pieces = requiredString(info, "pieces", Error.MissingPieces, Error.InvalidPieces) catch |err| return err;
    if (pieces.len == 0 or pieces.len % 20 != 0) return Error.InvalidPieces;

    var hash: InfoHash = undefined;
    std.crypto.hash.Sha1.hash(info.dict.raw, &hash, .{});

    const has_length = info.dictGet("length") != null;
    const has_files = info.dictGet("files") != null;
    if (has_length == has_files) return Error.AmbiguousFileMode;

    const mode: Mode = if (has_length)
        .{ .single_file = requiredPositiveInt(info, "length", Error.InvalidLength, Error.InvalidLength) catch return Error.InvalidLength }
    else
        .{ .multi_file = try parseFiles(allocator, info.dictGet("files").?) };
    errdefer switch (mode) {
        .multi_file => |files| {
            for (files) |file| allocator.free(file.path);
            allocator.free(files);
        },
        else => {},
    };

    const announce = if (root.dictGet("announce")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const private_torrent = if (info.dictGet("private")) |v| switch (v) {
        .int => |i| i != 0,
        else => false,
    } else false;

    return .{
        .allocator = allocator,
        .bytes = bytes,
        .root = root,
        .announce = announce,
        .private_torrent = private_torrent,
        .name = name,
        .piece_length = piece_length,
        .pieces = pieces,
        .info_hash = hash,
        .mode = mode,
    };
}

fn requiredString(dict: bencode.Value, key: []const u8, missing_error: Error, invalid_error: Error) Error![]const u8 {
    const value = dict.dictGet(key) orelse return missing_error;
    return switch (value) {
        .string => |s| s,
        else => invalid_error,
    };
}

fn requiredPositiveInt(dict: bencode.Value, key: []const u8, missing_error: Error, invalid_error: Error) Error!u64 {
    const value = dict.dictGet(key) orelse return missing_error;
    const int = switch (value) {
        .int => |i| i,
        else => return invalid_error,
    };
    if (int <= 0) return invalid_error;
    return @intCast(int);
}

fn parseFiles(allocator: std.mem.Allocator, value: bencode.Value) ![]File {
    if (value != .list or value.list.len == 0) return Error.InvalidFiles;
    var files = try allocator.alloc(File, value.list.len);
    errdefer allocator.free(files);
    var filled: usize = 0;
    errdefer for (files[0..filled]) |file| allocator.free(file.path);

    for (value.list, 0..) |file_value, i| {
        if (file_value != .dict) return Error.InvalidFiles;
        const length = requiredPositiveInt(file_value, "length", Error.InvalidLength, Error.InvalidLength) catch return Error.InvalidLength;
        const path_value = file_value.dictGet("path") orelse return Error.InvalidFilePath;
        if (path_value != .list or path_value.list.len == 0) return Error.InvalidFilePath;
        const path = try allocator.alloc([]const u8, path_value.list.len);
        errdefer allocator.free(path);
        for (path_value.list, 0..) |component, j| {
            path[j] = switch (component) {
                .string => |s| if (s.len == 0 or std.mem.indexOfScalar(u8, s, '/') != null) return Error.InvalidFilePath else s,
                else => return Error.InvalidFilePath,
            };
        }
        files[i] = .{ .length = length, .path = path };
        filled += 1;
    }
    return files;
}

pub fn infoHashFromInfoBytes(info_bytes: []const u8) InfoHash {
    var hash: InfoHash = undefined;
    std.crypto.hash.Sha1.hash(info_bytes, &hash, .{});
    return hash;
}

pub fn wrapInfoBytes(allocator: std.mem.Allocator, info_bytes: []const u8, announce: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 'd');
    if (announce) |url| {
        try out.appendSlice(allocator, "8:announce");
        const len_prefix = try std.fmt.allocPrint(allocator, "{d}:", .{url.len});
        defer allocator.free(len_prefix);
        try out.appendSlice(allocator, len_prefix);
        try out.appendSlice(allocator, url);
    }
    try out.appendSlice(allocator, "4:info");
    try out.appendSlice(allocator, info_bytes);
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

fn expectHashHex(actual: InfoHash, expected_hex: []const u8) !void {
    const encoded = std.fmt.bytesToHex(actual, .lower);
    try std.testing.expectEqualStrings(expected_hex, &encoded);
}

test "parses single-file fixture and computes info hash from raw info dictionary" {
    const fixture = @embedFile("fixtures/single-file.torrent");
    const metadata = try Metadata.parseBytes(std.testing.allocator, fixture);
    defer metadata.deinit();

    try std.testing.expectEqualStrings("tiny.txt", metadata.name);
    try std.testing.expectEqual(@as(u64, 4), metadata.piece_length);
    try std.testing.expectEqual(@as(usize, 20), metadata.pieces.len);
    try expectHashHex(metadata.info_hash, "78fc7061455539a27d6ccc8241e09d325850d9e5");
    try std.testing.expectEqual(@as(u64, 4), metadata.mode.single_file);
}

test "parses multi-file fixture" {
    const fixture = @embedFile("fixtures/multi-file.torrent");
    const metadata = try Metadata.parseBytes(std.testing.allocator, fixture);
    defer metadata.deinit();

    try std.testing.expectEqualStrings("bundle", metadata.name);
    try expectHashHex(metadata.info_hash, "39e80df97ad002eec55285fbaf4853b85e68d845");
    const files = metadata.mode.multi_file;
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("dir", files[0].path[0]);
    try std.testing.expectEqualStrings("a.txt", files[0].path[1]);
    try std.testing.expectEqual(@as(u64, 5), files[1].length);
}

test "rejects invalid pieces length" {
    try std.testing.expectError(Error.InvalidPieces, Metadata.parseBytes(std.testing.allocator, "d4:infod6:lengthi1e4:name1:x12:piece lengthi1e6:pieces3:abcee"));
}

test "rejects torrent metadata that exceeds configured limits" {
    const fixture = @embedFile("fixtures/single-file.torrent");
    const metadata = try Metadata.parseBytes(std.testing.allocator, fixture);
    defer metadata.deinit();
    var limits = config.Limits{};
    limits.max_content_bytes = 1;
    try std.testing.expectError(LimitError.ContentTooLarge, validateLimits(metadata, limits, fixture.len));
}
