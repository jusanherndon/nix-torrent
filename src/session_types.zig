// Leaf types for Torrent Session. Split from session.zig so collaborators can import without a cycle against session.tick.
const std = @import("std");
const peer = @import("peer.zig");
const storage = @import("storage.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");
const dht = @import("dht.zig");

pub const metadata_piece_size: u32 = 16 * 1024;

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
    /// Deduplicated peer candidates from trackers and DHT (V2_NETWORK_PLAN).
    peer_candidates: std.ArrayList(tracker.Peer) = .empty,
    peer_candidate_cursor: usize = 0,
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
        self.peer_candidates.deinit(allocator);
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
