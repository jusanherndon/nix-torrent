# Handoff: magnet metadata peer crash and encryption expansion

Date: 2026-07-02  
Torrent under test: `[Erai-raws] Koori no Jouheki - 13 ...` (`e25fde8783c90f3c9595cc2e347542ccd21508ef`)

## Summary

Adding a magnet link and fetching metadata caused `torrentd` to crash during the first engine tick while connecting to peers returned by `udp://tracker-udp.anirena.com:80/announce`. The daemon never completed metadata fetch.

Two fixes were applied immediately:

1. **Harden `encryption.sharedSecret`** so malformed MSE key material returns `MalformedEncryption` instead of panicking.
2. **Cap peer connect attempts per tick** via new limit `max_peer_connect_attempts_per_tick` (default `5`) so one tracker announce cannot block the daemon for many minutes.

Plaintext handshake fallback is **not** the desired direction for follow-up work. Future work should complete de facto MSE negotiation (`0x01` / `0x02`) and keep RC4-only operation where policy requires it. See [Agreed design](#agreed-design-2026-07-02) below.

## Incident timeline

1. `torrent add magnet:...` succeeded; session entered `fetching_metadata`.
2. First UDP announce to `tracker-udp.anirena.com` succeeded (~72 peers).
3. `connectMetadataBatch` began sequential outbound TCP + MSE handshakes inside a single `engine.tick()`.
4. Daemon crashed with `panic: integer overflow` in `encryption.sharedSecret` while handling a peer encryption response.

Earlier in the same debugging session, a separate crash was observed:

- `panic: programmer bug caused syscall error: AGAIN` in `peer.readStreamSlice` when using Zig 0.16 Io readers on sockets with `SO_RCVTIMEO` / non-blocking connect paths.

That read path was switched to `tcp.readSome()` (poll + `recv`).

## Root causes

### 1. Integer overflow in `encryption.sharedSecret` (fatal)

**Location:** `src/encryption.zig` — `sharedSecret`

**Trigger:** MSE handshake with a live peer after `tryEncryptedHandshake` read a response and called `sharedSecret` with key slices whose lengths were not exactly 96 bytes, or with buffer arithmetic that could overflow in Debug builds.

**Symptom:** Uncaught panic; entire daemon exits. Peer connect failure was not logged because the panic occurred mid-log line.

**Fix applied:** Require exactly 96-byte private and remote public keys; use fixed `[192]u8` buffer with explicit layout; return `error.MalformedEncryption` on violation.

### 2. Unbounded peer connects inside one engine tick (performance / availability)

**Location:** `src/peer_pool.zig` — `connectMetadataBatch` / `connectContentBatch`, called from `engine.announceTrackerEndpoint`

**Trigger:** Successful tracker announce returning dozens of peers; batch loop attempted up to `max_peers_per_torrent` (50) connects synchronously, each with 10s connect timeout and up to 30s read timeout.

**Symptom:** Control socket unresponsive for many minutes; state not persisted until tick completed; operator perceived hang.

**Fix applied:** New config limit `limits.max_peer_connect_attempts_per_tick` (default `5`). Each batch call attempts at most that many connects; remaining peers are tried on subsequent ticks.

### 3. Peer read panic on `EAGAIN` (fixed separately)

**Location:** `src/peer.zig` — `readStreamSlice` via Zig Io

**Trigger:** `SO_RCVTIMEO` expiry or non-blocking socket state surfaced as `EAGAIN`; Zig 0.16 Threaded Io treats that as a programmer bug in Debug builds.

**Fix applied:** Peer reads use `tcp.readSome()` with explicit poll timeout.

## Log signatures to recognize

```text
tracker announce ok for udp://tracker-udp.anirena.com:80/announce: N peers
metadata peer connect failed ...: Timeout
metadata peer connect failed ...: MalformedEncryption
metadata peer connect failed ...: UnsupportedEncryption
panic: integer overflow
/home/justin/git/nix-torrent/src/encryption.zig:...: in sharedSecret
panic: programmer bug caused syscall error: AGAIN
/home/justin/git/nix-torrent/src/peer.zig:...: in readStreamSlice
```

## Configuration

New limit in `[limits]`:

```toml
# Maximum outbound peer TCP+MSE handshake attempts per engine tick (per batch).
max_peer_connect_attempts_per_tick = 5
```

Validation: must be `> 0` and `<= max_peers_per_torrent`.

## Future work: MSE expansion

**Product direction:** Complete Message Stream Encryption (MSE) negotiation for real-world swarms. Do not add AES or other non-standard schemes. Remove non-MSE plaintext fallback under `prefer`.

### Agreed design (2026-07-02)

Design decisions are recorded in [`CONTEXT.md`](../CONTEXT.md) (glossary) and [`docs/adr/0004-full-mse-handshake-parsing.md`](adr/0004-full-mse-handshake-parsing.md) (MSE parsing approach). [`docs/V2_NETWORK_PLAN.md`](V2_NETWORK_PLAN.md) milestone 11 acceptance criteria match this design.

### De facto encryption schemes

MSE defines two `crypto_provide` / `crypto_select` bits only:

| Bit | Scheme | Stream after negotiation |
|-----|--------|--------------------------|
| `0x01` | Plaintext-within-MSE | Standard BitTorrent protocol on cleartext stream (obfuscated handshake) |
| `0x02` | RC4 | RC4-encrypted stream (first 1024 keystream bytes discarded) |

AES was proposed during MSE design but was never standardized. No real peers advertise it.

### Encryption policy mapping

| Policy | MSE attempt | Scheme selection | Non-MSE peer (raw BitTorrent handshake) |
|--------|-------------|------------------|---------------------------------------|
| `disable` | No | N/A — plaintext BitTorrent handshake | Connect |
| `prefer` | Yes | RC4 (`0x02`) if offered, else plaintext-within-MSE (`0x01`) | **Skip** — try next peer |
| `require` | Yes | RC4 (`0x02`) only | **Skip** |

When a peer offers both `0x01` and `0x02`, select `0x02`.

### Per-peer connection modes (status)

Surface three modes for connected peers in detailed torrent status:

- `encrypted` — RC4 active after MSE
- `obfuscated` — MSE completed with plaintext-within-MSE (`0x01`)
- `plaintext` — no MSE (`disable` policy only)

Peers skipped due to policy or unsupported schemes do not appear as connected.

### Tracker MSE signaling (HTTP only)

| Policy | Announce parameters |
|--------|---------------------|
| `prefer` | `supportcrypto=1` |
| `require` | `supportcrypto=1` and `requirecrypto=1` |
| `disable` | neither |

When the tracker returns `crypto_flags` (one byte per compact peer):

- **`require`:** skip peers with flag `0` before connect
- **`prefer`:** no filter; order flag-`1` peers ahead of flag-`0` in each batch
- **`disable`:** ignore

UDP trackers have no equivalent parameters.

### MSE implementation approach

**Spec-first, full compliance** on both initiator and responder paths: VC verification, RC4-decrypted negotiation frames, variable pads, and `crypto_select` validation (exactly one known bit set). Refine against live swarms if interoperability gaps appear. Replaces the current simplified 608-byte fixed-offset layout.

Relevant files:

- `src/encryption.zig` — MSE build/parse, scheme selection, RC4 `Session`, `sharedSecret`
- `src/peer.zig` — `tryEncryptedHandshake`, `performHandshake`, connection mode reporting
- `src/tracker.zig` — HTTP announce signaling and `crypto_flags` parsing
- `src/integration_harness.zig` — full-spec fake peers with scheme variants

### Current implementation (baseline)

| Piece | Status |
|-------|--------|
| MSE initiator/responder DH step | Partial — simplified 608-byte frames |
| `CryptoFlags.rc4` (`0x02`) | Supported |
| `supportsRc4()` negotiation | RC4-only gate; no `0x01` path |
| Encrypted BitTorrent handshake | Supported after RC4 select |
| Plaintext-within-MSE (`0x01`) | Not implemented |
| Full-spec VC/pad/decrypt parsing | Not implemented |
| Non-MSE plaintext fallback on `prefer` | Exists in code; **to be removed** |
| HTTP tracker MSE signaling | Not implemented |
| HTTP tracker `crypto_flags` use | Not implemented |

### Implementation order

1. **Full-spec MSE** in `encryption.zig` — build/parse initiator and responder frames; scheme selection (`0x02` over `0x01` when both offered).
2. **Policy wiring** in `peer.zig` — three connection modes; remove non-MSE `prefer` fallback; skip-on-fail.
3. **Tracker layer** — `supportcrypto` / `requirecrypto` on HTTP announces; parse `crypto_flags` for filter/order.
4. **Harness** — upgrade encrypted fakes in place; add `rc4_only`, `plaintext_only`, and `both` scheme variants.
5. **Docs** — this handoff and milestone 11 (done).
6. **Manual test** — magnet add for `e25fde8783c90f3c9595cc2e347542ccd21508ef`; daemon stays up; metadata session progresses.

### Test plan for encryption expansion

- Unit: `sharedSecret` rejects all non-96-byte inputs (done).
- Unit: truncated or malformed MSE response → `MalformedEncryption`, no panic.
- Unit: `crypto_select` with zero or multiple bits set → `MalformedEncryption`.
- Integration: fake peer advertising RC4 + plaintext-within-MSE; client selects RC4 under `prefer`.
- Integration: fake peer advertising only `0x01`; client connects as `obfuscated` under `prefer`.
- Integration: fake peer advertising only `0x01`; client skips under `require`.
- Integration: fake peer with non-MSE handshake; client skips under `prefer` and `require`.
- Integration: fake peer advertising no supported scheme → `UnsupportedEncryption`, peer skipped, daemon survives.
- Integration: `policy = "require"` with fake RC4-only peer succeeds.
- Manual: Anirena magnet; daemon survives first tick; metadata fetch progresses.

### References

- [BEP 10: Extension Protocol](http://bittorrent.org/beps/bep_0010.html) (ut_metadata — already used; not MSE)
- [De facto MSE spec](https://wiki.theory.org/BitTorrentSpecification) — Message Stream Encryption / Protocol Encryption
- [`CONTEXT.md`](../CONTEXT.md) — domain glossary
- [`docs/adr/0004-full-mse-handshake-parsing.md`](adr/0004-full-mse-handshake-parsing.md)
- [`docs/V2_NETWORK_PLAN.md`](V2_NETWORK_PLAN.md) milestone 11

## Related engine work (optional, separate PR)

- Flush structured logs inside long ticks (partially addressed with post-tick stderr flush in `daemon.zig`).
- Accept control connections before `engine.tick()` (done) — prevents add/status blocking on tick start only; long ticks still block until cap reduces duration.
- Persist tracker state incrementally after each announce instead of only at end of `tickMetadataSession`.
