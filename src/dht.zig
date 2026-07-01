const std = @import("std");
const bencode = @import("bencode.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

const net = std.Io.net;

pub const NodeId = [20]u8;
pub const Node = struct { id: NodeId, ip: [4]u8, port: u16 };

pub const Config = struct {
    enabled: bool = true,
    bootstrap_nodes: []const []const u8,
    request_timeout_ms: u64 = 5000,
    refresh_interval_ms: u64 = 900_000,
};

pub const RoutingTable = struct {
    allocator: std.mem.Allocator,
    node_id: NodeId,
    nodes: std.ArrayList(Node) = .empty,

    pub fn init(allocator: std.mem.Allocator, node_id: NodeId) RoutingTable {
        return .{ .allocator = allocator, .node_id = node_id };
    }

    pub fn deinit(self: *RoutingTable) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn addNode(self: *RoutingTable, node: Node) !void {
        for (self.nodes.items) |existing| {
            if (std.mem.eql(u8, &existing.id, &node.id)) return;
            if (existing.ip[0] == node.ip[0] and existing.ip[1] == node.ip[1] and existing.ip[2] == node.ip[2] and existing.ip[3] == node.ip[3] and existing.port == node.port) return;
        }
        if (self.nodes.items.len >= 128) return;
        try self.nodes.append(self.allocator, node);
    }

    pub fn addCompactNodes(self: *RoutingTable, bytes: []const u8) !void {
        if (bytes.len % 26 != 0) return;
        var i: usize = 0;
        while (i + 26 <= bytes.len) : (i += 26) {
            var id: NodeId = undefined;
            @memcpy(&id, bytes[i .. i + 20]);
            const ip: [4]u8 = .{ bytes[i + 20], bytes[i + 21], bytes[i + 22], bytes[i + 23] };
            const port = std.mem.readInt(u16, bytes[i + 24 .. i + 26][0..2], .big);
            try self.addNode(.{ .id = id, .ip = ip, .port = port });
        }
    }
};

pub const SlotAllocator = struct {
    slots: []bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_slots: usize) !SlotAllocator {
        const slots = try allocator.alloc(bool, max_slots);
        @memset(slots, false);
        return .{ .slots = slots, .allocator = allocator };
    }

    pub fn deinit(self: *SlotAllocator) void {
        self.allocator.free(self.slots);
    }

    pub fn allocate(self: *SlotAllocator) ?usize {
        for (self.slots, 0..) |taken, i| {
            if (!taken) {
                self.slots[i] = true;
                return i;
            }
        }
        return null;
    }

    pub fn release(self: *SlotAllocator, slot: usize) void {
        if (slot < self.slots.len) self.slots[slot] = false;
    }

    pub fn reserve(self: *SlotAllocator, slot: usize) bool {
        if (slot >= self.slots.len or self.slots[slot]) return false;
        self.slots[slot] = true;
        return true;
    }
};

pub const TorrentDhtSocket = struct {
    slot: usize,
    bind_port: u16,
    socket: ?net.Socket = null,
    last_error: ?[]const u8 = null,
    last_lookup_ms: i64 = 0,
    lookup_interval_ms: i64 = 60_000,
    opened: bool = false,

    pub fn open(self: *TorrentDhtSocket, io: std.Io, bind_port: u16) !void {
        if (self.opened) return;
        const addr = net.IpAddress{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = bind_port } };
        self.socket = try net.IpAddress.bind(&addr, io, .{ .mode = .dgram });
        self.bind_port = bind_port;
        self.opened = true;
    }

    pub fn close(self: *TorrentDhtSocket, io: std.Io, allocator: std.mem.Allocator) void {
        if (self.socket) |s| s.close(io);
        self.socket = null;
        self.opened = false;
        if (self.last_error) |e| allocator.free(e);
        self.last_error = null;
    }

    pub fn tick(
        self: *TorrentDhtSocket,
        io: std.Io,
        allocator: std.mem.Allocator,
        routing: *RoutingTable,
        cfg: Config,
        info_hash: torrent.InfoHash,
        now_ms: i64,
    ) ![]tracker.Peer {
        const socket = self.socket orelse return &.{};
        if (now_ms - self.last_lookup_ms < self.lookup_interval_ms) return &.{};
        self.last_lookup_ms = now_ms;

        const targets: []const BootstrapTarget = if (routing.nodes.items.len > 0) blk: {
            const slice = routing.nodes.items[0..@min(routing.nodes.items.len, 3)];
            var converted = try allocator.alloc(BootstrapTarget, slice.len);
            for (slice, 0..) |node, i| converted[i] = .{ .ip = node.ip, .port = node.port, .id = node.id };
            break :blk converted;
        } else try parseBootstrapNodes(allocator, cfg.bootstrap_nodes);

        defer if (routing.nodes.items.len == 0) allocator.free(targets);

        var peers = std.ArrayList(tracker.Peer).empty;
        errdefer {
            for (peers.items) |_| {}
            peers.deinit(allocator);
        }

        for (targets) |node| {
            const response = sendGetPeers(io, allocator, socket, routing.node_id, info_hash, node, cfg.request_timeout_ms) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "dht get_peers failed: {s}", .{@errorName(err)});
                if (self.last_error) |old| allocator.free(old);
                self.last_error = msg;
                continue;
            };
            defer response.deinit();
            if (self.last_error) |old| allocator.free(old);
            self.last_error = null;
            if (response.nodes) |nodes| try routing.addCompactNodes(nodes);
            if (response.peers) |compact| {
                const parsed = try tracker.parseCompactPeers(allocator, compact);
                defer allocator.free(parsed);
                for (parsed) |p| try peers.append(allocator, p);
            }
        }

        return peers.toOwnedSlice(allocator);
    }
};

const BootstrapTarget = struct { ip: [4]u8, port: u16, id: NodeId };

fn parseBootstrapNodes(allocator: std.mem.Allocator, nodes: []const []const u8) ![]BootstrapTarget {
    var out = std.ArrayList(BootstrapTarget).empty;
    errdefer out.deinit(allocator);
    for (nodes) |spec| {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse continue;
        const host = spec[0..colon];
        const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch continue;
        const ip4 = net.Ip4Address.parse(host, 0) catch continue;
        var id: NodeId = undefined;
        @memset(&id, 0);
        try out.append(allocator, .{ .ip = ip4.bytes, .port = port, .id = id });
    }
    return out.toOwnedSlice(allocator);
}

const GetPeersResponse = struct {
    peers: ?[]const u8 = null,
    nodes: ?[]const u8 = null,
    allocator: std.mem.Allocator,
    fn deinit(self: GetPeersResponse) void {
        if (self.peers) |p| self.allocator.free(p);
        if (self.nodes) |n| self.allocator.free(n);
    }
};

fn sendGetPeers(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket: net.Socket,
    node_id: NodeId,
    info_hash: torrent.InfoHash,
    target: BootstrapTarget,
    timeout_ms: u64,
) !GetPeersResponse {
    const tx = "nt";
    const query = try encodeGetPeersQuery(allocator, tx, node_id, info_hash);
    defer allocator.free(query);
    const dest = net.IpAddress{ .ip4 = .{ .bytes = target.ip, .port = target.port } };
    try socket.send(io, &dest, query);
    var buf: [4096]u8 = undefined;
    const timeout: std.Io.Timeout = .{ .duration = .{
        .clock = .awake,
        .raw = .fromNanoseconds(timeout_ms * std.time.ns_per_ms),
    } };
    const message = try socket.receiveTimeout(io, &buf, timeout);
    return parseGetPeersResponse(allocator, message.data);
}

fn encodeGetPeersQuery(allocator: std.mem.Allocator, tx: []const u8, node_id: NodeId, info_hash: torrent.InfoHash) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d1:q9:get_peers1:t");
    try out.append(allocator, @intCast(tx.len));
    try out.append(allocator, ':');
    try out.appendSlice(allocator, tx);
    try out.appendSlice(allocator, "1:y1:qa");
    try out.append(allocator, 'd');
    try out.appendSlice(allocator, "2:id20:");
    try out.appendSlice(allocator, &node_id);
    try out.appendSlice(allocator, "9:info_hash20:");
    try out.appendSlice(allocator, &info_hash);
    try out.append(allocator, 'e');
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

fn parseGetPeersResponse(allocator: std.mem.Allocator, bytes: []const u8) !GetPeersResponse {
    const root = try bencode.parse(allocator, bytes);
    defer root.deinit(allocator);
    if (root != .dict) return error.InvalidDhtResponse;
    const r = root.dictGet("r") orelse return error.InvalidDhtResponse;
    if (r != .dict) return error.InvalidDhtResponse;
    var out: GetPeersResponse = .{ .allocator = allocator };
    if (r.dictGet("values")) |v| {
        if (v == .string) out.peers = try allocator.dupe(u8, v.string);
    }
    if (r.dictGet("nodes")) |n| {
        if (n == .string) out.nodes = try allocator.dupe(u8, n.string);
    }
    return out;
}

pub fn deriveNodeId(peer_id: [20]u8) NodeId {
    return peer_id;
}

pub fn bootstrap(
    io: std.Io,
    allocator: std.mem.Allocator,
    routing: *RoutingTable,
    socket: net.Socket,
    bootstrap_nodes: []const []const u8,
    timeout_ms: u64,
) !void {
    for (bootstrap_nodes) |spec| {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse continue;
        const host = spec[0..colon];
        const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch continue;
        const ip4 = net.Ip4Address.parse(host, 0) catch continue;
        const tx = "bs";
        const query = try encodePingQuery(allocator, tx, routing.node_id);
        defer allocator.free(query);
        const dest = net.IpAddress{ .ip4 = .{ .bytes = ip4.bytes, .port = port } };
        socket.send(io, &dest, query) catch continue;
        var buf: [4096]u8 = undefined;
        const timeout: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromNanoseconds(timeout_ms * std.time.ns_per_ms),
        } };
        const message = socket.receiveTimeout(io, &buf, timeout) catch continue;
        const root = bencode.parse(allocator, message.data) catch continue;
        defer root.deinit(allocator);
        if (root != .dict) continue;
        const r = root.dictGet("r") orelse continue;
        if (r != .dict) continue;
        const id_v = r.dictGet("id") orelse continue;
        if (id_v != .string or id_v.string.len != 20) continue;
        var id: NodeId = undefined;
        @memcpy(&id, id_v.string[0..20]);
        try routing.addNode(.{ .id = id, .ip = ip4.bytes, .port = port });
    }
}

fn encodePingQuery(allocator: std.mem.Allocator, tx: []const u8, node_id: NodeId) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d1:q4:ping1:t");
    try out.append(allocator, @intCast(tx.len));
    try out.append(allocator, ':');
    try out.appendSlice(allocator, tx);
    try out.appendSlice(allocator, "1:y1:qa");
    try out.append(allocator, 'd');
    try out.appendSlice(allocator, "2:id20:");
    try out.appendSlice(allocator, &node_id);
    try out.append(allocator, 'e');
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

test "parses compact dht nodes" {
    var table = RoutingTable.init(std.testing.allocator, [_]u8{1} ** 20);
    defer table.deinit();
    var node_bytes: [26]u8 = undefined;
    @memset(node_bytes[0..20], 2);
    node_bytes[20] = 127;
    node_bytes[21] = 0;
    node_bytes[22] = 0;
    node_bytes[23] = 1;
    std.mem.writeInt(u16, node_bytes[24..26], 6881, .big);
    try table.addCompactNodes(&node_bytes);
    try std.testing.expectEqual(@as(usize, 1), table.nodes.items.len);
}
