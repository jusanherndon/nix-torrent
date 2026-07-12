# Handoff: magnet metadata fetch for Sayonara Lara 02

Date: 2026-07-12  
Torrent under test: `[Erai-raws] Sayonara Lara - 02 ...`  
Info hash: `eb91484e28cbb4a6bfbbd2d34eb3203f335cea56`

Magnet:

```text
magnet:?xt=urn:btih:EB91484E28CBB4A6BFBBD2D34EB3203F335CEA56&dn=%5BErai-raws%5D%20Sayonara%20Lara%20-%2002%20%5B1080p%20CR%20WEB-DL%20AVC%20AAC%5D%5BMultiSub%5D%5BD8961E66%5D.mkv&tr=http%3A%2F%2Fnyaa.tracker.wf%3A7777%2Fannounce&tr=https%3A%2F%2Ftracker.nekobt.to%2Fapi%2Ftracker%2Fpublic%2Fannounce&tr=udp%3A%2F%2Ftracker-udp.anirena.com%3A80%2Fannounce&tr=udp%3A%2F%2Fopen.stealth.si%3A80%2Fannounce&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce&tr=udp%3A%2F%2Ftracker.tiny-vps.com%3A6969%2Fannounce&tr=http%3A%2F%2Ftracker.acgnx.se%2Fannounce
```

## Summary

`torrent add` of this magnet succeeded and entered `fetching_metadata`. The daemon stayed up (no panic). Metadata never completed in a ~3 minute debug run: zero connected metadata peers, zero `ut_metadata` pieces.

Two concrete bugs were found and fixed in-tree. A third class of failures (`MalformedEncryption` after TCP connect) remains and matches the open MSE work in [`handoff-peer-encryption-crash.md`](handoff-peer-encryption-crash.md).

## How to reproduce

```sh
zig build -Doptimize=Debug
mkdir -p /tmp/nix-torrent/{staging,downloads}
# config: logging.level = "debug", network.encryption.policy = "prefer"
./zig-out/bin/torrentd --config /tmp/nix-torrent/config.toml > /tmp/nix-torrent/daemon.log 2>&1 &
./zig-out/bin/torrent --config /tmp/nix-torrent/config.toml add 'magnet:?xt=urn:btih:EB91484E28CBB4A6BFBBD2D34EB3203F335CEA56&...'
./zig-out/bin/torrent --config /tmp/nix-torrent/config.toml show eb91484e28cbb4a6bfbbd2d34eb3203f335cea56
```

## Observed behavior (before fixes)

| Stage | Result |
|-------|--------|
| Magnet parse / add | OK — 7 trackers kept (`https://tracker.nekobt.to/...` dropped as unsupported) |
| UDP Anirena / open.stealth.si | OK — 72 and 50 peers |
| HTTP nyaa.tracker.wf | Fail — `InvalidToken` |
| UDP tiny-vps | Fail — `UnknownHostName` |
| UDP opentrackr / sometimes torrent.eu.org | Fail — `Timeout` |
| HTTP acgnx.se | OK — 2 peers (`127.0.0.1`, `255.255.255.255`) |
| DHT `get_peers` | Fail — `Timeout` |
| Peer TCP | Mostly `Timeout` / `ConnectionRefused` |
| Metadata | Stuck — `metadata_complete=false`, `connected_peer_count=0` |

Control socket often blocked for minutes during the first engine tick (tracker timeouts + peer connect attempts).

## Root causes and fixes applied

### 1. Peer candidates discarded after each announce (fixed)

**Design (V2_NETWORK_PLAN):** merge tracker/DHT peers into one deduplicated candidate set and drain connects across ticks.

**Bug:** `announceTrackerEndpoint` called `connectMetadataBatch` immediately, tried at most `max_peer_connect_attempts_per_tick` (5) peers, then dropped the rest. Successful trackers schedule the next announce ~30 minutes later, so the remaining ~67 Anirena peers were never retried.

**Fix:**

- `TorrentSession.peer_candidates` + round-robin `peer_candidate_cursor`
- `peer_pool.mergeCandidates` / `connectCandidateBatch`
- Announce and DHT paths only merge; each metadata/content tick drains up to 5 connects from the shared set
- Filter unroutable peers (`127/8`, `0/8`, `255.255.255.255`, port 0)
- Cap candidates at 512

**Log signature after fix:**

```text
tracker announce ok for udp://tracker-udp.anirena.com:80/announce: 72 peers
merged 71 peer candidates for eb91484e... (71 total)
merged 40 peer candidates for eb91484e... (111 total)
```

### 2. HTTP tracker announce used HTTP/1.0 (fixed)

**Bug:** `announceGet` sent `HTTP/1.0`. nyaa.tracker.wf responds:

```text
HTTP/1.1 505 HTTP Version Not Supported
<body starting with <h1>...>  → bencode InvalidToken
```

**Fix:** send `HTTP/1.1` with existing `Host` + `Connection: close`. Confirmed live: HTTP/1.0 → 505 HTML; HTTP/1.1 → 200 bencode peers (50 peers merged).

**Log signature before fix:**

```text
HTTP announce parse failed for nyaa.tracker.wf:7777: InvalidToken
(body_len=112, prefix=<h1>HTTP Version Not Supported</h1><p>This serve)
```

### 2b. HTTP/1.1 chunked responses not decoded (fixed)

After switching to HTTP/1.1, `tracker.acgnx.se` returned `Transfer-Encoding: chunked`. Body prefix looked like `5a\r\nd8:complete...`, which failed bencode as `InvalidStringLength`.

**Fix:** `tcp.extractHttpBody` decodes chunked bodies when `Transfer-Encoding: chunked` is set and `Content-Length` is absent.
### 3. Mid-tick logs not flushed (fixed)

Debug lines during long ticks sat in the stderr writer buffer until tick end. `log.flush()` now runs after peer connect failures so live debugging shows progress.

## Remaining blockers (not fixed)

### A. MSE handshake failures (`MalformedEncryption`)

After the candidate-set fix, some peers accept TCP and fail during MSE:

```text
metadata peer connect failed 47.151.96.47:18350: MalformedEncryption
metadata peer connect failed 143.223.99.53:41604: MalformedEncryption
metadata peer connect failed 89.141.31.140:6888: MalformedEncryption
```

Under `prefer`, non-MSE peers that answer with a raw BitTorrent handshake (`0x13`) become `UnsupportedEncryption` and are skipped (by design — see encryption handoff). `MalformedEncryption` means the peer spoke something else / truncated DH / failed responder-frame parse. Full-spec MSE work in milestone 11 / [`handoff-peer-encryption-crash.md`](handoff-peer-encryption-crash.md) is still the path forward. Do **not** reintroduce non-MSE plaintext fallback under `prefer`.

### B. Long engine ticks still starve the control socket

Even with 5 connects/tick, a tick that also retries several failed trackers (each up to `tracker_request_timeout_ms`) can block `show`/`status` for tens of seconds. Candidate drain helped vs 5×N_trackers connects, but announce I/O is still synchronous inside `engine.tick()`.

### C. DHT and some UDP trackers unreliable from this network

`dht get_peers` timed out; `tracker.tiny-vps.com` does not resolve here; opentrackr often times out. Not necessarily client bugs.

## Files touched

- `src/engine_session.zig` — candidate list on session
- `src/peer_pool.zig` — merge / drain / routability filter + tests
- `src/engine.zig` — call `connectCandidateBatch` once per tick
- `src/tracker.zig` — HTTP/1.1; parse-failure body preview log
- `src/tcp.zig` — chunked `Transfer-Encoding` body decode
- `src/log.zig` — `flush()`
- `build.zig` — register `peer_pool` and `tcp` tests

## Suggested next steps

1. Re-run this magnet on the fixed binary; confirm nyaa announce succeeds and candidate count grows from that tracker.
2. Continue MSE full-spec work until `MalformedEncryption` / `UnsupportedEncryption` rates drop on live anime swarms; keep policy table from the encryption handoff.
3. Optionally move tracker announce I/O or peer connects off the control-accept path (or shorten per-tick announce budget) so `show` stays responsive during metadata fetch.
4. Manual acceptance: metadata session reaches `metadata_complete=true`, then content download / handoff for this single-file `.mkv`.
