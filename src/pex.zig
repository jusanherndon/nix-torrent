//! Peer Exchange (`ut_pex`, BEP 11) message codecs.
//!
//! PEX is an LTEP extension. We advertise `ut_pex` on content and metadata
//! connections, consume `added`/`added6` on both, and emit `added`/`dropped`
//! only on content connections. Consumed peers are merged into the candidate
//! set as dual-stack `tracker.Peer` values.

const std = @import("std");
const address = @import("address.zig");
const bencode = @import("bencode.zig");
const tracker = @import("tracker.zig");

/// Local extension id advertised for `ut_pex` in the LTEP handshake `m` dict.
pub const local_ut_pex_id: u8 = 2;

/// Parse the `added`/`added6` compact peer lists from a `ut_pex` payload.
/// `bencode_bytes` is the extension payload *after* the leading extension-id
/// byte (i.e. the bencoded dict itself).
pub fn parsePexPeers(allocator: std.mem.Allocator, bencode_bytes: []const u8) ![]tracker.Peer {
    const root = bencode.parse(allocator, bencode_bytes) catch return allocator.alloc(tracker.Peer, 0);
    defer root.deinit(allocator);
    if (root != .dict) return allocator.alloc(tracker.Peer, 0);

    var out: std.ArrayList(tracker.Peer) = .empty;
    errdefer out.deinit(allocator);

    if (root.dictGet("added")) |added| {
        if (added == .string) {
            var i: usize = 0;
            while (i + 6 <= added.string.len) : (i += 6) {
                const ip: [4]u8 = added.string[i .. i + 4][0..4].*;
                const port = std.mem.readInt(u16, added.string[i + 4 .. i + 6][0..2], .big);
                try out.append(allocator, tracker.Peer.v4(ip, port));
            }
        }
    }
    if (root.dictGet("added6")) |added6| {
        if (added6 == .string) {
            var i: usize = 0;
            while (i + 18 <= added6.string.len) : (i += 18) {
                const ip: [16]u8 = added6.string[i .. i + 16][0..16].*;
                const port = std.mem.readInt(u16, added6.string[i + 16 .. i + 18][0..2], .big);
                try out.append(allocator, tracker.Peer.v6(ip, port));
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a `ut_pex` bencoded dict body (without the extension-id byte or the
/// LTEP message framing). Splits peers into `added`/`added6` compact lists.
pub fn encodePexBody(
    allocator: std.mem.Allocator,
    added: []const address.Address,
    dropped: []const address.Address,
) ![]u8 {
    var added_v4: std.ArrayList(u8) = .empty;
    defer added_v4.deinit(allocator);
    var added_v6: std.ArrayList(u8) = .empty;
    defer added_v6.deinit(allocator);
    var added_flags: std.ArrayList(u8) = .empty;
    defer added_flags.deinit(allocator);
    var dropped_v4: std.ArrayList(u8) = .empty;
    defer dropped_v4.deinit(allocator);
    var dropped_v6: std.ArrayList(u8) = .empty;
    defer dropped_v6.deinit(allocator);

    for (added) |a| try appendCompact(allocator, &added_v4, &added_v6, a, &added_flags);
    for (dropped) |d| try appendCompact(allocator, &dropped_v4, &dropped_v6, d, null);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, 'd');
    try appendStringEntry(allocator, &out, "added", added_v4.items);
    try appendStringEntry(allocator, &out, "added.f", added_flags.items);
    try appendStringEntry(allocator, &out, "added6", added_v6.items);
    try appendStringEntry(allocator, &out, "dropped", dropped_v4.items);
    try appendStringEntry(allocator, &out, "dropped6", dropped_v6.items);
    try out.append(allocator, 'e');
    return out.toOwnedSlice(allocator);
}

fn appendCompact(
    allocator: std.mem.Allocator,
    v4: *std.ArrayList(u8),
    v6: *std.ArrayList(u8),
    a: address.Address,
    flags: ?*std.ArrayList(u8),
) !void {
    switch (a.ip) {
        .v4 => |bytes| {
            try v4.appendSlice(allocator, &bytes);
            var port: [2]u8 = undefined;
            std.mem.writeInt(u16, &port, a.port, .big);
            try v4.appendSlice(allocator, &port);
            if (flags) |f| try f.append(allocator, 0);
        },
        .v6 => |bytes| {
            try v6.appendSlice(allocator, &bytes);
            var port: [2]u8 = undefined;
            std.mem.writeInt(u16, &port, a.port, .big);
            try v6.appendSlice(allocator, &port);
        },
    }
}

fn appendStringEntry(allocator: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    var num: [20]u8 = undefined;
    const key_len = try std.fmt.bufPrint(&num, "{d}:", .{key.len});
    try out.appendSlice(allocator, key_len);
    try out.appendSlice(allocator, key);
    const val_len = try std.fmt.bufPrint(&num, "{d}:", .{value.len});
    try out.appendSlice(allocator, val_len);
    try out.appendSlice(allocator, value);
}

test "parses added and added6 peers from pex payload" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try buf.appendSlice(std.testing.allocator, "d5:added6:");
    try buf.appendSlice(std.testing.allocator, &[_]u8{ 127, 0, 0, 1, 0x1a, 0xe1 });
    try buf.appendSlice(std.testing.allocator, "6:added618:");
    try buf.appendSlice(std.testing.allocator, &([_]u8{0} ** 15 ++ [_]u8{1} ++ [_]u8{ 0x1a, 0xe1 }));
    try buf.append(std.testing.allocator, 'e');

    const peers = try parsePexPeers(std.testing.allocator, buf.items);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 2), peers.len);
    try std.testing.expect(peers[0].ip == .v4);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].port);
    try std.testing.expect(peers[1].ip == .v6);
    try std.testing.expectEqual(@as(u16, 6881), peers[1].port);
}

test "encode pex body round-trips through parser" {
    const added = [_]address.Address{
        address.Address.v4(.{ 10, 0, 0, 1 }, 6881),
        address.Address.v6([_]u8{0} ** 15 ++ [_]u8{2}, 51413),
    };
    const body = try encodePexBody(std.testing.allocator, &added, &.{});
    defer std.testing.allocator.free(body);
    const peers = try parsePexPeers(std.testing.allocator, body);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 2), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].port);
    try std.testing.expectEqual(@as(u16, 51413), peers[1].port);
}

test "malformed pex payload yields empty list" {
    const peers = try parsePexPeers(std.testing.allocator, "not bencode");
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);
}
