# Handoff: live magnet add stuck in `fetching_metadata`

**Date:** 2026-07-14  
**Info hash:** `8ff2f0613abac28104998b4d349895dfb013b6c5`  
**Source:** Nyaa-style magnet with 8 `tr=` URLs (HTTP + HTTPS + UDP)  
**Environment:** local Debug build (`zig-out/bin/torrentd`), isolated config under `/tmp/nix-torrent-magnet-test/`, listen `16881`, DHT base `16882`, port mapping **off**

## Verdict

`torrent add <magnet>` succeeds at the control plane. Metadata never completes. Over multi-minute runs under both `encryption.policy = prefer` (default) and `disable`, the daemon kept **0 connected metadata peers** despite **50 tracker peer candidates**. The magnet path is broken end-to-end for this swarm primarily by unreachable peers + slow sequential dials, compounded by MSE interoperability failures under `prefer`, DHT `get_peers` never returning peers, and a DHT tick memory leak.

## What worked

| Step | Result |
|------|--------|
| Magnet parse | OK (`dn`, 8 trackers, info hash) |
| Control `add` | `ok: true`, lifecycle `active`, activity `fetching_metadata` |
| Registry / `list` / `show` / `status` | Responsive (control-plane worker OK) |
| HTTP announce `http://nyaa.tracker.wf:7777/announce` | OK, **50 peers**, interval ~1860s |
| DHT bootstrap | `status.dht.bootstrapped = true` (3 bootstrap nodes) |
| Inbound Listen Socket | Bound `[::]:16881` |
| LSD | Listening |

## Failure mode (symptoms)

After add, `show` stayed:

- `derived_activity`: `fetching_metadata`
- `metadata_complete`: `false`
- `connected_peer_count`: `0`
- `peer_candidate_count`: `50`
- `inbound_peer_count`: `0`
- `dht_last_error`: `dht get_peers failed: Timeout` (appears after first DHT lookup window)
- Trackers: **1× `ok`**, **7× `pending`** (never announced while cursor sticks on the working URL)

Never observed: `connected metadata peer …`, assembled metadata, or `metadata_complete: true`.

## Experiments

### A — `network.encryption.policy = "prefer"` (~3–4 min)

Peer dial error histogram (from live logs):

| Error | Count (approx) | Meaning |
|-------|----------------|---------|
| `Timeout` | majority | TCP connect / handshake wall clock exhausted |
| `ConnectionRefused` | few | peer port closed |
| `MseVcEof` | several | DH key received, then EOF while waiting for MSE VC |
| `MsePe2Short` | ≥1 | peer response shorter than 96-byte DH key and not a BT handshake (`0x13`) |
| `ShortRead` | ≥1 | mid-handshake disconnect |

**0** successful metadata connects. No `PeerNotMse` / `UnsupportedEncryption` lines — reachable peers that answered did not cleanly advertise “plain BT”; MSE negotiation failed mid-stream instead.

### B — `network.encryption.policy = "disable"` (~4.5 min)

| Error | Count |
|-------|-------|
| `Timeout` | 22 |
| `ConnectionRefused` | 3 |
| `MetadataHandshakeFailed` | 2 |

**0** successful metadata connects. Attempts remained ~27 over ~270s (~0.1 dial/s). Plaintext removes MSE errors but does **not** unblock metadata for this peer set; the few peers that accept TCP fail during LTEP/`ut_metadata` negotiation (EOF → `MetadataHandshakeFailed`).

Archived plaintext log: [`2026-07-14-magnet-plaintext-daemon.log`](./2026-07-14-magnet-plaintext-daemon.log).  
Prefer-run exit dump (DebugAllocator leaks, including DHT tick): [`2026-07-14-magnet-prefer-exit-leaks.log`](./2026-07-14-magnet-prefer-exit-leaks.log).

## Ranked issues for the next agent

### 1. Dead/unreachable peer set + blocking dial budget (P0)

Most of the 50 compact peers from Nyaa are NAT’d/offline. Each failed dial can burn `peer_connect_timeout_ms` (10s). `connectCandidateBatch` does **serial** connects, capped by `max_peer_connect_attempts_per_tick` (5) and `peer_connect_batch_budget_ms` (15s). Result: crawling through dead addresses for minutes with almost no successful BT/LTEP handshakes.

**Evidence:** 50 candidates constant; ~15–27 dial failures over several minutes; 0 connects under both policies.

**Next steps:** parallel dials or much shorter connect timeouts for metadata; demote/cooldown failed addresses; prefer candidates that previously completed MSE/BT; surface dial attempt rate on `show`.

### 2. MSE `prefer` fails against live peers that partially speak (P0 for default config)

Per CONTEXT.md / ADR posture, `prefer` **never** falls back to a raw BitTorrent handshake. Live failures were not clean `PeerNotMse` detections but `MseVcEof` / `MsePe2Short` — suggesting DH-looking bytes or truncated noise rather than a clean `0x13` handshake probe, or peers that abort MSE mid-handshake.

**Evidence:** Prefer run produced MSE-specific failures; plaintext A/B still failed, so MSE is not the sole cause — but default `prefer` adds a hard filter for any non-MSE peer and freights MSE parse bugs onto peers that might work with plaintext.

**Next steps:** Harmonize with ADR 0004 “refine against live swarms”: instrument first bytes of PE2; retry once with plaintext on `MsePe2Short`/`MseVcEof` when policy is `prefer` (policy design change — currently forbidden); or shorten MSE read timeouts separately from TCP connect timeout.

### 3. DHT `get_peers` returns nothing (P0 for magnet diversity)

`dht_last_error` sticks at `dht get_peers failed: Timeout`. Bootstrap reports success, but lookups against routing-table nodes time out; candidate count never grows beyond the single tracker’s 50 peers. Lookup interval is 60s (`lookup_interval_ms`), so recovery is slow.

**Evidence:** `status.dht.bootstrapped: true` + per-torrent `dht_last_error: Timeout`; no `DHT returned N peers` log lines.

**Next steps:** Verify UDP reachability / firewall; widen or multi-hop get_peers (more than top-3 nodes); distinguish “no values yet” from “all RPCs timed out”; ensure announce_peer / token path doesn’t block values collection.

### 4. DHT tick leaks `BootstrapTarget` buffer every successful routing-table lookup (P1)

In `dht.zig` `tick`:

```zig
const targets = if (routing.nodes.items.len > 0) blk: {
    var converted = try allocator.alloc(BootstrapTarget, slice.len);
    // ...
    break :blk converted;
} else try parseBootstrapNodes(...);

defer if (routing.nodes.items.len == 0) allocator.free(targets);
```

When the routing table is non-empty, `converted` is allocated and **never freed**. DebugAllocator dumps on daemon exit repeatedly cite `dht.zig:153` via `peer_pool.tickDht` → `metadata_fetch.tickDht`.

**Next steps:** Always `defer allocator.free(targets)` (or free both arms symmetrically). Easy isolated fix + unit test.

### 5. Magnet BEP 12: only one tracker ever announces (P2, intentional but costly)

Magnet `tr=` URLs form one synthetic tier. After the first announce succeeds, the cursor stays on that URL until the long interval elapses (~31 min). The other 7 trackers remain `pending` with `next_announce: 0` forever in practice.

**Evidence:** `show.trackers` → 1 `ok` / 7 `pending`; logs show a single `tracker announce ok`.

**Next steps:** For magnet metadata discovery, consider parallel/multi-tracker announce (or announce all URLs once on first meta fetch) rather than strict single-URL BEP 12 failover — diversity matters more than interval fidelity before metadata exists.

### 6. Metadata LTEP negotiation is brittle (P2)

`negotiateMetadataAfterHandshake` loops until `ut_metadata_id` is set. Peers that complete BT handshake then close → `MetadataHandshakeFailed`. Peers advertising LTEP without `ut_metadata`+`metadata_size` yield `null` from `parsePeerExtendedHandshake`; assigning `ut_metadata_id = null` leaves the wait loop spinning until EOF/timeout rather than returning `MetadataUnsupported` immediately.

**Evidence:** Plaintext run: 2× `MetadataHandshakeFailed`, 0× `MetadataUnsupported`.

**Next steps:** Treat missing `ut_metadata` as hard `MetadataUnsupported`; add a dedicated handshake read deadline; log peer extended-handshake keys for live diagnosis.

### 7. No inbound path helping metadata (P3 for this repro)

Port mapping was disabled for the test; home-lab NAT likely blocks inbound. Swarms dominated by firewalled peers need outbound success or DHT+PEX diversity. Re-test later with `port_mapping.enabled = true` once outbound metadata works.

### 8. Shutdown leaks from magnet add path (P3)

DebugAllocator on exit also reported leaks from `addMagnet` / `buildTrackerRecords` (tracker URL dupes, display name). Likely incomplete session teardown on kill — note if remove/shutdown should free Registry + session tracker records.

## Suggested fix order

1. Fix DHT `BootstrapTarget` leak (`dht.zig` free path) — small, deterministic.
2. Speed up / parallelize metadata peer dials + shorten connect timeout for metadata mode.
3. Make DHT get_peers actually refill candidates (instrument node RTT / values).
4. Soften or diagnose MSE `prefer` mid-handshake failures against live peers (ADR 0004 refinement).
5. Magnet-phase multi-tracker announce for peer diversity.
6. Harden `negotiateMetadataAfterHandshake` unsupported/`MetadataUnsupported` exit.

## Repro

```sh
# config: staging/final/socket under /tmp/nix-torrent-magnet-test, listen_port=16881,
# port_mapping.enabled=false, logging.level=debug
zig build
./zig-out/bin/torrentd --config /tmp/nix-torrent-magnet-test/config.toml &
./zig-out/bin/torrent --config /tmp/nix-torrent-magnet-test/config.toml add 'magnet:?xt=urn:btih:8FF2F0613ABAC28104998B4D349895DFB013B6C5&...'
./zig-out/bin/torrent --config /tmp/nix-torrent-magnet-test/config.toml show 8ff2f0613abac28104998b4d349895dfb013b6c5
# watch peer_candidate_count / connected_peer_count / metadata_complete / dht_last_error
# and daemon log lines: tracker announce ok | metadata peer connect failed | DHT returned
```

## Out of scope / not observed

- Piece download / handoff (never left metadata fetch)
- HTTPS tracker announce behavior (`tracker.nekobt.to` never attempted)
- UDP tracker path (same — never attempted while HTTP tier-0 cursor held)
- Inbound metadata attach
