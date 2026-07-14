const std = @import("std");
const config = @import("config.zig");
const handoff = @import("handoff.zig");
const log = @import("log.zig");
const magnet = @import("magnet.zig");
const state = @import("state.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");
const staging = @import("staging.zig");
const session = @import("session.zig");

pub const DhtContext = session.DhtContext;
pub const PieceDownload = session.PieceDownload;
pub const TrackerEndpoint = session.TrackerEndpoint;
pub const TorrentSession = session.TorrentSession;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(TorrentSession) = .empty,

    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Engine, io: std.Io) void {
        for (self.sessions.items) |*sess| sess.deinit(io, self.allocator);
        self.sessions.deinit(self.allocator);
    }

    pub fn loadFromRegistry(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, dht_ctx: ?DhtContext) !void {
        for (self.sessions.items) |*sess| sess.deinit(io, self.allocator);
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

        // V3: trackers and DHT announce_peer advertise the listen port, while the
        // per-torrent DHT socket binds to dht_base_port + slot.
        const dht_bind_port: u16 = if (rec.dht_slot) |slot| @intCast(cfg.network.dht_base_port + slot) else @intCast(cfg.network.dht_base_port);
        const advertise_port: u16 = @intCast(cfg.network.listen_port);
        const dht_socket = try openDhtSocket(io, self.allocator, rec, dht_ctx, dht_bind_port);

        const sess = TorrentSession{
            .info_hash_hex = rec.info_hash_hex,
            .info_hash = loaded.meta.info_hash,
            .fetching_metadata = false,
            .meta = loaded.meta,
            .layout = loaded.layout,
            .content_dir = loaded.content_dir,
            .trackers = trackers,
            .announce_port = advertise_port,
            .dht_socket = dht_socket,
            .peers = .empty,
            .metadata_peers = .empty,
            .metadata_chunks = std.AutoHashMap(u32, []u8).init(self.allocator),
            .active_piece = null,
        };
        try self.sessions.append(self.allocator, sess);
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

        const dht_bind_port: u16 = if (rec.dht_slot) |slot| @intCast(cfg.network.dht_base_port + slot) else @intCast(cfg.network.dht_base_port);
        const advertise_port: u16 = @intCast(cfg.network.listen_port);
        const dht_socket = try openDhtSocket(io, self.allocator, rec, dht_ctx, dht_bind_port);

        const sess = TorrentSession{
            .info_hash_hex = rec.info_hash_hex,
            .info_hash = info_hash,
            .fetching_metadata = true,
            .meta = null,
            .layout = null,
            .content_dir = null,
            .trackers = trackers,
            .announce_port = advertise_port,
            .dht_socket = dht_socket,
            .peers = .empty,
            .metadata_peers = .empty,
            .metadata_chunks = std.AutoHashMap(u32, []u8).init(self.allocator),
            .active_piece = null,
        };
        try self.sessions.append(self.allocator, sess);
        log.debug("engine", "started metadata session for {s} ({d} trackers)", .{ rec.info_hash_hex, trackers.items.len });
    }

    pub fn removeSession(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        for (self.sessions.items, 0..) |*sess, i| {
            if (std.mem.eql(u8, sess.info_hash_hex, info_hash_hex)) {
                log.debug("engine", "removed session for {s}", .{info_hash_hex});
                sess.deinit(io, self.allocator);
                _ = self.sessions.orderedRemove(i);
                return;
            }
        }
    }

    pub fn findSession(self: *Engine, info_hash_hex: []const u8) ?*TorrentSession {
        for (self.sessions.items) |*sess| {
            if (std.mem.eql(u8, sess.info_hash_hex, info_hash_hex)) return sess;
        }
        return null;
    }

    /// Total inbound (Listen Socket) peers currently attached across all sessions.
    pub fn inboundPeerCount(self: *Engine) u64 {
        var n: u64 = 0;
        for (self.sessions.items) |*sess| {
            for (sess.peers.items) |p| {
                if (p.direction == .inbound) n += 1;
            }
            for (sess.metadata_peers.items) |p| {
                if (p.direction == .inbound) n += 1;
            }
        }
        return n;
    }

    pub fn sendTrackerEvent(
        self: *Engine,
        io: std.Io,
        cfg: config.Config,
        sess: *TorrentSession,
        rec: *state.TorrentRecord,
        peer_id: [20]u8,
        event: tracker.Event,
        now_ms: i64,
    ) void {
        session.announceEvent(sess, .{
            .allocator = self.allocator,
            .io = io,
            .cfg = cfg,
            .peer_id = peer_id,
            .now_ms = now_ms,
            .dht = null,
        }, rec, event);
    }

    pub fn closeDht(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        if (self.findSession(info_hash_hex)) |sess| {
            if (sess.dht_socket) |*sock| sock.close(io, self.allocator);
            sess.dht_socket = null;
        }
    }

    pub fn projectTrackerStates(self: *Engine, rec: *state.TorrentRecord, sess: *TorrentSession) void {
        session.projectToRecord(self.allocator, rec, sess);
    }

    pub fn persistTorrentState(
        self: *Engine,
        io: std.Io,
        staging_root: []const u8,
        rec: *state.TorrentRecord,
        sess: ?*TorrentSession,
    ) !void {
        if (sess) |s| session.projectToRecord(self.allocator, rec, s);
        try state.writeTorrentState(io, self.allocator, staging_root, rec.*);
    }

    pub fn tick(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, peer_id: [20]u8, now_ms: i64, dht_ctx: ?DhtContext) !void {
        if (dht_ctx) |ctx| try maybeRefreshDht(io, self.allocator, ctx, cfg, now_ms);

        const world = session.World{
            .allocator = self.allocator,
            .io = io,
            .cfg = cfg,
            .peer_id = peer_id,
            .now_ms = now_ms,
            .dht = dht_ctx,
        };

        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const sess = &self.sessions.items[i];
            const rec = registry.find(sess.info_hash_hex) orelse {
                i += 1;
                continue;
            };

            switch (try session.tick(sess, world, rec)) {
                .idle, .continued => {
                    try state.writeTorrentState(io, self.allocator, cfg.staging_area, rec.*);
                    i += 1;
                },
                .ready_for_handoff => {
                    try completeHandoff(self, io, cfg, registry, sess, rec);
                    // Session removed — do not advance i.
                },
            }
        }
    }
};

fn buildTrackerEndpoints(allocator: std.mem.Allocator, cfg: config.Config, rec: *state.TorrentRecord) !std.ArrayList(TrackerEndpoint) {
    var trackers: std.ArrayList(TrackerEndpoint) = .empty;
    for (rec.trackers) |*tr_rec| {
        const parsed = try tracker.parseAnnounceUrl(allocator, tr_rec.url);
        errdefer parsed.deinit(allocator);
        try trackers.append(allocator, .{
            .raw_url = try allocator.dupe(u8, tr_rec.url),
            .parsed = parsed,
            .tier = tr_rec.tier,
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

fn maybeRefreshDht(io: std.Io, allocator: std.mem.Allocator, ctx: DhtContext, cfg: config.Config, now_ms: i64) !void {
    if (!ctx.cfg.enabled) return;
    if (now_ms - ctx.last_refresh_ms.* < @as(i64, @intCast(ctx.cfg.refresh_interval_ms))) return;
    ctx.last_refresh_ms.* = now_ms;
    _ = allocator;
    _ = cfg;
    _ = io;
}

fn completeHandoff(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    registry: *state.Registry,
    sess: *TorrentSession,
    rec: *state.TorrentRecord,
) !void {
    log.info("engine", "torrent {s} download complete, moving to final destination", .{rec.info_hash_hex});

    const final_path = handoff.moveCompletedContent(io, engine.allocator, sess.content_dir.?, sess.meta.?, cfg.final_destination) catch {
        rec.status = .failed;
        try state.writeTorrentState(io, engine.allocator, cfg.staging_area, rec.*);
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
    const info_hash_hex = rec.info_hash_hex;
    _ = registry.remove(info_hash_hex);
    deleteTorrentStatePath(io, engine.allocator, cfg.staging_area, info_hash_hex) catch {};
    engine.removeSession(io, info_hash_hex);
}

fn deleteTorrentStatePath(io: std.Io, allocator: std.mem.Allocator, staging_area: []const u8, info_hash: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ staging_area, info_hash, "state.json" });
    defer allocator.free(path);
    if (std.fs.path.isAbsolute(path)) try std.Io.Dir.deleteFileAbsolute(io, path) else try std.Io.Dir.cwd().deleteFile(io, path);
}
