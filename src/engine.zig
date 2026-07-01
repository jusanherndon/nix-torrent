const std = @import("std");
const config = @import("config.zig");
const handoff = @import("handoff.zig");
const magnet = @import("magnet.zig");
const peer = @import("peer.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");

pub const DhtContext = struct {
    routing: *dht.RoutingTable,
    cfg: dht.Config,
    bootstrapped: *bool,
    last_refresh_ms: *i64,
    slots: *dht.SlotAllocator,
};

const BlockMap = std.AutoHashMap(u32, void);

pub const PieceDownload = struct {
    piece_index: usize,
    peer_index: usize,
    buffer: []u8,
    received: BlockMap,
    block_size: u32,
    inflight: std.AutoHashMap(u32, i64),

    pub fn deinit(self: *PieceDownload, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
        self.received.deinit();
        self.inflight.deinit();
    }

    pub fn complete(self: PieceDownload, piece_len: usize) bool {
        return self.received.count() > 0 and self.receivedBytes() >= piece_len;
    }

    pub fn receivedBytes(self: PieceDownload) usize {
        var total: usize = 0;
        var it = self.received.keyIterator();
        while (it.next()) |begin| {
            total += @min(self.block_size, self.buffer.len - begin.*);
        }
        return total;
    }
};

pub const TrackerEndpoint = struct {
    raw_url: []const u8,
    parsed: tracker.AnnounceUrl,
    state: tracker.TrackerState,
    udp: tracker.UdpSession,

    pub fn deinit(self: *TrackerEndpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.raw_url);
        self.state.deinit(allocator);
        self.parsed.deinit(allocator);
    }
};

const metadata_piece_size: u32 = 16 * 1024;

pub const TorrentSession = struct {
    info_hash_hex: []const u8,
    info_hash: torrent.InfoHash,
    fetching_metadata: bool,
    meta: ?torrent.Metadata,
    layout: ?storage.Layout,
    content_dir: ?[]const u8,
    trackers: std.ArrayList(TrackerEndpoint),
    announce_port: u16,
    dht_socket: ?dht.TorrentDhtSocket = null,
    peers: std.ArrayList(peer.Connection),
    metadata_peers: std.ArrayList(peer.Connection),
    metadata_chunks: std.AutoHashMap(u32, []u8),
    metadata_size: ?usize = null,
    metadata_next_request: u32 = 0,
    active_piece: ?PieceDownload,
    failure_reason: ?[]const u8 = null,

    pub fn deinit(self: *TorrentSession, io: std.Io, allocator: std.mem.Allocator) void {
        for (self.peers.items) |*p| p.deinit(io);
        self.peers.deinit(allocator);
        for (self.metadata_peers.items) |*p| p.deinit(io);
        self.metadata_peers.deinit(allocator);
        var chunk_it = self.metadata_chunks.iterator();
        while (chunk_it.next()) |entry| allocator.free(entry.value_ptr.*);
        self.metadata_chunks.deinit();
        if (self.active_piece) |*piece| piece.deinit(allocator);
        if (self.layout) |*layout| layout.deinit();
        if (self.meta) |*meta| meta.deinit();
        if (self.content_dir) |dir| allocator.free(dir);
        for (self.trackers.items) |*tr| tr.deinit(allocator);
        self.trackers.deinit(allocator);
        if (self.dht_socket) |*sock| sock.close(io, allocator);
        if (self.failure_reason) |s| allocator.free(s);
    }
};

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
        const metadata_path = try std.fs.path.join(self.allocator, &.{ cfg.staging_area, rec.info_hash_hex, "metadata.torrent" });
        defer self.allocator.free(metadata_path);
        const meta = try torrent.Metadata.parseFile(self.allocator, io, metadata_path);
        errdefer meta.deinit();
        const content_dir = try std.fs.path.join(self.allocator, &.{ cfg.staging_area, rec.info_hash_hex, "content" });
        errdefer self.allocator.free(content_dir);
        var layout = try storage.Layout.init(self.allocator, meta);
        errdefer layout.deinit();
        try storage.recheck(io, self.allocator, content_dir, meta, &layout);
        rec.verified_piece_count = 0;
        for (layout.piece_states) |ps| {
            if (ps == .verified) rec.verified_piece_count += 1;
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
            .info_hash = meta.info_hash,
            .fetching_metadata = false,
            .meta = meta,
            .layout = layout,
            .content_dir = content_dir,
            .trackers = trackers,
            .announce_port = announce_port,
            .dht_socket = dht_socket,
            .peers = .empty,
            .metadata_peers = .empty,
            .metadata_chunks = std.AutoHashMap(u32, []u8).init(self.allocator),
            .active_piece = null,
        };
        try self.sessions.append(self.allocator, session);
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
    }

    pub fn removeSession(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        for (self.sessions.items, 0..) |*session, i| {
            if (std.mem.eql(u8, session.info_hash_hex, info_hash_hex)) {
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
        for (session.trackers.items, 0..) |*endpoint, i| {
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
                cfg.network.tracker_request_timeout_ms,
                now_ms,
            ) catch continue;
            response.deinit(self.allocator);
            if (event == .started) endpoint.state.started_sent = true;
            if (event == .stopped) endpoint.state.started_sent = false;
            syncTrackerRecord(self.allocator, rec, i, endpoint);
        }
    }

    pub fn closeDht(self: *Engine, io: std.Io, info_hash_hex: []const u8) void {
        if (self.findSession(info_hash_hex)) |session| {
            if (session.dht_socket) |*sock| sock.close(io, self.allocator);
            session.dht_socket = null;
        }
    }

    pub fn tick(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, peer_id: [20]u8, now_ms: i64, dht_ctx: ?DhtContext) !void {
        if (dht_ctx) |ctx| try maybeRefreshDht(io, self.allocator, ctx, cfg, now_ms);
        for (self.sessions.items) |*session| {
            const rec = registry.find(session.info_hash_hex) orelse continue;
            try tickSession(self, io, cfg, registry, session, rec, peer_id, now_ms, dht_ctx);
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

fn syncTrackerRecord(allocator: std.mem.Allocator, rec: *state.TorrentRecord, index: usize, endpoint: *TrackerEndpoint) void {
    if (index >= rec.trackers.len) return;
    const tr = &rec.trackers[index];
    tr.next_announce_ms = endpoint.state.next_announce_ms;
    tr.started_sent = endpoint.state.started_sent;
    if (tr.last_error) |old| allocator.free(old);
    tr.last_error = if (endpoint.state.last_error) |s| allocator.dupe(u8, s) catch null else null;
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
        if (rec.status == .paused or rec.status == .failed) closePeers(session, io, engine.allocator);
        return;
    }

    if (session.fetching_metadata) {
        try tickMetadataSession(engine, io, cfg, registry, session, rec, peer_id, now_ms, dht_ctx);
        return;
    }

    if (session.layout.?.complete()) {
        try completeTorrent(engine, io, cfg, registry, session, rec, peer_id, now_ms);
        return;
    }

    for (session.trackers.items, 0..) |*endpoint, i| {
        if (endpoint.state.due(now_ms)) {
            try announceTrackerEndpoint(engine, io, cfg, session, rec, endpoint, i, peer_id, now_ms);
        }
    }

    if (dht_ctx) |ctx| {
        if (session.dht_socket) |*sock| {
            const dht_peers = try sock.tick(io, engine.allocator, ctx.routing, ctx.cfg, session.info_hash, now_ms);
            defer engine.allocator.free(dht_peers);
            for (dht_peers) |tp| {
                if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasPeer(session, tp.ip, tp.port)) continue;
                var conn = peer.Connection.connect(io, engine.allocator, tp.ip, tp.port, cfg.network.peer_connect_timeout_ms) catch continue;
                conn.performHandshake(io, session.info_hash, peer_id, config.encryptionPolicy(cfg.network), false) catch {
                    conn.deinit(io);
                    continue;
                };
                conn.sendInterested(io) catch {
                    conn.deinit(io);
                    continue;
                };
                try session.peers.append(engine.allocator, conn);
            }
        }
    }

    try maintainPeers(engine.allocator, io, cfg, session, peer_id, now_ms);
    try pollPeers(io, cfg, session, rec, now_ms);
    try scheduleDownloads(engine.allocator, io, cfg, session, rec, now_ms);
    rec.verified_piece_count = countVerified(session.layout.?);
    try state.writeTorrentState(io, engine.allocator, cfg.staging_area, rec.*);
}

fn countVerified(layout: storage.Layout) usize {
    var n: usize = 0;
    for (layout.piece_states) |ps| {
        if (ps == .verified) n += 1;
    }
    return n;
}

fn closePeers(session: *TorrentSession, io: std.Io, allocator: std.mem.Allocator) void {
    for (session.peers.items) |*p| p.close(io);
    session.peers.clearRetainingCapacity();
    for (session.metadata_peers.items) |*p| p.close(io);
    session.metadata_peers.clearRetainingCapacity();
    if (session.active_piece) |*piece| {
        piece.deinit(allocator);
        session.active_piece = null;
    }
}

fn tickMetadataSession(
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
    for (session.trackers.items, 0..) |*endpoint, i| {
        if (endpoint.state.due(now_ms)) {
            try announceTrackerEndpoint(engine, io, cfg, session, rec, endpoint, i, peer_id, now_ms);
        }
    }

    if (dht_ctx) |ctx| {
        if (session.dht_socket) |*sock| {
            const dht_peers = try sock.tick(io, engine.allocator, ctx.routing, ctx.cfg, session.info_hash, now_ms);
            defer engine.allocator.free(dht_peers);
            for (dht_peers) |tp| {
                if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasMetadataPeer(session, tp.ip, tp.port)) continue;
                try connectMetadataPeer(engine, io, cfg, session, tp.ip, tp.port, peer_id);
            }
        }
    }

    try maintainMetadataPeers(engine, io, cfg, session);
    try tryCompleteMetadata(engine, io, cfg, registry, session, rec, dht_ctx);
    try state.writeTorrentState(io, engine.allocator, cfg.staging_area, rec.*);
}

fn hasMetadataPeer(session: *TorrentSession, ip: [4]u8, port: u16) bool {
    for (session.metadata_peers.items) |p| {
        if (p.peer_ip[0] == ip[0] and p.peer_ip[1] == ip[1] and p.peer_ip[2] == ip[2] and p.peer_ip[3] == ip[3] and p.peer_port == port) return true;
    }
    return false;
}

fn connectMetadataPeer(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    ip: [4]u8,
    port: u16,
    peer_id: [20]u8,
) !void {
    if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) return;
    if (hasMetadataPeer(session, ip, port)) return;
    var conn = peer.Connection.connect(io, engine.allocator, ip, port, cfg.network.peer_connect_timeout_ms) catch return;
    conn.performMetadataHandshake(io, session.info_hash, peer_id, config.encryptionPolicy(cfg.network)) catch {
        conn.deinit(io);
        return;
    };
    if (conn.metadata_size) |size| {
        if (session.metadata_size == null) session.metadata_size = size;
    }
    try session.metadata_peers.append(engine.allocator, conn);
    try conn.requestMetadataPiece(io, session.metadata_next_request);
}

fn maintainMetadataPeers(engine: *Engine, io: std.Io, cfg: config.Config, session: *TorrentSession) !void {
    _ = cfg;
    var i: usize = 0;
    while (i < session.metadata_peers.items.len) {
        var conn = &session.metadata_peers.items[i];
        const data = conn.readMetadataPiece(io) catch {
            conn.deinit(io);
            _ = session.metadata_peers.orderedRemove(i);
            continue;
        };
        if (data) |piece| {
            defer engine.allocator.free(piece.bytes);
            if (session.metadata_chunks.fetchRemove(piece.piece)) |old| engine.allocator.free(old.value);
            try session.metadata_chunks.put(piece.piece, try engine.allocator.dupe(u8, piece.bytes));
            session.metadata_next_request = piece.piece + 1;
            if (session.metadata_size) |size| {
                const piece_count = (size + metadata_piece_size - 1) / metadata_piece_size;
                if (session.metadata_next_request < piece_count) {
                    conn.requestMetadataPiece(io, session.metadata_next_request) catch {};
                }
            }
        }
        i += 1;
    }
}

fn tryCompleteMetadata(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    registry: *state.Registry,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    dht_ctx: ?DhtContext,
) !void {
    _ = registry;
    const size = session.metadata_size orelse return;
    const piece_count = (size + metadata_piece_size - 1) / metadata_piece_size;
    var i: usize = 0;
    while (i < piece_count) : (i += 1) {
        if (!session.metadata_chunks.contains(@intCast(i))) return;
    }

    const assembled = try engine.allocator.alloc(u8, size);
    defer engine.allocator.free(assembled);
    i = 0;
    while (i < piece_count) : (i += 1) {
        const chunk = session.metadata_chunks.get(@intCast(i)) orelse return;
        const offset = i * metadata_piece_size;
        const copy_len = @min(chunk.len, size - offset);
        @memcpy(assembled[offset .. offset + copy_len], chunk[0..copy_len]);
    }

    const hash = torrent.infoHashFromInfoBytes(assembled);
    if (!std.mem.eql(u8, &hash, &session.info_hash)) {
        setMetadataError(engine, io, rec, session, "metadata info hash mismatch");
        clearMetadataChunks(engine, session);
        return;
    }

    const announce = if (rec.trackers.len > 0) rec.trackers[0].url else null;
    const torrent_bytes = try torrent.wrapInfoBytes(engine.allocator, assembled, announce);
    defer engine.allocator.free(torrent_bytes);
    const meta = torrent.Metadata.parseBytes(engine.allocator, torrent_bytes) catch {
        setMetadataError(engine, io, rec, session, "metadata parse failed");
        clearMetadataChunks(engine, session);
        return;
    };
    errdefer meta.deinit();
    torrent.validateLimits(meta, cfg.limits, torrent_bytes.len) catch {
        rec.status = .failed;
        if (rec.metadata_error) |old| engine.allocator.free(old);
        rec.metadata_error = try engine.allocator.dupe(u8, "metadata exceeds configured safety limits");
        meta.deinit();
        return;
    };
    storage.validatePaths(engine.allocator, meta) catch {
        rec.status = .failed;
        if (rec.metadata_error) |old| engine.allocator.free(old);
        rec.metadata_error = try engine.allocator.dupe(u8, "metadata contains unsafe file paths");
        meta.deinit();
        return;
    };

    const torrent_dir = try std.fs.path.join(engine.allocator, &.{ cfg.staging_area, rec.info_hash_hex });
    defer engine.allocator.free(torrent_dir);
    const metadata_path = try std.fs.path.join(engine.allocator, &.{ torrent_dir, "metadata.torrent" });
    defer engine.allocator.free(metadata_path);
    const content_dir = try std.fs.path.join(engine.allocator, &.{ torrent_dir, "content" });
    try std.Io.Dir.cwd().createDirPath(io, torrent_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = metadata_path, .data = torrent_bytes, .flags = .{ .truncate = true } });
    try std.Io.Dir.cwd().createDirPath(io, content_dir);
    storage.createStagedFiles(io, engine.allocator, content_dir, meta) catch {
        engine.allocator.free(content_dir);
        rec.status = .failed;
        meta.deinit();
        return;
    };

    var layout = try storage.Layout.init(engine.allocator, meta);
    try storage.recheck(io, engine.allocator, content_dir, meta, &layout);

    for (session.metadata_peers.items) |*p| p.deinit(io);
    session.metadata_peers.clearRetainingCapacity();
    clearMetadataChunks(engine, session);

    rec.metadata_complete = true;
    rec.private_torrent = meta.private_torrent;
    engine.allocator.free(rec.name);
    rec.name = try engine.allocator.dupe(u8, meta.name);
    rec.total_bytes = state.totalBytes(meta);
    rec.piece_length = meta.piece_length;
    rec.piece_count = meta.pieces.len / 20;
    rec.verified_piece_count = 0;
    if (rec.metadata_error) |old| engine.allocator.free(old);
    rec.metadata_error = null;

    if (meta.private_torrent) {
        if (session.dht_socket) |*sock| sock.close(io, engine.allocator);
        session.dht_socket = null;
        if (rec.dht_slot) |slot| {
            if (dht_ctx) |ctx| ctx.slots.release(slot);
            rec.dht_slot = null;
        }
    }

    session.fetching_metadata = false;
    session.meta = meta;
    session.layout = layout;
    session.content_dir = content_dir;
    session.info_hash = meta.info_hash;
    session.metadata_size = null;
    session.metadata_next_request = 0;
}

fn setMetadataError(engine: *Engine, io: std.Io, rec: *state.TorrentRecord, session: *TorrentSession, message: []const u8) void {
    if (rec.metadata_error) |old| engine.allocator.free(old);
    rec.metadata_error = engine.allocator.dupe(u8, message) catch null;
    for (session.metadata_peers.items) |*p| p.deinit(io);
    session.metadata_peers.clearRetainingCapacity();
}

fn clearMetadataChunks(engine: *Engine, session: *TorrentSession) void {
    var it = session.metadata_chunks.iterator();
    while (it.next()) |entry| engine.allocator.free(entry.value_ptr.*);
    session.metadata_chunks.clearRetainingCapacity();
    session.metadata_next_request = 0;
}

fn announceTrackerEndpoint(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    endpoint: *TrackerEndpoint,
    tracker_index: usize,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    const left = sessionLeftBytes(session, rec);
    const event: tracker.Event = if (!endpoint.state.started_sent) .started else .none;
    const downloaded = if (session.fetching_metadata) @as(u64, 0) else rec.total_bytes - left;
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
        cfg.network.tracker_request_timeout_ms,
        now_ms,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(engine.allocator, "tracker announce failed: {s}", .{@errorName(err)});
        defer engine.allocator.free(msg);
        try endpoint.state.scheduleFailure(now_ms, msg, engine.allocator);
        syncTrackerRecord(engine.allocator, rec, tracker_index, endpoint);
        return;
    };
    defer response.deinit(engine.allocator);
    if (response.failure_reason) |reason| {
        try endpoint.state.scheduleFailure(now_ms, reason, engine.allocator);
        syncTrackerRecord(engine.allocator, rec, tracker_index, endpoint);
        return;
    }
    if (endpoint.state.last_error) |old| engine.allocator.free(old);
    endpoint.state.last_error = null;
    endpoint.state.started_sent = true;
    endpoint.state.scheduleSuccess(now_ms, response.interval);
    syncTrackerRecord(engine.allocator, rec, tracker_index, endpoint);
    for (response.peers) |tp| {
        if (session.fetching_metadata) {
            try connectMetadataPeer(engine, io, cfg, session, tp.ip, tp.port, peer_id);
        } else {
            if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
            if (hasPeer(session, tp.ip, tp.port)) continue;
            var conn = peer.Connection.connect(io, engine.allocator, tp.ip, tp.port, cfg.network.peer_connect_timeout_ms) catch continue;
            conn.performHandshake(io, session.info_hash, peer_id, config.encryptionPolicy(cfg.network), false) catch {
                conn.deinit(io);
                continue;
            };
            conn.sendInterested(io) catch {
                conn.deinit(io);
                continue;
            };
            try session.peers.append(engine.allocator, conn);
        }
    }
}

fn hasPeer(session: *TorrentSession, ip: [4]u8, port: u16) bool {
    for (session.peers.items) |p| {
        if (p.peer_ip[0] == ip[0] and p.peer_ip[1] == ip[1] and p.peer_ip[2] == ip[2] and p.peer_ip[3] == ip[3] and p.peer_port == port) return true;
    }
    return false;
}

fn maintainPeers(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, session: *TorrentSession, peer_id: [20]u8, now_ms: i64) !void {
    _ = peer_id;
    var i: usize = 0;
    while (i < session.peers.items.len) {
        var conn = &session.peers.items[i];
        const msg = conn.readMessage(io, cfg.limits.max_peer_message_bytes) catch {
            conn.deinit(io);
            _ = session.peers.orderedRemove(i);
            if (session.active_piece) |*piece| if (piece.peer_index == i) discardPiece(session, piece, allocator);
            continue;
        };
        if (msg == null) {
            i += 1;
            continue;
        }
        switch (msg.?) {
            .bitfield => |bits| conn.state.setBitfield(allocator, session.layout.?.piece_states.len, bits) catch {},
            .have => |index| conn.state.setHave(allocator, session.layout.?.piece_states.len, index) catch {},
            .unchoke => {},
            .piece => |block| try handlePieceBlock(cfg, session, i, block, now_ms),
            else => {},
        }
        conn.state.apply(msg.?);
        i += 1;
    }
}

fn pollPeers(io: std.Io, cfg: config.Config, session: *TorrentSession, rec: *state.TorrentRecord, now_ms: i64) !void {
    _ = io;
    _ = cfg;
    _ = session;
    _ = rec;
    _ = now_ms;
}

fn handlePieceBlock(_: config.Config, session: *TorrentSession, peer_index: usize, block: peer.PieceBlock, now_ms: i64) !void {
    _ = now_ms;
    const piece_index = @as(usize, @intCast(block.index));
    if (piece_index >= session.layout.?.piece_states.len) return;
    if (session.active_piece) |*piece| {
        if (piece.piece_index != piece_index or piece.peer_index != peer_index) return;
        if (block.begin + block.block.len > piece.buffer.len) return;
        @memcpy(piece.buffer[block.begin..][0..block.block.len], block.block);
        try piece.received.put(block.begin, {});
        _ = piece.inflight.remove(block.begin);
    }
}

fn scheduleDownloads(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, session: *TorrentSession, rec: *state.TorrentRecord, now_ms: i64) !void {
    _ = rec;
    if (session.active_piece == null) {
        if (pickPiece(session)) |piece_index| {
            if (pickPeer(session, piece_index)) |peer_index| {
                const span = session.layout.?.pieceSpan(piece_index);
                const buffer = try allocator.alloc(u8, span.length);
                session.active_piece = .{
                    .piece_index = piece_index,
                    .peer_index = peer_index,
                    .buffer = buffer,
                    .received = std.AutoHashMap(u32, void).init(allocator),
                    .block_size = @intCast(cfg.engine.block_request_bytes),
                    .inflight = std.AutoHashMap(u32, i64).init(allocator),
                };
                session.layout.?.mark(piece_index, .in_progress);
            }
        }
    }
    if (session.active_piece) |*piece| {
        try requestBlocks(allocator, io, cfg, session, piece, now_ms);
        if (piece.complete(session.layout.?.pieceSpan(piece.piece_index).length)) {
            try finishPiece(io, allocator, cfg, session, piece);
        }
    }
}

fn pickPiece(session: *TorrentSession) ?usize {
    var sequential: ?usize = null;
    for (session.layout.?.piece_states, 0..) |ps, i| {
        if (ps != .missing) continue;
        if (sequential == null) sequential = i;
        if (peerHasPiece(session, i)) return i;
    }
    return sequential;
}

fn peerHasPiece(session: *TorrentSession, piece_index: usize) bool {
    for (session.peers.items) |*conn| {
        if (!conn.state.peer_choking and conn.state.hasPiece(piece_index)) return true;
    }
    return false;
}

fn pickPeer(session: *TorrentSession, piece_index: usize) ?usize {
    for (session.peers.items, 0..) |*conn, i| {
        if (!conn.state.peer_choking and conn.state.hasPiece(piece_index)) return i;
    }
    return null;
}

fn requestBlocks(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, session: *TorrentSession, piece: *PieceDownload, now_ms: i64) !void {
    const conn = &session.peers.items[piece.peer_index];
    if (conn.state.peer_choking) return;
    const span = session.layout.?.pieceSpan(piece.piece_index);
    var begin: u32 = 0;
    while (begin < span.length) {
        if (piece.inflight.count() >= cfg.limits.max_in_flight_blocks_per_peer) break;
        const remaining = span.length - begin;
        const req_len: u32 = @intCast(@min(remaining, piece.block_size));
        if (piece.received.contains(begin)) {
            begin += req_len;
            continue;
        }
        if (piece.inflight.contains(begin)) {
            begin += req_len;
            continue;
        }
        try conn.sendRequest(io, .{ .index = @intCast(piece.piece_index), .begin = begin, .length = req_len });
        try piece.inflight.put(begin, now_ms);
        begin += req_len;
    }
    var it = piece.inflight.iterator();
    while (it.next()) |entry| {
        if (now_ms - entry.value_ptr.* >= @as(i64, @intCast(cfg.network.peer_request_timeout_ms))) {
            discardPiece(session, piece, allocator);
            return;
        }
    }
}

fn finishPiece(io: std.Io, allocator: std.mem.Allocator, _: config.Config, session: *TorrentSession, piece: *PieceDownload) !void {
    storage.writeVerifiedPiece(io, allocator, session.content_dir.?, session.meta.?, &session.layout.?, piece.piece_index, piece.buffer) catch {
        session.layout.?.mark(piece.piece_index, .missing);
        discardPiece(session, piece, allocator);
        return;
    };
    piece.deinit(allocator);
    session.active_piece = null;
}

fn discardPiece(session: *TorrentSession, piece: *PieceDownload, allocator: std.mem.Allocator) void {
    session.layout.?.mark(piece.piece_index, .missing);
    piece.deinit(allocator);
    session.active_piece = null;
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
    closePeers(session, io, engine.allocator);
    engine.sendTrackerEvent(io, cfg, session, rec, peer_id, .completed, now_ms);

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

test "selects peer-available missing pieces ahead of unavailable sequential pieces" {
    var ps: peer.PeerState = .{};
    defer ps.deinit(std.testing.allocator);
    try ps.setHave(std.testing.allocator, 4, 2);

    var conn = peer.Connection{
        .allocator = std.testing.allocator,
        .stream = undefined,
        .peer_ip = .{ 127, 0, 0, 1 },
        .peer_port = 6881,
        .state = ps,
        .recv_buffer = .empty,
    };
    defer conn.recv_buffer.deinit(std.testing.allocator);
    conn.state.peer_choking = false;

    var states = [_]storage.PieceState{ .missing, .missing, .missing, .missing };
    var lengths = [_]u64{16};
    const layout = storage.Layout{
        .allocator = std.testing.allocator,
        .file_lengths = &lengths,
        .piece_length = 4,
        .total_length = 16,
        .piece_states = &states,
    };

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
        .active_piece = null,
    };
    defer session.metadata_chunks.deinit();
    defer session.peers.deinit(std.testing.allocator);
    defer session.trackers.deinit(std.testing.allocator);
    try session.peers.append(std.testing.allocator, conn);
    try std.testing.expectEqual(@as(?usize, 2), pickPiece(&session));
}
