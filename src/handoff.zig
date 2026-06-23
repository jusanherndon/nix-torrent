const std = @import("std");

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
    // Atomic rename on the same filesystem. Cross-device fallback can be added
    // when the storage layer starts exercising real staged trees in integration tests.
    try std.fs.cwd().rename(src, dst);
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
