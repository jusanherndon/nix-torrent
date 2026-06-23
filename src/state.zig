const std = @import("std");

pub const Status = enum { active, paused, complete, failed };

pub const TorrentRecord = struct {
    info_hash_hex: []const u8,
    name: []const u8,
    status: Status = .active,
    tracker_error: ?[]const u8 = null,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    active_limit: usize,
    peer_limit_per_torrent: usize,
    records: std.ArrayList(TorrentRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator, active_limit: usize, peer_limit_per_torrent: usize) Registry {
        return .{ .allocator = allocator, .active_limit = active_limit, .peer_limit_per_torrent = peer_limit_per_torrent };
    }
    pub fn deinit(self: *Registry) void {
        for (self.records.items) |record| {
            self.allocator.free(record.info_hash_hex);
            self.allocator.free(record.name);
        }
        self.records.deinit(self.allocator);
    }
    pub fn add(self: *Registry, info_hash_hex: []const u8, name: []const u8) !void {
        if (self.find(info_hash_hex) != null) return error.DuplicateTorrent;
        if (self.records.items.len >= self.active_limit) return error.ActiveTorrentLimit;
        try self.records.append(self.allocator, .{ .info_hash_hex = try self.allocator.dupe(u8, info_hash_hex), .name = try self.allocator.dupe(u8, name) });
    }
    pub fn find(self: Registry, info_hash_hex: []const u8) ?*TorrentRecord {
        for (self.records.items) |*record| if (std.mem.eql(u8, record.info_hash_hex, info_hash_hex)) return record;
        return null;
    }
    pub fn remove(self: *Registry, info_hash_hex: []const u8) bool {
        for (self.records.items, 0..) |record, i| if (std.mem.eql(u8, record.info_hash_hex, info_hash_hex)) {
            self.allocator.free(record.info_hash_hex);
            self.allocator.free(record.name);
            _ = self.records.orderedRemove(i);
            return true;
        };
        return false;
    }
};

test "rejects duplicate torrent by info hash" {
    var registry = Registry.init(std.testing.allocator, 4, 20);
    defer registry.deinit();
    try registry.add("abcd", "one");
    try std.testing.expectError(error.DuplicateTorrent, registry.add("abcd", "two"));
}

test "enforces active torrent limits" {
    var registry = Registry.init(std.testing.allocator, 1, 20);
    defer registry.deinit();
    try registry.add("a", "one");
    try std.testing.expectError(error.ActiveTorrentLimit, registry.add("b", "two"));
}
