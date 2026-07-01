const std = @import("std");

pub const Policy = enum { prefer, require, disable };
pub const Mode = enum { plaintext, encrypted };

pub const CryptoFlags = struct {
    pub const rc4: u32 = 0x02;
};

pub fn parsePolicy(value: []const u8) ?Policy {
    if (std.mem.eql(u8, value, "prefer")) return .prefer;
    if (std.mem.eql(u8, value, "require")) return .require;
    if (std.mem.eql(u8, value, "disable")) return .disable;
    return null;
}

pub const Rc4 = struct {
    s: [256]u8,
    i: u8 = 0,
    j: u8 = 0,

    pub fn init(key: []const u8) Rc4 {
        var rc: Rc4 = .{ .s = undefined };
        for (0..256) |n| rc.s[n] = @intCast(n);
        var j: u8 = 0;
        for (0..256) |n| {
            j = j +% rc.s[n] +% key[n % key.len];
            const tmp = rc.s[n];
            rc.s[n] = rc.s[j];
            rc.s[j] = tmp;
        }
        return rc;
    }

    pub fn crypt(self: *Rc4, data: []u8) void {
        for (data) |*byte| {
            self.i +%= 1;
            self.j +%= self.s[self.i];
            const tmp = self.s[self.i];
            self.s[self.i] = self.s[self.j];
            self.s[self.j] = tmp;
            byte.* ^= self.s[self.s[self.i] +% self.s[self.j]];
        }
    }
};


pub const Session = struct {
    encrypt: Rc4,
    decrypt: Rc4,
    mode: Mode = .encrypted,

    pub fn derive(allocator: std.mem.Allocator, shared: []const u8, initiator: bool) !Session {
        var skey: [96]u8 = [_]u8{0} ** 96;
        const copy_len = @min(shared.len, skey.len);
        @memcpy(skey[skey.len - copy_len ..], shared[shared.len - copy_len ..]);
        const enc_label = if (initiator) "keyA" else "keyB";
        const dec_label = if (initiator) "keyB" else "keyA";
        const enc_suffix = if (initiator) "AAA1" else "AAA2";
        const dec_suffix = if (initiator) "AAA2" else "AAA1";
        const enc_key = try deriveRc4Key(allocator, enc_label, &skey, enc_suffix);
        defer allocator.free(enc_key);
        const dec_key = try deriveRc4Key(allocator, dec_label, &skey, dec_suffix);
        defer allocator.free(dec_key);
        return .{ .encrypt = Rc4.init(enc_key), .decrypt = Rc4.init(dec_key) };
    }
};

fn deriveRc4Key(allocator: std.mem.Allocator, label: []const u8, skey: *const [96]u8, suffix: []const u8) ![]u8 {
    var h1: [20]u8 = undefined;
    var buf: [100]u8 = undefined;
    @memcpy(buf[0..label.len], label);
    @memcpy(buf[label.len..][0..96], skey);
    std.crypto.hash.Sha1.hash(buf[0 .. label.len + 96], &h1, .{});
    var h2: [20]u8 = undefined;
    @memcpy(buf[0..20], &h1);
    @memcpy(buf[20..][0..suffix.len], suffix);
    std.crypto.hash.Sha1.hash(buf[0 .. 20 + suffix.len], &h2, .{});
    return allocator.dupe(u8, &h2);
}


pub fn generateKeyPair(allocator: std.mem.Allocator) !struct { public: [96]u8, private: []u8 } {
    var private_bytes: [96]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
    prng.random().bytes(&private_bytes);
    const private = try allocator.dupe(u8, &private_bytes);
    var public: [96]u8 = [_]u8{0} ** 96;
    std.crypto.hash.Sha1.hash(&private_bytes, public[76..96], .{});
    return .{ .public = public, .private = private };
}

pub fn sharedSecret(allocator: std.mem.Allocator, private_key: []const u8, remote_public: []const u8) ![]u8 {
    var remote: [96]u8 = [_]u8{0} ** 96;
    const copy_len = @min(remote_public.len, 96);
    @memcpy(remote[96 - copy_len ..], remote_public[remote_public.len - copy_len ..]);
    var buf: [192]u8 = undefined;
    const priv_len = @min(private_key.len, 96);
    @memcpy(buf[0..priv_len], private_key[0..priv_len]);
    @memcpy(buf[priv_len .. priv_len + 96], &remote);
    var out: [96]u8 = [_]u8{0} ** 96;
    std.crypto.hash.Sha1.hash(buf[0 .. priv_len + 96], out[76..96], .{});
    return allocator.dupe(u8, &out);
}

pub fn buildInitiatorPayload(allocator: std.mem.Allocator, public_key: [96]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, 608 - 96 - 2);
    try out.append(allocator, 0x14);
    try out.append(allocator, 0x01);
    try out.appendSlice(allocator, &public_key);
    return out.toOwnedSlice(allocator);
}

pub fn buildResponderPayload(allocator: std.mem.Allocator, public_key: [96]u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendNTimes(allocator, 0, 608 - 96 - 2);
    try out.append(allocator, 0x14);
    try out.append(allocator, 0x01);
    try out.appendSlice(allocator, &public_key);
    var provide: [4]u8 = undefined;
    std.mem.writeInt(u32, &provide, CryptoFlags.rc4, .big);
    try out.appendSlice(allocator, &provide);
    try out.appendSlice(allocator, &[_]u8{ 0, 0 });
    return out.toOwnedSlice(allocator);
}

pub fn buildSelectPayload(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var select: [4]u8 = undefined;
    std.mem.writeInt(u32, &select, CryptoFlags.rc4, .big);
    try out.appendSlice(allocator, &select);
    try out.appendSlice(allocator, &[_]u8{ 0, 0 });
    return out.toOwnedSlice(allocator);
}

pub fn extractRemotePublic(response: []const u8) ?[]const u8 {
    if (response.len < 96) return null;
    return response[response.len - 96 ..];
}

pub fn supportsRc4(response: []const u8) bool {
    if (response.len < 96 + 4) return false;
    const off = response.len - 96 - 4;
    const flags = std.mem.readInt(u32, response[off .. off + 4][0..4], .big);
    return flags & CryptoFlags.rc4 != 0;
}

test "rc4 round trip" {
    var rc = Rc4.init("key");
    var data: [5]u8 = .{ 1, 2, 3, 4, 5 };
    rc.crypt(&data);
    var rc2 = Rc4.init("key");
    rc2.crypt(&data);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
}

test "parses encryption policy" {
    try std.testing.expectEqual(Policy.prefer, parsePolicy("prefer").?);
    try std.testing.expectEqual(Policy.require, parsePolicy("require").?);
    try std.testing.expect(parsePolicy("wat") == null);
}
