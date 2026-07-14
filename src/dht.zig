const std = @import("std");
const address = @import("address.zig");
const bencode = @import("bencode.zig");
const dns = @import("dns.zig");
const torrent = @import("torrent.zig");
const tracker = @import("tracker.zig");

const net = std.Io.net;

pub const NodeId = [20]u8;
pub const Node = struct {
    id: NodeId,
    addr: address.Address,

    pub fn v4(id: NodeId, ip: [4]u8, port: u16) Node {
        return .{ .id = id, .addr = address.Address.v4(ip, port) };
    }
};

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
            if (existing.addr.eql(node.addr)) return;
        }
        if (self.nodes.items.len >= 128) return;
        try self.nodes.append(self.allocator, node);
    }

    /// BEP 5 compact nodes: 26 bytes each (20 id + 4 IPv4 + 2 port).
    pub fn addCompactNodes(self: *RoutingTable, bytes: []const u8) !void {
        if (bytes.len % 26 != 0) return;
        var i: usize = 0;
        while (i + 26 <= bytes.len) : (i += 26) {
            var id: NodeId = undefined;
            @memcpy(&id, bytes[i .. i + 20]);
            const ip: [4]u8 = .{ bytes[i + 20], bytes[i + 21], bytes[i + 22], bytes[i + 23] };
            const port = std.mem.readInt(u16, bytes[i + 24 .. i + 26][0..2], .big);
            try self.addNode(Node.v4(id, ip, port));
        }
    }

    /// BEP 32 compact nodes6: 38 bytes each (20 id + 16 IPv6 + 2 port).
    pub fn addCompactNodes6(self: *RoutingTable, bytes: []const u8) !void {
        if (bytes.len % 38 != 0) return;
        var i: usize = 0;
        while (i + 38 <= bytes.len) : (i += 38) {
            var id: NodeId = undefined;
            @memcpy(&id, bytes[i .. i + 20]);
            var ip: [16]u8 = undefined;
            @memcpy(&ip, bytes[i + 20 .. i + 36]);
            const port = std.mem.readInt(u16, bytes[i + 36 .. i + 38][0..2], .big);
            try self.addNode(.{ .id = id, .addr = address.Address.v6(ip, port) });
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

/// Max DHT nodes contacted per get_peers round (parallel UDP).
const get_peers_fanout: usize = 8;
/// Extra round after folding returned nodes into the routing table.
const get_peers_hops: usize = 2;

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
        advertise_port: u16,
    ) ![]tracker.Peer {
        const socket = self.socket orelse return &.{};
        if (now_ms - self.last_lookup_ms < self.lookup_interval_ms) return &.{};
        self.last_lookup_ms = now_ms;

        var peers = std.ArrayList(tracker.Peer).empty;
        errdefer peers.deinit(allocator);

        var queried = std.ArrayList(address.Address).empty;
        defer queried.deinit(allocator);

        var any_rpc_ok = false;
        var last_rpc_err: ?[]const u8 = null;
        defer if (last_rpc_err) |e| allocator.free(e);

        var hop: usize = 0;
        while (hop < get_peers_hops) : (hop += 1) {
            const targets = try selectGetPeersTargets(io, allocator, routing, cfg.bootstrap_nodes, info_hash, queried.items);
            defer allocator.free(targets);
            if (targets.len == 0) break;

            for (targets) |t| try queried.append(allocator, t.addr);

            const round = collectGetPeersRound(io, allocator, socket, routing.node_id, info_hash, targets, cfg.request_timeout_ms) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "dht get_peers failed: {s}", .{@errorName(err)});
                if (last_rpc_err) |old| allocator.free(old);
                last_rpc_err = msg;
                continue;
            };
            defer {
                for (round.responses) |*r| r.deinit();
                allocator.free(round.responses);
                allocator.free(round.targets);
            }

            if (round.responses.len == 0) {
                if (last_rpc_err == null) {
                    last_rpc_err = try std.fmt.allocPrint(allocator, "dht get_peers failed: Timeout", .{});
                }
                continue;
            }
            any_rpc_ok = true;

            for (round.responses, 0..) |response, i| {
                if (response.nodes) |nodes| try routing.addCompactNodes(nodes);
                if (response.nodes6) |nodes6| try routing.addCompactNodes6(nodes6);
                if (advertise_port != 0) {
                    if (response.token) |token| {
                        // Fire-and-forget: do not serialize on announce_peer replies during lookup.
                        sendAnnouncePeer(io, allocator, socket, routing.node_id, info_hash, round.targets[i], token, advertise_port) catch {};
                    }
                }
                for (response.values.items) |compact| {
                    const parsed = try tracker.parseCompactPeers(allocator, compact, null);
                    defer allocator.free(parsed);
                    for (parsed) |p| try peers.append(allocator, p);
                }
                for (response.values6.items) |compact| {
                    const parsed = try tracker.parseCompactPeers6(allocator, compact);
                    defer allocator.free(parsed);
                    for (parsed) |p| try peers.append(allocator, p);
                }
            }

            // Stop early once we have peer values; further hops are for refill.
            if (peers.items.len > 0) break;
        }

        if (any_rpc_ok) {
            if (self.last_error) |old| allocator.free(old);
            self.last_error = null;
            if (peers.items.len == 0 and last_rpc_err == null) {
                // Nodes answered with closer contacts but no values yet — not an RPC failure.
                self.last_error = try std.fmt.allocPrint(allocator, "dht get_peers: no values yet", .{});
            }
        } else if (last_rpc_err) |err_msg| {
            if (self.last_error) |old| allocator.free(old);
            self.last_error = try allocator.dupe(u8, err_msg);
        }

        return peers.toOwnedSlice(allocator);
    }
};

const BootstrapTarget = struct {
    addr: address.Address,
    id: NodeId,

    fn dest(self: BootstrapTarget) net.IpAddress {
        return self.addr.toIpAddress();
    }
};

fn xorDistance(a: NodeId, b: NodeId) NodeId {
    var out: NodeId = undefined;
    for (&out, a, b) |*o, x, y| o.* = x ^ y;
    return out;
}

fn distanceLessThan(a: NodeId, b: NodeId) bool {
    return std.mem.order(u8, &a, &b) == .lt;
}

fn alreadyQueried(queried: []const address.Address, addr: address.Address) bool {
    for (queried) |q| {
        if (q.eql(addr)) return true;
    }
    return false;
}

/// Selects up to `get_peers_fanout` closest routing-table nodes to `info_hash`,
/// falling back to bootstrap node specs when the table is empty.
fn selectGetPeersTargets(
    io: std.Io,
    allocator: std.mem.Allocator,
    routing: *RoutingTable,
    bootstrap_nodes: []const []const u8,
    info_hash: torrent.InfoHash,
    queried: []const address.Address,
) ![]BootstrapTarget {
    if (routing.nodes.items.len == 0) {
        const boot = try parseBootstrapNodes(io, allocator, bootstrap_nodes);
        var kept: usize = 0;
        for (boot) |t| {
            if (alreadyQueried(queried, t.addr)) continue;
            boot[kept] = t;
            kept += 1;
        }
        if (kept == 0) {
            allocator.free(boot);
            return try allocator.alloc(BootstrapTarget, 0);
        }
        if (kept == boot.len) return boot;
        return try allocator.realloc(boot, kept);
    }

    var scored = try allocator.alloc(struct { dist: NodeId, target: BootstrapTarget }, routing.nodes.items.len);
    defer allocator.free(scored);
    var n: usize = 0;
    for (routing.nodes.items) |node| {
        if (alreadyQueried(queried, node.addr)) continue;
        scored[n] = .{
            .dist = xorDistance(node.id, info_hash),
            .target = .{ .addr = node.addr, .id = node.id },
        };
        n += 1;
    }
    if (n == 0) return try allocator.alloc(BootstrapTarget, 0);

    std.sort.pdq(@TypeOf(scored[0]), scored[0..n], {}, struct {
        fn less(_: void, a: @TypeOf(scored[0]), b: @TypeOf(scored[0])) bool {
            return distanceLessThan(a.dist, b.dist);
        }
    }.less);

    const take = @min(n, get_peers_fanout);
    var out = try allocator.alloc(BootstrapTarget, take);
    for (0..take) |i| out[i] = scored[i].target;
    return out;
}

const GetPeersRound = struct {
    responses: []GetPeersResponse,
    targets: []BootstrapTarget,
};

/// Sends get_peers to all targets in parallel, then collects matching replies
/// until `timeout_ms` elapses or every outstanding query is answered.
fn collectGetPeersRound(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket: net.Socket,
    node_id: NodeId,
    info_hash: torrent.InfoHash,
    targets: []const BootstrapTarget,
    timeout_ms: u64,
) !GetPeersRound {
    if (targets.len == 0) {
        return .{
            .responses = try allocator.alloc(GetPeersResponse, 0),
            .targets = try allocator.alloc(BootstrapTarget, 0),
        };
    }

    // Unique 2-byte transaction ids per target so replies can be matched.
    var queries = try allocator.alloc(?[]u8, targets.len);
    defer {
        for (queries) |q| if (q) |bytes| allocator.free(bytes);
        allocator.free(queries);
    }
    @memset(queries, null);

    var outstanding = try allocator.alloc(bool, targets.len);
    defer allocator.free(outstanding);
    @memset(outstanding, false);

    var sent: usize = 0;
    for (targets, 0..) |target, i| {
        if (i > 255) break;
        var tx: [2]u8 = .{ 'g', @intCast(i) };
        const query = encodeGetPeersQuery(allocator, &tx, node_id, info_hash) catch continue;
        const dest = target.dest();
        socket.send(io, &dest, query) catch {
            allocator.free(query);
            continue;
        };
        queries[i] = query;
        outstanding[i] = true;
        sent += 1;
    }
    if (sent == 0) return error.Timeout;

    var responses = std.ArrayList(GetPeersResponse).empty;
    errdefer {
        for (responses.items) |*r| r.deinit();
        responses.deinit(allocator);
    }
    var matched_targets = std.ArrayList(BootstrapTarget).empty;
    errdefer matched_targets.deinit(allocator);

    var remaining_ns: u64 = timeout_ms * std.time.ns_per_ms;
    var buf: [4096]u8 = undefined;
    while (sent > 0 and remaining_ns > 0) {
        const slice_start_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();
        const timeout: std.Io.Timeout = .{ .duration = .{
            .clock = .awake,
            .raw = .fromNanoseconds(remaining_ns),
        } };
        const message = socket.receiveTimeout(io, &buf, timeout) catch break;
        const elapsed_ms = @max(@as(i64, 0), std.Io.Timestamp.now(io, .real).toMilliseconds() - slice_start_ms);
        const elapsed_ns: u64 = @as(u64, @intCast(elapsed_ms)) * std.time.ns_per_ms;
        remaining_ns = if (elapsed_ns >= remaining_ns) 0 else remaining_ns - elapsed_ns;

        const parsed = parseGetPeersResponse(allocator, message.data) catch continue;
        const idx = parsed.tx_index orelse {
            parsed.deinit();
            continue;
        };
        if (idx >= targets.len or !outstanding[idx]) {
            parsed.deinit();
            continue;
        }
        outstanding[idx] = false;
        sent -= 1;
        try responses.append(allocator, parsed);
        try matched_targets.append(allocator, targets[idx]);
    }

    return .{
        .responses = try responses.toOwnedSlice(allocator),
        .targets = try matched_targets.toOwnedSlice(allocator),
    };
}

fn parseBootstrapNodes(io: std.Io, allocator: std.mem.Allocator, nodes: []const []const u8) ![]BootstrapTarget {
    var out = std.ArrayList(BootstrapTarget).empty;
    errdefer out.deinit(allocator);
    for (nodes) |spec| {
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse continue;
        const host = spec[0..colon];
        const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch continue;
        const addr = dns.resolveAddress(io, host, port) catch continue;
        var id: NodeId = undefined;
        @memset(&id, 0);
        try out.append(allocator, .{ .addr = addr, .id = id });
    }
    return out.toOwnedSlice(allocator);
}

const GetPeersResponse = struct {
    values: std.ArrayList([]const u8) = .empty,
    values6: std.ArrayList([]const u8) = .empty,
    nodes: ?[]const u8 = null,
    nodes6: ?[]const u8 = null,
    token: ?[]const u8 = null,
    /// Index encoded in the 2-byte `t` field (`g` + index), when present.
    tx_index: ?usize = null,
    allocator: std.mem.Allocator,
    fn deinit(self: *const GetPeersResponse) void {
        for (self.values.items) |v| self.allocator.free(v);
        for (self.values6.items) |v| self.allocator.free(v);
        var values = self.values;
        values.deinit(self.allocator);
        var values6 = self.values6;
        values6.deinit(self.allocator);
        if (self.nodes) |n| self.allocator.free(n);
        if (self.nodes6) |n| self.allocator.free(n);
        if (self.token) |t| self.allocator.free(t);
    }
};

fn sendAnnouncePeer(
    io: std.Io,
    allocator: std.mem.Allocator,
    socket: net.Socket,
    node_id: NodeId,
    info_hash: torrent.InfoHash,
    target: BootstrapTarget,
    token: []const u8,
    port: u16,
) !void {
    const tx = "ap";
    const query = try encodeAnnouncePeerQuery(allocator, tx, node_id, info_hash, port, token);
    defer allocator.free(query);
    const dest = target.dest();
    try socket.send(io, &dest, query);
}

/// BEP 5 announce_peer with an explicit `port` (implied_port=0).
fn encodeAnnouncePeerQuery(
    allocator: std.mem.Allocator,
    tx: []const u8,
    node_id: NodeId,
    info_hash: torrent.InfoHash,
    port: u16,
    token: []const u8,
) ![]u8 {
    var num_buf: [24]u8 = undefined;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "d1:ad2:id20:");
    try out.appendSlice(allocator, &node_id);
    try out.appendSlice(allocator, "12:implied_porti0e9:info_hash20:");
    try out.appendSlice(allocator, &info_hash);
    try out.appendSlice(allocator, "4:porti");
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}", .{port}));
    try out.appendSlice(allocator, "e5:token");
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}:", .{token.len}));
    try out.appendSlice(allocator, token);
    try out.appendSlice(allocator, "e1:q13:announce_peer1:t");
    try out.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "{d}:", .{tx.len}));
    try out.appendSlice(allocator, tx);
    try out.appendSlice(allocator, "1:y1:qe");
    return out.toOwnedSlice(allocator);
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
    errdefer out.deinit();
    if (root.dictGet("t")) |t| {
        if (t == .string and t.string.len == 2 and t.string[0] == 'g') {
            out.tx_index = t.string[1];
        }
    }
    if (r.dictGet("values")) |v| {
        switch (v) {
            // BEP 5: values is a list of compact peer strings (6 or 18 bytes each).
            .list => |items| {
                for (items) |item| {
                    if (item != .string) continue;
                    try appendValue(allocator, &out, item.string);
                }
            },
            // Some implementations concatenate into a single string.
            .string => |s| try appendValue(allocator, &out, s),
            else => {},
        }
    }
    if (r.dictGet("nodes")) |n| {
        if (n == .string) out.nodes = try allocator.dupe(u8, n.string);
    }
    if (r.dictGet("nodes6")) |n| {
        if (n == .string) out.nodes6 = try allocator.dupe(u8, n.string);
    }
    if (r.dictGet("token")) |t| {
        if (t == .string) out.token = try allocator.dupe(u8, t.string);
    }
    return out;
}

/// Classifies a compact peer string by length: 18-byte entries are IPv6 (BEP 7/32),
/// other multiples of 6 are IPv4.
fn appendValue(allocator: std.mem.Allocator, out: *GetPeersResponse, s: []const u8) !void {
    if (s.len == 0) return;
    if (s.len % 18 == 0 and s.len % 6 != 0) {
        try out.values6.append(allocator, try allocator.dupe(u8, s));
    } else if (s.len == 18) {
        try out.values6.append(allocator, try allocator.dupe(u8, s));
    } else if (s.len % 6 == 0) {
        try out.values.append(allocator, try allocator.dupe(u8, s));
    }
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
        const addr = dns.resolveAddress(io, host, port) catch continue;
        const tx = "bs";
        const query = try encodePingQuery(allocator, tx, routing.node_id);
        defer allocator.free(query);
        const dest = addr.toIpAddress();
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
        try routing.addNode(.{ .id = id, .addr = addr });
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
    try std.testing.expect(table.nodes.items[0].addr.ip == .v4);
}

test "parses compact dht nodes6 (BEP 32)" {
    var table = RoutingTable.init(std.testing.allocator, [_]u8{1} ** 20);
    defer table.deinit();
    var node_bytes: [38]u8 = undefined;
    @memset(node_bytes[0..20], 3);
    @memset(node_bytes[20..36], 0);
    node_bytes[20] = 0x20;
    node_bytes[21] = 0x01;
    node_bytes[35] = 1;
    std.mem.writeInt(u16, node_bytes[36..38], 6881, .big);
    try table.addCompactNodes6(&node_bytes);
    try std.testing.expectEqual(@as(usize, 1), table.nodes.items.len);
    try std.testing.expect(table.nodes.items[0].addr.ip == .v6);
    try std.testing.expectEqual(@as(u16, 6881), table.nodes.items[0].addr.port);
}

test "encodeAnnouncePeerQuery embeds explicit port and token" {
    const allocator = std.testing.allocator;
    const node_id: NodeId = [_]u8{7} ** 20;
    const info_hash: torrent.InfoHash = [_]u8{9} ** 20;
    const q = try encodeAnnouncePeerQuery(allocator, "ap", node_id, info_hash, 6881, "tok");
    defer allocator.free(q);
    // Bencoded query must contain announce_peer, explicit port, and the token.
    try std.testing.expect(std.mem.indexOf(u8, q, "9:announce_peer") == null); // key is "13:announce_peer"
    try std.testing.expect(std.mem.indexOf(u8, q, "13:announce_peer") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "4:porti6881e") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "5:token3:tok") != null);
    try std.testing.expect(std.mem.indexOf(u8, q, "12:implied_porti0e") != null);
    // The whole message parses as a valid bencode dict.
    const parsed = try bencode.parse(allocator, q);
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed == .dict);
}

test "parseGetPeersResponse classifies values by family and captures token" {
    const allocator = std.testing.allocator;
    // r dict: values list with one 6-byte v4 and one 18-byte v6 entry, plus token.
    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, "d1:rd5:token4:aaaa6:valuesl");
    try msg.appendSlice(allocator, "6:"); // v4 peer 6 bytes
    try msg.appendSlice(allocator, &[_]u8{ 1, 2, 3, 4, 0x1a, 0xe1 });
    try msg.appendSlice(allocator, "18:"); // v6 peer 18 bytes
    try msg.appendSlice(allocator, &([_]u8{0x20} ++ [_]u8{0} ** 15 ++ [_]u8{ 0x1a, 0xe1 }));
    try msg.appendSlice(allocator, "ee1:t2:aa1:y1:re");

    var resp = try parseGetPeersResponse(allocator, msg.items);
    defer resp.deinit();
    try std.testing.expectEqual(@as(usize, 1), resp.values.items.len);
    try std.testing.expectEqual(@as(usize, 1), resp.values6.items.len);
    try std.testing.expect(resp.token != null);
    try std.testing.expectEqualStrings("aaaa", resp.token.?);
}

test "selectGetPeersTargets prefers closer xor distance" {
    const allocator = std.testing.allocator;
    const info_hash: torrent.InfoHash = [_]u8{0} ** 20;
    var table = RoutingTable.init(allocator, [_]u8{1} ** 20);
    defer table.deinit();

    const far_id: NodeId = [_]u8{0xff} ** 20;
    var near_id: NodeId = [_]u8{0} ** 20;
    near_id[19] = 1;
    try table.addNode(.{ .id = far_id, .addr = address.Address.v4(.{ 9, 9, 9, 9 }, 1) });
    try table.addNode(.{ .id = near_id, .addr = address.Address.v4(.{ 1, 1, 1, 1 }, 1) });

    const targets = try selectGetPeersTargets(std.testing.io, allocator, &table, &.{}, info_hash, &.{});
    defer allocator.free(targets);
    try std.testing.expect(targets.len >= 1);
    try std.testing.expect(targets[0].addr.eql(address.Address.v4(.{ 1, 1, 1, 1 }, 1)));
}

test "parseGetPeersResponse extracts tx index" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "d1:rd2:id20:");
    try buf.appendSlice(allocator, &([_]u8{'a'} ** 20));
    try buf.appendSlice(allocator, "e1:t2:");
    try buf.appendSlice(allocator, &[_]u8{ 'g', 3 });
    try buf.appendSlice(allocator, "1:y1:re");
    var resp = try parseGetPeersResponse(allocator, buf.items);
    defer resp.deinit();
    try std.testing.expectEqual(@as(?usize, 3), resp.tx_index);
}
