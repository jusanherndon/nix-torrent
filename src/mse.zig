const std = @import("std");
const encryption = @import("encryption.zig");
const torrent = @import("torrent.zig");

/// Port at the byte-stream seam. Two adapters justify it: Peer Connection + harness fd.
pub const ByteStream = struct {
    ptr: *anyopaque,
    readFn: *const fn (ptr: *anyopaque, dest: []u8) anyerror!usize,
    writeFn: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn read(self: ByteStream, dest: []u8) anyerror!usize {
        return self.readFn(self.ptr, dest);
    }

    pub fn writeAll(self: ByteStream, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ptr, bytes);
    }
};

pub const InitiatorRequest = struct {
    info_hash: torrent.InfoHash,
    local_peer_id: [20]u8,
    policy: encryption.Policy,
    extensions: bool,
};

/// Post-MSE wire state for an Encrypted or Obfuscated Peer Connection.
pub const Established = struct {
    mode: encryption.Mode,
    crypto: ?encryption.Keystreams,
    remote_handshake: [encryption.handshake_len]u8,
    /// Plaintext bytes already read past the remote BitTorrent handshake (caller owns).
    leftover: []u8,

    pub fn deinit(self: *Established, allocator: std.mem.Allocator) void {
        if (self.leftover.len != 0) allocator.free(self.leftover);
        self.leftover = &.{};
    }
};

pub const HandshakeError = error{
    PolicyDisabled,
    PeerNotMse,
    EncryptionRequired,
    UnsupportedEncryption,
    MalformedEncryption,
    /// PE2 ended before Yb (96 bytes) — often EOF / peer closed.
    MsePe2Short,
    /// ENCRYPT(VC) not found within PadB window.
    MseVcNotFound,
    /// Peer closed during VC search (EOF), before PadB window exhausted.
    MseVcEof,
    /// PE4 crypto_select / pad frame could not be parsed.
    MsePe4Parse,
    /// Remote BitTorrent handshake truncated after PE4.
    MseHandshakeEof,
    InfoHashMismatch,
    ShortRead,
    OutOfMemory,
};

fn encodeBtHandshake(out: *[encryption.handshake_len]u8, info_hash: torrent.InfoHash, peer_id: [20]u8, extensions: bool) void {
    out[0] = 19;
    @memcpy(out[1..20], "BitTorrent protocol");
    @memset(out[20..28], 0);
    if (extensions) out[20] = 0x10;
    @memcpy(out[28..48], &info_hash);
    @memcpy(out[48..68], &peer_id);
}

fn infoHashFromHandshake(bytes: *const [encryption.handshake_len]u8) torrent.InfoHash {
    return bytes[28..48].*;
}

fn readExact(stream: ByteStream, dest: []u8) HandshakeError!void {
    var got: usize = 0;
    while (got < dest.len) {
        const n = stream.read(dest[got..]) catch return error.ShortRead;
        if (n == 0) return error.ShortRead;
        got += n;
    }
}

fn readDhPeerKey(stream: ByteStream, buf: []u8) HandshakeError!usize {
    // At least Y (96). Do not block waiting for more pad — that delays the next frame.
    var total: usize = 0;
    while (total < 96) {
        const n = stream.read(buf[total..]) catch return error.ShortRead;
        if (n == 0) return total;
        total += n;
        if (buf[0] == 19) return total;
    }
    return total;
}

/// Completes MSE Handshake as initiator, including BitTorrent handshake as IA.
pub fn establishInitiator(
    allocator: std.mem.Allocator,
    stream: ByteStream,
    req: InitiatorRequest,
) HandshakeError!Established {
    if (req.policy == .disable) return error.PolicyDisabled;

    var dh = encryption.DhKeyExchange.generate(allocator) catch return error.OutOfMemory;
    defer dh.deinit();

    const pe1 = encryption.buildDhOutgoing(allocator, &dh.local_public) catch return error.OutOfMemory;
    defer allocator.free(pe1);
    stream.writeAll(pe1) catch return error.ShortRead;

    var pe2_buf: [encryption.max_dh_packet_len]u8 = undefined;
    const pe2_len = try readDhPeerKey(stream, &pe2_buf);
    if (pe2_len >= 1 and pe2_buf[0] == 19) return error.PeerNotMse;
    if (pe2_len < 96) return error.MsePe2Short;

    var remote_pub: [96]u8 = undefined;
    @memcpy(&remote_pub, pe2_buf[0..96]);
    dh.computeShared(allocator, &remote_pub) catch return error.MalformedEncryption;
    const shared = dh.shared().*;

    const crypto_provide = encryption.cryptoProvideForPolicy(req.policy);
    var keys = encryption.Keystreams.derive(&shared, req.info_hash, true);
    const pe3 = encryption.buildInitiatorSync(allocator, &shared, req.info_hash, crypto_provide, &keys) catch return error.OutOfMemory;
    defer allocator.free(pe3);

    var hs_out: [encryption.handshake_len]u8 = undefined;
    encodeBtHandshake(&hs_out, req.info_hash, req.local_peer_id, req.extensions);
    var hs_scratch = hs_out;
    keys.encrypt.crypt(&hs_scratch);

    const pe3_ia = allocator.alloc(u8, pe3.len + hs_scratch.len) catch return error.OutOfMemory;
    defer allocator.free(pe3_ia);
    @memcpy(pe3_ia[0..pe3.len], pe3);
    @memcpy(pe3_ia[pe3.len..], &hs_scratch);
    stream.writeAll(pe3_ia) catch return error.ShortRead;

    var pe4_buf: [encryption.pe4_sync_buf_len]u8 = undefined;
    var pe4_len: usize = 0;
    if (pe2_len > 96) {
        const seed = @min(pe2_len - 96, pe4_buf.len);
        @memcpy(pe4_buf[0..seed], pe2_buf[96 .. 96 + seed]);
        pe4_len = seed;
    }
    const search_limit = encryption.max_pad + encryption.vc_len;
    const vc_off = blk: {
        while (true) {
            if (pe4_len >= encryption.vc_len) {
                if (encryption.findVerificationConstant(pe4_buf[0..pe4_len], &keys.decrypt, encryption.max_pad)) |off| {
                    break :blk off;
                }
            }
            if (pe4_len >= search_limit) return error.MseVcNotFound;
            const n = stream.read(pe4_buf[pe4_len..search_limit]) catch return error.ShortRead;
            if (n == 0) return error.MseVcEof;
            pe4_len += n;
        }
    };
    const header_end = vc_off + encryption.vc_len + 6;
    while (pe4_len < header_end) {
        const n = stream.read(pe4_buf[pe4_len..header_end]) catch return error.ShortRead;
        if (n == 0) return error.MsePe4Parse;
        pe4_len += n;
    }
    const pe4_total = encryption.responderFrameTotalLen(pe4_buf[vc_off..header_end], &keys.decrypt) catch return error.MsePe4Parse;
    const frame_end = vc_off + pe4_total;
    if (frame_end > pe4_buf.len) return error.MsePe4Parse;
    while (pe4_len < frame_end) {
        const n = stream.read(pe4_buf[pe4_len..frame_end]) catch return error.ShortRead;
        if (n == 0) return error.MsePe4Parse;
        pe4_len += n;
    }

    var hs_enc: [encryption.handshake_len]u8 = undefined;
    var hs_got: usize = 0;
    var post_frame = pe4_len - frame_end;
    if (post_frame > 0) {
        const take = @min(post_frame, hs_enc.len);
        @memcpy(hs_enc[0..take], pe4_buf[frame_end .. frame_end + take]);
        hs_got = take;
        post_frame -= take;
    }
    while (hs_got < hs_enc.len) {
        const n = stream.read(hs_enc[hs_got..]) catch return error.ShortRead;
        if (n == 0) return error.MseHandshakeEof;
        hs_got += n;
    }

    const parsed = encryption.parseResponderSync(&keys.decrypt, pe4_buf[vc_off..frame_end], &hs_enc, crypto_provide, req.policy) catch |err| switch (err) {
        error.UnsupportedEncryption => return if (req.policy == .require) error.EncryptionRequired else error.UnsupportedEncryption,
        error.MalformedEncryption => return error.MsePe4Parse,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (!std.mem.eql(u8, &infoHashFromHandshake(&parsed.remote_handshake), &req.info_hash)) {
        return error.InfoHashMismatch;
    }

    var leftover: []u8 = &.{};
    if (post_frame > 0) {
        const extra = pe4_buf[frame_end + encryption.handshake_len .. pe4_len];
        leftover = allocator.dupe(u8, extra) catch return error.OutOfMemory;
        if (parsed.scheme == .rc4) keys.decrypt.crypt(leftover);
    }

    const mode = encryption.modeForScheme(parsed.scheme);
    return .{
        .mode = mode,
        .crypto = if (parsed.scheme == .rc4) keys else null,
        .remote_handshake = parsed.remote_handshake,
        .leftover = leftover,
    };
}

/// Completes MSE Handshake as responder (harness / future inbound).
pub fn establishResponder(
    allocator: std.mem.Allocator,
    stream: ByteStream,
    info_hash: torrent.InfoHash,
    local_peer_id: [20]u8,
    offered_schemes: u32,
) HandshakeError!Established {
    var pe1_buf: [encryption.max_dh_packet_len]u8 = undefined;
    const pe1_len = try readDhPeerKey(stream, &pe1_buf);
    if (pe1_len < 96) return error.MalformedEncryption;
    if (pe1_buf[0] == 19) return error.PeerNotMse;

    var remote_pub: [96]u8 = undefined;
    @memcpy(&remote_pub, pe1_buf[0..96]);

    var dh = encryption.DhKeyExchange.generate(allocator) catch return error.OutOfMemory;
    defer dh.deinit();
    dh.computeShared(allocator, &remote_pub) catch return error.MalformedEncryption;
    const shared = dh.shared().*;

    // Send Yb only; leave PadB until after PE3 so the initiator must sync on ENCRYPT(VC).
    stream.writeAll(dh.local_public[0..]) catch return error.ShortRead;

    // PE3 without PadC: HASH(req1)+skey+ENCRYPT(VC+provide+padC_len+IA_len) = 56 bytes.
    var frame_buf: [128]u8 = undefined;
    var frame_len: usize = 0;
    while (frame_len < 56) {
        const n = stream.read(frame_buf[frame_len..56]) catch return error.ShortRead;
        if (n == 0) return error.MalformedEncryption;
        frame_len += n;
    }
    var ia_enc: [encryption.handshake_len]u8 = undefined;
    try readExact(stream, &ia_enc);

    var keys = encryption.Keystreams.derive(&shared, info_hash, false);
    const parsed = encryption.parseInitiatorSync(&keys.decrypt, frame_buf[0..frame_len], &ia_enc, &shared, info_hash) catch return error.MalformedEncryption;

    const selected = encryption.responderSelectScheme(parsed.crypto_provide, offered_schemes) orelse return error.UnsupportedEncryption;

    var pad_b: [32]u8 = undefined;
    @memset(&pad_b, 0xAB);
    stream.writeAll(&pad_b) catch return error.ShortRead;

    const pe4 = encryption.buildResponderSync(allocator, &keys, @intFromEnum(selected)) catch return error.OutOfMemory;
    defer allocator.free(pe4);
    stream.writeAll(pe4) catch return error.ShortRead;

    var hs_out: [encryption.handshake_len]u8 = undefined;
    encodeBtHandshake(&hs_out, info_hash, local_peer_id, false);
    if (selected == .rc4) {
        var hs_scratch = hs_out;
        keys.encrypt.crypt(&hs_scratch);
        stream.writeAll(&hs_scratch) catch return error.ShortRead;
    } else {
        stream.writeAll(&hs_out) catch return error.ShortRead;
    }

    if (!std.mem.eql(u8, &infoHashFromHandshake(&parsed.initiator_handshake), &info_hash)) {
        return error.InfoHashMismatch;
    }

    return .{
        .mode = encryption.modeForScheme(selected),
        .crypto = if (selected == .rc4) keys else null,
        .remote_handshake = parsed.initiator_handshake,
        .leftover = &.{},
    };
}

pub const ResponderMatch = struct {
    established: Established,
    info_hash: torrent.InfoHash,
};

/// MSE responder that probes the initiator's skey hash against a set of active
/// info hashes (inbound Listen Socket path). Identifies the torrent from the
/// obfuscated skey in PE3, then completes the handshake as `establishResponder`.
pub fn establishResponderMulti(
    allocator: std.mem.Allocator,
    stream: ByteStream,
    candidates: []const torrent.InfoHash,
    local_peer_id: [20]u8,
    offered_schemes: u32,
) HandshakeError!ResponderMatch {
    if (candidates.len == 0) return error.InfoHashMismatch;

    var pe1_buf: [encryption.max_dh_packet_len]u8 = undefined;
    const pe1_len = try readDhPeerKey(stream, &pe1_buf);
    if (pe1_len < 96) return error.MalformedEncryption;
    if (pe1_buf[0] == 19) return error.PeerNotMse;

    var remote_pub: [96]u8 = undefined;
    @memcpy(&remote_pub, pe1_buf[0..96]);

    var dh = encryption.DhKeyExchange.generate(allocator) catch return error.OutOfMemory;
    defer dh.deinit();
    dh.computeShared(allocator, &remote_pub) catch return error.MalformedEncryption;
    const shared = dh.shared().*;

    stream.writeAll(dh.local_public[0..]) catch return error.ShortRead;

    var frame_buf: [128]u8 = undefined;
    var frame_len: usize = 0;
    while (frame_len < 56) {
        const n = stream.read(frame_buf[frame_len..56]) catch return error.ShortRead;
        if (n == 0) return error.MalformedEncryption;
        frame_len += n;
    }
    var ia_enc: [encryption.handshake_len]u8 = undefined;
    try readExact(stream, &ia_enc);

    // Identify the torrent: the initiator's obfuscated skey hash matches exactly one candidate.
    const matched: torrent.InfoHash = blk: {
        for (candidates) |candidate| {
            var trial = encryption.Keystreams.derive(&shared, candidate, false);
            if (encryption.parseInitiatorSync(&trial.decrypt, frame_buf[0..frame_len], &ia_enc, &shared, candidate)) |_| {
                break :blk candidate;
            } else |_| {}
        }
        return error.InfoHashMismatch;
    };

    var keys = encryption.Keystreams.derive(&shared, matched, false);
    const parsed = encryption.parseInitiatorSync(&keys.decrypt, frame_buf[0..frame_len], &ia_enc, &shared, matched) catch return error.MalformedEncryption;

    const selected = encryption.responderSelectScheme(parsed.crypto_provide, offered_schemes) orelse return error.UnsupportedEncryption;

    var pad_b: [32]u8 = undefined;
    @memset(&pad_b, 0xAB);
    stream.writeAll(&pad_b) catch return error.ShortRead;

    const pe4 = encryption.buildResponderSync(allocator, &keys, @intFromEnum(selected)) catch return error.OutOfMemory;
    defer allocator.free(pe4);
    stream.writeAll(pe4) catch return error.ShortRead;

    var hs_out: [encryption.handshake_len]u8 = undefined;
    encodeBtHandshake(&hs_out, matched, local_peer_id, false);
    if (selected == .rc4) {
        var hs_scratch = hs_out;
        keys.encrypt.crypt(&hs_scratch);
        stream.writeAll(&hs_scratch) catch return error.ShortRead;
    } else {
        stream.writeAll(&hs_out) catch return error.ShortRead;
    }

    if (!std.mem.eql(u8, &infoHashFromHandshake(&parsed.initiator_handshake), &matched)) {
        return error.InfoHashMismatch;
    }

    return .{
        .established = .{
            .mode = encryption.modeForScheme(selected),
            .crypto = if (selected == .rc4) keys else null,
            .remote_handshake = parsed.initiator_handshake,
            .leftover = &.{},
        },
        .info_hash = matched,
    };
}

test "establish initiator refuses disable policy" {
    const stream = ByteStream{
        .ptr = undefined,
        .readFn = struct {
            fn r(_: *anyopaque, _: []u8) anyerror!usize {
                return 0;
            }
        }.r,
        .writeFn = struct {
            fn w(_: *anyopaque, _: []const u8) anyerror!void {}
        }.w,
    };
    try std.testing.expectError(error.PolicyDisabled, establishInitiator(std.testing.allocator, stream, .{
        .info_hash = [_]u8{1} ** 20,
        .local_peer_id = [_]u8{2} ** 20,
        .policy = .disable,
        .extensions = false,
    }));
}
