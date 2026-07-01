const std = @import("std");
const engine_mod = @import("engine.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const config = @import("config.zig");

test "integration: rejects duplicate torrent add by info hash" {
    var registry = state.Registry.init(std.testing.allocator, 4, 20);
    defer registry.deinit();
    var trackers = [_]state.TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{ .info_hash_hex = "deadbeef", .name = "one", .trackers = trackers[0..] });
    try std.testing.expectError(error.DuplicateTorrent, registry.add(.{ .info_hash_hex = "deadbeef", .name = "two", .trackers = trackers[0..] }));
}

test "integration: engine startup recheck reports zero verified bytes for empty staging" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staging = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/staging", .{tmp.sub_path});
    defer allocator.free(staging);
    const hex = state.infoHashHex(meta.info_hash);
    const torrent_dir = try std.fs.path.join(allocator, &.{ staging, &hex });
    defer allocator.free(torrent_dir);
    const content_dir = try std.fs.path.join(allocator, &.{ torrent_dir, "content" });
    defer allocator.free(content_dir);
    try std.Io.Dir.cwd().createDirPath(io, content_dir);
    try storage.createStagedFiles(io, allocator, content_dir, meta);

    var registry = state.Registry.init(allocator, 4, 20);
    defer registry.deinit();
    var trackers = [_]state.TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{
        .info_hash_hex = &hex,
        .name = meta.name,
        .status = .active,
        .trackers = trackers[0..],
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
    });
    const rec = registry.find(&hex).?;

    var cfg = try config.loadFromArgs(allocator, &.{});
    defer cfg.deinit(allocator);
    const old_staging = cfg.staging_area;
    cfg.staging_area = try allocator.dupe(u8, staging);
    allocator.free(old_staging);
    const metadata_path = try std.fs.path.join(allocator, &.{ torrent_dir, "metadata.torrent" });
    defer allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = fixture });

    var eng = engine_mod.Engine.init(allocator);
    defer eng.deinit(io);
    try eng.addSession(io, cfg, &registry, rec, null);
    try std.testing.expectEqual(@as(usize, 0), rec.verified_piece_count);
}

test "integration: corrupt staged piece is detected on recheck" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/content", .{tmp.sub_path});
    defer allocator.free(content_dir);
    try std.Io.Dir.cwd().createDirPath(io, content_dir);
    try storage.createStagedFiles(io, allocator, content_dir, meta);
    const path = try std.fs.path.join(allocator, &.{ content_dir, "tiny.txt" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "wxyz", .flags = .{ .truncate = true } });

    var layout = try storage.Layout.init(allocator, meta);
    defer layout.deinit();
    try storage.recheck(io, allocator, content_dir, meta, &layout);
    try std.testing.expectEqual(storage.PieceState.missing, layout.piece_states[0]);
}
