# Handoff: magnet metadata peer crash and encryption expansion

Date: 2026-07-02  
Torrent under test: `[Erai-raws] Koori no Jouheki - 13 ...` (`e25fde8783c90f3c9595cc2e347542ccd21508ef`)

## Summary

Adding a magnet link and fetching metadata caused `torrentd` to crash during the first engine tick while connecting to peers returned by `udp://tracker-udp.anirena.com:80/announce`. The daemon never completed metadata fetch.

Two fixes were applied immediately:

1. **Harden `encryption.sharedSecret`** so malformed MSE key material returns `MalformedEncryption` instead of panicking.
2. **Cap peer connect attempts per tick** via new limit `max_peer_connect_attempts_per_tick` (default `5`) so one tracker announce cannot block the daemon for many minutes.

Plaintext handshake fallback is **not** the desired direction for follow-up work. Future work should expand supported **encryption schemes** and keep encrypted-only operation where policy requires it.

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

## Future work: expand encryption schemes (not plaintext fallback)

**Product direction:** Do not add or rely on plaintext fallback for metadata/content peers when encryption is required. Instead, broaden MSE negotiation so more real-world peers complete encrypted handshakes.

### Current implementation (baseline)

| Piece | Status |
|-------|--------|
| MSE initiator/responder DH step | Partial — RC4-only selection |
| `CryptoFlags.rc4` (0x02) | Supported |
| `supportsRc4()` negotiation | Supported |
| Encrypted BitTorrent handshake | Supported after RC4 select |
| Plaintext fallback on `prefer` | Exists in code today; **not** the desired long-term path |

Relevant files:

- `src/encryption.zig` — keygen, MSE payloads, RC4, `sharedSecret`
- `src/peer.zig` — `tryEncryptedHandshake`, `performHandshake`, `performMetadataHandshake`

### Schemes to implement

Priority follows common peer compatibility for anime/public swarms:

1. **RC4 (existing)** — keep as baseline; ensure handshake reads full fixed-size MSE frames before parsing (608-byte initiator, variable responder with minimum length checks).

2. **AES128/256 CTR or other MSE crypto provide bits** — parse full crypto provide field from peer response; negotiate highest mutually supported scheme instead of RC4-only `supportsRc4()`.

3. **Stricter frame validation** — reject truncated/padded responses before `sharedSecret`; return typed errors (`MalformedEncryption`, `UnsupportedEncryption`) at every step.

4. **Read loop for MSE response** — `tryEncryptedHandshake` currently does a single `readStreamSlice` into 700 bytes. Real peers may deliver the 608+ byte response across multiple reads. Loop until minimum frame length or timeout.

5. **Policy semantics** — with `require`, failed encryption is a disconnect, not plaintext retry. Document and test that `prefer` behavior may be narrowed or removed per product decision.

### Suggested implementation order

1. **Framed MSE read helper** in `encryption.zig` or `peer.zig`: read until `608` bytes for initiator step response or timeout; centralize length checks.
2. **Crypto provide parser** — expose `supportedSchemes(response) -> bit set`; replace `supportsRc4()` with scheme selection function.
3. **AES path** — add derive/encrypt/decrypt session alongside RC4 in `encryption.Session`.
4. **Integration harness** — extend `spawnFakeMetadataPeer` / fake encrypted peer to advertise multiple schemes; add tests for `require` and each scheme.
5. **Remove or gate plaintext fallback** once encrypted coverage is sufficient; update `V2_NETWORK_PLAN.md` milestone 11 acceptance criteria to match.

### Test plan for encryption expansion

- Unit: `sharedSecret` rejects all non-96-byte inputs (done).
- Unit: truncated MSE response → `MalformedEncryption`, no panic.
- Integration: fake peer advertising RC4 + second scheme; client picks best shared scheme.
- Integration: fake peer advertising only unsupported scheme → `UnsupportedEncryption`, peer skipped, daemon survives.
- Manual: magnet add for `e25fde8783c90f3c9595cc2e347542ccd21508ef`; daemon stays up through first tick; metadata session progresses.

### References

- [BEP 10: Extension Protocol](http://bittorrent.org/beps/bep_0010.html) (ut_metadata — already used)
- [BEP 3 / de facto MSE spec](https://wiki.theory.org/BitTorrentSpecification) — Message Stream Encryption / Protocol Encryption
- Project plan: `docs/V2_NETWORK_PLAN.md` milestone 11 (update when plaintext fallback decision changes)

## Related engine work (optional, separate PR)

- Flush structured logs inside long ticks (partially addressed with post-tick stderr flush in `daemon.zig`).
- Accept control connections before `engine.tick()` (done) — prevents add/status blocking on tick start only; long ticks still block until cap reduces duration.
- Persist tracker state incrementally after each announce instead of only at end of `tickMetadataSession`.
