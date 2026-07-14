//! Tracker Tier failover (BEP 12).
//!
//! Announce scheduling is organized into ordered tiers. Within a tier we
//! announce strictly sequentially, preferring the last working tracker; on
//! failure we advance to the next URL, and only advance to the next tier when
//! the current tier has no usable tracker. `.torrent` `announce-list` maps to
//! real tiers; a lone `announce` is a single-URL tier; a magnet's `tr=` URLs
//! form one synthetic tier in URI order.

const std = @import("std");
const tracker = @import("tracker.zig");

/// A single tracker URL within a tier, with its live cursor position kept by
/// the owning `TierSet` rather than here.
pub const TierUrl = struct {
    url: []const u8,
    supported: bool,
};

pub const Tier = struct {
    urls: []TierUrl,
};

/// Ordered set of tiers plus the cursor identifying the current tracker.
pub const TierSet = struct {
    allocator: std.mem.Allocator,
    tiers: []Tier,
    tier_index: usize = 0,
    url_index: usize = 0,

    pub fn deinit(self: *TierSet) void {
        for (self.tiers) |tier| self.allocator.free(tier.urls);
        self.allocator.free(self.tiers);
    }

    /// The URL the scheduler should announce to now, or null if no supported
    /// tracker remains in any tier.
    pub fn current(self: *TierSet) ?[]const u8 {
        self.skipUnsupported();
        if (self.tier_index >= self.tiers.len) return null;
        return self.tiers[self.tier_index].urls[self.url_index].url;
    }

    /// BEP 12: on success, keep the working tracker at the front of its tier so
    /// subsequent announces prefer it.
    pub fn recordSuccess(self: *TierSet) void {
        if (self.tier_index >= self.tiers.len) return;
        const tier = self.tiers[self.tier_index];
        if (self.url_index == 0) return;
        const winner = tier.urls[self.url_index];
        var i = self.url_index;
        while (i > 0) : (i -= 1) tier.urls[i] = tier.urls[i - 1];
        tier.urls[0] = winner;
        self.url_index = 0;
    }

    /// Advance to the next tracker on failure: next URL in the tier, else the
    /// first URL of the next tier.
    pub fn recordFailure(self: *TierSet) void {
        if (self.tier_index >= self.tiers.len) return;
        self.url_index += 1;
        if (self.url_index >= self.tiers[self.tier_index].urls.len) {
            self.tier_index += 1;
            self.url_index = 0;
        }
    }

    fn skipUnsupported(self: *TierSet) void {
        while (self.tier_index < self.tiers.len) {
            const tier = self.tiers[self.tier_index];
            while (self.url_index < tier.urls.len and !tier.urls[self.url_index].supported) {
                self.url_index += 1;
            }
            if (self.url_index < tier.urls.len) return;
            self.tier_index += 1;
            self.url_index = 0;
        }
    }

    /// True when no supported tracker remains in any tier.
    pub fn exhausted(self: *TierSet) bool {
        return self.current() == null;
    }
};

/// Build tiers from `.torrent` metadata. `announce_list` is the tier-of-tiers
/// structure; when empty, `announce` (if present) becomes a single-URL tier.
pub fn buildFromAnnounceList(
    allocator: std.mem.Allocator,
    announce: ?[]const u8,
    announce_list: []const []const []const u8,
) !TierSet {
    var tiers: std.ArrayList(Tier) = .empty;
    errdefer {
        for (tiers.items) |t| allocator.free(t.urls);
        tiers.deinit(allocator);
    }

    if (announce_list.len > 0) {
        for (announce_list) |tier_urls| {
            if (tier_urls.len == 0) continue;
            var urls = try allocator.alloc(TierUrl, tier_urls.len);
            for (tier_urls, 0..) |u, i| urls[i] = .{ .url = u, .supported = tracker.isSupportedTrackerScheme(u) };
            try tiers.append(allocator, .{ .urls = urls });
        }
    } else if (announce) |a| {
        var urls = try allocator.alloc(TierUrl, 1);
        urls[0] = .{ .url = a, .supported = tracker.isSupportedTrackerScheme(a) };
        try tiers.append(allocator, .{ .urls = urls });
    }

    return .{ .allocator = allocator, .tiers = try tiers.toOwnedSlice(allocator) };
}

/// Build one synthetic tier from magnet `tr=` URLs, in URI order.
pub fn buildFromMagnet(allocator: std.mem.Allocator, tr_urls: []const []const u8) !TierSet {
    var tiers: std.ArrayList(Tier) = .empty;
    errdefer {
        for (tiers.items) |t| allocator.free(t.urls);
        tiers.deinit(allocator);
    }
    if (tr_urls.len > 0) {
        var urls = try allocator.alloc(TierUrl, tr_urls.len);
        for (tr_urls, 0..) |u, i| urls[i] = .{ .url = u, .supported = tracker.isSupportedTrackerScheme(u) };
        try tiers.append(allocator, .{ .urls = urls });
    }
    return .{ .allocator = allocator, .tiers = try tiers.toOwnedSlice(allocator) };
}

test "lone announce becomes a single-url tier" {
    var set = try buildFromAnnounceList(std.testing.allocator, "http://a/announce", &.{});
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.tiers.len);
    try std.testing.expectEqualStrings("http://a/announce", set.current().?);
}

test "stays on tier 0 while a tracker there works" {
    const t0 = [_][]const u8{ "http://a/announce", "udp://b:6969/announce" };
    const t1 = [_][]const u8{"http://c/announce"};
    const list = [_][]const []const u8{ &t0, &t1 };
    var set = try buildFromAnnounceList(std.testing.allocator, null, &list);
    defer set.deinit();

    // First tracker in tier 0 works; we never advance to tier 1.
    try std.testing.expectEqualStrings("http://a/announce", set.current().?);
    set.recordSuccess();
    try std.testing.expectEqualStrings("http://a/announce", set.current().?);
    try std.testing.expectEqual(@as(usize, 0), set.tier_index);
}

test "failover advances within tier then to next tier" {
    const t0 = [_][]const u8{ "http://a/announce", "udp://b:6969/announce" };
    const t1 = [_][]const u8{"http://c/announce"};
    const list = [_][]const []const u8{ &t0, &t1 };
    var set = try buildFromAnnounceList(std.testing.allocator, null, &list);
    defer set.deinit();

    try std.testing.expectEqualStrings("http://a/announce", set.current().?);
    set.recordFailure();
    try std.testing.expectEqualStrings("udp://b:6969/announce", set.current().?);
    set.recordFailure();
    // Tier 0 exhausted -> tier 1.
    try std.testing.expectEqualStrings("http://c/announce", set.current().?);
    try std.testing.expectEqual(@as(usize, 1), set.tier_index);
    set.recordFailure();
    try std.testing.expect(set.exhausted());
}

test "successful failover tracker moves to front of its tier" {
    const t0 = [_][]const u8{ "http://a/announce", "udp://b:6969/announce" };
    const list = [_][]const []const u8{&t0};
    var set = try buildFromAnnounceList(std.testing.allocator, null, &list);
    defer set.deinit();

    set.recordFailure(); // a failed, now on b
    try std.testing.expectEqualStrings("udp://b:6969/announce", set.current().?);
    set.recordSuccess(); // b becomes preferred
    try std.testing.expectEqualStrings("udp://b:6969/announce", set.current().?);
    try std.testing.expectEqual(@as(usize, 0), set.url_index);
}

test "unsupported schemes are skipped within and across tiers" {
    const t0 = [_][]const u8{ "wss://a/announce", "http://b/announce" };
    const t1 = [_][]const u8{"ftp://c/announce"};
    const list = [_][]const []const u8{ &t0, &t1 };
    var set = try buildFromAnnounceList(std.testing.allocator, null, &list);
    defer set.deinit();
    // wss skipped -> http://b.
    try std.testing.expectEqualStrings("http://b/announce", set.current().?);
    set.recordFailure();
    // tier 1 only has ftp (unsupported) -> exhausted.
    try std.testing.expect(set.exhausted());
}

test "magnet tr urls form one ordered tier" {
    const tr = [_][]const u8{ "udp://a:6969/announce", "http://b/announce" };
    var set = try buildFromMagnet(std.testing.allocator, &tr);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.tiers.len);
    try std.testing.expectEqual(@as(usize, 2), set.tiers[0].urls.len);
    try std.testing.expectEqualStrings("udp://a:6969/announce", set.current().?);
}
