const std = @import("std");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");

pub const Provisioned = struct {
    verified_piece_count: usize,
    total_bytes: u64,
    piece_length: u64,
    piece_count: usize,
    private_torrent: bool,
};

pub const StagedContent = struct {
    provisioned: Provisioned,
    meta: torrent.Metadata,
    layout: storage.Layout,
    content_dir: []const u8,

    pub fn deinit(self: *StagedContent, allocator: std.mem.Allocator) void {
        self.layout.deinit();
        self.meta.deinit();
        allocator.free(self.content_dir);
    }
};

pub const LoadError = error{
    StateCorruption,
    MetadataMissing,
};

fn torrentDir(allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ staging_area, info_hash_hex });
}

fn metadataPath(allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) ![]const u8 {
    const dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "metadata.torrent" });
}

fn contentDirPath(allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) ![]const u8 {
    const dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "content" });
}

fn statePath(allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) ![]const u8 {
    const dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, "state.json" });
}

pub fn dirExistsWithoutState(io: std.Io, dir: []const u8, state_path: []const u8) !bool {
    _ = try std.Io.Dir.cwd().statFile(io, dir, .{ .follow_symlinks = false });
    const state_stat = std.Io.Dir.cwd().statFile(io, state_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    _ = state_stat;
    return false;
}

fn recheckLayout(
    io: std.Io,
    allocator: std.mem.Allocator,
    content_dir: []const u8,
    meta: torrent.Metadata,
    layout: *storage.Layout,
) !Provisioned {
    try storage.recheck(io, allocator, content_dir, meta, layout);
    return provisionedFromLayout(meta, layout.*);
}

fn provisionedFromLayout(meta: torrent.Metadata, layout: storage.Layout) Provisioned {
    var verified: usize = 0;
    for (layout.piece_states) |ps| {
        if (ps == .verified) verified += 1;
    }
    return .{
        .verified_piece_count = verified,
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
        .private_torrent = meta.private_torrent,
    };
}

pub fn applyProvisioned(rec: *state.TorrentRecord, p: Provisioned) void {
    rec.verified_piece_count = p.verified_piece_count;
    rec.total_bytes = p.total_bytes;
    rec.piece_length = p.piece_length;
    rec.piece_count = p.piece_count;
    rec.private_torrent = p.private_torrent;
}

/// Prepare staging from an already-validated Torrent File (limits, paths, tracker checked by caller).
pub fn provisionFromTorrentFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging_area: []const u8,
    info_hash_hex: []const u8,
    meta: torrent.Metadata,
) !Provisioned {
    const hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &hex, info_hash_hex)) return LoadError.StateCorruption;

    const dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(dir);
    const state_path = try statePath(allocator, staging_area, info_hash_hex);
    defer allocator.free(state_path);
    const adopting = dirExistsWithoutState(io, dir, state_path) catch |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    try std.Io.Dir.cwd().createDirPath(io, dir);
    const metadata_path = try metadataPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(metadata_path);
    if (adopting) {
        if (std.Io.Dir.cwd().readFileAlloc(io, metadata_path, allocator, .limited(16 * 1024 * 1024))) |existing_bytes| {
            defer allocator.free(existing_bytes);
            const existing = torrent.Metadata.parseBytes(allocator, existing_bytes) catch return LoadError.StateCorruption;
            defer existing.deinit();
            const existing_hex = state.infoHashHex(existing.info_hash);
            if (!std.mem.eql(u8, &existing_hex, info_hash_hex)) return LoadError.StateCorruption;
        } else |_| {}
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = meta.bytes, .flags = .{ .truncate = true } });

    const content_dir = try contentDirPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(content_dir);
    try std.Io.Dir.cwd().createDirPath(io, content_dir);
    if (!adopting) {
        try storage.createStagedFiles(io, allocator, content_dir, meta);
    }

    var layout = try storage.Layout.init(allocator, meta);
    defer layout.deinit();
    return recheckLayout(io, allocator, content_dir, meta, &layout);
}

/// Create the per-torrent staging directory for a magnet before metadata is available.
pub fn provisionFromMagnet(io: std.Io, allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) !void {
    const dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
}

/// Write assembled metadata bytes to staging, create content files, and recheck.
pub fn finalizeMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging_area: []const u8,
    info_hash_hex: []const u8,
    torrent_bytes: []const u8,
) !StagedContent {
    const meta = torrent.Metadata.parseBytes(allocator, torrent_bytes) catch return LoadError.StateCorruption;
    errdefer meta.deinit();
    const hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &hex, info_hash_hex)) return LoadError.StateCorruption;

    const torrent_dir = try torrentDir(allocator, staging_area, info_hash_hex);
    defer allocator.free(torrent_dir);
    const metadata_path = try metadataPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(metadata_path);
    const content_dir = try contentDirPath(allocator, staging_area, info_hash_hex);
    errdefer allocator.free(content_dir);

    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = torrent_bytes, .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().createDirPath(io, content_dir);
    try storage.createStagedFiles(io, allocator, content_dir, meta);

    var layout = try storage.Layout.init(allocator, meta);
    errdefer layout.deinit();
    const provisioned = try recheckLayout(io, allocator, content_dir, meta, &layout);

    return .{
        .provisioned = provisioned,
        .meta = meta,
        .layout = layout,
        .content_dir = content_dir,
    };
}

/// Recheck staged content on disk and return derived progress fields.
pub fn recheckExisting(io: std.Io, allocator: std.mem.Allocator, staging_area: []const u8, info_hash_hex: []const u8) !Provisioned {
    const metadata_path = try metadataPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(metadata_path);
    const meta = try torrent.Metadata.parseFile(allocator, io, metadata_path);
    defer meta.deinit();
    const parsed_hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &parsed_hex, info_hash_hex)) return LoadError.StateCorruption;

    const content_dir = try contentDirPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(content_dir);
    var layout = try storage.Layout.init(allocator, meta);
    defer layout.deinit();
    return recheckLayout(io, allocator, content_dir, meta, &layout);
}

/// Load metadata and recheck layout for engine session attach. Caller owns returned strings and metadata.
pub fn loadForSession(
    io: std.Io,
    allocator: std.mem.Allocator,
    staging_area: []const u8,
    info_hash_hex: []const u8,
) !struct { meta: torrent.Metadata, layout: storage.Layout, content_dir: []const u8 } {
    const metadata_path = try metadataPath(allocator, staging_area, info_hash_hex);
    defer allocator.free(metadata_path);
    const meta = try torrent.Metadata.parseFile(allocator, io, metadata_path);
    errdefer meta.deinit();
    const parsed_hex = state.infoHashHex(meta.info_hash);
    if (!std.mem.eql(u8, &parsed_hex, info_hash_hex)) {
        meta.deinit();
        return LoadError.StateCorruption;
    }

    const content_dir = try contentDirPath(allocator, staging_area, info_hash_hex);
    errdefer allocator.free(content_dir);
    var layout = try storage.Layout.init(allocator, meta);
    errdefer layout.deinit();
    try storage.recheck(io, allocator, content_dir, meta, &layout);

    return .{ .meta = meta, .layout = layout, .content_dir = content_dir };
}

test "provisionFromTorrentFile creates staging and reports zero verified pieces" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();
    const hex = state.infoHashHex(meta.info_hash);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staging = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/staging", .{tmp.sub_path});
    defer allocator.free(staging);

    const provisioned = try provisionFromTorrentFile(io, allocator, staging, &hex, meta);
    try std.testing.expectEqual(@as(usize, 0), provisioned.verified_piece_count);
    try std.testing.expect(provisioned.total_bytes > 0);
    try std.testing.expectEqual(meta.piece_length, provisioned.piece_length);
}

test "recheckExisting matches provisionFromTorrentFile" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();
    const hex = state.infoHashHex(meta.info_hash);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staging = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/staging", .{tmp.sub_path});
    defer allocator.free(staging);

    const provisioned = try provisionFromTorrentFile(io, allocator, staging, &hex, meta);
    const rechecked = try recheckExisting(io, allocator, staging, &hex);
    try std.testing.expectEqual(provisioned.verified_piece_count, rechecked.verified_piece_count);
    try std.testing.expectEqual(provisioned.total_bytes, rechecked.total_bytes);
    try std.testing.expectEqual(provisioned.piece_count, rechecked.piece_count);
}

test "provisionFromMagnet creates staging directory only" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staging = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/staging", .{tmp.sub_path});
    defer allocator.free(staging);

    try provisionFromMagnet(io, allocator, staging, "abc123");
    const dir = try torrentDir(allocator, staging, "abc123");
    defer allocator.free(dir);
    _ = try std.Io.Dir.cwd().statFile(io, dir, .{ .follow_symlinks = false });
}
