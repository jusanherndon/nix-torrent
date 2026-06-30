const std = @import("std");
const torrent = @import("torrent.zig");

pub const Completion = struct {
    info_hash_hex: []const u8,
    final_path: []const u8,
    completed_at_ms: i64,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    completions: std.ArrayList(Completion) = .empty,

    pub fn init(allocator: std.mem.Allocator) History { return .{ .allocator = allocator }; }
    pub fn deinit(self: *History) void {
        for (self.completions.items) |item| {
            self.allocator.free(item.info_hash_hex);
            self.allocator.free(item.final_path);
        }
        self.completions.deinit(self.allocator);
    }
    pub fn record(self: *History, info_hash_hex: []const u8, final_path: []const u8, completed_at_ms: i64) !void {
        try self.completions.append(self.allocator, .{
            .info_hash_hex = try self.allocator.dupe(u8, info_hash_hex),
            .final_path = try self.allocator.dupe(u8, final_path),
            .completed_at_ms = completed_at_ms,
        });
    }
};

pub fn finalPath(allocator: std.mem.Allocator, final_root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ final_root, name });
}

pub fn moveCompletedTree(src: []const u8, dst: []const u8) !void {
    try std.fs.cwd().rename(src, dst);
}

pub fn moveCompletedContent(io: std.Io, allocator: std.mem.Allocator, content_dir: []const u8, meta: torrent.Metadata, final_root: []const u8) ![]u8 {
    try std.Io.Dir.cwd().createDirPath(io, final_root);
    switch (meta.mode) {
        .single_file => {
            const src = try std.fs.path.join(allocator, &.{ content_dir, meta.name });
            defer allocator.free(src);
            const dst = try std.fs.path.join(allocator, &.{ final_root, meta.name });
            errdefer allocator.free(dst);
            if (pathExists(io, dst)) return error.DestinationExists;
            try renamePath(io, src, dst);
            return dst;
        },
        .multi_file => {
            const dst = try std.fs.path.join(allocator, &.{ final_root, meta.name });
            errdefer allocator.free(dst);
            if (pathExists(io, dst)) return error.DestinationExists;
            try renamePath(io, content_dir, dst);
            return dst;
        },
    }
}

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn renamePath(io: std.Io, src: []const u8, dst: []const u8) !void {
    if (std.fs.path.dirname(dst)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
    if (std.fs.path.isAbsolute(src) and std.fs.path.isAbsolute(dst)) {
        try std.Io.Dir.renameAbsolute(src, dst, io);
    } else {
        try std.Io.Dir.cwd().rename(src, std.Io.Dir.cwd(), dst, io);
    }
}

test "records completed torrent history for list and show" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();
    try history.record("abcd", "/downloads/file", 42);
    try std.testing.expectEqual(@as(usize, 1), history.completions.items.len);
    try std.testing.expectEqualStrings("abcd", history.completions.items[0].info_hash_hex);
}

test "builds final destination path" {
    const path = try finalPath(std.testing.allocator, "/srv/downloads", "tiny.txt");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/srv/downloads/tiny.txt", path);
}

test "refuses to overwrite existing final destination paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const final_root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/final", .{tmp.sub_path});
    defer std.testing.allocator.free(final_root);
    const content = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    defer std.testing.allocator.free(content);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, final_root);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, content);
    const existing = try std.fs.path.join(std.testing.allocator, &.{ final_root, "tiny.txt" });
    defer std.testing.allocator.free(existing);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = existing, .data = "taken" });

    const meta_bytes = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(std.testing.allocator, meta_bytes);
    defer meta.deinit();
    const staged = try std.fs.path.join(std.testing.allocator, &.{ content, "tiny.txt" });
    defer std.testing.allocator.free(staged);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = staged, .data = "abcd" });

    try std.testing.expectError(error.DestinationExists, moveCompletedContent(std.testing.io, std.testing.allocator, content, meta, final_root));
}
