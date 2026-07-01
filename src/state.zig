const std = @import("std");
const torrent = @import("torrent.zig");

pub const Status = enum { active, paused, complete, failed };

pub const TrackerRecord = struct {
    url: []const u8,
    last_error: ?[]const u8 = null,
    next_announce_ms: i64 = 0,
    started_sent: bool = false,

    pub fn deinit(self: *TrackerRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.last_error) |s| allocator.free(s);
    }

    pub fn clone(allocator: std.mem.Allocator, record: TrackerRecord) !TrackerRecord {
        return .{
            .url = try allocator.dupe(u8, record.url),
            .last_error = if (record.last_error) |s| try allocator.dupe(u8, s) else null,
            .next_announce_ms = record.next_announce_ms,
            .started_sent = record.started_sent,
        };
    }
};

pub const TorrentRecord = struct {
    info_hash_hex: []const u8,
    name: []const u8,
    status: Status = .active,
    trackers: []TrackerRecord,
    dht_slot: ?usize = null,
    private_torrent: bool = false,
    total_bytes: u64 = 0,
    piece_length: u64 = 0,
    piece_count: usize = 0,
    verified_piece_count: usize = 0,
};

pub const CompletionRecord = struct {
    info_hash_hex: []const u8,
    name: []const u8,
    final_path: []const u8,
    completed_at: []const u8,
    total_bytes: u64 = 0,
};

pub fn cloneCompletion(allocator: std.mem.Allocator, record: CompletionRecord) !CompletionRecord {
    return .{
        .info_hash_hex = try allocator.dupe(u8, record.info_hash_hex),
        .name = try allocator.dupe(u8, record.name),
        .final_path = try allocator.dupe(u8, record.final_path),
        .completed_at = try allocator.dupe(u8, record.completed_at),
        .total_bytes = record.total_bytes,
    };
}

pub fn deinitCompletion(allocator: std.mem.Allocator, record: CompletionRecord) void {
    allocator.free(record.info_hash_hex);
    allocator.free(record.name);
    allocator.free(record.final_path);
    allocator.free(record.completed_at);
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    active_limit: usize,
    peer_limit_per_torrent: usize,
    records: std.ArrayList(TorrentRecord) = .empty,
    history: std.ArrayList(CompletionRecord) = .empty,

    pub fn init(allocator: std.mem.Allocator, active_limit: usize, peer_limit_per_torrent: usize) Registry {
        return .{ .allocator = allocator, .active_limit = active_limit, .peer_limit_per_torrent = peer_limit_per_torrent };
    }
    pub fn deinit(self: *Registry) void {
        for (self.records.items) |record| deinitRecord(self.allocator, record);
        self.records.deinit(self.allocator);
        for (self.history.items) |record| deinitCompletion(self.allocator, record);
        self.history.deinit(self.allocator);
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
    pub fn findCompletion(self: Registry, info_hash_hex: []const u8) ?*CompletionRecord {
        for (self.history.items) |*record| if (std.mem.eql(u8, record.info_hash_hex, info_hash_hex)) return record;
        return null;
    }
    pub fn addCompletion(self: *Registry, record: CompletionRecord) !void {
        if (self.findCompletion(record.info_hash_hex) != null) return error.DuplicateCompletion;
        try self.history.append(self.allocator, try cloneCompletion(self.allocator, record));
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
    const trackers = try allocator.alloc(TrackerRecord, record.trackers.len);
    errdefer {
        for (trackers) |*tr| tr.deinit(allocator);
        allocator.free(trackers);
    }
    for (record.trackers, 0..) |tr, i| trackers[i] = try TrackerRecord.clone(allocator, tr);
    return .{
        .info_hash_hex = try allocator.dupe(u8, record.info_hash_hex),
        .name = try allocator.dupe(u8, record.name),
        .status = record.status,
        .trackers = trackers,
        .dht_slot = record.dht_slot,
        .private_torrent = record.private_torrent,
        .total_bytes = record.total_bytes,
        .piece_length = record.piece_length,
        .piece_count = record.piece_count,
        .verified_piece_count = record.verified_piece_count,
    };
}

pub fn deinitRecord(allocator: std.mem.Allocator, record: TorrentRecord) void {
    allocator.free(record.info_hash_hex);
    allocator.free(record.name);
    for (record.trackers) |*tr| tr.deinit(allocator);
    allocator.free(record.trackers);
}

pub fn findTracker(record: *TorrentRecord, url: []const u8) ?*TrackerRecord {
    for (record.trackers) |*tr| if (std.mem.eql(u8, tr.url, url)) return tr;
    return null;
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
    try jw.objectField("info_hash");
    try jw.write(record.info_hash_hex);
    try jw.objectField("name");
    try jw.write(record.name);
    try jw.objectField("status");
    try jw.write(@tagName(record.status));
    try jw.objectField("tracker_announce_urls");
    try jw.beginArray();
    for (record.trackers) |tr| try jw.write(tr.url);
    try jw.endArray();
    try jw.objectField("trackers");
    try jw.beginArray();
    for (record.trackers) |tr| {
        try jw.beginObject();
        try jw.objectField("url");
        try jw.write(tr.url);
        try jw.objectField("started_sent");
        try jw.write(tr.started_sent);
        try jw.objectField("next_announce_ms");
        try jw.write(tr.next_announce_ms);
        try jw.objectField("last_error");
        if (tr.last_error) |s| try jw.write(s) else try jw.write(null);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.objectField("total_bytes");
    try jw.write(record.total_bytes);
    try jw.objectField("piece_length");
    try jw.write(record.piece_length);
    try jw.objectField("piece_count");
    try jw.write(record.piece_count);
    try jw.objectField("verified_piece_count");
    try jw.write(record.verified_piece_count);
    try jw.objectField("dht_slot");
    if (record.dht_slot) |slot| try jw.write(slot) else try jw.write(null);
    try jw.objectField("private_torrent");
    try jw.write(record.private_torrent);
    try jw.endObject();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn readHistory(io: std.Io, allocator: std.mem.Allocator, staging_root: []const u8) ![]CompletionRecord {
    const path = try std.fs.path.join(allocator, &.{ staging_root, "history.json" });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return try allocator.alloc(CompletionRecord, 0),
        else => return err,
    };
    defer allocator.free(bytes);
    const Wire = struct { info_hash: []const u8, name: []const u8, final_path: []const u8, completed_at: []const u8, total_bytes: u64 = 0 };
    const parsed = try std.json.parseFromSlice([]Wire, allocator, bytes, .{});
    defer parsed.deinit();
    var out = try allocator.alloc(CompletionRecord, parsed.value.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |record| deinitCompletion(allocator, record);
        allocator.free(out);
    }
    for (parsed.value, 0..) |item, i| {
        for (out[0..i]) |prior| if (std.mem.eql(u8, prior.info_hash_hex, item.info_hash)) return error.DuplicateCompletion;
        out[i] = .{
            .info_hash_hex = try allocator.dupe(u8, item.info_hash),
            .name = try allocator.dupe(u8, item.name),
            .final_path = try allocator.dupe(u8, item.final_path),
            .completed_at = try allocator.dupe(u8, item.completed_at),
            .total_bytes = item.total_bytes,
        };
        initialized += 1;
    }
    return out;
}

pub fn freeHistory(allocator: std.mem.Allocator, history: []CompletionRecord) void {
    for (history) |record| deinitCompletion(allocator, record);
    allocator.free(history);
}

pub fn writeHistory(io: std.Io, allocator: std.mem.Allocator, staging_root: []const u8, history: []const CompletionRecord) !void {
    try std.Io.Dir.cwd().createDirPath(io, staging_root);
    const path = try std.fs.path.join(allocator, &.{ staging_root, "history.json" });
    defer allocator.free(path);
    try writeHistoryAtomic(io, allocator, path, history);
}

pub fn appendHistoryRecord(io: std.Io, allocator: std.mem.Allocator, staging_root: []const u8, record: CompletionRecord) !void {
    const existing = try readHistory(io, allocator, staging_root);
    defer freeHistory(allocator, existing);
    for (existing) |item| if (std.mem.eql(u8, item.info_hash_hex, record.info_hash_hex)) return error.DuplicateCompletion;

    var combined = try allocator.alloc(CompletionRecord, existing.len + 1);
    defer allocator.free(combined);
    for (existing, 0..) |item, i| combined[i] = item;
    combined[existing.len] = record;
    try writeHistory(io, allocator, staging_root, combined);
}

fn writeHistoryAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, history: []const CompletionRecord) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    const json = try historyJson(allocator, history);
    defer allocator.free(json);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = json });
    if (std.fs.path.isAbsolute(path)) try std.Io.Dir.renameAbsolute(tmp, path, io) else try std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, io);
}

fn historyJson(allocator: std.mem.Allocator, history: []const CompletionRecord) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer };
    try jw.beginArray();
    for (history) |record| {
        try jw.beginObject();
        try jw.objectField("info_hash");
        try jw.write(record.info_hash_hex);
        try jw.objectField("name");
        try jw.write(record.name);
        try jw.objectField("final_path");
        try jw.write(record.final_path);
        try jw.objectField("completed_at");
        try jw.write(record.completed_at);
        try jw.objectField("total_bytes");
        try jw.write(record.total_bytes);
        try jw.endObject();
    }
    try jw.endArray();
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

pub fn readTorrentState(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !TorrentRecord {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(bytes);
    const WireTracker = struct {
        url: []const u8,
        started_sent: bool = false,
        next_announce_ms: i64 = 0,
        last_error: ?[]const u8 = null,
    };
    const Wire = struct {
        info_hash: []const u8,
        name: []const u8,
        status: []const u8,
        tracker_url: ?[]const u8 = null,
        tracker_announce_urls: ?[][]const u8 = null,
        trackers: ?[]WireTracker = null,
        total_bytes: u64 = 0,
        piece_length: u64 = 0,
        piece_count: usize = 0,
        verified_piece_count: usize = 0,
        dht_slot: ?usize = null,
        private_torrent: bool = false,
    };
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();

    const url_count = if (parsed.value.tracker_announce_urls) |urls| urls.len else if (parsed.value.tracker_url != null) 1 else if (parsed.value.trackers) |trs| trs.len else 0;
    const trackers = try allocator.alloc(TrackerRecord, url_count);
    errdefer {
        for (trackers) |*tr| tr.deinit(allocator);
        allocator.free(trackers);
    }

    if (parsed.value.trackers) |wire_trackers| {
        for (wire_trackers, 0..) |wt, i| {
            trackers[i] = .{
                .url = try allocator.dupe(u8, wt.url),
                .last_error = if (wt.last_error) |s| try allocator.dupe(u8, s) else null,
                .next_announce_ms = wt.next_announce_ms,
                .started_sent = wt.started_sent,
            };
        }
    } else if (parsed.value.tracker_announce_urls) |urls| {
        for (urls, 0..) |url, i| trackers[i] = .{ .url = try allocator.dupe(u8, url) };
    } else if (parsed.value.tracker_url) |url| {
        trackers[0] = .{ .url = try allocator.dupe(u8, url) };
    }

    return .{
        .info_hash_hex = try allocator.dupe(u8, parsed.value.info_hash),
        .name = try allocator.dupe(u8, parsed.value.name),
        .status = parseStatus(parsed.value.status) orelse .failed,
        .trackers = trackers,
        .dht_slot = parsed.value.dht_slot,
        .private_torrent = parsed.value.private_torrent,
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
    var trackers = [_]TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{ .info_hash_hex = "abcd", .name = "one", .trackers = trackers[0..] });
    try std.testing.expectError(error.DuplicateTorrent, registry.add(.{ .info_hash_hex = "abcd", .name = "two", .trackers = trackers[0..] }));
}

test "enforces active torrent limits" {
    var registry = Registry.init(std.testing.allocator, 1, 20);
    defer registry.deinit();
    var trackers = [_]TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{ .info_hash_hex = "a", .name = "one", .trackers = trackers[0..] });
    try std.testing.expectError(error.ActiveTorrentLimit, registry.add(.{ .info_hash_hex = "b", .name = "two", .trackers = trackers[0..] }));
}

test "loads completion history and rejects duplicate info hashes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/history.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\[{"info_hash":"abc","name":"one","final_path":"/final/one","completed_at":"2026-01-01T00:00:00Z","total_bytes":3}]
    });
    const history = try readHistory(std.testing.io, std.testing.allocator, dir);
    defer freeHistory(std.testing.allocator, history);
    try std.testing.expectEqual(@as(usize, 1), history.len);
    try std.testing.expectEqualStrings("abc", history[0].info_hash_hex);
    try std.testing.expectEqualStrings("/final/one", history[0].final_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data =
        \\[{"info_hash":"abc","name":"one","final_path":"/final/one","completed_at":"2026-01-01T00:00:00Z"},{"info_hash":"abc","name":"two","final_path":"/final/two","completed_at":"2026-01-02T00:00:00Z"}]
    });
    try std.testing.expectError(error.DuplicateCompletion, readHistory(std.testing.io, std.testing.allocator, dir));
}

test "writes and appends completion history atomically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(dir);

    try appendHistoryRecord(std.testing.io, std.testing.allocator, dir, .{
        .info_hash_hex = "abc",
        .name = "one",
        .final_path = "/final/one",
        .completed_at = "2026-01-01T00:00:00Z",
        .total_bytes = 3,
    });
    try appendHistoryRecord(std.testing.io, std.testing.allocator, dir, .{
        .info_hash_hex = "def",
        .name = "two",
        .final_path = "/final/two",
        .completed_at = "2026-01-02T00:00:00Z",
        .total_bytes = 4,
    });
    try std.testing.expectError(error.DuplicateCompletion, appendHistoryRecord(std.testing.io, std.testing.allocator, dir, .{
        .info_hash_hex = "abc",
        .name = "again",
        .final_path = "/final/again",
        .completed_at = "2026-01-03T00:00:00Z",
    }));

    const history = try readHistory(std.testing.io, std.testing.allocator, dir);
    defer freeHistory(std.testing.allocator, history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("def", history[1].info_hash_hex);
    try std.testing.expectEqual(@as(u64, 4), history[1].total_bytes);
}
