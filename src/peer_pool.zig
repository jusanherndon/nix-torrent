const std = @import("std");
const address = @import("address.zig");
const config = @import("config.zig");
const encryption = @import("encryption.zig");
const log = @import("log.zig");
const peer = @import("peer.zig");
const pex = @import("pex.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");
const session_types = @import("session_types.zig");
const piece_scheduler = @import("piece_scheduler.zig");
const torrent = @import("torrent.zig");

const TorrentSession = session_types.TorrentSession;

pub const DhtPeerMode = enum { content, metadata };

pub const DhtContext = struct {
    routing: *dht.RoutingTable,
    cfg: dht.Config,
    bootstrapped: *bool,
    last_refresh_ms: *i64,
    slots: *dht.SlotAllocator,
};

fn peerListHas(peers: []const peer.Connection, addr: address.Address) bool {
    for (peers) |p| {
        if (p.peer_addr.eql(addr)) return true;
    }
    return false;
}

fn hasContent(session: *TorrentSession, addr: address.Address) bool {
    return peerListHas(session.peers.items, addr);
}

fn hasMetadata(session: *TorrentSession, addr: address.Address) bool {
    return peerListHas(session.metadata_peers.items, addr);
}

fn logConnectFailure(mode: []const u8, session: *TorrentSession, addr: address.Address, err: anyerror) void {
    var buf: [64]u8 = undefined;
    log.debug("peer_pool", "{s} peer connect failed {s} for {s}: {s}", .{
        mode, addr.render(&buf), session.info_hash_hex, @errorName(err),
    });
    log.flush();
}

const max_peer_candidates: usize = 512;
const metadata_lookup_interval_ms: i64 = 15_000;
const content_lookup_interval_ms: i64 = 60_000;

fn peerKeyEq(a: tracker.Peer, b: tracker.Peer) bool {
    return a.addr().eql(b.addr());
}

fn candidateExists(session: *TorrentSession, candidate: tracker.Peer) bool {
    for (session.peer_candidates.items) |existing| {
        if (peerKeyEq(existing, candidate)) return true;
    }
    return false;
}

/// Rejects unroutable / garbage compact-peer entries some trackers return.
pub fn isRoutablePeer(candidate: tracker.Peer) bool {
    return address.isRoutable(candidate.addr());
}

fn ensureCooldownCapacity(allocator: std.mem.Allocator, session: *TorrentSession) void {
    while (session.peer_candidate_cooldown_until.items.len < session.peer_candidates.items.len) {
        session.peer_candidate_cooldown_until.append(allocator, 0) catch return;
    }
}

fn markCandidateCooldown(session: *TorrentSession, idx: usize, now_ms: i64, cooldown_ms: u64) void {
    if (idx >= session.peer_candidate_cooldown_until.items.len) return;
    session.peer_candidate_cooldown_until.items[idx] = now_ms + @as(i64, @intCast(cooldown_ms));
}

fn candidateOnCooldown(session: *TorrentSession, idx: usize, now_ms: i64) bool {
    if (idx >= session.peer_candidate_cooldown_until.items.len) return false;
    return now_ms < session.peer_candidate_cooldown_until.items[idx];
}

/// Merges discovery results into the session candidate set (deduped, capped).
pub fn mergeCandidates(allocator: std.mem.Allocator, session: *TorrentSession, peers: []const tracker.Peer) void {
    var added: usize = 0;
    for (peers) |tp| {
        if (session.peer_candidates.items.len >= max_peer_candidates) break;
        if (!isRoutablePeer(tp)) continue;
        if (candidateExists(session, tp)) continue;
        session.peer_candidates.append(allocator, tp) catch break;
        session.peer_candidate_cooldown_until.append(allocator, 0) catch {
            _ = session.peer_candidates.pop();
            break;
        };
        added += 1;
    }
    if (added > 0) {
        log.debug("peer_pool", "merged {d} peer candidates for {s} ({d} total)", .{ added, session.info_hash_hex, session.peer_candidates.items.len });
    }
}

fn connectTimeoutMs(cfg: config.Config, mode: DhtPeerMode) u64 {
    return switch (mode) {
        .metadata => cfg.network.metadata_peer_connect_timeout_ms,
        .content => cfg.network.peer_connect_timeout_ms,
    };
}

fn maxAttemptsForMode(cfg: config.Config, mode: DhtPeerMode) usize {
    const base = @as(usize, @intCast(cfg.limits.max_peer_connect_attempts_per_tick));
    return switch (mode) {
        // Metadata fetcher is gated on finding any live peer; spend more of the
        // tick budget probing short-timeout dials through dead candidates.
        .metadata => @min(base * 2, @as(usize, @intCast(cfg.limits.max_peers_per_torrent))),
        .content => base,
    };
}

fn isPreferPlaintextRetry(err: anyerror) bool {
    return err == error.MsePe2Short or err == error.MseVcEof or err == error.MseVcNotFound;
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
    ensureCooldownCapacity(allocator, session);
    const max_attempts = maxAttemptsForMode(cfg, mode);
    const batch_budget_ms = @as(i64, @intCast(cfg.network.peer_connect_batch_budget_ms));
    const batch_start_ms = nowMs(io);
    const policy = config.encryptionPolicy(cfg.network);
    const connect_timeout = connectTimeoutMs(cfg, mode);
    var attempts: usize = 0;
    var examined: usize = 0;
    while (examined < n and attempts < max_attempts) {
        if (attempts > 0 and nowMs(io) - batch_start_ms >= batch_budget_ms) break;
        const idx = (session.peer_candidate_cursor + examined) % n;
        examined += 1;
        if (candidateOnCooldown(session, idx, batch_start_ms)) continue;
        const tp = session.peer_candidates.items[idx];
        if (!tracker.peerAllowedForEncryption(tp, policy)) continue;
        switch (mode) {
            .content => {
                if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasContent(session, tp.addr())) continue;
                attempts += 1;
                connectContentTimed(allocator, io, cfg, session, tp.addr(), peer_id, connect_timeout) catch |err| {
                    markCandidateCooldown(session, idx, nowMs(io), cfg.network.peer_connect_fail_cooldown_ms);
                    logConnectFailure("content", session, tp.addr(), err);
                };
            },
            .metadata => {
                if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) break;
                if (hasMetadata(session, tp.addr())) continue;
                attempts += 1;
                connectMetadataTimed(allocator, io, cfg, session, tp.addr(), peer_id, connect_timeout) catch |err| {
                    markCandidateCooldown(session, idx, nowMs(io), cfg.network.peer_connect_fail_cooldown_ms);
                    logConnectFailure("metadata", session, tp.addr(), err);
                };
            },
        }
    }
    if (n > 0) session.peer_candidate_cursor = (session.peer_candidate_cursor + examined) % n;
}

pub fn connectContent(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    addr: address.Address,
    peer_id: [20]u8,
) !void {
    try connectContentTimed(allocator, io, cfg, session, addr, peer_id, cfg.network.peer_connect_timeout_ms);
}

fn connectContentTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    addr: address.Address,
    peer_id: [20]u8,
    connect_timeout_ms: u64,
) !void {
    if (session.peers.items.len >= cfg.limits.max_peers_per_torrent) return;
    if (hasContent(session, addr)) return;
    const policy = config.encryptionPolicy(cfg.network);
    var conn = try dialWithPreferPlaintextRetry(io, allocator, addr, connect_timeout_ms, cfg.network.peer_request_timeout_ms, session.info_hash, peer_id, policy, false);
    errdefer conn.deinit(io);
    try conn.sendInterested(io);
    // Advertise our LTEP extensions so the peer can send us `ut_pex` (BEP 11).
    if (cfg.network.pex.enabled) conn.sendExtendedHandshake(io) catch {};
    try session.peers.append(allocator, conn);
    var buf: [64]u8 = undefined;
    log.debug("peer_pool", "connected content peer {s} ({s}) for {s} ({d} total)", .{ addr.render(&buf), addr.ip.family(), session.info_hash_hex, session.peers.items.len });
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
    addr: address.Address,
    peer_id: [20]u8,
) !void {
    try connectMetadataTimed(allocator, io, cfg, session, addr, peer_id, cfg.network.metadata_peer_connect_timeout_ms);
}

fn connectMetadataTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    addr: address.Address,
    peer_id: [20]u8,
    connect_timeout_ms: u64,
) !void {
    if (session.metadata_peers.items.len >= cfg.limits.max_peers_per_torrent) return;
    if (hasMetadata(session, addr)) return;
    const policy = config.encryptionPolicy(cfg.network);
    var conn = try dialMetadataWithPreferPlaintextRetry(io, allocator, addr, connect_timeout_ms, cfg.network.peer_request_timeout_ms, session.info_hash, peer_id, policy);
    errdefer conn.deinit(io);
    if (conn.metadata_size) |size| {
        if (session.metadata_size == null) session.metadata_size = size;
    }
    try session.metadata_peers.append(allocator, conn);
    var buf: [64]u8 = undefined;
    log.debug("peer_pool", "connected metadata peer {s} ({s}) for {s} ({d} total)", .{ addr.render(&buf), addr.ip.family(), session.info_hash_hex, session.metadata_peers.items.len });
    // Always request; leftover bitfield/have in recv_buffer must not block ut_metadata.
    try conn.requestMetadataPiece(io, session.metadata_next_request);
}

/// Outbound dial + handshake. On `prefer`, one reconnect with plaintext after mid-MSE
/// abort (`MsePe2Short` / `MseVcEof` / `MseVcNotFound`) — ADR 0004 live-swarm refinement.
fn dialWithPreferPlaintextRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    addr: address.Address,
    connect_timeout_ms: u64,
    read_timeout_ms: u64,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    policy: encryption.Policy,
    extensions: bool,
) !peer.Connection {
    var conn = try peer.Connection.connectAddr(io, allocator, addr, connect_timeout_ms, read_timeout_ms);
    var alive = true;
    errdefer if (alive) conn.deinit(io);
    conn.performHandshake(io, info_hash, peer_id, policy, extensions) catch |err| {
        if (policy != .prefer or !isPreferPlaintextRetry(err)) return err;
        conn.deinit(io);
        alive = false;
        conn = try peer.Connection.connectAddr(io, allocator, addr, connect_timeout_ms, read_timeout_ms);
        alive = true;
        try conn.performHandshake(io, info_hash, peer_id, .disable, extensions);
    };
    alive = false;
    return conn;
}

fn dialMetadataWithPreferPlaintextRetry(
    io: std.Io,
    allocator: std.mem.Allocator,
    addr: address.Address,
    connect_timeout_ms: u64,
    read_timeout_ms: u64,
    info_hash: torrent.InfoHash,
    peer_id: [20]u8,
    policy: encryption.Policy,
) !peer.Connection {
    var conn = try peer.Connection.connectAddr(io, allocator, addr, connect_timeout_ms, read_timeout_ms);
    var alive = true;
    errdefer if (alive) conn.deinit(io);
    conn.performMetadataHandshake(io, info_hash, peer_id, policy) catch |err| {
        if (policy != .prefer or !isPreferPlaintextRetry(err)) return err;
        var buf: [64]u8 = undefined;
        log.debug("peer_pool", "metadata MSE mid-handshake abort from {s}; retrying plaintext", .{addr.render(&buf)});
        conn.deinit(io);
        alive = false;
        conn = try peer.Connection.connectAddr(io, allocator, addr, connect_timeout_ms, read_timeout_ms);
        alive = true;
        try conn.performMetadataHandshake(io, info_hash, peer_id, .disable);
    };
    alive = false;
    return conn;
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
    const sock = &(session.dht_socket orelse return);
    sock.lookup_interval_ms = switch (mode) {
        .metadata => metadata_lookup_interval_ms,
        .content => content_lookup_interval_ms,
    };
    // session.announce_port carries the advertised listen port (V3 split).
    const dht_peers = try sock.tick(io, allocator, ctx.routing, ctx.cfg, session.info_hash, now_ms, session.announce_port);
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
    var buf: [64]u8 = undefined;
    log.debug("peer_pool", "disconnecting content peer {s} from {s}", .{ conn.peer_addr.render(&buf), session.info_hash_hex });
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
                .extended => |payload| {
                    if (payload.len >= 1 and payload[0] == 0) {
                        if (peer.parsePeerUtPexId(allocator, payload)) |id| conn.peer_ut_pex_id = id;
                    } else consumePex(allocator, session, payload);
                },
                else => {},
            }
            conn.state.apply(msg.?);
        }
        i += 1;
    }
}

/// Minimum wall-clock gap between `ut_pex` emissions on a connection set.
pub const pex_emit_interval_ms: i64 = 60_000;

/// Emit a `ut_pex` (BEP 11) `added` list of currently connected content peers
/// to every peer that advertised `ut_pex`. Throttled and best-effort. Callers
/// must gate on config `pex.enabled` and non-private torrents.
pub fn emitPex(allocator: std.mem.Allocator, io: std.Io, session: *TorrentSession, now_ms: i64) void {
    if (now_ms - session.last_pex_emit_ms < pex_emit_interval_ms) return;
    var any_target = false;
    for (session.peers.items) |*p| {
        if (p.peer_ut_pex_id != null) {
            any_target = true;
            break;
        }
    }
    if (!any_target) return;
    session.last_pex_emit_ms = now_ms;

    var added: std.ArrayList(address.Address) = .empty;
    defer added.deinit(allocator);
    for (session.peers.items) |*p| added.append(allocator, p.peer_addr) catch return;
    const body = pex.encodePexBody(allocator, added.items, &.{}) catch return;
    defer allocator.free(body);
    for (session.peers.items) |*p| {
        if (p.peer_ut_pex_id == null) continue;
        p.sendPex(io, body) catch {};
    }
}

/// Consume an incoming `ut_pex` (BEP 11) message and merge its peers into the
/// candidate set. Non-PEX extended messages (e.g. LTEP handshakes) are ignored.
fn consumePex(allocator: std.mem.Allocator, session: *TorrentSession, payload: []const u8) void {
    if (payload.len < 2 or payload[0] != pex.local_ut_pex_id) return;
    const learned = pex.parsePexPeers(allocator, payload[1..]) catch return;
    defer allocator.free(learned);
    if (learned.len > 0) mergeCandidates(allocator, session, learned);
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .real).toMilliseconds();
}

test "rejects unroutable peer candidates" {
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v4(.{ 127, 0, 0, 1 }, 6881)));
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v4(.{ 0, 0, 0, 0 }, 6881)));
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v4(.{ 255, 255, 255, 255 }, 45353)));
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v4(.{ 1, 2, 3, 4 }, 0)));
    try std.testing.expect(isRoutablePeer(tracker.Peer.v4(.{ 1, 2, 3, 4 }, 6881)));
    // IPv6: unspecified and loopback rejected, global unicast accepted.
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, 6881)));
    try std.testing.expect(!isRoutablePeer(tracker.Peer.v6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 6881)));
    try std.testing.expect(isRoutablePeer(tracker.Peer.v6(.{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }, 6881)));
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
        tracker.Peer.v4(.{ 1, 2, 3, 4 }, 6881),
        tracker.Peer.v4(.{ 127, 0, 0, 1 }, 6881),
        tracker.Peer.v4(.{ 1, 2, 3, 4 }, 6881),
        tracker.Peer.v4(.{ 5, 6, 7, 8 }, 51413),
    };
    mergeCandidates(std.testing.allocator, &session, &batch);
    try std.testing.expectEqual(@as(usize, 2), session.peer_candidates.items.len);
    try std.testing.expectEqual(@as(u8, 1), session.peer_candidates.items[0].ip.v4[0]);
    try std.testing.expectEqual(@as(u8, 5), session.peer_candidates.items[1].ip.v4[0]);
}
