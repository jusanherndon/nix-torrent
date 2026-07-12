const std = @import("std");
const config = @import("config.zig");
const log = @import("log.zig");
const peer = @import("peer.zig");
const staging = @import("staging.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const session_types = @import("session_types.zig");
const peer_pool = @import("peer_pool.zig");

const TorrentSession = session_types.TorrentSession;
const metadata_piece_size = session_types.metadata_piece_size;

pub fn tick(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    dht_ctx: ?peer_pool.DhtContext,
) !void {
    try maintainPeers(allocator, io, cfg, session);
    try tryComplete(allocator, io, cfg, session, rec, dht_ctx);
}

pub fn tickDht(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    ctx: peer_pool.DhtContext,
    peer_id: [20]u8,
    now_ms: i64,
) !void {
    try peer_pool.tickDht(allocator, io, cfg, session, ctx, peer_id, now_ms, .metadata);
}

fn maintainPeers(allocator: std.mem.Allocator, io: std.Io, cfg: config.Config, session: *TorrentSession) !void {
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
            defer allocator.free(piece.bytes);
            log.debug("metadata_fetch", "received metadata piece {d} ({d} bytes) for {s}", .{ piece.piece, piece.bytes.len, session.info_hash_hex });
            if (session.metadata_chunks.fetchRemove(piece.piece)) |old| allocator.free(old.value);
            try session.metadata_chunks.put(piece.piece, try allocator.dupe(u8, piece.bytes));
            session.metadata_next_request = piece.piece + 1;
            if (session.metadata_size) |size| {
                const piece_count = (size + metadata_piece_size - 1) / metadata_piece_size;
                if (session.metadata_next_request < piece_count) {
                    conn.requestMetadataPiece(io, session.metadata_next_request) catch {};
                }
            }
        } else {
            conn.deinit(io);
            _ = session.metadata_peers.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

fn tryComplete(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: config.Config,
    session: *TorrentSession,
    rec: *state.TorrentRecord,
    dht_ctx: ?peer_pool.DhtContext,
) !void {
    const size = session.metadata_size orelse return;
    const piece_count = (size + metadata_piece_size - 1) / metadata_piece_size;
    var i: usize = 0;
    while (i < piece_count) : (i += 1) {
        if (!session.metadata_chunks.contains(@intCast(i))) return;
    }

    const assembled = try allocator.alloc(u8, size);
    defer allocator.free(assembled);
    i = 0;
    while (i < piece_count) : (i += 1) {
        const chunk = session.metadata_chunks.get(@intCast(i)) orelse return;
        const offset = i * metadata_piece_size;
        const copy_len = @min(chunk.len, size - offset);
        @memcpy(assembled[offset .. offset + copy_len], chunk[0..copy_len]);
    }

    const hash = torrent.infoHashFromInfoBytes(assembled);
    if (!std.mem.eql(u8, &hash, &session.info_hash)) {
        log.warn("metadata_fetch", "metadata info hash mismatch for {s}", .{session.info_hash_hex});
        setError(allocator, io, rec, session, "metadata info hash mismatch");
        clearChunks(allocator, session);
        return;
    }

    const announce = if (rec.trackers.len > 0) rec.trackers[0].url else null;
    const torrent_bytes = try torrent.wrapInfoBytes(allocator, assembled, announce);
    defer allocator.free(torrent_bytes);
    const meta = torrent.Metadata.parseBytes(allocator, torrent_bytes) catch {
        setError(allocator, io, rec, session, "metadata parse failed");
        clearChunks(allocator, session);
        return;
    };
    errdefer meta.deinit();
    torrent.validateLimits(meta, cfg.limits, torrent_bytes.len) catch {
        rec.status = .failed;
        if (rec.metadata_error) |old| allocator.free(old);
        rec.metadata_error = try allocator.dupe(u8, "metadata exceeds configured safety limits");
        meta.deinit();
        return;
    };
    storage.validatePaths(allocator, meta) catch {
        rec.status = .failed;
        if (rec.metadata_error) |old| allocator.free(old);
        rec.metadata_error = try allocator.dupe(u8, "metadata contains unsafe file paths");
        meta.deinit();
        return;
    };
    meta.deinit();

    var staged = try staging.finalizeMetadata(io, allocator, cfg.staging_area, rec.info_hash_hex, torrent_bytes);
    errdefer staged.deinit(allocator);

    for (session.metadata_peers.items) |*p| p.deinit(io);
    session.metadata_peers.clearRetainingCapacity();
    clearChunks(allocator, session);

    rec.metadata_complete = true;
    staging.applyProvisioned(rec, staged.provisioned);
    allocator.free(rec.name);
    rec.name = try allocator.dupe(u8, staged.meta.name);
    if (rec.metadata_error) |old| allocator.free(old);
    rec.metadata_error = null;

    if (staged.meta.private_torrent) {
        if (session.dht_socket) |*sock| sock.close(io, allocator);
        session.dht_socket = null;
        if (rec.dht_slot) |slot| {
            if (dht_ctx) |ctx| ctx.slots.release(slot);
            rec.dht_slot = null;
        }
    }

    session.fetching_metadata = false;
    session.meta = staged.meta;
    session.layout = staged.layout;
    session.content_dir = staged.content_dir;
    session.info_hash = staged.meta.info_hash;
    session.metadata_size = null;
    session.metadata_next_request = 0;
    for (session.trackers.items) |*endpoint| endpoint.state.next_announce_ms = 0;
    log.info("metadata_fetch", "metadata complete for {s} ({d} bytes)", .{ rec.info_hash_hex, size });
}

fn setError(allocator: std.mem.Allocator, io: std.Io, rec: *state.TorrentRecord, session: *TorrentSession, message: []const u8) void {
    if (rec.metadata_error) |old| allocator.free(old);
    rec.metadata_error = allocator.dupe(u8, message) catch null;
    for (session.metadata_peers.items) |*p| p.deinit(io);
    session.metadata_peers.clearRetainingCapacity();
}

fn clearChunks(allocator: std.mem.Allocator, session: *TorrentSession) void {
    var it = session.metadata_chunks.iterator();
    while (it.next()) |entry| allocator.free(entry.value_ptr.*);
    session.metadata_chunks.clearRetainingCapacity();
    session.metadata_next_request = 0;
}
