const std = @import("std");
const bencode = @import("bencode.zig");
const encryption = @import("encryption.zig");
const peer = @import("peer.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

const net = std.Io.net;
const c = std.c;

fn pollFd(fd: c.fd_t, timeout_ms: c_int) bool {
    var fds = [_]c.pollfd{.{
        .fd = fd,
        .events = c.POLL.IN,
        .revents = 0,
    }};
    return c.poll(&fds, 1, timeout_ms) > 0;
}

pub const Endpoint = struct {
    ip: [4]u8 = .{ 127, 0, 0, 1 },
    port: u16,
};

pub fn compactPeerBytes(ep: Endpoint) [6]u8 {
    var out: [6]u8 = undefined;
    out[0] = ep.ip[0];
    out[1] = ep.ip[1];
    out[2] = ep.ip[2];
    out[3] = ep.ip[3];
    std.mem.writeInt(u16, out[4..6], ep.port, .big);
    return out;
}

pub fn buildHttpTrackerBody(allocator: std.mem.Allocator, peers: []const Endpoint) ![]u8 {
    var compact: std.ArrayList(u8) = .empty;
    errdefer compact.deinit(allocator);
    for (peers) |ep| try compact.appendSlice(allocator, &compactPeerBytes(ep));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d8:intervali60e5:peers");
    const prefix = try std.fmt.allocPrint(allocator, "{d}:", .{compact.items.len});
    defer allocator.free(prefix);
    try out.appendSlice(allocator, prefix);
    try out.appendSlice(allocator, compact.items);
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

pub const BackgroundServer = struct {
    thread: std.Thread,
    allocator: std.mem.Allocator,
    stop: *std.atomic.Value(bool),
    port: u16,
    server: ?*net.Server = null,
    socket: ?*net.Socket = null,

    pub fn join(self: BackgroundServer, io: std.Io) void {
        self.stop.store(true, .release);
        self.thread.join();
        if (self.server) |server| server.deinit(io);
        if (self.socket) |socket| socket.close(io);
        self.allocator.destroy(self.stop);
    }
};

pub fn spawnFakeHttpTracker(io: std.Io, allocator: std.mem.Allocator, peers: []const Endpoint) !BackgroundServer {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const server = try addr.listen(io, .{ .mode = .stream, .kernel_backlog = 8 });
    const port = server.socket.address.ip4.port;
    const stop = try allocator.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const body = try buildHttpTrackerBody(allocator, peers);
    const ctx = try allocator.create(HttpCtx);
    ctx.* = .{ .allocator = allocator, .server = server, .stop = stop, .body = body };
    const thread = try std.Thread.spawn(.{}, httpWorker, .{ctx});
    return .{ .thread = thread, .allocator = allocator, .stop = stop, .port = port, .server = &ctx.server };
}

const HttpCtx = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    stop: *std.atomic.Value(bool),
    body: []const u8,
};

fn httpWorker(ctx: *HttpCtx) void {
    const listen_fd = ctx.server.socket.handle;
    defer {
        ctx.allocator.free(ctx.body);
        ctx.allocator.destroy(ctx);
    }
    while (!ctx.stop.load(.acquire)) {
        if (!pollFd(listen_fd, 50)) continue;
        const client_fd = c.accept(listen_fd, null, null);
        if (client_fd < 0) continue;
        handleHttpPosix(client_fd, ctx.body) catch {};
        _ = c.close(client_fd);
    }
}

fn handleHttpPosix(client_fd: c.fd_t, body: []const u8) !void {
    var buf: [4096]u8 = undefined;
    _ = c.read(client_fd, &buf, buf.len);
    const header = try std.fmt.allocPrint(std.heap.page_allocator, "HTTP/1.0 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len});
    defer std.heap.page_allocator.free(header);
    _ = c.write(client_fd, header.ptr, header.len);
    _ = c.write(client_fd, body.ptr, body.len);
}

pub fn spawnFakeUdpTracker(io: std.Io, allocator: std.mem.Allocator, peers: []const Endpoint) !BackgroundServer {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const socket = try net.IpAddress.bind(&addr, io, .{ .mode = .dgram });
    const port = socket.address.ip4.port;
    const stop = try allocator.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const ctx = try allocator.create(UdpCtx);
    ctx.* = .{ .allocator = allocator, .socket = socket, .fd = socket.handle, .stop = stop, .peers = peers };
    const thread = try std.Thread.spawn(.{}, udpWorker, .{ctx});
    return .{ .thread = thread, .allocator = allocator, .stop = stop, .port = port, .socket = &ctx.socket };
}

const UdpCtx = struct {
    allocator: std.mem.Allocator,
    socket: net.Socket,
    fd: c.fd_t,
    stop: *std.atomic.Value(bool),
    peers: []const Endpoint,
};

fn udpWorker(ctx: *UdpCtx) void {
    defer ctx.allocator.destroy(ctx);
    var buf: [1500]u8 = undefined;
    while (!ctx.stop.load(.acquire)) {
        if (!pollFd(ctx.fd, 50)) continue;
        var src: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
        src.family = c.AF.INET;
        var src_len: c.socklen_t = @sizeOf(c.sockaddr.in);
        const n = c.recvfrom(ctx.fd, &buf, buf.len, 0, @ptrCast(&src), &src_len);
        if (n < 0) continue;
        if (n < 16) continue;
        const action = std.mem.readInt(u32, buf[8..12], .big);
        const tx = std.mem.readInt(u32, buf[12..16], .big);
        if (action == 0) {
            var resp: [16]u8 = undefined;
            std.mem.writeInt(u32, resp[0..4], 0, .big);
            std.mem.writeInt(u32, resp[4..8], tx, .big);
            std.mem.writeInt(i64, resp[8..16], 1, .big);
            _ = c.sendto(ctx.fd, &resp, resp.len, 0, @ptrCast(&src), src_len);
        } else if (action == 1) {
            var header: [20]u8 = [_]u8{0} ** 20;
            std.mem.writeInt(u32, header[0..4], 1, .big);
            std.mem.writeInt(u32, header[4..8], tx, .big);
            std.mem.writeInt(u32, header[8..12], 60, .big);
            var resp: std.ArrayList(u8) = .empty;
            resp.appendSlice(ctx.allocator, &header) catch continue;
            for (ctx.peers) |ep| resp.appendSlice(ctx.allocator, &compactPeerBytes(ep)) catch {};
            _ = c.sendto(ctx.fd, resp.items.ptr, resp.items.len, 0, @ptrCast(&src), src_len);
            resp.deinit(ctx.allocator);
        }
    }
}

pub fn spawnFakeDhtNode(io: std.Io, allocator: std.mem.Allocator, peers: []const Endpoint) !BackgroundServer {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const socket = try net.IpAddress.bind(&addr, io, .{ .mode = .dgram });
    const port = socket.address.ip4.port;
    const stop = try allocator.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const ctx = try allocator.create(DhtCtx);
    ctx.* = .{ .allocator = allocator, .socket = socket, .fd = socket.handle, .stop = stop, .peers = peers };
    const thread = try std.Thread.spawn(.{}, dhtWorker, .{ctx});
    return .{ .thread = thread, .allocator = allocator, .stop = stop, .port = port, .socket = &ctx.socket };
}

const DhtCtx = struct {
    allocator: std.mem.Allocator,
    socket: net.Socket,
    fd: c.fd_t,
    stop: *std.atomic.Value(bool),
    peers: []const Endpoint,
};

fn dhtWorker(ctx: *DhtCtx) void {
    defer ctx.allocator.destroy(ctx);
    var buf: [4096]u8 = undefined;
    var node_id: [20]u8 = [_]u8{9} ** 20;
    while (!ctx.stop.load(.acquire)) {
        if (!pollFd(ctx.fd, 50)) continue;
        var src: c.sockaddr.in = std.mem.zeroes(c.sockaddr.in);
        src.family = c.AF.INET;
        var src_len: c.socklen_t = @sizeOf(c.sockaddr.in);
        const n = c.recvfrom(ctx.fd, &buf, buf.len, 0, @ptrCast(&src), &src_len);
        if (n < 0) continue;
        const size: usize = @intCast(n);
        const root = bencode.parse(ctx.allocator, buf[0..size]) catch continue;
        defer root.deinit(ctx.allocator);
        if (root != .dict) continue;
        const q = root.dictGet("q") orelse continue;
        if (q != .string) continue;
        const t = root.dictGet("t") orelse continue;
        if (t != .string) continue;
        const response = if (std.mem.eql(u8, q.string, "ping"))
            buildDhtPingResponse(ctx.allocator, t.string, &node_id) catch continue
        else if (std.mem.eql(u8, q.string, "get_peers"))
            buildDhtGetPeersResponse(ctx.allocator, t.string, &node_id, ctx.peers) catch continue
        else
            continue;
        defer ctx.allocator.free(response);
        _ = c.sendto(ctx.fd, response.ptr, response.len, 0, @ptrCast(&src), src_len);
    }
}

fn buildDhtPingResponse(allocator: std.mem.Allocator, tx: []const u8, node_id: *const [20]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d1:rd2:id20:");
    try out.appendSlice(allocator, node_id);
    try out.append(allocator, 'e');
    try out.appendSlice(allocator, "1:t");
    const tx_prefix = try std.fmt.allocPrint(allocator, "{d}:", .{tx.len});
    defer allocator.free(tx_prefix);
    try out.appendSlice(allocator, tx_prefix);
    try out.appendSlice(allocator, tx);
    try out.appendSlice(allocator, "1:y1:r");
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

fn buildDhtGetPeersResponse(allocator: std.mem.Allocator, tx: []const u8, node_id: *const [20]u8, peers: []const Endpoint) ![]u8 {
    var values: std.ArrayList(u8) = .empty;
    defer values.deinit(allocator);
    for (peers) |ep| try values.appendSlice(allocator, &compactPeerBytes(ep));
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d1:rd2:id20:");
    try out.appendSlice(allocator, node_id);
    try out.appendSlice(allocator, "6:values");
    const len_prefix = try std.fmt.allocPrint(allocator, "{d}:", .{values.items.len});
    defer allocator.free(len_prefix);
    try out.appendSlice(allocator, len_prefix);
    try out.appendSlice(allocator, values.items);
    try out.append(allocator, 'e');
    try out.appendSlice(allocator, "1:t");
    const tx_prefix = try std.fmt.allocPrint(allocator, "{d}:", .{tx.len});
    defer allocator.free(tx_prefix);
    try out.appendSlice(allocator, tx_prefix);
    try out.appendSlice(allocator, tx);
    try out.appendSlice(allocator, "1:y1:r");
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

pub const ContentPeerMode = enum { plaintext, encrypted };

pub fn spawnFakeContentPeer(
    io: std.Io,
    allocator: std.mem.Allocator,
    meta: torrent.Metadata,
    mode: ContentPeerMode,
) !BackgroundServer {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const server = try addr.listen(io, .{ .mode = .stream, .kernel_backlog = 8 });
    const port = server.socket.address.ip4.port;
    const stop = try allocator.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const info = meta.root.dictGet("info").?;
    const info_bytes = info.dict.raw;
    const ctx = try allocator.create(ContentCtx);
    ctx.* = .{
        .allocator = allocator,
        .server = server,
        .stop = stop,
        .info_hash = meta.info_hash,
        .info_bytes = info_bytes,
        .piece_length = meta.piece_length,
        .piece_count = meta.pieces.len / 20,
        .mode = mode,
    };
    const thread = try std.Thread.spawn(.{}, contentWorker, .{ctx});
    return .{ .thread = thread, .allocator = allocator, .stop = stop, .port = port, .server = &ctx.server };
}

const ContentCtx = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    stop: *std.atomic.Value(bool),
    info_hash: torrent.InfoHash,
    info_bytes: []const u8,
    piece_length: u64,
    piece_count: usize,
    mode: ContentPeerMode,
};

fn contentWorker(ctx: *ContentCtx) void {
    const listen_fd = ctx.server.socket.handle;
    defer ctx.allocator.destroy(ctx);
    while (!ctx.stop.load(.acquire)) {
        if (!pollFd(listen_fd, 50)) continue;
        const client_fd = c.accept(listen_fd, null, null);
        if (client_fd < 0) continue;
        handleContentPeerFd(ctx, client_fd) catch {};
        _ = c.close(client_fd);
    }
}

fn handleContentPeerFd(ctx: *ContentCtx, fd: c.fd_t) !void {
    switch (ctx.mode) {
        .plaintext => try servePlainContentPeerFd(fd, ctx.info_hash, ctx.info_bytes, ctx.piece_length, ctx.piece_count),
        .encrypted => try serveEncryptedContentPeerFd(ctx.allocator, fd, ctx.info_hash, ctx.info_bytes, ctx.piece_length, ctx.piece_count),
    }
}

fn servePlainContentPeerFd(fd: c.fd_t, info_hash: torrent.InfoHash, info_bytes: []const u8, piece_length: u64, piece_count: usize) !void {
    var hs_in: [700]u8 = undefined;
    const first = try readSomeFd(fd, &hs_in);
    if (first == 0) return;
    if (hs_in[0] != 19) {
        var hs_out: [68]u8 = undefined;
        peer.encodeHandshake(&hs_out, info_hash, [_]u8{0x2A} ** 20, false);
        try writeAllFd(fd, &hs_out);
        return;
    }
    var got: usize = first;
    while (got < 68) {
        const n = try readSomeFd(fd, hs_in[got..]);
        if (n == 0) return error.ShortMessage;
        got += n;
    }
    var hs_out: [68]u8 = undefined;
    peer.encodeHandshake(&hs_out, info_hash, [_]u8{0x2A} ** 20, false);
    try writeAllFd(fd, &hs_out);
    const extensions = hs_in[20] & 0x10 != 0;
    if (extensions) return;
    const bitfield_len = (piece_count + 7) / 8;
    const bitfield = try std.heap.page_allocator.alloc(u8, bitfield_len);
    defer std.heap.page_allocator.free(bitfield);
    @memset(bitfield, 0xFF);
    const bf_msg = try peer.encodeMessage(std.heap.page_allocator, .{ .bitfield = bitfield });
    defer std.heap.page_allocator.free(bf_msg);
    try writeAllFd(fd, bf_msg);
    const unchoke = try peer.encodeMessage(std.heap.page_allocator, .unchoke);
    defer std.heap.page_allocator.free(unchoke);
    try writeAllFd(fd, unchoke);
    servePieceRequestsFd(fd, info_bytes, piece_length) catch {};
}

fn serveEncryptedContentPeerFd(allocator: std.mem.Allocator, fd: c.fd_t, info_hash: torrent.InfoHash, info_bytes: []const u8, piece_length: u64, piece_count: usize) !void {
    var init_buf: [700]u8 = undefined;
    const init_len = try readSomeFd(fd, &init_buf);
    const remote_pub = encryption.extractRemotePublic(init_buf[0..init_len]) orelse return error.MalformedEncryption;
    const keys = try encryption.generateKeyPair(allocator);
    defer allocator.free(keys.private);
    const resp = try encryption.buildResponderPayload(allocator, keys.public);
    defer allocator.free(resp);
    try writeAllFd(fd, resp);
    var select_buf: [8]u8 = undefined;
    try readExactFd(fd, &select_buf);
    const shared = try encryption.sharedSecret(allocator, keys.private, remote_pub);
    defer allocator.free(shared);
    var session = try encryption.Session.derive(allocator, shared, false);
    var hs_in: [68]u8 = undefined;
    try readExactFd(fd, &hs_in);
    session.decrypt.crypt(&hs_in);
    var hs_out: [68]u8 = undefined;
    peer.encodeHandshake(&hs_out, info_hash, [_]u8{0x2A} ** 20, false);
    session.encrypt.crypt(&hs_out);
    try writeAllFd(fd, &hs_out);
    const bitfield_len = (piece_count + 7) / 8;
    const bitfield = try allocator.alloc(u8, bitfield_len);
    defer allocator.free(bitfield);
    @memset(bitfield, 0xFF);
    const bf_msg = try peer.encodeMessage(allocator, .{ .bitfield = bitfield });
    defer allocator.free(bf_msg);
    const bf_scratch = try allocator.dupe(u8, bf_msg);
    defer allocator.free(bf_scratch);
    session.encrypt.crypt(bf_scratch);
    try writeAllFd(fd, bf_scratch);
    const unchoke = try peer.encodeMessage(allocator, .unchoke);
    defer allocator.free(unchoke);
    const uc_scratch = try allocator.dupe(u8, unchoke);
    defer allocator.free(uc_scratch);
    session.encrypt.crypt(uc_scratch);
    try writeAllFd(fd, uc_scratch);
    serveEncryptedPieceRequestsFd(fd, &session, info_bytes, piece_length) catch {};
}

fn servePieceRequestsFd(fd: c.fd_t, info_bytes: []const u8, piece_length: u64) !void {
    var recv: std.ArrayList(u8) = .empty;
    defer recv.deinit(std.heap.page_allocator);
    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = readSomeFd(fd, &scratch) catch break;
        if (n == 0) break;
        recv.appendSlice(std.heap.page_allocator, scratch[0..n]) catch break;
        while (recv.items.len >= 4) {
            const len = std.mem.readInt(u32, recv.items[0..4], .big);
            if (recv.items.len < 4 + len) break;
            const frame = recv.items[4 .. 4 + len];
            const msg = peer.decodeMessage(frame) catch break;
            if (msg == .request) {
                const block = msg.request;
                const begin = block.begin;
                const end = begin + block.length;
                if (end > piece_length or end > info_bytes.len) break;
                const piece_msg = try peer.encodeMessage(std.heap.page_allocator, .{ .piece = .{
                    .index = block.index,
                    .begin = begin,
                    .block = info_bytes[begin..end],
                } });
                defer std.heap.page_allocator.free(piece_msg);
                try writeAllFd(fd, piece_msg);
            }
            recv.replaceRange(std.heap.page_allocator, 0, 4 + len, &.{}) catch break;
        }
    }
}

fn serveEncryptedPieceRequestsFd(fd: c.fd_t, session: *encryption.Session, info_bytes: []const u8, piece_length: u64) !void {
    var recv: std.ArrayList(u8) = .empty;
    defer recv.deinit(std.heap.page_allocator);
    var scratch: [4096]u8 = undefined;
    while (true) {
        const n = readSomeFd(fd, &scratch) catch break;
        if (n == 0) break;
        const chunk = scratch[0..n];
        session.decrypt.crypt(chunk);
        recv.appendSlice(std.heap.page_allocator, chunk) catch break;
        while (recv.items.len >= 4) {
            const len = std.mem.readInt(u32, recv.items[0..4], .big);
            if (recv.items.len < 4 + len) break;
            const frame = recv.items[4 .. 4 + len];
            const msg = peer.decodeMessage(frame) catch break;
            if (msg == .request) {
                const block = msg.request;
                const begin = block.begin;
                const end = begin + block.length;
                if (end > piece_length or end > info_bytes.len) break;
                const piece_msg = try peer.encodeMessage(std.heap.page_allocator, .{ .piece = .{
                    .index = block.index,
                    .begin = begin,
                    .block = info_bytes[begin..end],
                } });
                defer std.heap.page_allocator.free(piece_msg);
                const out = try std.heap.page_allocator.dupe(u8, piece_msg);
                defer std.heap.page_allocator.free(out);
                session.encrypt.crypt(out);
                try writeAllFd(fd, out);
            }
            recv.replaceRange(std.heap.page_allocator, 0, 4 + len, &.{}) catch break;
        }
    }
}

pub fn spawnFakeMetadataPeer(io: std.Io, allocator: std.mem.Allocator, info_hash: torrent.InfoHash, info_bytes: []const u8) !BackgroundServer {
    const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 0 } };
    const server = try addr.listen(io, .{ .mode = .stream, .kernel_backlog = 8 });
    const port = server.socket.address.ip4.port;
    const stop = try allocator.create(std.atomic.Value(bool));
    stop.* = std.atomic.Value(bool).init(false);
    const ctx = try allocator.create(MetadataCtx);
    ctx.* = .{ .allocator = allocator, .server = server, .stop = stop, .info_hash = info_hash, .info_bytes = info_bytes };
    const thread = try std.Thread.spawn(.{}, metadataWorker, .{ctx});
    return .{ .thread = thread, .allocator = allocator, .stop = stop, .port = port, .server = &ctx.server };
}

const MetadataCtx = struct {
    allocator: std.mem.Allocator,
    server: net.Server,
    stop: *std.atomic.Value(bool),
    info_hash: torrent.InfoHash,
    info_bytes: []const u8,
};

fn metadataWorker(ctx: *MetadataCtx) void {
    const listen_fd = ctx.server.socket.handle;
    defer ctx.allocator.destroy(ctx);
    while (!ctx.stop.load(.acquire)) {
        if (!pollFd(listen_fd, 50)) continue;
        const client_fd = c.accept(listen_fd, null, null);
        if (client_fd < 0) continue;
        handleMetadataPeerFd(ctx, client_fd);
    }
}

fn handleMetadataPeerFd(ctx: *MetadataCtx, fd: c.fd_t) void {
    handleMetadataPeerFdInner(ctx, fd) catch {};
    _ = c.close(fd);
}

fn handleMetadataPeerFdInner(ctx: *MetadataCtx, fd: c.fd_t) !void {
    var hs_in: [700]u8 = undefined;
    var got: usize = 0;
    while (got < 68) {
        const n = try readSomeFd(fd, hs_in[got..]);
        if (n == 0) return error.ShortMessage;
        got += n;
    }
    const extensions = hs_in[20] & 0x10 != 0;
    var hs_out: [68]u8 = undefined;
    peer.encodeHandshake(&hs_out, ctx.info_hash, [_]u8{0x2B} ** 20, extensions);
    try writeAllFd(fd, &hs_out);
    if (!extensions) return;

    const ext_out = try encodeMetadataHandshake(ctx.allocator, ctx.info_bytes.len);
    defer ctx.allocator.free(ext_out);
    try writeAllFd(fd, ext_out);
    const data_msg = try encodeMetadataData(ctx.allocator, 0, ctx.info_bytes);
    defer ctx.allocator.free(data_msg);
    try writeAllFd(fd, data_msg);
}

fn encodeMetadataHandshake(allocator: std.mem.Allocator, metadata_size: usize) ![]u8 {
    const dict = try std.fmt.allocPrint(allocator, "d1:md11:ut_metadatai1ee13:metadata_sizei{d}ee", .{metadata_size});
    defer allocator.free(dict);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 0);
    try payload.appendSlice(allocator, dict);
    return peer.encodeMessage(allocator, .{ .extended = payload.items });
}

fn encodeMetadataData(allocator: std.mem.Allocator, piece: u32, info_bytes: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "d8:msg_typei1e5:piecei{d}ee", .{piece});
    defer allocator.free(header);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try payload.append(allocator, 1);
    try payload.appendSlice(allocator, header);
    try payload.appendSlice(allocator, info_bytes);
    return peer.encodeMessage(allocator, .{ .extended = payload.items });
}

fn readExactFd(fd: c.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.read(fd, buf[got..].ptr, buf.len - got);
        if (n <= 0) return error.ShortMessage;
        got += @intCast(n);
    }
}

fn readSomeFdPoll(fd: c.fd_t, buf: []u8) !usize {
    if (!pollFd(fd, 50)) return 0;
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return 0;
    return @intCast(n);
}

fn readSomeFd(fd: c.fd_t, buf: []u8) !usize {
    const n = c.read(fd, buf.ptr, buf.len);
    if (n < 0) return 0;
    return @intCast(n);
}

fn writeAllFd(fd: c.fd_t, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.write(fd, bytes[sent..].ptr, bytes.len - sent);
        if (n <= 0) return error.BrokenPipe;
        sent += @intCast(n);
    }
}

test "fake metadata handshake message parses" {
    const allocator = std.testing.allocator;
    const msg = try encodeMetadataHandshake(allocator, 512);
    defer allocator.free(msg);
    const decoded = try peer.decodeMessage(msg);
    try std.testing.expect(decoded == .extended);
    const parsed = try peer.parsePeerExtendedHandshake(allocator, decoded.extended);
    const hs = parsed orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u8, 1), hs.ut_metadata_id);
    try std.testing.expectEqual(@as(usize, 512), hs.metadata_size);
}

test "fake dht get_peers response is valid bencode" {
    const ep = Endpoint{ .port = 12345 };
    const id = [_]u8{9} ** 20;
    const bytes = try buildDhtGetPeersResponse(std.testing.allocator, "nt", &id, &.{ep});
    defer std.testing.allocator.free(bytes);
    const root = try bencode.parse(std.testing.allocator, bytes);
    defer root.deinit(std.testing.allocator);
    const r = root.dictGet("r").?;
    try std.testing.expect(r == .dict);
    const values = r.dictGet("values").?;
    try std.testing.expect(values == .string);
    try std.testing.expectEqual(@as(usize, 6), values.string.len);
}
