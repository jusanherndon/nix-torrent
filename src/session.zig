const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const tracker = @import("tracker.zig");
const peer_pool = @import("peer_pool.zig");
const piece_scheduler = @import("piece_scheduler.zig");
const metadata_fetch = @import("metadata_fetch.zig");
const session_types = @import("session_types.zig");

pub const metadata_piece_size = session_types.metadata_piece_size;
pub const PieceDownload = session_types.PieceDownload;
pub const TrackerEndpoint = session_types.TrackerEndpoint;
pub const TorrentSession = session_types.TorrentSession;
pub const ConnectDiag = session_types.ConnectDiag;
pub const DhtContext = peer_pool.DhtContext;

/// Everything a Torrent Session needs from outside for one tick.
pub const World = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    peer_id: [20]u8,
    now_ms: i64,
    dht: ?DhtContext,
};

pub const TickResult = enum {
    /// Paused / failed / already complete: Peers closed if needed; rec projected.
    idle,
    /// Normal progress (content or Metadata exchange). rec projected.
    continued,
    /// All Pieces verified; Peers closed and completed Announce sent. Engine must Handoff.
    ready_for_handoff,
};

pub fn projectToRecord(allocator: std.mem.Allocator, rec: *state.TorrentRecord, session: *TorrentSession) void {
    const n = @min(session.trackers.items.len, rec.trackers.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        state.applyTrackerState(allocator, &rec.trackers[i], session.trackers.items[i].state);
    }
    rec.connected_peer_count = session.peers.items.len + session.metadata_peers.items.len;
    rec.peer_candidate_count = session.peer_candidates.items.len;
    rec.downloading = session.active_piece != null;
    rec.connect_diag = session.connect_diag;
    if (rec.dht_last_error) |old| allocator.free(old);
    rec.dht_last_error = if (session.dht_socket) |sock|
        if (sock.last_error) |e| allocator.dupe(u8, e) catch null else null
    else
        null;
}

pub fn leftBytes(session: *TorrentSession, rec: *state.TorrentRecord) u64 {
    if (session.fetching_metadata) return 1;
    return layoutLeftBytes(session.layout.?, rec.total_bytes);
}

fn layoutLeftBytes(layout: storage.Layout, total_bytes: u64) u64 {
    var verified: u64 = 0;
    for (layout.piece_states, 0..) |ps, i| {
        if (ps == .verified) verified += layout.pieceSpan(i).length;
    }
    return total_bytes - @min(verified, total_bytes);
}

/// Explicit Tracker lifecycle events (pause/remove/start) — not the tick path.
pub fn announceEvent(
    session: *TorrentSession,
    world: World,
    rec: *state.TorrentRecord,
    event: tracker.Event,
) void {
    for (session.trackers.items) |*endpoint| {
        if (event == .stopped and !endpoint.state.started_sent) continue;
        if (event == .started and endpoint.state.started_sent) continue;
        const left = leftBytes(session, rec);
        const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
        const response = tracker.announce(
            world.io,
            world.allocator,
            endpoint.parsed,
            &endpoint.udp,
            session.info_hash,
            world.peer_id,
            session.announce_port,
            0,
            downloaded,
            left,
            event,
            config.encryptionPolicy(world.cfg.network),
            world.cfg.network.tracker_ca_file,
            world.cfg.network.tracker_request_timeout_ms,
            world.now_ms,
        ) catch continue;
        response.deinit(world.allocator);
        if (event == .started) endpoint.state.started_sent = true;
        if (event == .stopped) endpoint.state.started_sent = false;
    }
}

/// One tick of this Torrent Session. Projects onto `rec` before returning.
/// Does not persist state.json or run Handoff — Engine owns those.
pub fn tick(session: *TorrentSession, world: World, rec: *state.TorrentRecord) !TickResult {
    if (rec.status == .paused or rec.status == .failed or rec.status == .complete) {
        if (rec.status == .paused or rec.status == .failed) peer_pool.close(session, world.io, world.allocator);
        projectToRecord(world.allocator, rec, session);
        return .idle;
    }

    if (session.fetching_metadata) {
        try tickMetadata(session, world, rec);
        projectToRecord(world.allocator, rec, session);
        return .continued;
    }

    if (session.layout.?.complete()) {
        peer_pool.close(session, world.io, world.allocator);
        announceEvent(session, world, rec, .completed);
        projectToRecord(world.allocator, rec, session);
        return .ready_for_handoff;
    }

    try tickTrackerAnnounces(session, world, rec);
    if (world.dht) |ctx| try peer_pool.tickDht(world.allocator, world.io, world.cfg, session, ctx, world.peer_id, world.now_ms, .content);
    peer_pool.connectCandidateBatch(world.allocator, world.io, world.cfg, session, world.peer_id, .content);
    try peer_pool.poll(world.io, world.cfg, session, world.allocator);
    try peer_pool.maintain(world.allocator, world.io, world.cfg, session);
    if (world.cfg.network.pex.enabled and !rec.private_torrent)
        peer_pool.emitPex(world.allocator, world.io, session, world.now_ms);
    rec.verified_piece_count = try piece_scheduler.tick(world.allocator, world.io, world.cfg, session, world.now_ms);
    projectToRecord(world.allocator, rec, session);
    return .continued;
}

fn tickMetadata(session: *TorrentSession, world: World, rec: *state.TorrentRecord) !void {
    try tickTrackerAnnounces(session, world, rec);
    if (world.dht) |ctx| try metadata_fetch.tickDht(world.allocator, world.io, world.cfg, session, ctx, world.peer_id, world.now_ms);
    peer_pool.connectCandidateBatch(world.allocator, world.io, world.cfg, session, world.peer_id, .metadata);
    try metadata_fetch.tick(world.allocator, world.io, world.cfg, session, rec, world.dht);
}

/// Tracker announce scheduler. After metadata exists, BEP 12 prefer-working
/// applies (one due tracker per tick at the cursor). While fetching magnet
/// metadata, announce every due tracker up to `max_tracker_announces_per_tick`
/// so peer diversity is not stuck behind a single long interval.
fn tickTrackerAnnounces(session: *TorrentSession, world: World, rec: *state.TorrentRecord) !void {
    const trs = session.trackers.items;
    if (trs.len == 0) return;
    if (session.tracker_cursor >= trs.len) session.tracker_cursor = 0;

    if (session.fetching_metadata) {
        try tickMetadataTrackerAnnounces(session, world, rec);
        return;
    }

    const idx = session.tracker_cursor;
    const endpoint = &trs[idx];
    if (!endpoint.state.due(world.now_ms)) return;

    const ok = try announceTrackerEndpoint(session, world, rec, endpoint);
    if (!ok) {
        // One retry on the same URL after scheduleFailure's backoff, then fail over.
        if (endpoint.state.consecutive_failures < 2) return;
        if (endpoint.state.started_sent) {
            sendStoppedBestEffort(session, world, rec, endpoint);
            endpoint.state.started_sent = false;
        }
        endpoint.state.consecutive_failures = 0;
        session.tracker_cursor = (idx + 1) % trs.len;
    }
}

fn tickMetadataTrackerAnnounces(session: *TorrentSession, world: World, rec: *state.TorrentRecord) !void {
    const trs = session.trackers.items;
    const max = @as(usize, @intCast(world.cfg.limits.max_tracker_announces_per_tick));
    var announced: usize = 0;
    var examined: usize = 0;
    while (examined < trs.len and announced < max) : (examined += 1) {
        const idx = (session.tracker_cursor + examined) % trs.len;
        const endpoint = &trs[idx];
        if (!endpoint.state.due(world.now_ms)) continue;
        const ok = try announceTrackerEndpoint(session, world, rec, endpoint);
        announced += 1;
        if (ok) {
            // Prefer a working tracker as the content-phase cursor once metadata completes.
            session.tracker_cursor = idx;
        } else if (endpoint.state.consecutive_failures >= 2) {
            if (endpoint.state.started_sent) {
                sendStoppedBestEffort(session, world, rec, endpoint);
                endpoint.state.started_sent = false;
            }
            endpoint.state.consecutive_failures = 0;
        }
    }
}

fn sendStoppedBestEffort(session: *TorrentSession, world: World, rec: *state.TorrentRecord, endpoint: *TrackerEndpoint) void {
    const left = leftBytes(session, rec);
    const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
    const response = tracker.announce(
        world.io,
        world.allocator,
        endpoint.parsed,
        &endpoint.udp,
        session.info_hash,
        world.peer_id,
        session.announce_port,
        0,
        downloaded,
        left,
        .stopped,
        config.encryptionPolicy(world.cfg.network),
        world.cfg.network.tracker_ca_file,
        world.cfg.network.tracker_request_timeout_ms,
        world.now_ms,
    ) catch return;
    response.deinit(world.allocator);
}

fn announceTrackerEndpoint(
    session: *TorrentSession,
    world: World,
    rec: *state.TorrentRecord,
    endpoint: *TrackerEndpoint,
) !bool {
    const left = leftBytes(session, rec);
    const event: tracker.Event = if (!endpoint.state.started_sent) .started else .none;
    const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
    log.debug("session", "announcing to tier {d} tracker {s} ({s})", .{ endpoint.tier, endpoint.raw_url, endpoint.parsed.host });
    const enc_policy = config.encryptionPolicy(world.cfg.network);
    const response = tracker.announce(
        world.io,
        world.allocator,
        endpoint.parsed,
        &endpoint.udp,
        session.info_hash,
        world.peer_id,
        session.announce_port,
        0,
        downloaded,
        left,
        event,
        enc_policy,
        world.cfg.network.tracker_ca_file,
        world.cfg.network.tracker_request_timeout_ms,
        world.now_ms,
    ) catch |announce_err| {
        const msg = try std.fmt.allocPrint(world.allocator, "tracker announce failed: {s}", .{@errorName(announce_err)});
        defer world.allocator.free(msg);
        log.debug("session", "tracker announce failed for {s} ({s}): {s}", .{ endpoint.raw_url, endpoint.parsed.host, @errorName(announce_err) });
        try endpoint.state.scheduleFailure(world.now_ms, msg, world.allocator);
        return false;
    };
    defer response.deinit(world.allocator);
    if (response.failure_reason) |reason| {
        log.debug("session", "tracker rejected announce for {s}: {s}", .{ endpoint.raw_url, reason });
        try endpoint.state.scheduleFailure(world.now_ms, reason, world.allocator);
        return false;
    }
    if (endpoint.state.last_error) |old| world.allocator.free(old);
    endpoint.state.last_error = null;
    endpoint.state.started_sent = true;
    endpoint.state.scheduleSuccess(world.now_ms, response.interval);
    log.debug("session", "tracker announce ok for {s}: {d} peers, interval {d}s", .{ endpoint.raw_url, response.peers.len, response.interval });
    const sorted_peers = tracker.sortPeersForEncryption(world.allocator, response.peers, enc_policy) catch response.peers;
    defer if (sorted_peers.ptr != response.peers.ptr) world.allocator.free(sorted_peers);
    if (session.fetching_metadata) {
        peer_pool.connectMetadataBatch(world.allocator, world.io, world.cfg, session, sorted_peers, world.peer_id);
    } else {
        peer_pool.connectContentBatch(world.allocator, world.io, world.cfg, session, sorted_peers, world.peer_id);
    }
    return true;
}

test "projectToRecord copies live session fields onto torrent record" {
    var tr = state.TrackerRecord{ .url = try std.testing.allocator.dupe(u8, "http://127.0.0.1/announce") };
    defer tr.deinit(std.testing.allocator);
    var trackers = [_]state.TrackerRecord{tr};
    var rec = state.TorrentRecord{
        .info_hash_hex = "abcd",
        .name = "test",
        .trackers = trackers[0..],
    };

    var states = [_]storage.PieceState{ .missing, .missing };
    var lengths = [_]u64{32};
    const layout = storage.Layout{
        .allocator = std.testing.allocator,
        .file_lengths = &lengths,
        .piece_length = 16,
        .total_length = 32,
        .piece_states = &states,
    };
    const buffer = try std.testing.allocator.alloc(u8, 16);
    var sess = TorrentSession{
        .info_hash_hex = "abcd",
        .info_hash = [_]u8{0} ** 20,
        .fetching_metadata = false,
        .meta = null,
        .layout = layout,
        .content_dir = "content",
        .trackers = .empty,
        .announce_port = 6881,
        .peers = .empty,
        .metadata_peers = .empty,
        .metadata_chunks = std.AutoHashMap(u32, []u8).init(std.testing.allocator),
        .active_piece = .{
            .piece_index = 0,
            .peer_index = 0,
            .buffer = buffer,
            .received = std.AutoHashMap(u32, void).init(std.testing.allocator),
            .block_size = 16,
            .inflight = std.AutoHashMap(u32, i64).init(std.testing.allocator),
        },
    };
    defer sess.metadata_chunks.deinit();
    defer sess.trackers.deinit(std.testing.allocator);
    defer sess.peers.deinit(std.testing.allocator);
    defer sess.metadata_peers.deinit(std.testing.allocator);
    if (sess.active_piece) |*piece| piece.deinit(std.testing.allocator);

    sess.connect_diag.attempts = 7;
    sess.connect_diag.handshake_ok = 1;
    try sess.peer_candidates.append(std.testing.allocator, tracker.Peer.v4(.{ 1, 2, 3, 4 }, 6881));
    defer sess.peer_candidates.deinit(std.testing.allocator);

    projectToRecord(std.testing.allocator, &rec, &sess);
    try std.testing.expect(rec.downloading);
    try std.testing.expectEqual(@as(usize, 0), rec.connected_peer_count);
    try std.testing.expectEqual(@as(usize, 1), rec.peer_candidate_count);
    try std.testing.expectEqual(@as(u64, 7), rec.connect_diag.attempts);
    try std.testing.expectEqual(@as(u64, 1), rec.connect_diag.handshake_ok);
}
