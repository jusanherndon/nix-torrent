const std = @import("std");
const config = @import("config.zig");
const dht = @import("dht.zig");
const encryption = @import("encryption.zig");
const engine_mod = @import("engine.zig");
const harness = @import("integration_harness.zig");
const magnet = @import("magnet.zig");
const peer = @import("peer.zig");
const protocol = @import("protocol.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

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

test "integration: udp tracker returns fake peer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();

    var content_peer = try harness.spawnFakeContentPeer(io, allocator, meta, .plaintext);
    defer content_peer.join(io);
    const peer_ep = harness.Endpoint{ .port = content_peer.port };

    var udp_tracker = try harness.spawnFakeUdpTracker(io, allocator, &.{peer_ep});
    defer udp_tracker.join(io);

    const url = try std.fmt.allocPrint(allocator, "udp://127.0.0.1:{d}/announce", .{udp_tracker.port});
    defer allocator.free(url);
    const parsed = try tracker.parseAnnounceUrl(allocator, url);
    defer parsed.deinit(allocator);
    var udp_session: tracker.UdpSession = .{};
    const response = try tracker.announce(io, allocator, parsed, &udp_session, meta.info_hash, [_]u8{1} ** 20, 6881, 0, 0, meta.mode.single_file, .started, 2000, 0);
    defer response.deinit(allocator);
    try std.testing.expect(response.peers.len >= 1);
    try std.testing.expectEqual(peer_ep.port, response.peers[0].port);
}

test "integration: dht routing table targets fake node" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();

    var content_peer = try harness.spawnFakeContentPeer(io, allocator, meta, .plaintext);
    defer content_peer.join(io);
    const peer_ep = harness.Endpoint{ .port = content_peer.port };

    var dht_node = try harness.spawnFakeDhtNode(io, allocator, &.{peer_ep});
    defer dht_node.join(io);

    var routing = dht.RoutingTable.init(allocator, [_]u8{3} ** 20);
    defer routing.deinit();
    const node_id: [20]u8 = [_]u8{9} ** 20;
    try routing.addNode(.{ .id = node_id, .ip = .{ 127, 0, 0, 1 }, .port = dht_node.port });
    try std.testing.expectEqual(@as(usize, 1), routing.nodes.items.len);
    try std.testing.expectEqual(dht_node.port, routing.nodes.items[0].port);
}

test "integration: two dht-eligible torrents bind distinct ports" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var slots = try dht.SlotAllocator.init(allocator, 4);
    defer slots.deinit();
    const slot_a = slots.allocate() orelse return error.TestExpectedFailure;
    const slot_b = slots.allocate() orelse return error.TestExpectedFailure;
    try std.testing.expect(slot_a != slot_b);
    const base: u16 = 6881;
    var sock_a: dht.TorrentDhtSocket = .{ .slot = slot_a, .bind_port = base + @as(u16, @intCast(slot_a)) };
    var sock_b: dht.TorrentDhtSocket = .{ .slot = slot_b, .bind_port = base + @as(u16, @intCast(slot_b)) };
    try sock_a.open(io, base + @as(u16, @intCast(slot_a)));
    defer sock_a.close(io, allocator);
    try sock_b.open(io, base + @as(u16, @intCast(slot_b)));
    defer sock_b.close(io, allocator);
    try std.testing.expectEqual(base + @as(u16, @intCast(slot_a)), sock_a.bind_port);
    try std.testing.expectEqual(base + @as(u16, @intCast(slot_b)), sock_b.bind_port);
    try std.testing.expect(sock_a.bind_port != sock_b.bind_port);
}

test "integration: encrypted policy rejects plaintext peer" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();

    var peer_srv = try harness.spawnFakeContentPeer(io, allocator, meta, .plaintext);
    defer peer_srv.join(io);

    var conn = try peer.Connection.connect(io, allocator, .{ 127, 0, 0, 1 }, peer_srv.port, 2000);
    defer conn.deinit(io);
    try std.testing.expectError(error.EncryptionRequired, conn.performHandshake(io, meta.info_hash, [_]u8{4} ** 20, encryption.Policy.require, false));
}

test "integration: metadata peer handshake and piece fetch" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const fixture = @embedFile("fixtures/single-file.torrent");
    const meta = try torrent.Metadata.parseBytes(allocator, fixture);
    defer meta.deinit();
    const info = meta.root.dictGet("info").?;
    const info_bytes = info.dict.raw;

    var metadata_peer = try harness.spawnFakeMetadataPeer(io, allocator, meta.info_hash, info_bytes);
    defer metadata_peer.join(io);

    var conn = try peer.Connection.connect(io, allocator, .{ 127, 0, 0, 1 }, metadata_peer.port, 2000);
    defer conn.deinit(io);
    try conn.performMetadataHandshake(io, meta.info_hash, [_]u8{6} ** 20, .disable);
    try std.testing.expectEqual(@as(usize, info_bytes.len), conn.metadata_size.?);
    if (conn.recv_buffer.items.len == 0) try conn.requestMetadataPiece(io, 0);
    const piece = (try conn.readMetadataPiece(io)) orelse return error.TestExpectedEqual;
    defer allocator.free(piece.bytes);
    try std.testing.expectEqual(info_bytes.len, piece.bytes.len);
}

test "integration: magnet discovery source policy" {
    const allocator = std.testing.allocator;
    const uri = "magnet:?xt=urn:btih:78fc7061455539a27d6ccc8241e09d325850d9e5";
    const m = try magnet.parse(allocator, uri);
    defer magnet.deinit(m, allocator);
    try std.testing.expect(!magnet.hasDiscoverySource(m, false));
    try std.testing.expect(magnet.hasDiscoverySource(m, true));
    const with_tracker = try magnet.parse(allocator, "magnet:?xt=urn:btih:78fc7061455539a27d6ccc8241e09d325850d9e5&tr=udp%3A%2F%2F127.0.0.1%3A6969%2Fannounce");
    defer magnet.deinit(with_tracker, allocator);
    try std.testing.expect(magnet.hasDiscoverySource(with_tracker, false));
}

test "integration: private torrent does not open dht socket" {
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
    const torrent_dir = try std.fs.path.join(allocator, &.{ staging, &hex });
    defer allocator.free(torrent_dir);
    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ torrent_dir, "metadata.torrent" });
    defer allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = fixture });

    var registry = state.Registry.init(allocator, 4, 20);
    defer registry.deinit();
    var trackers = [_]state.TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{
        .info_hash_hex = &hex,
        .name = meta.name,
        .trackers = trackers[0..],
        .private_torrent = true,
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
        .dht_slot = 0,
    });
    const rec = registry.find(&hex).?;

    var cfg = try config.loadFromArgs(allocator, &.{});
    defer cfg.deinit(allocator);
    allocator.free(cfg.staging_area);
    cfg.staging_area = try allocator.dupe(u8, staging);
    cfg.network.dht.enabled = true;

    var slots = try dht.SlotAllocator.init(allocator, 4);
    defer slots.deinit();
    var routing = dht.RoutingTable.init(allocator, [_]u8{7} ** 20);
    defer routing.deinit();
    var bootstrapped = false;
    var last_refresh: i64 = 0;
    const dht_ctx = engine_mod.DhtContext{
        .routing = &routing,
        .cfg = .{
            .enabled = cfg.network.dht.enabled,
            .bootstrap_nodes = cfg.network.dht.bootstrap_nodes,
            .request_timeout_ms = cfg.network.dht.request_timeout_ms,
            .refresh_interval_ms = cfg.network.dht.refresh_interval_ms,
        },
        .bootstrapped = &bootstrapped,
        .last_refresh_ms = &last_refresh,
        .slots = &slots,
    };

    var eng = engine_mod.Engine.init(allocator);
    defer eng.deinit(io);
    try eng.addSession(io, cfg, &registry, rec, dht_ctx);
    const session = eng.findSession(&hex).?;
    try std.testing.expect(session.dht_socket == null);
}

test "integration: dht disabled config does not bind sockets" {
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
    const torrent_dir = try std.fs.path.join(allocator, &.{ staging, &hex });
    defer allocator.free(torrent_dir);
    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ torrent_dir, "metadata.torrent" });
    defer allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = fixture });

    var registry = state.Registry.init(allocator, 4, 20);
    defer registry.deinit();
    var trackers = [_]state.TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    try registry.add(.{
        .info_hash_hex = &hex,
        .name = meta.name,
        .trackers = trackers[0..],
        .dht_slot = 0,
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
    });
    const rec = registry.find(&hex).?;

    var cfg = try config.loadFromArgs(allocator, &.{});
    defer cfg.deinit(allocator);
    allocator.free(cfg.staging_area);
    cfg.staging_area = try allocator.dupe(u8, staging);
    cfg.network.dht.enabled = false;

    var eng = engine_mod.Engine.init(allocator);
    defer eng.deinit(io);
    try eng.addSession(io, cfg, &registry, rec, null);
    const session = eng.findSession(&hex).?;
    try std.testing.expect(session.dht_socket == null);
}

test "integration: resume magnet torrent before metadata complete" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const hex = "78fc7061455539a27d6ccc8241e09d325850d9e5";

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staging = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/staging", .{tmp.sub_path});
    defer allocator.free(staging);
    const torrent_dir = try std.fs.path.join(allocator, &.{ staging, hex });
    defer allocator.free(torrent_dir);
    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);

    var trackers = [_]state.TrackerRecord{.{ .url = "udp://127.0.0.1:6969/announce" }};
    const rec = state.TorrentRecord{
        .info_hash_hex = hex,
        .name = hex,
        .status = .active,
        .trackers = trackers[0..],
        .metadata_complete = false,
        .source = "magnet",
    };
    try state.writeTorrentState(io, allocator, staging, rec);

    var registry = state.Registry.init(allocator, 4, 20);
    defer registry.deinit();
    const state_path = try std.fs.path.join(allocator, &.{ torrent_dir, "state.json" });
    defer allocator.free(state_path);
    const loaded = try state.readTorrentState(io, allocator, state_path);
    defer state.deinitRecord(allocator, loaded);
    try registry.add(loaded);
    const stored = registry.find(hex).?;

    var eng = engine_mod.Engine.init(allocator);
    defer eng.deinit(io);
    var cfg = try config.loadFromArgs(allocator, &.{});
    defer cfg.deinit(allocator);
    allocator.free(cfg.staging_area);
    cfg.staging_area = try allocator.dupe(u8, staging);
    try eng.addSession(io, cfg, &registry, stored, null);
    try std.testing.expect(eng.findSession(hex).?.fetching_metadata);
}

test "integration: resume magnet torrent after metadata known" {
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
    const torrent_dir = try std.fs.path.join(allocator, &.{ staging, &hex });
    defer allocator.free(torrent_dir);
    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);
    const metadata_path = try std.fs.path.join(allocator, &.{ torrent_dir, "metadata.torrent" });
    defer allocator.free(metadata_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = fixture });

    var trackers = [_]state.TrackerRecord{.{ .url = "http://127.0.0.1/announce" }};
    const rec = state.TorrentRecord{
        .info_hash_hex = &hex,
        .name = meta.name,
        .status = .active,
        .trackers = trackers[0..],
        .metadata_complete = true,
        .source = "magnet",
        .total_bytes = state.totalBytes(meta),
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
    };
    try state.writeTorrentState(io, allocator, staging, rec);

    var registry = state.Registry.init(allocator, 4, 20);
    defer registry.deinit();
    const state_path = try std.fs.path.join(allocator, &.{ torrent_dir, "state.json" });
    defer allocator.free(state_path);
    const loaded = try state.readTorrentState(io, allocator, state_path);
    defer state.deinitRecord(allocator, loaded);
    try registry.add(loaded);
    const stored = registry.find(&hex).?;

    var eng = engine_mod.Engine.init(allocator);
    defer eng.deinit(io);
    var cfg = try config.loadFromArgs(allocator, &.{});
    defer cfg.deinit(allocator);
    allocator.free(cfg.staging_area);
    cfg.staging_area = try allocator.dupe(u8, staging);
    try eng.addSession(io, cfg, &registry, stored, null);
    const session = eng.findSession(&hex).?;
    try std.testing.expect(!session.fetching_metadata);
    try std.testing.expect(session.meta != null);
}

test "integration: control protocol version 2 in status response" {
    var root: std.json.ObjectMap = .empty;
    defer root.deinit(std.testing.allocator);
    try root.put(std.testing.allocator, "control_protocol_version", .{ .integer = @intCast(protocol.CONTROL_PROTOCOL_VERSION) });
    const response = protocol.Response{ .success = .{ .object = root } };
    const json = try response.toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    const parsed = try protocol.parseResponse(std.testing.allocator, json);
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const version = result.get("control_protocol_version").?.integer;
    try std.testing.expectEqual(@as(i64, @intCast(protocol.CONTROL_PROTOCOL_VERSION)), version);
    try std.testing.expect(version == 2);
}
