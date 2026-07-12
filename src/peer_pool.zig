const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig");
const peer = @import("peer.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");
const engine_session = @import("engine_session.zig");
const piece_scheduler = @import("piece_scheduler.zig");

const TorrentSession = engine_session.TorrentSession;

pub const DhtPeerMode = enum { content, metadata };

pub const DhtContext = struct {
    routing: *dht.RoutingTable,
    cfg: dht.Config,
    bootstrapped: *bool,
    last_refresh_ms: *i64,
    slots: *dht.SlotAllocator,
};

fn peerListHas(peers: []const peer.Connection, ip: [4]u8, port: u16) bool {
    for (peers) |p| {
        if (p.peer_ip[0] == ip[0] and p.peer_ip[1] == ip[1] and p.peer_ip[2] == ip[2] and p.peer_ip[3] == ip[3] and p.peer_port == port) return true;
    }
    return false;
}

fn hasContent(session: *TorrentSession, ip: [4]u8, port: u16) bool {
    return peerListHas(session.peers.items, ip, port);
}

fn hasMetadata(session: *TorrentSession, ip: [4]u8, port: u16) bool {
    return peerListHas(session.metadata_peers.items, ip, port);
}

pub fn connectContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    ip: [4]u8,
    port: u16,
    peer_id: [20]u8,
) !void {
    if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) return;
    if (hasContent(session, ip, port)) return;
    var conn = try peer.Connection.connect(io, allocator, ip, port, cfg.network.peer_connect_timeout_ms, cfg.network.peer_request_timeout_ms);
    errdefer conn.deinit(io);
    try conn.performHandshake(io, session.info_hash, peer_id, config.encryptionPolicy(cfg.network), false);
    try conn.sendInterested(io);
    try session.peers.append(allocator, conn);
    log.debug("peer_pool", "connected content peer {d}.{d}.{d}.{d}:{d} for {s} ({d} total)", .{ ip[0], ip[1], ip[2], ip[3], port, session.info_hash_hex, session.peers.items.len });
}

fn logConnectFailure(mode: []const u8, session: *TorrentSession, ip: [4]u8, port: u16, err: anyerror) void {
    log.debug("peer_pool", "{s} peer connect failed {d}.{d}.{d}.{d}:{d} for {s}: {s}", .{
        mode, ip[0], ip[1], ip[2], ip[3], port, session.info_hash_hex, @errorName(err),
    });
    log.flush();
}

const max_peer_candidates: usize = 512;

fn peerKeyEq(a: tracker.Peer, b: tracker.Peer) bool {
    return a.ip[0] == b.ip[0] and a.ip[1] == b.ip[1] and a.ip[2] == b.ip[2] and a.ip[3] == b.ip[3] and a.port == b.port;
}

fn candidateExists(session: *TorrentSession, candidate: tracker.Peer) bool {
    for (session.peer_candidates.items) |existing| {
        if (peerKeyEq(existing, candidate)) return true;
    }
    return false;
}

/// Rejects unroutable / garbage compact-peer entries some trackers return.
pub fn isRoutablePeer(candidate: tracker.Peer) bool {
    if (candidate.port == 0) return false;
    if (candidate.ip[0] == 0) return false; // 0.0.0.0/8
    if (candidate.ip[0] == 127) return false; // loopback
    if (candidate.ip[0] == 255 and candidate.ip[1] == 255 and candidate.ip[2] == 255 and candidate.ip[3] == 255) return false;
    return true;
}

/// Merges discovery results into the session candidate set (deduped, capped).
pub fn mergeCandidates(allocator: std.mem.Allocator, session: *TorrentSession, peers: []const tracker.Peer) void {
    var added: usize = 0;
    for (peers) |tp| {
        if (session.peer_candidates.items.len >= max_peer_candidates) break;
        if (!isRoutablePeer(tp)) continue;
        if (candidateExists(session, tp)) continue;
        session.peer_candidates.append(allocator, tp) catch break;
        added += 1;
    }
    if (added > 0) {
        log.debug("peer_pool", "merged {d} peer candidates for {s} ({d} total)", .{ added, session.info_hash_hex, session.peer_candidates.items.len });
    }
}

pub fn connectCandidateBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    peer_id: [20]u8,
    mode: DhtPeerMode,
) void {
    const n = session.peer_candidates.items.len;
    if (n == 0) return;
    const max_attempts = @as(usize, @intCast(cfg.limits.max_peer_connect_attempts_per_tick));
    const policy = config.encryptionPolicy(cfg.network);
    var attempts: usize = 0;
    var examined: usize = 0;
    while (examined < n and attempts < max_attempts) {
        const idx = (session.peer_candidate_cursor + examined) % n;
        examined += 1;
        const tp = session.peer_candidates.items[idx];
        if (!tracker.peerAllowedForEncryption(tp, policy)) continue;
        switch (mode) {
            .content => {
                if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasContent(session, tp.ip, tp.port)) continue;
                attempts += 1;
                connectContent(allocator, io, cfg, session, tp.ip, tp.port, peer_id) catch |err| {
                    logConnectFailure("content", session, tp.ip, tp.port, err);
                };
            },
            .metadata => {
                if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasMetadata(session, tp.ip, tp.port)) continue;
                attempts += 1;
                connectMetadata(allocator, io, cfg, session, tp.ip, tp.port, peer_id) catch |err| {
                    logConnectFailure("metadata", session, tp.ip, tp.port, err);
                };
            },
        }
    }
    if (n > 0) session.peer_candidate_cursor = (session.peer_candidate_cursor + examined) % n;
}

pub fn connectContentBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    peers: []const tracker.Peer,
    peer_id: [20]u8,
) void {
    _ = io;
    _ = cfg;
    _ = peer_id;
    mergeCandidates(allocator, session, peers);
    // Connection attempts happen via connectCandidateBatch once per engine tick.
}

pub fn connectMetadata(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    ip: [4]u8,
    port: u16,
    peer_id: [20]u8,
) !void {
    if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) return;
    if (hasMetadata(session, ip, port)) return;
    var conn = try peer.Connection.connect(io, allocator, ip, port, cfg.network.peer_connect_timeout_ms, cfg.network.peer_request_timeout_ms);
    errdefer conn.deinit(io);
    try conn.performMetadataHandshake(io, session.info_hash, peer_id, config.encryptionPolicy(cfg.network));
    if (conn.metadata_size) |size| {
        if (session.metadata_size == null) session.metadata_size = size;
    }
    try session.metadata_peers.append(allocator, conn);
    log.debug("peer_pool", "connected metadata peer {d}.{d}.{d}.{d}:{d} for {s} ({d} total)", .{ ip[0], ip[1], ip[2], ip[3], port, session.info_hash_hex, session.metadata_peers.items.len });
    if (conn.recv_buffer.items.len == 0) try conn.requestMetadataPiece(io, session.metadata_next_request);
}

pub fn connectMetadataBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    peers: []const tracker.Peer,
    peer_id: [20]u8,
) void {
    _ = io;
    _ = cfg;
    _ = peer_id;
    mergeCandidates(allocator, session, peers);
    // Connection attempts happen via connectCandidateBatch once per engine tick.
}

pub fn tickDht(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    ctx: DhtContext,
    peer_id: [20]u8,
    now_ms: i64,
    mode: DhtPeerMode,
) !void {
    _ = cfg;
    _ = peer_id;
    _ = mode;
    const sock = &(session.dht_socket orelse return);
    const dht_peers = try sock.tick(io, allocator, ctx.routing, ctx.cfg, session.info_hash, now_ms);
    defer allocator.free(dht_peers);
    if (dht_peers.len > 0) {
        log.debug("peer_pool", "DHT returned {d} peers for {s}", .{ dht_peers.len, session.info_hash_hex });
    }
    mergeCandidates(allocator, session, dht_peers);
}

pub fn close(session: *TorrentSession, io: std.Io, allocator: std.mem.Allocator) void {
    for (session.peers.items) |*p| p.close(io);
    session.peers.clearRetainingCapacity();
    for (session.metadata_peers.items) |*p| p.close(io);
    session.metadata_peers.clearRetainingCapacity();
    if (session.active_piece) |*piece| {
        piece_scheduler.discard(session, piece, allocator);
    }
}

fn removeContentPeer(session: *TorrentSession, io: std.Io, allocator: std.mem.Allocator, index: usize) void {
    const conn = session.peers.items[index];
    log.debug("peer_pool", "disconnecting content peer {d}.{d}.{d}.{d}:{d} from {s}", .{ conn.peer_ip[0], conn.peer_ip[1], conn.peer_ip[2], conn.peer_ip[3], conn.peer_port, session.info_hash_hex });
    var conn_mut = conn;
    conn_mut.deinit(io);
    _ = session.peers.orderedRemove(index);
    if (session.active_piece) |*piece| {
        if (piece.peer_index == index) piece_scheduler.discard(session, piece, allocator);
    }
}

pub fn poll(io: std.Io, cfg: config.Config, session: *TorrentSession, allocator: std.mem.Allocator) !void {
    _ = cfg;
    var i: usize = 0;
    while (i < session.peers.items.len) {
        var conn = &session.peers.items[i];
        if (conn.recv_buffer.items.len < 4096) {
            const n = conn.readAvailable(io) catch {
                removeContentPeer(session, io, allocator, i);
                continue;
            };
            if (n == 0 and conn.recv_buffer.items.len == 0) {
                removeContentPeer(session, io, allocator, i);
                continue;
            }
        }
        i += 1;
    }
}

pub fn maintain(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, session: *TorrentSession) !void {
    var i: usize = 0;
    while (i < session.peers.items.len) {
        var conn = &session.peers.items[i];
        while (true) {
            const msg = conn.pollMessage(cfg.limits.max_peer_message_bytes) catch {
                removeContentPeer(session, io, allocator, i);
                break;
            };
            if (msg == null) break;
            switch (msg.?) {
                .bitfield => |bits| conn.state.setBitfield(allocator, session.layout.?.piece_states.len, bits) catch {},
                .have => |index| conn.state.setHave(allocator, session.layout.?.piece_states.len, index) catch {},
                .unchoke => {},
                .piece => |block| try piece_scheduler.handleBlock(cfg, session, i, block),
                else => {},
            }
            conn.state.apply(msg.?);
        }
        i += 1;
    }
}

test "rejects unroutable peer candidates" {
    try std.testing.expect(!isRoutablePeer(.{ .ip = .{ 127, 0, 0, 1 }, .port = 6881 }));
    try std.testing.expect(!isRoutablePeer(.{ .ip = .{ 0, 0, 0, 0 }, .port = 6881 }));
    try std.testing.expect(!isRoutablePeer(.{ .ip = .{ 255, 255, 255, 255 }, .port = 45353 }));
    try std.testing.expect(!isRoutablePeer(.{ .ip = .{ 1, 2, 3, 4 }, .port = 0 }));
    try std.testing.expect(isRoutablePeer(.{ .ip = .{ 1, 2, 3, 4 }, .port = 6881 }));
}

test "mergeCandidates dedupes and skips garbage" {
    var session = TorrentSession{
        .info_hash_hex = "abcd",
        .info_hash = [_]u8{0} ** 20,
        .fetching_metadata = true,
        .meta = null,
        .layout = null,
        .content_dir = null,
        .trackers = .empty,
        .announce_port = 6881,
        .peers = .empty,
        .metadata_peers = .empty,
        .metadata_chunks = std.AutoHashMap(u32, []u8).init(std.testing.allocator),
        .active_piece = null,
    };
    defer session.deinit(std.testing.io, std.testing.allocator);

    const batch = [_]tracker.Peer{
        .{ .ip = .{ 1, 2, 3, 4 }, .port = 6881 },
        .{ .ip = .{ 127, 0, 0, 1 }, .port = 6881 },
        .{ .ip = .{ 1, 2, 3, 4 }, .port = 6881 },
        .{ .ip = .{ 5, 6, 7, 8 }, .port = 51413 },
    };
    mergeCandidates(std.testing.allocator, &session, &batch);
    try std.testing.expectEqual(@as(usize, 2), session.peer_candidates.items.len);
    try std.testing.expectEqual(@as(u8, 1), session.peer_candidates.items[0].ip[0]);
    try std.testing.expectEqual(@as(u8, 5), session.peer_candidates.items[1].ip[0]);
}
