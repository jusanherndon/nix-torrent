const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig");
const peer = @import("peer.zig");
const storage = @import("storage.zig");
const engine_session = @import("engine_session.zig");

const PieceDownload = engine_session.PieceDownload;
const TorrentSession = engine_session.TorrentSession;

pub fn countVerified(layout: storage.Layout) usize {
    var n: usize = 0;
    for (layout.piece_states) |ps| {
        if (ps == .verified) n += 1;
    }
    return n;
}

pub fn tick(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    now_ms: i64,
) !usize {
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
                log.debug("piece_scheduler", "started piece {d} from peer {d} for {s}", .{ piece_index, peer_index, session.info_hash_hex });
            }
        }
    }
    if (session.active_piece) |*piece| {
        try requestBlocks(allocator, io, cfg, session, piece, now_ms);
        if (piece.complete(session.layout.?.pieceSpan(piece.piece_index).length)) {
            try finish(io, allocator, session, piece);
        }
    }
    return countVerified(session.layout.?);
}

pub fn pickPiece(session: *TorrentSession) ?usize {
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

pub fn handleBlock(cfg: config.Config, session: *TorrentSession, peer_index: usize, block: peer.PieceBlock) !void {
    const piece_index = @as(usize, @intCast(block.index));
    if (piece_index >= session.layout.?.piece_states.len) return;
    if (session.active_piece) |*piece| {
        if (piece.piece_index != piece_index or piece.peer_index != peer_index) return;
        if (block.begin + block.block.len > piece.buffer.len) return;
        @memcpy(piece.buffer[block.begin..][0..block.block.len], block.block);
        try piece.received.put(block.begin, {});
        _ = piece.inflight.remove(block.begin);
    }
    _ = cfg;
}

fn requestBlocks(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    piece: *PieceDownload,
    now_ms: i64,
) !void {
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
            discard(session, piece, allocator);
            return;
        }
    }
}

fn finish(io: std.Io, allocator: std.mem.Allocator, session: *TorrentSession, piece: *PieceDownload) !void {
    storage.writeVerifiedPiece(io, allocator, session.content_dir.?, session.meta.?, &session.layout.?, piece.piece_index, piece.buffer) catch {
        log.warn("piece_scheduler", "failed to verify piece {d} for {s}", .{ piece.piece_index, session.info_hash_hex });
        session.layout.?.mark(piece.piece_index, .missing);
        discard(session, piece, allocator);
        return;
    };
    log.debug("piece_scheduler", "verified piece {d} for {s}", .{ piece.piece_index, session.info_hash_hex });
    piece.deinit(allocator);
    session.active_piece = null;
}

pub fn discard(session: *TorrentSession, piece: *PieceDownload, allocator: std.mem.Allocator) void {
    log.debug("piece_scheduler", "discarding piece {d} for {s}", .{ piece.piece_index, session.info_hash_hex });
    session.layout.?.mark(piece.piece_index, .missing);
    piece.deinit(allocator);
    session.active_piece = null;
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
