const std = @import("std");
const torrent = @import("torrent.zig");

pub const Policy = enum { prefer, require, disable };
pub const Mode = enum { plaintext, obfuscated, encrypted };
pub const Scheme = enum(u32) { plaintext_within_mse = 0x01, rc4 = 0x02 };

pub const CryptoFlags = struct {
    pub const plaintext_within_mse: u32 = 0x01;
    pub const rc4: u32 = 0x02;
};

pub const Error = error{
    MalformedEncryption,
    UnsupportedEncryption,
    OutOfMemory,
};

const Limb = std.math.big.Limb;
const limb_bits = @typeInfo(Limb).int.bits;
const Managed = std.math.big.int.Managed;
pub const max_dh_packet_len = 608;
pub const handshake_len = 68;

const dh_key_len = 96;
pub const vc_len = 8;
pub const max_pad = 512;
const max_dh_packet = max_dh_packet_len;
/// Buffer large enough for leftover PadB + full PE4 frame (VC/header/PadD).
pub const pe4_sync_buf_len = max_pad + vc_len + 6 + max_pad;
const rc4_discard = 1024;

fn bitIsSet(n: *const Managed, bit: usize) bool {
    const c = n.toConst();
    const limb_idx = bit / limb_bits;
    if (limb_idx >= c.limbs.len) return false;
    const limb = c.limbs[limb_idx];
    return (limb >> @intCast(bit % limb_bits)) & 1 == 1;
}

const dh_prime: [dh_key_len]u8 = .{
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xc9, 0x0f, 0xda, 0xa2, 0x21, 0x68, 0xc2, 0x34,
    0xc4, 0xc6, 0x62, 0x8b, 0x80, 0xdc, 0x1c, 0xd1, 0x29, 0x02, 0x4e, 0x08, 0x8a, 0x67, 0xcc, 0x74,
    0x02, 0x0b, 0xbe, 0xa6, 0x3b, 0x13, 0x9b, 0x22, 0x51, 0x4a, 0x08, 0x79, 0x8e, 0x34, 0x04, 0xdd,
    0xef, 0x95, 0x19, 0xb3, 0xcd, 0x3a, 0x43, 0x1b, 0x30, 0x2b, 0x0a, 0x6d, 0xf2, 0x5f, 0x14, 0x37,
    0x4f, 0xe1, 0x35, 0x6d, 0x6d, 0x51, 0xc2, 0x45, 0xe4, 0x85, 0xb5, 0x76, 0x62, 0x5e, 0x7e, 0xc6,
    0xf4, 0x4c, 0x42, 0xe9, 0xa6, 0x3a, 0x36, 0x21, 0x00, 0x00, 0x00, 0x00, 0x00, 0x90, 0x56, 0x3,
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

    pub fn initDiscarded(key: *const [20]u8) Rc4 {
        var rc = init(key);
        var discard: [rc4_discard]u8 = undefined;
        rc.crypt(&discard);
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

    pub fn derive(shared: *const [dh_key_len]u8, info_hash: torrent.InfoHash, initiator: bool) Session {
        const enc_label = if (initiator) "keyA" else "keyB";
        const dec_label = if (initiator) "keyB" else "keyA";
        const enc_key = deriveRc4Key(enc_label, shared, &info_hash);
        const dec_key = deriveRc4Key(dec_label, shared, &info_hash);
        return .{
            .encrypt = Rc4.initDiscarded(&enc_key),
            .decrypt = Rc4.initDiscarded(&dec_key),
        };
    }
};

fn deriveRc4Key(label: []const u8, shared: *const [dh_key_len]u8, info_hash: *const torrent.InfoHash) [20]u8 {
    var out: [20]u8 = undefined;
    var buf: [4 + dh_key_len + 20]u8 = undefined;
    @memcpy(buf[0..4], label);
    for (0..dh_key_len) |i| buf[4 + i] = shared[i];
    @memcpy(buf[4 + dh_key_len ..], info_hash);
    std.crypto.hash.Sha1.hash(&buf, &out, .{});
    return out;
}

pub const DhKeyExchange = struct {
    local_public: [dh_key_len]u8 = undefined,
    local_secret: Managed,
    shared_secret: [dh_key_len]u8 = undefined,
    xor_mask: [20]u8 = undefined,
    has_shared: bool = false,

    pub fn deinit(self: *DhKeyExchange) void {
        self.local_secret.deinit();
    }

    pub fn generate(allocator: std.mem.Allocator) Error!DhKeyExchange {
        var random_key: [dh_key_len]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
        prng.random().bytes(&random_key);
        var local_secret = try Managed.init(allocator);
        errdefer local_secret.deinit();
        try setFromBytesBe(&local_secret, &random_key);
        var local_public = try Managed.init(allocator);
        defer local_public.deinit();
        try modPowTwo(&local_public, &local_secret, &dh_prime);
        var out: DhKeyExchange = .{ .local_secret = local_secret };
        exportBytesBe(&local_public, &out.local_public);
        return out;
    }

    pub fn computeShared(self: *DhKeyExchange, allocator: std.mem.Allocator, remote_public: *const [dh_key_len]u8) Error!void {
        var remote = try Managed.init(allocator);
        defer remote.deinit();
        try setFromBytesBe(&remote, remote_public);
        var shared_int = try Managed.init(allocator);
        defer shared_int.deinit();
        var modulus = try Managed.init(allocator);
        defer modulus.deinit();
        try setFromBytesBe(&modulus, &dh_prime);
        try modPow(&shared_int, &remote, &self.local_secret, &modulus);
        exportBytesBe(&shared_int, &self.shared_secret);
        self.has_shared = true;
        const req3 = "req3";
        var buf: [4 + dh_key_len]u8 = undefined;
        @memcpy(buf[0..4], req3);
        for (0..dh_key_len) |i| buf[4 + i] = self.shared_secret[i];
        var req3_hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(&buf, &req3_hash, .{});
        self.xor_mask = req3_hash;
    }

    pub fn shared(self: DhKeyExchange) *const [dh_key_len]u8 {
        return &self.shared_secret;
    }
};

fn setFromBytesBe(n: *Managed, bytes: []const u8) Error!void {
    try n.ensureCapacity((bytes.len + @sizeOf(std.math.big.Limb) - 1) / @sizeOf(std.math.big.Limb));
    var m = n.toMutable();
    m.readTwosComplement(bytes, bytes.len * 8, .big, .unsigned);
    n.setMetadata(true, m.len);
}

fn exportBytesBe(n: *const Managed, out: *[dh_key_len]u8) void {
    @memset(out, 0);
    var tmp: [dh_key_len]u8 = undefined;
    n.toConst().writeTwosComplement(&tmp, .big);
    var start: usize = 0;
    while (start < dh_key_len and tmp[start] == 0) start += 1;
    const len = dh_key_len - start;
    @memcpy(out[dh_key_len - len ..], tmp[start..]);
}

fn modPowTwo(result: *Managed, exponent: *const Managed, modulus_bytes: *const [dh_key_len]u8) Error!void {
    var base = try Managed.init(result.allocator);
    defer base.deinit();
    try base.set(@as(u8, 2));
    var modulus = try Managed.init(result.allocator);
    defer modulus.deinit();
    try setFromBytesBe(&modulus, modulus_bytes);
    try modPow(result, &base, exponent, &modulus);
}

fn modPow(result: *Managed, base: *const Managed, exponent: *const Managed, modulus: *const Managed) Error!void {
    try result.set(@as(u8, 1));
    const exp_bits = exponent.bitCountAbs();
    if (exp_bits == 0) return;
    var i: usize = exp_bits;
    while (i > 0) {
        i -= 1;
        try squareMod(result, result, modulus);
        if (bitIsSet(exponent, i)) {
            try mulMod(result, result, base, modulus);
        }
    }
}

fn squareMod(result: *Managed, value: *const Managed, modulus: *const Managed) Error!void {
    var tmp = try Managed.init(result.allocator);
    defer tmp.deinit();
    try tmp.mul(value, value);
    try remMod(result, &tmp, modulus);
}

fn mulMod(result: *Managed, a: *const Managed, b: *const Managed, modulus: *const Managed) Error!void {
    var tmp = try Managed.init(result.allocator);
    defer tmp.deinit();
    try tmp.mul(a, b);
    try remMod(result, &tmp, modulus);
}

fn remMod(result: *Managed, value: *const Managed, modulus: *const Managed) Error!void {
    var q = try Managed.init(result.allocator);
    defer q.deinit();
    try Managed.divTrunc(&q, result, value, modulus);
}

fn hashReq1(shared_bytes: *const [dh_key_len]u8) [20]u8 {
    const req1 = "req1";
    var buf: [4 + dh_key_len]u8 = undefined;
    @memcpy(buf[0..4], req1);
    for (0..dh_key_len) |i| buf[4 + i] = shared_bytes[i];
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&buf, &out, .{});
    return out;
}

fn hashReq2(info_hash: *const torrent.InfoHash) [20]u8 {
    const req2 = "req2";
    var buf: [4 + 20]u8 = undefined;
    @memcpy(buf[0..4], req2);
    @memcpy(buf[4..], info_hash);
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&buf, &out, .{});
    return out;
}

fn hashReq3(shared_bytes: *const [dh_key_len]u8) [20]u8 {
    const req3 = "req3";
    var buf: [4 + dh_key_len]u8 = undefined;
    @memcpy(buf[0..4], req3);
    for (0..dh_key_len) |i| buf[4 + i] = shared_bytes[i];
    var out: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(&buf, &out, .{});
    return out;
}

fn obfuscatedSkeyHash(shared: *const [dh_key_len]u8, info_hash: *const torrent.InfoHash) [20]u8 {
    const req2_hash = hashReq2(info_hash);
    const req3_hash = hashReq3(shared);
    var out: [20]u8 = undefined;
    for (0..20) |i| out[i] = req2_hash[i] ^ req3_hash[i];
    return out;
}

pub fn cryptoProvideForPolicy(policy: Policy) u32 {
    return switch (policy) {
        .prefer => CryptoFlags.plaintext_within_mse | CryptoFlags.rc4,
        .require => CryptoFlags.rc4,
        .disable => 0,
    };
}

pub fn selectScheme(crypto_provide: u32, policy: Policy) ?Scheme {
    const supported = crypto_provide & (CryptoFlags.plaintext_within_mse | CryptoFlags.rc4);
    if (supported == 0) return null;
    if (policy == .require) {
        if (supported & CryptoFlags.rc4 != 0) return .rc4;
        return null;
    }
    if (supported & CryptoFlags.rc4 != 0) return .rc4;
    if (supported & CryptoFlags.plaintext_within_mse != 0) return .plaintext_within_mse;
    return null;
}

pub fn validateCryptoSelect(crypto_select: u32, crypto_provide: u32) Error!Scheme {
    // Ignore undefined high bits — some peers set reserved flags. Require exactly one known scheme.
    const known = crypto_select & (CryptoFlags.plaintext_within_mse | CryptoFlags.rc4);
    if (known == 0) return error.MalformedEncryption;
    if (@popCount(known) != 1) return error.MalformedEncryption;
    if (known & crypto_provide == 0) return error.MalformedEncryption;
    return @enumFromInt(known);
}

pub fn modeForScheme(scheme: Scheme) Mode {
    return switch (scheme) {
        .rc4 => .encrypted,
        .plaintext_within_mse => .obfuscated,
    };
}

pub fn buildDhOutgoing(allocator: std.mem.Allocator, public_key: *const [dh_key_len]u8) Error![]u8 {
    var prng = std.Random.DefaultPrng.init(@intCast(std.os.linux.getpid()));
    const pad_len: usize = prng.random().intRangeAtMost(usize, 0, max_pad);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, public_key);
    try out.appendNTimes(allocator, 0, pad_len);
    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

pub fn buildInitiatorSync(
    allocator: std.mem.Allocator,
    shared: *const [dh_key_len]u8,
    info_hash: torrent.InfoHash,
    crypto_provide: u32,
    session: *Session,
) Error![]u8 {
    const shared_bytes = shared.*;
    const pad_len: u16 = 0;
    const ia_len: u16 = handshake_len;
    const plain_len = vc_len + 4 + 2 + pad_len + 2;
    var plain = try allocator.alloc(u8, plain_len);
    defer allocator.free(plain);
    @memset(plain[0..vc_len], 0);
    std.mem.writeInt(u32, plain[vc_len .. vc_len + 4], crypto_provide, .big);
    std.mem.writeInt(u16, plain[vc_len + 4 .. vc_len + 6], pad_len, .big);
    std.mem.writeInt(u16, plain[vc_len + 6 .. vc_len + 8], ia_len, .big);
    session.encrypt.crypt(plain);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const sync = hashReq1(&shared_bytes);
    try out.appendSlice(allocator, sync[0..]);
    const skey = obfuscatedSkeyHash(&shared_bytes, &info_hash);
    try out.appendSlice(allocator, skey[0..]);
    try out.appendSlice(allocator, plain);
    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

pub fn buildInitiatorSyncWithPad(
    allocator: std.mem.Allocator,
    shared: *const [dh_key_len]u8,
    info_hash: torrent.InfoHash,
    crypto_provide: u32,
    pad_len: u16,
    session: *Session,
) Error![]u8 {
    if (pad_len > max_pad) return error.MalformedEncryption;
    const shared_bytes = shared.*;
    const ia_len: u16 = handshake_len;
    const plain_len = vc_len + 4 + 2 + pad_len + 2;
    var plain = try allocator.alloc(u8, plain_len);
    defer allocator.free(plain);
    @memset(plain[0..vc_len], 0);
    std.mem.writeInt(u32, plain[vc_len .. vc_len + 4], crypto_provide, .big);
    std.mem.writeInt(u16, plain[vc_len + 4 .. vc_len + 6], pad_len, .big);
    if (pad_len > 0) @memset(plain[vc_len + 6 .. vc_len + 6 + pad_len], 0);
    std.mem.writeInt(u16, plain[vc_len + 6 + pad_len .. vc_len + 8 + pad_len], ia_len, .big);
    session.encrypt.crypt(plain);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const sync = hashReq1(&shared_bytes);
    try out.appendSlice(allocator, sync[0..]);
    const skey = obfuscatedSkeyHash(&shared_bytes, &info_hash);
    try out.appendSlice(allocator, skey[0..]);
    try out.appendSlice(allocator, plain);
    return out.toOwnedSlice(allocator) catch error.OutOfMemory;
}

pub fn buildResponderSync(allocator: std.mem.Allocator, session: *Session, crypto_select: u32) Error![]u8 {
    return buildResponderSyncWithPad(allocator, session, crypto_select, 0);
}

pub fn buildResponderSyncWithPad(allocator: std.mem.Allocator, session: *Session, crypto_select: u32, pad_len: u16) Error![]u8 {
    if (pad_len > max_pad) return error.MalformedEncryption;
    const plain_len = vc_len + 4 + 2 + pad_len;
    var plain = try allocator.alloc(u8, plain_len);
    defer allocator.free(plain);
    @memset(plain[0..vc_len], 0);
    std.mem.writeInt(u32, plain[vc_len .. vc_len + 4], crypto_select, .big);
    std.mem.writeInt(u16, plain[vc_len + 4 .. vc_len + 6], pad_len, .big);
    if (pad_len > 0) @memset(plain[vc_len + 6 .. vc_len + 6 + pad_len], 0);
    session.encrypt.crypt(plain);
    return allocator.dupe(u8, plain) catch error.OutOfMemory;
}

pub fn findSyncHash(haystack: []const u8, sync_hash: *const [20]u8) ?usize {
    if (haystack.len < 20) return null;
    const limit = haystack.len - 19;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + 20], sync_hash)) return i;
    }
    return null;
}

fn vcCiphertextPattern(decrypt: *const Rc4) [vc_len]u8 {
    var pattern: [vc_len]u8 = [_]u8{0} ** vc_len;
    var probe = decrypt.*;
    probe.crypt(&pattern);
    return pattern;
}

pub fn findVerificationConstant(haystack: []const u8, decrypt: *const Rc4, max_search: usize) ?usize {
    const pattern = vcCiphertextPattern(decrypt);
    if (haystack.len < vc_len) return null;
    const limit = @min(haystack.len - vc_len + 1, max_search + 1);
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + vc_len], &pattern)) return i;
    }
    return null;
}

pub const InitiatorParse = struct {
    scheme: Scheme,
    remote_handshake: [handshake_len]u8,
};

pub fn responderFrameTotalLen(frame_prefix: []const u8, decrypt: *const Rc4) Error!usize {
    if (frame_prefix.len < vc_len + 6) return error.MalformedEncryption;
    var probe = decrypt.*;
    var vc_check: [vc_len]u8 = undefined;
    @memcpy(&vc_check, frame_prefix[0..vc_len]);
    probe.crypt(&vc_check);
    if (!std.mem.allEqual(u8, &vc_check, 0)) return error.MalformedEncryption;
    var crypto_buf: [4]u8 = undefined;
    @memcpy(&crypto_buf, frame_prefix[vc_len .. vc_len + 4]);
    probe.crypt(&crypto_buf);
    var pad_len_buf: [2]u8 = undefined;
    @memcpy(&pad_len_buf, frame_prefix[vc_len + 4 .. vc_len + 6]);
    probe.crypt(&pad_len_buf);
    const pad_len = std.mem.readInt(u16, &pad_len_buf, .big);
    if (pad_len > max_pad) return error.MalformedEncryption;
    return vc_len + 6 + pad_len;
}

pub fn parseResponderSync(
    decrypt: *Rc4,
    frame: []const u8,
    remote_handshake_enc: []const u8,
    crypto_provide: u32,
    policy: Policy,
) Error!InitiatorParse {
    if (frame.len < vc_len + 6) return error.MalformedEncryption;
    var vc_check: [vc_len]u8 = undefined;
    @memcpy(&vc_check, frame[0..vc_len]);
    decrypt.crypt(&vc_check);
    if (!std.mem.allEqual(u8, &vc_check, 0)) return error.MalformedEncryption;
    var cursor: usize = vc_len;
    var crypto_buf: [4]u8 = undefined;
    @memcpy(&crypto_buf, frame[cursor .. cursor + 4]);
    decrypt.crypt(&crypto_buf);
    const crypto_select = std.mem.readInt(u32, &crypto_buf, .big);
    cursor += 4;
    var pad_len_buf: [2]u8 = undefined;
    @memcpy(&pad_len_buf, frame[cursor .. cursor + 2]);
    decrypt.crypt(&pad_len_buf);
    const pad_len = std.mem.readInt(u16, &pad_len_buf, .big);
    if (pad_len > max_pad) return error.MalformedEncryption;
    cursor += 2;
    if (frame.len < cursor + pad_len) return error.MalformedEncryption;
    if (pad_len > 0) {
        var pad_buf: [max_pad]u8 = undefined;
        @memcpy(pad_buf[0..pad_len], frame[cursor .. cursor + pad_len]);
        decrypt.crypt(pad_buf[0..pad_len]);
    }
    cursor += pad_len;
    const scheme = validateCryptoSelect(crypto_select, crypto_provide) catch |err| switch (err) {
        error.MalformedEncryption => return err,
        else => return error.MalformedEncryption,
    };
    if (selectScheme(crypto_provide, policy) == null) return error.UnsupportedEncryption;
    if (policy == .require and scheme != .rc4) return error.UnsupportedEncryption;
    if (remote_handshake_enc.len != handshake_len) return error.MalformedEncryption;
    var hs: [handshake_len]u8 = undefined;
    @memcpy(&hs, remote_handshake_enc);
    // Plaintext-within-MSE (0x01): payload after PE4 is cleartext. RC4 (0x02): continue keystream.
    if (scheme == .rc4) decrypt.crypt(&hs);
    return .{ .scheme = scheme, .remote_handshake = hs };
}

pub const InitiatorSyncHeader = struct {
    crypto_provide: u32,
    ia_len: u16,
};

pub const ResponderParse = struct {
    crypto_provide: u32,
    initiator_handshake: [handshake_len]u8,
};

pub fn parseInitiatorSyncHeader(
    decrypt: *Rc4,
    data: []const u8,
    shared: *const [dh_key_len]u8,
    info_hash: torrent.InfoHash,
) Error!InitiatorSyncHeader {
    const sync_hash = hashReq1(shared);
    const hash_search_len = @min(data.len, 628);
    const sync_off = findSyncHash(data[0..hash_search_len], &sync_hash) orelse return error.MalformedEncryption;
    const after_sync = sync_off + 20;
    if (data.len < after_sync + 20) return error.MalformedEncryption;
    var skey_buf: [20]u8 = undefined;
    @memcpy(&skey_buf, data[after_sync .. after_sync + 20]);
    const expected = obfuscatedSkeyHash(shared, &info_hash);
    if (!std.mem.eql(u8, &skey_buf, &expected)) return error.MalformedEncryption;
    const enc_start = after_sync + 20;
    if (data.len < enc_start + vc_len + 4 + 2) return error.MalformedEncryption;
    var cursor = enc_start;
    var vc: [vc_len]u8 = undefined;
    @memcpy(&vc, data[cursor .. cursor + vc_len]);
    decrypt.crypt(&vc);
    if (!std.mem.allEqual(u8, &vc, 0)) return error.MalformedEncryption;
    cursor += vc_len;
    var crypto_buf: [4]u8 = undefined;
    @memcpy(&crypto_buf, data[cursor .. cursor + 4]);
    decrypt.crypt(&crypto_buf);
    const crypto_provide = std.mem.readInt(u32, &crypto_buf, .big);
    cursor += 4;
    var pad_len_buf: [2]u8 = undefined;
    @memcpy(&pad_len_buf, data[cursor .. cursor + 2]);
    decrypt.crypt(&pad_len_buf);
    const pad_len = std.mem.readInt(u16, &pad_len_buf, .big);
    if (pad_len > max_pad) return error.MalformedEncryption;
    cursor += 2 + pad_len;
    if (data.len < cursor + 2) return error.MalformedEncryption;
    var ia_len_buf: [2]u8 = undefined;
    @memcpy(&ia_len_buf, data[cursor .. cursor + 2]);
    decrypt.crypt(&ia_len_buf);
    const ia_len = std.mem.readInt(u16, &ia_len_buf, .big);
    return .{ .crypto_provide = crypto_provide, .ia_len = ia_len };
}

pub fn decryptInitiatorHandshake(decrypt: *Rc4, data: []const u8) Error![handshake_len]u8 {
    if (data.len < handshake_len) return error.MalformedEncryption;
    var hs: [handshake_len]u8 = undefined;
    @memcpy(&hs, data[0..handshake_len]);
    decrypt.crypt(&hs);
    return hs;
}

pub fn parseInitiatorSync(
    decrypt: *Rc4,
    frame: []const u8,
    ia: []const u8,
    shared: *const [dh_key_len]u8,
    info_hash: torrent.InfoHash,
) Error!ResponderParse {
    const header = try parseInitiatorSyncHeader(decrypt, frame, shared, info_hash);
    if (header.ia_len != ia.len) return error.MalformedEncryption;
    const hs = try decryptInitiatorHandshake(decrypt, ia);
    return .{ .crypto_provide = header.crypto_provide, .initiator_handshake = hs };
}

pub fn responderSelectScheme(crypto_provide: u32, offered: u32) ?Scheme {
    const supported = crypto_provide & offered;
    if (supported & CryptoFlags.rc4 != 0) return .rc4;
    if (supported & CryptoFlags.plaintext_within_mse != 0) return .plaintext_within_mse;
    return null;
}

test "rc4 round trip" {
    var rc = Rc4.init("key");
    var data: [5]u8 = .{ 1, 2, 3, 4, 5 };
    rc.crypt(&data);
    var rc2 = Rc4.init("key");
    rc2.crypt(&data);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
}

test "rc4 discards first 1024 bytes" {
    const key = [_]u8{1} ** 20;
    var a = Rc4.initDiscarded(&key);
    var b = Rc4.init(&key);
    var discard: [rc4_discard]u8 = undefined;
    b.crypt(&discard);
    var data: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var expected: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    a.crypt(&data);
    b.crypt(&expected);
    try std.testing.expectEqualSlices(u8, &expected, &data);
}

test "dh key exchange produces 96-byte keys" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    try b.computeShared(std.testing.allocator, &a.local_public);
    try std.testing.expectEqualSlices(u8, a.shared(), b.shared());
}

test "validate crypto select rejects invalid values" {
    try std.testing.expectError(error.MalformedEncryption, validateCryptoSelect(0, CryptoFlags.rc4));
    try std.testing.expectError(error.MalformedEncryption, validateCryptoSelect(CryptoFlags.rc4 | CryptoFlags.plaintext_within_mse, CryptoFlags.rc4 | CryptoFlags.plaintext_within_mse));
    try std.testing.expectError(error.MalformedEncryption, validateCryptoSelect(CryptoFlags.rc4, CryptoFlags.plaintext_within_mse));
    try std.testing.expectEqual(Scheme.rc4, try validateCryptoSelect(CryptoFlags.rc4, CryptoFlags.rc4));
    // Reserved high bits are ignored when exactly one known scheme bit is set.
    try std.testing.expectEqual(Scheme.rc4, try validateCryptoSelect(CryptoFlags.rc4 | 0x8000_0000, CryptoFlags.rc4 | CryptoFlags.plaintext_within_mse));
}

test "select scheme prefers rc4 under prefer policy" {
    const both = CryptoFlags.rc4 | CryptoFlags.plaintext_within_mse;
    try std.testing.expectEqual(Scheme.rc4, selectScheme(both, .prefer).?);
    try std.testing.expectEqual(Scheme.plaintext_within_mse, selectScheme(CryptoFlags.plaintext_within_mse, .prefer).?);
    try std.testing.expect(selectScheme(CryptoFlags.plaintext_within_mse, .require) == null);
}

test "parses encryption policy" {
    try std.testing.expectEqual(Policy.prefer, parsePolicy("prefer").?);
    try std.testing.expectEqual(Policy.require, parsePolicy("require").?);
    try std.testing.expect(parsePolicy("wat") == null);
}

test "append stores hash bytes" {
    var secret: [96]u8 = [_]u8{2} ** 96;
    const sync = hashReq1(&secret);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try out.appendSlice(std.testing.allocator, sync[0..]);
    try std.testing.expectEqualSlices(u8, sync[0..], out.items[0..20]);
}

test "sync hash is at start of initiator step3" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    try b.computeShared(std.testing.allocator, &a.local_public);
    const info_hash: torrent.InfoHash = [_]u8{0xAB} ** 20;
    const shared_a = a.shared().*;
    const shared_b = b.shared().*;
    try std.testing.expectEqualSlices(u8, &shared_a, &shared_b);
    var ia_session = Session.derive(&shared_a, info_hash, true);
    const step3 = try buildInitiatorSync(std.testing.allocator, &shared_a, info_hash, cryptoProvideForPolicy(.prefer), &ia_session);
    defer std.testing.allocator.free(step3);
    const sync_a = hashReq1(&shared_a);
    const sync_b = hashReq1(&shared_b);
    try std.testing.expectEqualSlices(u8, sync_a[0..], sync_b[0..]);
    try std.testing.expectEqual(@as(usize, 56), step3.len);
    const sync_off = findSyncHash(step3, &sync_a);
    try std.testing.expect(sync_off != null);
    try std.testing.expectEqual(@as(usize, 0), sync_off.?);
}

test "initiator and responder sync round trip" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    try b.computeShared(std.testing.allocator, &a.local_public);

    const info_hash: torrent.InfoHash = [_]u8{0xAB} ** 20;
    const shared_a = a.shared().*;
    const shared_b = b.shared().*;
    var ia_session = Session.derive(&shared_a, info_hash, true);
    const crypto_provide = cryptoProvideForPolicy(.prefer);
    const step3 = try buildInitiatorSync(std.testing.allocator, &shared_a, info_hash, crypto_provide, &ia_session);
    defer std.testing.allocator.free(step3);

    var hs_out: [handshake_len]u8 = undefined;
    @memset(&hs_out, 0x42);
    var hs_scratch = hs_out;
    ia_session.encrypt.crypt(&hs_scratch);

    var recv: std.ArrayList(u8) = .empty;
    defer recv.deinit(std.testing.allocator);
    try recv.appendSlice(std.testing.allocator, step3);
    try recv.appendSlice(std.testing.allocator, &hs_scratch);

    var b_session = Session.derive(&shared_b, info_hash, false);
    const parsed = try parseInitiatorSync(&b_session.decrypt, step3, &hs_scratch, &shared_b, info_hash);
    try std.testing.expectEqual(crypto_provide, parsed.crypto_provide);

    const scheme = responderSelectScheme(parsed.crypto_provide, CryptoFlags.rc4 | CryptoFlags.plaintext_within_mse).?;
    const step4 = try buildResponderSync(std.testing.allocator, &b_session, @intFromEnum(scheme));
    defer std.testing.allocator.free(step4);

    var hs_in: [handshake_len]u8 = undefined;
    @memset(&hs_in, 0x24);
    var hs_in_scratch = hs_in;
    b_session.encrypt.crypt(&hs_in_scratch);

    const resp_parsed = try parseResponderSync(&ia_session.decrypt, step4, &hs_in_scratch, crypto_provide, .prefer);
    try std.testing.expectEqual(Scheme.rc4, resp_parsed.scheme);
    try std.testing.expectEqual(@as(u8, 0x24), resp_parsed.remote_handshake[0]);
}

test "findVerificationConstant skips PadB before PE4" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    try b.computeShared(std.testing.allocator, &a.local_public);

    const info_hash: torrent.InfoHash = [_]u8{0xCD} ** 20;
    const shared = a.shared().*;
    const pad_lens = [_]usize{ 0, 1, 512 };
    for (pad_lens) |pad_b_len| {
        var ia_session = Session.derive(&shared, info_hash, true);
        var b_session = Session.derive(&shared, info_hash, false);
        const step4 = try buildResponderSync(std.testing.allocator, &b_session, CryptoFlags.rc4);
        defer std.testing.allocator.free(step4);

        var haystack: [max_pad + 64]u8 = undefined;
        @memset(haystack[0..pad_b_len], 0xAA);
        @memcpy(haystack[pad_b_len .. pad_b_len + step4.len], step4);
        const total = pad_b_len + step4.len;
        const off = findVerificationConstant(haystack[0..total], &ia_session.decrypt, max_pad);
        try std.testing.expect(off != null);
        try std.testing.expectEqual(pad_b_len, off.?);

        var hs: [handshake_len]u8 = undefined;
        @memset(&hs, 0x55);
        var hs_enc = hs;
        b_session.encrypt.crypt(&hs_enc);

        const parsed = try parseResponderSync(&ia_session.decrypt, haystack[off.? .. off.? + step4.len], &hs_enc, CryptoFlags.rc4, .prefer);
        try std.testing.expectEqual(Scheme.rc4, parsed.scheme);
        try std.testing.expectEqual(@as(u8, 0x55), parsed.remote_handshake[0]);
    }
}

test "findVerificationConstant returns null when VC absent" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    const info_hash: torrent.InfoHash = [_]u8{0xEF} ** 20;
    var ia_session = Session.derive(a.shared(), info_hash, true);
    var junk: [64]u8 = undefined;
    @memset(&junk, 0x7E);
    try std.testing.expect(findVerificationConstant(&junk, &ia_session.decrypt, max_pad) == null);
}

test "parseResponderSync plaintext-within-mse uses cleartext handshake" {
    var a = try DhKeyExchange.generate(std.testing.allocator);
    defer a.deinit();
    var b = try DhKeyExchange.generate(std.testing.allocator);
    defer b.deinit();
    try a.computeShared(std.testing.allocator, &b.local_public);
    try b.computeShared(std.testing.allocator, &a.local_public);

    const info_hash: torrent.InfoHash = [_]u8{0x11} ** 20;
    const shared = a.shared().*;
    var ia_session = Session.derive(&shared, info_hash, true);
    var b_session = Session.derive(&shared, info_hash, false);
    const step4 = try buildResponderSync(std.testing.allocator, &b_session, CryptoFlags.plaintext_within_mse);
    defer std.testing.allocator.free(step4);

    var hs_in: [handshake_len]u8 = undefined;
    @memset(&hs_in, 0x24);
    const resp_parsed = try parseResponderSync(
        &ia_session.decrypt,
        step4,
        &hs_in,
        CryptoFlags.plaintext_within_mse,
        .prefer,
    );
    try std.testing.expectEqual(Scheme.plaintext_within_mse, resp_parsed.scheme);
    try std.testing.expectEqual(@as(u8, 0x24), resp_parsed.remote_handshake[0]);
}
