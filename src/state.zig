const std = @import("std");
const torrent = @import("torrent.zig");

pub const Status = enum { active, paused, complete, failed };

pub const TorrentRecord = struct {
    info_hash_hex: []const u8,
    name: []const u8,
    status: Status = .active,
    tracker_url: ?[]const u8 = null,
    tracker_error: ?[]const u8 = null,
    total_bytes: u64 = 0,
    piece_length: u64 = 0,
    piece_count: usize = 0,
    verified_piece_count: usize = 0,
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
        for (self.records.items) |record| deinitRecord(self.allocator, record);
        self.records.deinit(self.allocator);
    }
    pub fn add(self: *Registry, record: TorrentRecord) !void {
        if (self.find(record.info_hash_hex) != null) return error.DuplicateTorrent;
        if (self.records.items.len >= self.active_limit) return error.ActiveTorrentLimit;
        try self.records.append(self.allocator, try cloneRecord(self.allocator, record));
    }
    pub fn find(self: Registry, info_hash_hex: []const u8) ?*TorrentRecord {
        for (self.records.items) |*record| if (std.mem.eql(u8, record.info_hash_hex, info_hash_hex)) return record;
        return null;
    }
    pub fn remove(self: *Registry, info_hash_hex: []const u8) bool {
        for (self.records.items, 0..) |record, i| if (std.mem.eql(u8, record.info_hash_hex, info_hash_hex)) {
            deinitRecord(self.allocator, record);
            _ = self.records.orderedRemove(i);
            return true;
        };
        return false;
    }
};

pub fn infoHashHex(info_hash: torrent.InfoHash) [40]u8 {
    return std.fmt.bytesToHex(info_hash, .lower);
}

pub fn totalBytes(meta: torrent.Metadata) u64 {
    return switch (meta.mode) {
        .single_file => |len| len,
        .multi_file => |files| blk: {
            var total: u64 = 0;
            for (files) |file| total += file.length;
            break :blk total;
        },
    };
}

pub fn cloneRecord(allocator: std.mem.Allocator, record: TorrentRecord) !TorrentRecord {
    return .{
        .info_hash_hex = try allocator.dupe(u8, record.info_hash_hex),
        .name = try allocator.dupe(u8, record.name),
        .status = record.status,
        .tracker_url = if (record.tracker_url) |s| try allocator.dupe(u8, s) else null,
        .tracker_error = if (record.tracker_error) |s| try allocator.dupe(u8, s) else null,
        .total_bytes = record.total_bytes,
        .piece_length = record.piece_length,
        .piece_count = record.piece_count,
        .verified_piece_count = record.verified_piece_count,
    };
}

pub fn deinitRecord(allocator: std.mem.Allocator, record: TorrentRecord) void {
    allocator.free(record.info_hash_hex);
    allocator.free(record.name);
    if (record.tracker_url) |s| allocator.free(s);
    if (record.tracker_error) |s| allocator.free(s);
}

pub fn writeTorrentState(io: std.Io, allocator: std.mem.Allocator, staging_root: []const u8, record: TorrentRecord) !void {
    const dir = try std.fs.path.join(allocator, &.{ staging_root, record.info_hash_hex });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "state.json" });
    defer allocator.free(path);
    try writeRecordAtomic(io, allocator, path, record);
}

fn writeRecordAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, record: TorrentRecord) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    const json = try recordJson(allocator, record);
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = json });
    if (std.fs.path.isAbsolute(path)) try std.Io.Dir.renameAbsolute(tmp, path, io) else try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

fn recordJson(allocator: std.mem.Allocator, record: TorrentRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginObject();
    try jw.objectField("info_hash"); try jw.write(record.info_hash_hex);
    try jw.objectField("name"); try jw.write(record.name);
    try jw.objectField("status"); try jw.write(@tagName(record.status));
    try jw.objectField("tracker_url"); if (record.tracker_url) |s| try jw.write(s) else try jw.write(null);
    try jw.objectField("total_bytes"); try jw.write(record.total_bytes);
    try jw.objectField("piece_length"); try jw.write(record.piece_length);
    try jw.objectField("piece_count"); try jw.write(record.piece_count);
    try jw.objectField("verified_piece_count"); try jw.write(record.verified_piece_count);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn readTorrentState(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !TorrentRecord {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const Wire = struct {
        info_hash: []const u8,
        name: []const u8,
        status: []const u8,
        tracker_url: ?[]const u8 = null,
        total_bytes: u64 = 0,
        piece_length: u64 = 0,
        piece_count: usize = 0,
        verified_piece_count: usize = 0,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();
    return .{
        .info_hash_hex = try allocator.dupe(u8, parsed.value.info_hash),
        .name = try allocator.dupe(u8, parsed.value.name),
        .status = parseStatus(parsed.value.status) orelse .failed,
        .tracker_url = if (parsed.value.tracker_url) |s| try allocator.dupe(u8, s) else null,
        .total_bytes = parsed.value.total_bytes,
        .piece_length = parsed.value.piece_length,
        .piece_count = parsed.value.piece_count,
        .verified_piece_count = parsed.value.verified_piece_count,
    };
}

fn parseStatus(s: []const u8) ?Status {
    inline for (@typeInfo(Status).@"enum".fields) |f| if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    return null;
}

test "rejects duplicate torrent by info hash" {
    var registry = Registry.init(std.testing.allocator, 4, 20);
    defer registry.deinit();
    try registry.add(.{ .info_hash_hex = "abcd", .name = "one" });
    try std.testing.expectError(error.DuplicateTorrent, registry.add(.{ .info_hash_hex = "abcd", .name = "two" }));
}

test "enforces active torrent limits" {
    var registry = Registry.init(std.testing.allocator, 1, 20);
    defer registry.deinit();
    try registry.add(.{ .info_hash_hex = "a", .name = "one" });
    try std.testing.expectError(error.ActiveTorrentLimit, registry.add(.{ .info_hash_hex = "b", .name = "two" }));
}
