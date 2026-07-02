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
}

pub fn connectContentBatch(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    peers: []const tracker.Peer,
    peer_id: [20]u8,
) void {
    var attempts: usize = 0;
    const max_attempts = @as(usize, @intCast(cfg.limits.max_peer_connect_attempts_per_tick));
    for (peers) |tp| {
        if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
        if (attempts >= max_attempts) break;
        if (!tracker.peerAllowedForEncryption(tp, config.encryptionPolicy(cfg.network))) continue;
        attempts += 1;
        connectContent(allocator, io, cfg, session, tp.ip, tp.port, peer_id) catch |err| {
            logConnectFailure("content", session, tp.ip, tp.port, err);
        };
    }
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
    var attempts: usize = 0;
    const max_attempts = @as(usize, @intCast(cfg.limits.max_peer_connect_attempts_per_tick));
    for (peers) |tp| {
        if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) break;
        if (attempts >= max_attempts) break;
        if (!tracker.peerAllowedForEncryption(tp, config.encryptionPolicy(cfg.network))) continue;
        attempts += 1;
        connectMetadata(allocator, io, cfg, session, tp.ip, tp.port, peer_id) catch |err| {
            logConnectFailure("metadata", session, tp.ip, tp.port, err);
        };
    }
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
    const sock = &(session.dht_socket orelse return);
    const dht_peers = try sock.tick(io, allocator, ctx.routing, ctx.cfg, session.info_hash, now_ms);
    defer allocator.free(dht_peers);
    if (dht_peers.len > 0) {
        log.debug("peer_pool", "DHT returned {d} peers for {s}", .{ dht_peers.len, session.info_hash_hex });
    }
    switch (mode) {
        .content => connectContentBatch(allocator, io, cfg, session, dht_peers, peer_id),
        .metadata => connectMetadataBatch(allocator, io, cfg, session, dht_peers, peer_id),
    }
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
