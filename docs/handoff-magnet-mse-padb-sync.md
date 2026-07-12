# Handoff: MSE PadB sync and announce budget for magnet metadata

Date: 2026-07-12  
Follows: [`handoff-magnet-sayonara-lara.md`](handoff-magnet-sayonara-lara.md)  
Torrent under test: `[Erai-raws] Sayonara Lara - 02 ...`  
Info hash: `eb91484e28cbb4a6bfbbd2d34eb3203f335cea56`

## Summary

Continued the Sayonara Lara magnet metadata investigation after candidate-set / HTTP tracker fixes. This round fixed initiator MSE framing against variable PadB, stopped delaying PE3 while draining PadB, capped tracker announces per tick, and corrected plaintext-within-MSE (`0x01`) handshake handling.

Live result: trackers and candidate merge look healthy (including nyaa HTTP/1.1). `MalformedEncryption` is no longer the dominant failure mode, but metadata still did not complete in ~2 minute debug runs from this network — most peer attempts end in `Timeout` / `ConnectionRefused`, with a residual minority of `MalformedEncryption`. `connected_peer_count` stayed `0`; `metadata_complete` stayed `false`.

## How to reproduce

```sh
zig build -Doptimize=Debug
mkdir -p /tmp/nix-torrent/{staging,downloads}
# config under [paths], logging.level = "debug", network.encryption.policy = "prefer"
# optional: max_tracker_announces_per_tick = 1 (default)
./zig-out/bin/torrentd --config /tmp/nix-torrent/config.toml > /tmp/nix-torrent/daemon.log 2>&1 &
./zig-out/bin/torrent --config /tmp/nix-torrent/config.toml add 'magnet:?xt=urn:btih:EB91484E28CBB4A6BFBBD2D34EB3203F335CEA56&dn=...&tr=...'
./zig-out/bin/torrent --config /tmp/nix-torrent/config.toml show eb91484e28cbb4a6bfbbd2d34eb3203f335cea56
```

Useful log greps:

```sh
rg 'announce ok|merged|MalformedEncryption|UnsupportedEncryption|metadata peer connect failed' /tmp/nix-torrent/daemon.log
rg 'metadata peer connect failed' /tmp/nix-torrent/daemon.log | sed 's/.*: //' | sort | uniq -c | sort -rn
```

## Observed behavior (after this fix)

| Stage | Result |
|-------|--------|
| Magnet add | OK — `fetching_metadata` |
| UDP Anirena / open.stealth.si | OK — peers merged into candidate set |
| HTTP nyaa.tracker.wf | OK — `announce ok` + candidates merged (HTTP/1.1 + chunked decode from prior handoff) |
| HTTP acgnx.se | OK — announce succeeds; unroutable peers filtered |
| Peer TCP | Mostly `Timeout` / `ConnectionRefused` |
| MSE after TCP accept | Minority `MalformedEncryption`; much less dominant than before PE3-delay fix |
| Metadata | Still stuck — `metadata_complete=false`, `connected_peer_count=0` in ~2 min runs |
| Control socket | Improved vs all-trackers-in-one-tick; still can block for tens of seconds while draining up to 5 peer connects/tick |

Example failure mix from one ~2 min `prefer` run:

```text
22 Timeout
11 MalformedEncryption
 2 ConnectionRefused
```

Control run with `encryption.policy = "disable"` also got zero metadata peers (mostly `Timeout` / `ShortMessage` / `ReadFailed`) — reachability from this network is a major factor, not only MSE.

## Root causes and fixes applied

### 1. Initiator PE4 assumed VC at offset 0 (fixed)

**Bug:** After Yb, leftover PadB can still be on the socket (or already read into the PE2 buffer). PE4 parsing assumed `ENCRYPT(VC)` started immediately → `MalformedEncryption`.

**Fix:**

- [`src/peer.zig`](../src/peer.zig) `tryEncryptedHandshake` scans with `encryption.findVerificationConstant` over a PadB window, then parses PE4 from the VC offset
- Seed the PE4 sync buffer with any PadB bytes already read alongside Yb
- Integration harness sends Yb only, then PadB before PE4, so the initiator path is exercised end-to-end

### 2. PadB drain delayed PE3 by a full read timeout (fixed)

**Bug:** `readDhResponse` blocked up to `peer_request_timeout_ms` trying to drain PadB *before* sending PE3. Peers waiting on PE3 often hung up; later reads then failed as `MalformedEncryption` / EOF / `ReadFailed`.

**Fix:** Read at least Yb (96 bytes) and return immediately. Do not wait for more PadB. Leave PadB for PE4 VC sync.

### 3. Plaintext-within-MSE (`0x01`) decrypted the post-PE4 handshake (fixed)

**Bug:** [`parseResponderSync`](../src/encryption.zig) always RC4-decrypted the remote 68-byte handshake. Spec: after `crypto_select = 0x01`, payload is cleartext.

**Fix:** Decrypt the remote handshake only when scheme is RC4. Harness sends cleartext HS for `plaintext_only`.

### 4. Strict `crypto_select` rejected reserved bits (fixed)

**Bug:** Unknown high bits in `crypto_select` → `MalformedEncryption`. Transmission-style peers only require overlap with `crypto_provide`.

**Fix:** Mask to known bits (`0x01` / `0x02`); still require exactly one known scheme bit.

### 5. All due trackers announced in one tick (fixed)

**Bug:** `tickTrackerAnnounces` walked every due endpoint synchronously. Multi-tracker magnets blocked `show` for a long time even after the peer-connect-per-tick cap.

**Fix:**

- New limit `limits.max_tracker_announces_per_tick` (default `1`)
- UDP-then-HTTP order preserved; stop after N announce attempts
- Documented in [`docs/config.example.toml`](config.example.toml)

### 6. Misc MSE send shaping (fixed)

PE3 sync frame + encrypted IA are sent in one write so peers that read greedily see a complete step-3 payload.

## Remaining blockers (not fixed)

### A. No live metadata peer yet on this magnet from this network

After the fixes above, successful tracker announces and large candidate sets still yield `connected_peer_count=0` in short debug runs. Dominant errors are TCP `Timeout` / `ConnectionRefused`. Residual `MalformedEncryption` on a minority of peers that accept TCP still needs live diagnosis (stage-specific logging: PE2 short vs VC not found vs `crypto_select` / pad parse).

Do **not** reintroduce non-MSE plaintext fallback under `prefer`.

### B. Peer-connect batch still starves the control socket

Announce budget helped. Each tick can still spend up to `max_peer_connect_attempts_per_tick` × (connect + handshake read timeouts). `show` may still block for tens of seconds during metadata fetch.

### C. Environmental tracker / DHT noise

`UnknownHostName` (tiny-vps), intermittent UDP timeouts, DHT `get_peers` timeouts — same as prior handoff; not treated as client bugs.

## Files touched

- `src/peer.zig` — PE4 VC sync, no blocking PadB drain, PE3+IA single write, PadB seed from PE2 read
- `src/encryption.zig` — `0x01` cleartext HS; relaxed `crypto_select`; exported `vc_len` / `max_pad` / `pe4_sync_buf_len`; unit tests
- `src/integration_harness.zig` — PadB-before-PE4; cleartext HS for plaintext-within-MSE
- `src/engine.zig` — per-tick announce budget
- `src/config.zig` / `docs/config.example.toml` — `max_tracker_announces_per_tick`

## Suggested next steps

1. Add stage-tagged MSE failure logs (or counters) distinguishing PE2 short / VC miss / frame parse / HS mismatch so live `MalformedEncryption` is actionable.
2. Keep trying this magnet (and the Koori magnet from the encryption handoff) on a network with better peer reachability; confirm at least one `ut_metadata` session.
3. Optionally shorten metadata-handshake read timeouts or add a wall-clock tick budget so `show` stays responsive while still draining candidates.
4. Manual acceptance remains: `metadata_complete=true`, then content download for this single-file `.mkv`.
