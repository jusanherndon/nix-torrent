//! Live Local Service Discovery (BEP 14) over IPv4 multicast.
//!
//! Opens a UDP socket joined to the LSD multicast group, periodically announces
//! every non-private active torrent, and merges peers learned from inbound
//! `BT-SEARCH` announces into the owning session's candidate set. All socket
//! operations are best-effort: any failure disables the service without
//! crashing the daemon (e.g. sandboxes that forbid multicast).

const std = @import("std");
const c = std.c;
const linux = std.os.linux;

const address = @import("address.zig");
const config = @import("config.zig");
const engine_mod = @import("engine.zig");
const lsd = @import("lsd.zig");
const log = @import("log.zig");
const peer_pool = @import("peer_pool.zig");
const state = @import("state.zig");
const tracker = @import("tracker.zig");

const SOL_SOCKET: i32 = 1;
const SO_REUSEADDR: u32 = 2;
const SO_REUSEPORT: u32 = 15;
const IPPROTO_IP: i32 = 0;
const IP_ADD_MEMBERSHIP: u32 = 35;
const IP_MULTICAST_TTL: u32 = 33;
const IP_MULTICAST_LOOP: u32 = 34;

const ip_mreq = extern struct {
    imr_multiaddr: u32,
    imr_interface: u32,
};

pub const LsdService = struct {
    enabled: bool,
    fd: ?c.fd_t = null,
    last_announce_ms: i64 = 0,
    /// BEP 14 recommends announcing no more than every few minutes.
    announce_interval_ms: i64 = 300_000,

    pub fn init(enabled: bool) LsdService {
        return .{ .enabled = enabled };
    }

    /// Best-effort open + multicast join. Leaves `fd` null on any failure.
    pub fn start(self: *LsdService) void {
        if (!self.enabled) return;
        const fd = c.socket(c.AF.INET, c.SOCK.DGRAM, 0);
        if (fd == -1) return;
        var ok = true;

        const one: c_int = 1;
        _ = c.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(c_int));
        _ = c.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, @ptrCast(&one), @sizeOf(c_int));

        var bind_addr: c.sockaddr.in = .{
            .family = c.AF.INET,
            .port = std.mem.nativeToBig(u16, lsd.port),
            .addr = 0, // INADDR_ANY
            .zero = .{0} ** 8,
        };
        if (c.bind(fd, @ptrCast(&bind_addr), @sizeOf(c.sockaddr.in)) != 0) ok = false;

        if (ok) {
            var mreq: ip_mreq = .{
                .imr_multiaddr = @bitCast(lsd.group_v4),
                .imr_interface = 0,
            };
            _ = c.setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, @ptrCast(&mreq), @sizeOf(ip_mreq));
            const ttl: c_int = 4;
            _ = c.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, @ptrCast(&ttl), @sizeOf(c_int));
            const loop: c_int = 0;
            _ = c.setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, @ptrCast(&loop), @sizeOf(c_int));

            const flags = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
            if (flags != -1) _ = c.fcntl(fd, c.F.SETFL, flags | @as(c_int, 0x800));
        }

        if (!ok) {
            _ = c.close(fd);
            return;
        }
        self.fd = fd;
        log.info("lsd", "local service discovery listening on {d}.{d}.{d}.{d}:{d}", .{ lsd.group_v4[0], lsd.group_v4[1], lsd.group_v4[2], lsd.group_v4[3], lsd.port });
    }

    pub fn deinit(self: *LsdService) void {
        if (self.fd) |fd| _ = c.close(fd);
        self.fd = null;
    }

    /// Drain any pending multicast announces and merge learned peers into the
    /// matching non-private session's candidate set.
    pub fn poll(self: *LsdService, allocator: std.mem.Allocator, engine: *engine_mod.Engine, registry: *state.Registry) void {
        const fd = self.fd orelse return;
        var buf: [1500]u8 = undefined;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var src: c.sockaddr.in = undefined;
            var src_len: c.socklen_t = @sizeOf(c.sockaddr.in);
            const n = c.recvfrom(fd, &buf, buf.len, 0, @ptrCast(&src), &src_len);
            if (n <= 0) break;
            const msg = buf[0..@intCast(n)];
            const parsed = lsd.parseAnnounce(msg) orelse continue;
            const rec = registry.find(&parsed.info_hash_hex) orelse continue;
            if (rec.private_torrent or rec.status != .active) continue;
            const session = engine.findSession(&parsed.info_hash_hex) orelse continue;
            const ip_bytes: [4]u8 = @bitCast(src.addr);
            const learned = [_]tracker.Peer{tracker.Peer.v4(ip_bytes, parsed.port)};
            peer_pool.mergeCandidates(allocator, session, &learned);
        }
    }

    /// Periodically multicast a `BT-SEARCH` for each non-private active torrent.
    pub fn announce(self: *LsdService, allocator: std.mem.Allocator, registry: *state.Registry, listen_port: u16, now_ms: i64) void {
        const fd = self.fd orelse return;
        if (now_ms - self.last_announce_ms < self.announce_interval_ms) return;
        self.last_announce_ms = now_ms;

        var dest: c.sockaddr.in = .{
            .family = c.AF.INET,
            .port = std.mem.nativeToBig(u16, lsd.port),
            .addr = @bitCast(lsd.group_v4),
            .zero = .{0} ** 8,
        };
        for (registry.records.items) |rec| {
            if (rec.private_torrent or rec.status != .active) continue;
            const datagram = lsd.buildAnnounce(allocator, rec.info_hash_hex, listen_port) catch continue;
            defer allocator.free(datagram);
            _ = c.sendto(fd, datagram.ptr, datagram.len, 0, @ptrCast(&dest), @sizeOf(c.sockaddr.in));
        }
    }
};

test "lsd service is inert when disabled" {
    var svc = LsdService.init(false);
    svc.start();
    defer svc.deinit();
    try std.testing.expect(svc.fd == null);
}
