const std = @import("std");
const address = @import("address.zig");
const config = @import("config.zig");
const encryption = @import("encryption.zig");
const engine_mod = @import("engine.zig");
const log = @import("log.zig");
const peer = @import("peer.zig");
const state = @import("state.zig");
const tcp = @import("tcp.zig");
const torrent = @import("torrent.zig");

const net = std.Io.net;
const c = std.c;

/// Dual-stack TCP Listen Socket for inbound (download-only) BitTorrent peers.
/// Bound on `::` with `ip6_only=false` so IPv4-mapped peers are also accepted.
pub const InboundListener = struct {
    server: ?net.Server = null,
    listen_port: u16,
    /// Reported in status; set by the port-mapping subsystem (M3).
    listen_port_mapped: bool = false,

    pub fn init(listen_port: u16) InboundListener {
        return .{ .listen_port = listen_port };
    }

    pub fn start(self: *InboundListener, io: std.Io) !void {
        const addr = net.IpAddress{ .ip6 = net.Ip6Address.unspecified(self.listen_port) };
        self.server = try net.IpAddress.listen(&addr, io, .{ .mode = .stream, .kernel_backlog = 16 });
        log.info("inbound", "listening for inbound peers on [::]:{d}", .{self.listen_port});
    }

    pub fn deinit(self: *InboundListener, io: std.Io) void {
        if (self.server) |*s| s.deinit(io);
        self.server = null;
    }

    /// Non-blocking accept + handshake + attach. Runs once per daemon loop.
    /// Any failure closes the connection; the daemon must never crash on inbound.
    pub fn poll(
        self: *InboundListener,
        io: std.Io,
        cfg: config.Config,
        engine: *engine_mod.Engine,
        peer_id: [20]u8,
    ) void {
        const server = &(self.server orelse return);
        if (!socketReadable(server.socket.handle)) return;
        const stream = server.accept(io) catch return;
        var attached = false;
        var conn = peer.Connection.fromStream(cfg_allocator(engine), stream, peerAddress(stream), cfg.network.peer_request_timeout_ms);
        defer if (!attached) conn.deinit(io);

        const total_inbound = engine.inboundPeerCount();
        if (total_inbound >= cfg.limits.max_inbound_handshakes) return;

        var candidate_buf: [256]torrent.InfoHash = undefined;
        const candidates = collectCandidates(engine, &candidate_buf);
        if (candidates.len == 0) return;

        const policy = config.encryptionPolicy(cfg.network);
        const matched = conn.performInboundHandshake(io, candidates, peer_id, policy) catch return;

        const hex = state.infoHashHex(matched);
        const sess = engine.findSession(&hex) orelse return;

        if (sess.fetching_metadata) {
            if (inboundCount(sess.metadata_peers.items) >= cfg.limits.max_inbound_peers_per_torrent) return;
            conn.negotiateMetadataAfterHandshake(io) catch return;
            conn.requestMetadataPiece(io, sess.metadata_next_request) catch {};
            sess.metadata_peers.append(cfg_allocator(engine), conn) catch return;
            attached = true;
        } else {
            if (inboundCount(sess.peers.items) >= cfg.limits.max_inbound_peers_per_torrent) return;
            conn.sendInterested(io) catch return;
            sess.peers.append(cfg_allocator(engine), conn) catch return;
            attached = true;
        }
        var buf: [64]u8 = undefined;
        log.debug("inbound", "attached inbound peer {s} to {s}", .{ conn.peer_addr.render(&buf), sess.info_hash_hex });
    }
};

fn cfg_allocator(engine: *engine_mod.Engine) std.mem.Allocator {
    return engine.allocator;
}

fn peerAddress(stream: net.Stream) address.Address {
    return address.Address.fromIpAddress(stream.socket.address);
}

fn socketReadable(handle: net.Socket.Handle) bool {
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&fds, 0) catch return false;
    return n > 0;
}

fn inboundCount(peers: []const peer.Connection) u64 {
    var n: u64 = 0;
    for (peers) |p| {
        if (p.direction == .inbound) n += 1;
    }
    return n;
}

/// Active sessions eligible to receive inbound peers (downloading or fetching metadata).
fn collectCandidates(engine: *engine_mod.Engine, buf: []torrent.InfoHash) []const torrent.InfoHash {
    var n: usize = 0;
    for (engine.sessions.items) |*sess| {
        if (n >= buf.len) break;
        buf[n] = sess.info_hash;
        n += 1;
    }
    return buf[0..n];
}
