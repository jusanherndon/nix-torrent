const std = @import("std");
const config = @import("config.zig");
const handoff = @import("handoff.zig");
const log = @import("log.zig");
const magnet = @import("magnet.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");
const staging = @import("staging.zig");
const engine_session = @import("engine_session.zig");
const peer_pool = @import("peer_pool.zig");
const piece_scheduler = @import("piece_scheduler.zig");
const metadata_fetch = @import("metadata_fetch.zig");

pub const DhtContext = peer_pool.DhtContext;
pub const PieceDownload = engine_session.PieceDownload;
pub const TrackerEndpoint = engine_session.TrackerEndpoint;
pub const TorrentSession = engine_session.TorrentSession;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(TorrentSession) = .empty,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine, io: std.Io) void {
        for (self.sessions.items) |*session| session.deinit(io, self.allocator);
        self.sessions.deinit(self.allocator);
    }

    pub fn loadFromRegistry(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, dht_ctx: ?DhtContext) !void {
        for (self.sessions.items) |*session| session.deinit(io, self.allocator);
        self.sessions.clearRetainingCapacity();
        for (registry.records.items) |*rec| {
            if (rec.status == .complete) continue;
            try self.addSession(io, cfg, registry, rec, dht_ctx);
        }
    }

    pub fn addSession(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, rec: *state.TorrentRecord, dht_ctx: ?DhtContext) !void {
        _ = registry;
        if (self.findSession(rec.info_hash_hex) != null) return;
        if (!rec.metadata_complete) {
            try self.addMetadataSession(io, cfg, rec, dht_ctx);
            return;
        }
        const loaded = try staging.loadForSession(io, self.allocator, cfg.staging_area, rec.info_hash_hex);
        errdefer {
            loaded.layout.deinit();
            loaded.meta.deinit();
            self.allocator.free(loaded.content_dir);
        }
        const dht_enabled = dht_ctx != null and dht_ctx.?.cfg.enabled and !rec.private_torrent;
        if (rec.trackers.len == 0 and !dht_enabled) return error.MissingTracker;

        var trackers = try buildTrackerEndpoints(self.allocator, cfg, rec);
        errdefer {
            for (trackers.items) |*tr| tr.deinit(self.allocator);
            trackers.deinit(self.allocator);
        }

        const announce_port: u16 = if (rec.dht_slot) |slot| @intCast(cfg.network.dht_base_port + slot) else @intCast(cfg.network.dht_base_port);
        const dht_socket = try openDhtSocket(io, self.allocator, rec, dht_ctx, announce_port);

        const session = TorrentSession{
            .info_hash_hex = rec.info_hash_hex,
            .info_hash = loaded.meta.info_hash,
            .fetching_metadata = false,
            .meta = loaded.meta,
            .layout = loaded.layout,
            .content_dir = loaded.content_dir,
            .trackers = trackers,
            .announce_port = announce_port,
            .dht_socket = dht_socket,
            .peers = .empty,
            .metadata_peers = .empty,
            .metadata_chunks = std.AutoHashMap(u32, []u8).init(self.allocator),
            .active_piece = null,
        };
        try self.sessions.append(self.allocator, session);
        log.debug("engine", "started content session for {s} ({d} trackers)", .{ rec.info_hash_hex, trackers.items.len });
    }

    fn addMetadataSession(self: *Engine, io: std.Io, cfg: config.Config, rec: *state.TorrentRecord, dht_ctx: ?DhtContext) !void {
        const info_hash = try magnet.infoHashBytes(rec.info_hash_hex);
        const dht_enabled = dht_ctx != null and dht_ctx.?.cfg.enabled and !rec.private_torrent;
        if (rec.trackers.len == 0 and !dht_enabled) return error.MissingTracker;

        var trackers = try buildTrackerEndpoints(self.allocator, cfg, rec);
        errdefer {
            for (trackers.items) |*tr| tr.deinit(self.allocator);
            trackers.deinit(self.allocator);
        }

        const announce_port: u16 = if (rec.dht_slot) |slot| @intCast(cfg.network.dht_base_port + slot) else @intCast(cfg.network.dht_base_port);
        const dht_socket = try openDhtSocket(io, self.allocator, rec, dht_ctx, announce_port);

        const session = TorrentSession{
            .info_hash_hex = rec.info_hash_hex,
            .info_hash = info_hash,
            .fetching_metadata = true,
            .meta = null,
            .layout = null,
            .content_dir = null,
            .trackers = trackers,
            .announce_port = announce_port,
            .dht_socket = dht_socket,
            .peers = .empty,
            .metadata_peers = .empty,
            .metadata_chunks = std.AutoHashMap(u32, []u8).init(self.allocator),
            .active_piece = null,
        };
        try self.sessions.append(self.allocator, session);
        log.debug("engine", "started metadata session for {s} ({d} trackers)", .{ rec.info_hash_hex, trackers.items.len });
    }

    pub fn removeSession(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        for (self.sessions.items, 0..) |*session, i| {
            if (std.mem.eql(u8, session.info_hash_hex, info_hash_hex)) {
                log.debug("engine", "removed session for {s}", .{info_hash_hex});
                session.deinit(io, self.allocator);
                _ = self.sessions.orderedRemove(i);
                return;
            }
        }
    }

    pub fn findSession(self: *Engine, info_hash_hex: []const u8) ?*TorrentSession {
        for (self.sessions.items) |*session| {
            if (std.mem.eql(u8, session.info_hash_hex, info_hash_hex)) return session;
        }
        return null;
    }

    pub fn sendTrackerEvent(
        self: *Engine,
        io: std.Io,
        cfg: config.Config,
        session: *TorrentSession,
        rec: *state.TorrentRecord,
        peer_id: [20]u8,
        event: tracker.Event,
        now_ms: i64,
    ) void {
        for (session.trackers.items) |*endpoint| {
            if (event == .stopped and !endpoint.state.started_sent) continue;
            if (event == .started and endpoint.state.started_sent) continue;
            const left = sessionLeftBytes(session, rec);
            const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
            const response = tracker.announce(
                io,
                self.allocator,
                endpoint.parsed,
                &endpoint.udp,
                session.info_hash,
                peer_id,
                session.announce_port,
                0,
                downloaded,
                left,
                event,
                config.encryptionPolicy(cfg.network),
                cfg.network.tracker_request_timeout_ms,
                now_ms,
            ) catch continue;
            response.deinit(self.allocator);
            if (event == .started) endpoint.state.started_sent = true;
            if (event == .stopped) endpoint.state.started_sent = false;
        }
    }

    pub fn closeDht(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        if (self.findSession(info_hash_hex)) |session| {
            if (session.dht_socket) |*sock| sock.close(io, self.allocator);
            session.dht_socket = null;
        }
    }

    pub fn projectTrackerStates(self: *Engine, rec: *state.TorrentRecord, session: *TorrentSession) void {
        projectSessionToRecord(self.allocator, rec, session);
    }

    pub fn persistTorrentState(
        self: *Engine,
        io: std.Io,
        staging_root: []const u8,
        rec: *state.TorrentRecord,
        session: ?*TorrentSession,
    ) !void {
        if (session) |s| projectSessionToRecord(self.allocator, rec, s);
        try state.writeTorrentState(io, self.allocator, staging_root, rec.*);
    }

    pub fn tick(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, peer_id: [20]u8, now_ms: i64, dht_ctx: ?DhtContext) !void {
        if (dht_ctx) |ctx| try maybeRefreshDht(io, self.allocator, ctx, cfg, now_ms);
        for (self.sessions.items) |*session| {
            const rec = registry.find(session.info_hash_hex) orelse continue;
            try tickSession(self, io, cfg, registry, session, rec, peer_id, now_ms, dht_ctx);
        }
    }
};

fn projectSessionToRecord(allocator: std.mem.Allocator, rec: *state.TorrentRecord, session: *TorrentSession) void {
    const n = @min(session.trackers.items.len, rec.trackers.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        state.applyTrackerState(allocator, &rec.trackers[i], session.trackers.items[i].state);
    }
    rec.connected_peer_count = session.peers.items.len;
    rec.downloading = session.active_piece != null;
    if (rec.dht_last_error) |old| allocator.free(old);
    rec.dht_last_error = if (session.dht_socket) |sock|
        if (sock.last_error) |e| allocator.dupe(u8, e) catch null else null
    else
        null;
}

fn buildTrackerEndpoints(allocator: std.mem.Allocator, cfg: config.Config, rec: *state.TorrentRecord) !std.ArrayList(TrackerEndpoint) {
    var trackers: std.ArrayList(TrackerEndpoint) = .empty;
    for (rec.trackers) |*tr_rec| {
        const parsed = try tracker.parseAnnounceUrl(allocator, tr_rec.url);
        errdefer parsed.deinit(allocator);
        try trackers.append(allocator, .{
            .raw_url = try allocator.dupe(u8, tr_rec.url),
            .parsed = parsed,
            .state = .{
                .next_announce_ms = tr_rec.next_announce_ms,
                .last_error = if (tr_rec.last_error) |s| try allocator.dupe(u8, s) else null,
                .started_sent = tr_rec.started_sent,
                .retry_min_ms = @intCast(cfg.network.tracker_retry_min_ms),
                .retry_max_ms = @intCast(cfg.network.tracker_retry_max_ms),
                .retry_ms = @intCast(cfg.network.tracker_retry_min_ms),
            },
            .udp = .{},
        });
    }
    return trackers;
}

fn openDhtSocket(io: std.Io, allocator: std.mem.Allocator, rec: *state.TorrentRecord, dht_ctx: ?DhtContext, announce_port: u16) !?dht.TorrentDhtSocket {
    if (dht_ctx) |ctx| {
        if (ctx.cfg.enabled and !rec.private_torrent) {
            if (rec.dht_slot) |slot| {
                var dht_socket: dht.TorrentDhtSocket = .{ .slot = slot, .bind_port = announce_port };
                try dht_socket.open(io, announce_port);
                if (!ctx.bootstrapped.*) {
                    if (dht_socket.socket) |sock| {
                        dht.bootstrap(io, allocator, ctx.routing, sock, ctx.cfg.bootstrap_nodes, ctx.cfg.request_timeout_ms) catch {};
                        ctx.bootstrapped.* = true;
                    }
                }
                return dht_socket;
            }
        }
    }
    return null;
}

fn sessionLeftBytes(session: *TorrentSession, rec: *state.TorrentRecord) u64 {
    if (session.fetching_metadata) return 1;
    return leftBytes(session.layout.?, rec.total_bytes);
}

fn maybeRefreshDht(io: std.Io, allocator: std.mem.Allocator, ctx: DhtContext, cfg: config.Config, now_ms: i64) !void {
    if (!ctx.cfg.enabled) return;
    if (now_ms - ctx.last_refresh_ms.* < @as(i64, @intCast(ctx.cfg.refresh_interval_ms))) return;
    ctx.last_refresh_ms.* = now_ms;
    _ = allocator;
    _ = cfg;
    _ = io;
}

fn tickSession(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    registry: *state.Registry,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    peer_id: [20]u8,
    now_ms: i64,
    dht_ctx: ?DhtContext,
) !void {
    if (rec.status == .paused or rec.status == .failed or rec.status == .complete) {
        if (rec.status == .paused or rec.status == .failed) peer_pool.close(session, io, engine.allocator);
        return;
    }

    if (session.fetching_metadata) {
        try tickMetadataSession(engine, io, cfg, session, rec, peer_id, now_ms, dht_ctx);
        return;
    }

    if (session.layout.?.complete()) {
        try completeTorrent(engine, io, cfg, registry, session, rec, peer_id, now_ms);
        return;
    }

    try tickTrackerAnnounces(engine, io, cfg, session, rec, peer_id, now_ms);
    if (dht_ctx) |ctx| try peer_pool.tickDht(engine.allocator, io, cfg, session, ctx, peer_id, now_ms, .content);
    peer_pool.connectCandidateBatch(engine.allocator, io, cfg, session, peer_id, .content);
    try peer_pool.poll(io, cfg, session, engine.allocator);
    try peer_pool.maintain(engine.allocator, io, cfg, session);
    rec.verified_piece_count = try piece_scheduler.tick(engine.allocator, io, cfg, session, now_ms);
    try engine.persistTorrentState(io, cfg.staging_area, rec, session);
}

fn tickMetadataSession(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    peer_id: [20]u8,
    now_ms: i64,
    dht_ctx: ?DhtContext,
) !void {
    try tickTrackerAnnounces(engine, io, cfg, session, rec, peer_id, now_ms);
    if (dht_ctx) |ctx| try metadata_fetch.tickDht(engine.allocator, io, cfg, session, ctx, peer_id, now_ms);
    peer_pool.connectCandidateBatch(engine.allocator, io, cfg, session, peer_id, .metadata);
    try metadata_fetch.tick(engine.allocator, io, cfg, session, rec, dht_ctx);
    try engine.persistTorrentState(io, cfg.staging_area, rec, session);
}

fn tickTrackerAnnounces(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    const max_announces = @as(usize, @intCast(cfg.limits.max_tracker_announces_per_tick));
    var announced: usize = 0;
    for (session.trackers.items) |*endpoint| {
        if (endpoint.parsed.scheme != .udp) continue;
        if (!endpoint.state.due(now_ms)) continue;
        try announceTrackerEndpoint(engine, io, cfg, session, rec, endpoint, peer_id, now_ms);
        announced += 1;
        if (announced >= max_announces) return;
    }
    for (session.trackers.items) |*endpoint| {
        if (endpoint.parsed.scheme != .http) continue;
        if (!endpoint.state.due(now_ms)) continue;
        try announceTrackerEndpoint(engine, io, cfg, session, rec, endpoint, peer_id, now_ms);
        announced += 1;
        if (announced >= max_announces) return;
    }
}

fn announceTrackerEndpoint(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    endpoint: *TrackerEndpoint,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    const left = sessionLeftBytes(session, rec);
    const event: tracker.Event = if (!endpoint.state.started_sent) .started else .none;
    const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
    log.debug("engine", "announcing to {s} ({s})", .{ endpoint.raw_url, endpoint.parsed.host });
    const enc_policy = config.encryptionPolicy(cfg.network);
    const response = tracker.announce(
        io,
        engine.allocator,
        endpoint.parsed,
        &endpoint.udp,
        session.info_hash,
        peer_id,
        session.announce_port,
        0,
        downloaded,
        left,
        event,
        enc_policy,
        cfg.network.tracker_request_timeout_ms,
        now_ms,
    ) catch |announce_err| {
        const msg = try std.fmt.allocPrint(engine.allocator, "tracker announce failed: {s}", .{@errorName(announce_err)});
        defer engine.allocator.free(msg);
        log.debug("engine", "tracker announce failed for {s} ({s}): {s}", .{ endpoint.raw_url, endpoint.parsed.host, @errorName(announce_err) });
        try endpoint.state.scheduleFailure(now_ms, msg, engine.allocator);
        return;
    };
    defer response.deinit(engine.allocator);
    if (response.failure_reason) |reason| {
        log.debug("engine", "tracker rejected announce for {s}: {s}", .{ endpoint.raw_url, reason });
        try endpoint.state.scheduleFailure(now_ms, reason, engine.allocator);
        return;
    }
    if (endpoint.state.last_error) |old| engine.allocator.free(old);
    endpoint.state.last_error = null;
    endpoint.state.started_sent = true;
    endpoint.state.scheduleSuccess(now_ms, response.interval);
    log.debug("engine", "tracker announce ok for {s}: {d} peers, interval {d}s", .{ endpoint.raw_url, response.peers.len, response.interval });
    const sorted_peers = tracker.sortPeersForEncryption(engine.allocator, response.peers, enc_policy) catch response.peers;
    defer if (sorted_peers.ptr != response.peers.ptr) engine.allocator.free(sorted_peers);
    if (session.fetching_metadata) {
        peer_pool.connectMetadataBatch(engine.allocator, io, cfg, session, sorted_peers, peer_id);
    } else {
        peer_pool.connectContentBatch(engine.allocator, io, cfg, session, sorted_peers, peer_id);
    }
}

fn leftBytes(layout: storage.Layout, total_bytes: u64) u64 {
    var verified: u64 = 0;
    for (layout.piece_states, 0..) |ps, i| {
        if (ps == .verified) verified += layout.pieceSpan(i).length;
    }
    return total_bytes - @min(verified, total_bytes);
}

fn completeTorrent(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    registry: *state.Registry,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    peer_pool.close(session, io, engine.allocator);
    engine.sendTrackerEvent(io, cfg, session, rec, peer_id, .completed, now_ms);
    log.info("engine", "torrent {s} download complete, moving to final destination", .{rec.info_hash_hex});

    const final_path = handoff.moveCompletedContent(io, engine.allocator, session.content_dir.?, session.meta.?, cfg.final_destination) catch {
        rec.status = .failed;
        return;
    };
    defer engine.allocator.free(final_path);

    const completed_at = try std.fmt.allocPrint(engine.allocator, "{d}", .{std.Io.Timestamp.now(io, .real).toSeconds()});
    defer engine.allocator.free(completed_at);
    try state.appendHistoryRecord(io, engine.allocator, cfg.staging_area, .{
        .info_hash_hex = rec.info_hash_hex,
        .name = rec.name,
        .final_path = final_path,
        .completed_at = completed_at,
        .total_bytes = rec.total_bytes,
    });
    try registry.addCompletion(.{
        .info_hash_hex = try engine.allocator.dupe(u8, rec.info_hash_hex),
        .name = try engine.allocator.dupe(u8, rec.name),
        .final_path = try engine.allocator.dupe(u8, final_path),
        .completed_at = try engine.allocator.dupe(u8, completed_at),
        .total_bytes = rec.total_bytes,
    });
    _ = registry.remove(rec.info_hash_hex);
    deleteTorrentStatePath(io, engine.allocator, cfg.staging_area, rec.info_hash_hex) catch {};
    engine.removeSession(io, rec.info_hash_hex);
}

fn deleteTorrentStatePath(io: std.Io, allocator: std.mem.Allocator, staging_area: []const u8, info_hash: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ staging_area, info_hash, "state.json" });
    defer allocator.free(path);
    if (std.fs.path.isAbsolute(path)) try std.Io.Dir.deleteFileAbsolute(io, path) else try std.Io.Dir.cwd().deleteFile(io, path);
}

test "projectSessionToRecord copies live session fields onto torrent record" {
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
    var session = TorrentSession{
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
    defer session.metadata_chunks.deinit();
    defer session.trackers.deinit(std.testing.allocator);
    defer session.peers.deinit(std.testing.allocator);
    defer session.metadata_peers.deinit(std.testing.allocator);
    if (session.active_piece) |*piece| piece.deinit(std.testing.allocator);

    projectSessionToRecord(std.testing.allocator, &rec, &session);
    try std.testing.expect(rec.downloading);
    try std.testing.expectEqual(@as(usize, 0), rec.connected_peer_count);
}
