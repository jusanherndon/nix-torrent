const std = @import("std");
const config = @import("config.zig");
const handoff = @import("handoff.zig");
const peer = @import("peer.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

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

pub const TorrentSession = struct {
    info_hash_hex: []const u8,
    meta: torrent.Metadata,
    layout: storage.Layout,
    content_dir: []const u8,
    tracker_state: tracker.TrackerState,
    announce_url: tracker.AnnounceUrl,
    peers: std.ArrayList(peer.Connection),
    active_piece: ?PieceDownload,
    failure_reason: ?[]const u8 = null,

    pub fn deinit(self: *TorrentSession, io: std.Io, allocator: std.mem.Allocator) void {
        for (self.peers.items) |*p| p.deinit(io);
        self.peers.deinit(allocator);
        if (self.active_piece) |*piece| piece.deinit(allocator);
        self.layout.deinit();
        self.meta.deinit();
        allocator.free(self.content_dir);
        self.tracker_state.deinit(allocator);
        self.announce_url.deinit(allocator);
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

    pub fn loadFromRegistry(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry) !void {
        for (self.sessions.items) |*session| session.deinit(io, self.allocator);
        self.sessions.clearRetainingCapacity();
        for (registry.records.items) |*rec| {
            if (rec.status == .complete) continue;
            try self.addSession(io, cfg, registry, rec);
        }
    }

    pub fn addSession(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, rec: *state.TorrentRecord) !void {
        _ = registry;
        if (self.findSession(rec.info_hash_hex) != null) return;
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
        const announce_url = if (rec.tracker_url) |url| try tracker.parseAnnounceUrl(self.allocator, url) else return error.MissingTracker;
        const session = TorrentSession{
            .info_hash_hex = rec.info_hash_hex,
            .meta = meta,
            .layout = layout,
            .content_dir = content_dir,
            .tracker_state = .{
                .retry_min_ms = @intCast(cfg.network.tracker_retry_min_ms),
                .retry_max_ms = @intCast(cfg.network.tracker_retry_max_ms),
                .retry_ms = @intCast(cfg.network.tracker_retry_min_ms),
            },
            .announce_url = announce_url,
            .peers = .empty,
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

    pub fn tick(self: *Engine, io: std.Io, cfg: config.Config, registry: *state.Registry, peer_id: [20]u8, now_ms: i64) !void {
        for (self.sessions.items) |*session| {
            const rec = registry.find(session.info_hash_hex) orelse continue;
            try tickSession(self, io, cfg, registry, session, rec, peer_id, now_ms);
        }
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
    ) !void {
        if (rec.status == .paused or rec.status == .failed or rec.status == .complete) {
            if (rec.status == .paused or rec.status == .failed) closePeers(session, io);
            return;
        }

        if (session.layout.complete()) {
            try completeTorrent(engine, io, cfg, registry, session, rec, peer_id, now_ms);
            return;
        }

        if (session.tracker_state.due(now_ms)) {
            try announceTracker(engine, io, cfg, session, rec, peer_id, now_ms);
        }

        try maintainPeers(io, cfg, session, peer_id, now_ms);
        try pollPeers(io, cfg, session, rec, now_ms);
        try scheduleDownloads(io, cfg, session, rec, now_ms);
        rec.verified_piece_count = countVerified(session.layout);
        rec.tracker_error = if (session.tracker_state.last_error) |s| try engine.allocator.dupe(u8, s) else null;
        if (rec.tracker_error != null and session.tracker_state.last_error == null) {
            if (rec.tracker_error) |old| engine.allocator.free(old);
            rec.tracker_error = null;
        }
        try state.writeTorrentState(io, engine.allocator, cfg.staging_area, rec.*);
    }

    fn countVerified(layout: storage.Layout) usize {
        var n: usize = 0;
        for (layout.piece_states) |ps| {
            if (ps == .verified) n += 1;
        }
        return n;
    }
};

fn closePeers(session: *TorrentSession, io: std.Io) void {
    for (session.peers.items) |*p| p.close(io);
    session.peers.clearRetainingCapacity();
    if (session.active_piece) |*piece| {
        piece.deinit(session.meta.allocator);
        session.active_piece = null;
    }
}

fn announceTracker(
    engine: *Engine,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    const left = leftBytes(session.layout, rec.total_bytes);
    const event: tracker.Event = if (!session.tracker_state.started_sent) .started else .none;
    const path = try tracker.buildAnnouncePath(
        engine.allocator,
        session.announce_url.path,
        session.announce_url.has_query,
        session.meta.info_hash,
        peer_id,
        @intCast(cfg.network.announce_port),
        0,
        rec.total_bytes - left,
        left,
        event,
    );
    defer engine.allocator.free(path);
    const response = tracker.announceGet(io, engine.allocator, session.announce_url, path, cfg.network.tracker_request_timeout_ms) catch |err| {
        const msg = try std.fmt.allocPrint(engine.allocator, "tracker announce failed: {s}", .{@errorName(err)});
        defer engine.allocator.free(msg);
        try session.tracker_state.scheduleFailure(now_ms, msg, engine.allocator);
        if (rec.tracker_error) |old| engine.allocator.free(old);
        rec.tracker_error = try engine.allocator.dupe(u8, msg);
        return;
    };
    defer response.deinit(engine.allocator);
    if (response.failure_reason) |reason| {
        try session.tracker_state.scheduleFailure(now_ms, reason, engine.allocator);
        if (rec.tracker_error) |old| engine.allocator.free(old);
        rec.tracker_error = try engine.allocator.dupe(u8, reason);
        return;
    }
    if (rec.tracker_error) |old| engine.allocator.free(old);
    rec.tracker_error = null;
    if (session.tracker_state.last_error) |old| engine.allocator.free(old);
    session.tracker_state.last_error = null;
    session.tracker_state.started_sent = true;
    session.tracker_state.scheduleSuccess(now_ms, response.interval);
    for (response.peers) |tp| {
        if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
        if (hasPeer(session, tp.ip, tp.port)) continue;
        var conn = peer.Connection.connect(io, engine.allocator, tp.ip, tp.port, cfg.network.peer_connect_timeout_ms) catch continue;
        conn.performHandshake(io, session.meta.info_hash, peer_id) catch {
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

fn hasPeer(session: *TorrentSession, ip: [4]u8, port: u16) bool {
    for (session.peers.items) |p| {
        if (p.peer_ip[0] == ip[0] and p.peer_ip[1] == ip[1] and p.peer_ip[2] == ip[2] and p.peer_ip[3] == ip[3] and p.peer_port == port) return true;
    }
    return false;
}

fn maintainPeers(io: std.Io, cfg: config.Config, session: *TorrentSession, peer_id: [20]u8, now_ms: i64) !void {
    _ = peer_id;
    var i: usize = 0;
    while (i < session.peers.items.len) {
        var conn = &session.peers.items[i];
        const msg = conn.readMessage(io, cfg.limits.max_peer_message_bytes) catch {
            conn.deinit(io);
            _ = session.peers.orderedRemove(i);
            if (session.active_piece) |*piece| if (piece.peer_index == i) discardPiece(session, piece);
            continue;
        };
        if (msg == null) {
            i += 1;
            continue;
        }
        switch (msg.?) {
            .bitfield => |bits| conn.state.setBitfield(session.meta.allocator, session.layout.piece_states.len, bits) catch {},
            .have => |index| conn.state.setHave(session.meta.allocator, session.layout.piece_states.len, index) catch {},
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
    if (piece_index >= session.layout.piece_states.len) return;
    if (session.active_piece) |*piece| {
        if (piece.piece_index != piece_index or piece.peer_index != peer_index) return;
        if (block.begin + block.block.len > piece.buffer.len) return;
        @memcpy(piece.buffer[block.begin..][0..block.block.len], block.block);
        try piece.received.put(block.begin, {});
        _ = piece.inflight.remove(block.begin);
    }
}

fn scheduleDownloads(io: std.Io, cfg: config.Config, session: *TorrentSession, rec: *state.TorrentRecord, now_ms: i64) !void {
    _ = rec;
    if (session.active_piece == null) {
        if (pickPiece(session)) |piece_index| {
            if (pickPeer(session, piece_index)) |peer_index| {
                const span = session.layout.pieceSpan(piece_index);
                const buffer = try session.meta.allocator.alloc(u8, span.length);
                session.active_piece = .{
                    .piece_index = piece_index,
                    .peer_index = peer_index,
                    .buffer = buffer,
                    .received = std.AutoHashMap(u32, void).init(session.meta.allocator),
                    .block_size = @intCast(cfg.engine.block_request_bytes),
                    .inflight = std.AutoHashMap(u32, i64).init(session.meta.allocator),
                };
                session.layout.mark(piece_index, .in_progress);
            }
        }
    }
    if (session.active_piece) |*piece| {
        try requestBlocks(io, cfg, session, piece, now_ms);
        if (piece.complete(session.layout.pieceSpan(piece.piece_index).length)) {
            try finishPiece(io, cfg, session, piece);
        }
    }
}

fn pickPiece(session: *TorrentSession) ?usize {
    var sequential: ?usize = null;
    for (session.layout.piece_states, 0..) |ps, i| {
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

fn requestBlocks(io: std.Io, cfg: config.Config, session: *TorrentSession, piece: *PieceDownload, now_ms: i64) !void {
    const conn = &session.peers.items[piece.peer_index];
    if (conn.state.peer_choking) return;
    const span = session.layout.pieceSpan(piece.piece_index);
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
            discardPiece(session, piece);
            return;
        }
    }
}

fn finishPiece(io: std.Io, _: config.Config, session: *TorrentSession, piece: *PieceDownload) !void {
    storage.writeVerifiedPiece(io, session.meta.allocator, session.content_dir, session.meta, &session.layout, piece.piece_index, piece.buffer) catch {
        session.layout.mark(piece.piece_index, .missing);
        discardPiece(session, piece);
        return;
    };
    piece.deinit(session.meta.allocator);
    session.active_piece = null;
}

fn discardPiece(session: *TorrentSession, piece: *PieceDownload) void {
    session.layout.mark(piece.piece_index, .missing);
    piece.deinit(session.meta.allocator);
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
    _ = now_ms;
    closePeers(session, io);
    const left = leftBytes(session.layout, rec.total_bytes);
    if (left == 0 and !session.tracker_state.started_sent) {
        // still announce completed below
    }
    const path = try tracker.buildAnnouncePath(
        engine.allocator,
        session.announce_url.path,
        session.announce_url.has_query,
        session.meta.info_hash,
        peer_id,
        @intCast(cfg.network.announce_port),
        0,
        rec.total_bytes,
        0,
        .completed,
    );
    defer engine.allocator.free(path);
    _ = tracker.announceGet(io, engine.allocator, session.announce_url, path, cfg.network.tracker_request_timeout_ms) catch {};

    const final_path = handoff.moveCompletedContent(io, engine.allocator, session.content_dir, session.meta, cfg.final_destination) catch |err| {
        rec.status = .failed;
        if (rec.tracker_error) |old| engine.allocator.free(old);
        rec.tracker_error = try std.fmt.allocPrint(engine.allocator, "handoff failed: {s}", .{@errorName(err)});
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
        .meta = undefined,
        .layout = layout,
        .content_dir = "content",
        .tracker_state = .{},
        .announce_url = .{ .host = "127.0.0.1", .port = 80, .path = "/a", .has_query = false },
        .peers = .empty,
        .active_piece = null,
    };
    defer session.peers.deinit(std.testing.allocator);
    try session.peers.append(std.testing.allocator, conn);
    try std.testing.expectEqual(@as(?usize, 2), pickPiece(&session));
}
