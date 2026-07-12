# Handoff: why no data — peer reachability on Sayonara Lara magnet

Date: 2026-07-12  
Follows: [`handoff-magnet-mse-padb-sync.md`](handoff-magnet-mse-padb-sync.md)  
Torrent under test: `[Erai-raws] Sayonara Lara - 02 ...`  
Info hash: `eb91484e28cbb4a6bfbbd2d34eb3203f335cea56`

## Summary

A ~10 minute live `prefer` run after post-connect metadata fixes still never receives metadata or content bytes. **Discovery works; the pipeline dies before any `ut_metadata` peer is established.** Outbound TCP to swarm peers is the dominant failure (`Timeout` ≈ 66% of attempts). A minority accept TCP then fail MSE before the extended handshake. Zero `connected metadata peer` / `received metadata piece` / `metadata complete` log lines.

Content download cannot start until `metadata_complete=true`. This run never left `fetching_metadata` with `total_bytes=0`.

## Why data is not received (pipeline)

Magnet → content is a strict funnel. This run stalled at step 2–3:

| Step | What must happen | This run |
|------|------------------|----------|
| 1. Announce | Trackers/DHT return peer candidates | **OK** — 183 unique candidates merged from UDP trackers |
| 2. TCP connect | Outbound connect within `peer_connect_timeout_ms` (10s) | **Mostly fail** — `Timeout` / `ConnectionRefused` |
| 3. MSE + BT handshake | PE1–PE4 + BitTorrent handshake | **Rarely reached; all fail** — `MseVcNotFound` / `ShortRead` / `MsePe2Short` |
| 4. Ext + `ut_metadata` | Extended handshake, request piece 0 | **Never** — no `connected metadata peer` |
| 5. Metadata assemble | Pieces hash to info-hash → layout | **Never** — `metadata_complete=false` |
| 6. Content pieces | Bitfield / request / piece messages | **Never** — gated on step 5 |

So “no data” is not a piece-scheduler or storage bug. The daemon never gets a peer far enough to send or receive application payload (`ut_metadata` data, then later piece messages).

```text
candidates (183)
    │
    ▼
TCP connect ──Timeout/Refused──► drop (~72%)
    │ accept
    ▼
MSE/HS ──MseVcNotFound/ShortRead/Pe2Short──► drop (~28% of attempts)
    │ success
    ▼
ut_metadata  ◄── never reached this run
```

## Live failure mix (~10 min, encryption.policy = prefer)

47 metadata connect attempts (unique peers ≈ attempts):

```text
31 Timeout              # TCP connect did not complete in 10s
 7 MseVcNotFound        # TCP up; PE2 ok; ENCRYPT(VC) missing or peer EOF mid-PE4
 5 ShortRead            # socket closed / read error during handshake I/O
 3 ConnectionRefused    # peer (or middlebox) reset SYN
 1 MsePe2Short          # peer closed before full Yb (96 bytes)
 0 connected metadata peer
 0 received metadata piece
```

`Timeout` + `ConnectionRefused` = **peer unreachable from this host** (NAT, firewall, dead tracker entries, peer not listening). That is the primary explanation for no bytes.

Among peers that *did* accept TCP, MSE still never completed. Stage-tagged errors replaced the old opaque `MalformedEncryption` bucket:

- `MseVcNotFound` — PE3 sent; VC scan exhausted PadB window without finding ENCRYPT(VC)
- `MseVcEof` — peer hung up mid-VC scan (`n == 0` before window full)
- `ShortRead` — lower-level read failure during MSE/BT handshake
- `MsePe2Short` — incomplete DH public key

Until at least one attempt reaches `connected metadata peer`, residual MSE is secondary to reachability.

## What *did* work

- Magnet add → `fetching_metadata`
- UDP announces: Anirena (72), open.stealth.si (50), torrent.eu.org (50), opentrackr (50 after retries)
- Candidate merge + unroutable filter (prior handoff)
- MSE PadB / PE3 timing fixes (prior handoff); stage-tagged MSE errors (this session)
- Post-connect metadata fixes so a successful TCP+MSE peer would not stall on bitfield / leftover-buffer piece-0 skip (this session; untested live because no peer completed handshake)

## Amplifiers (not the root “no data” cause, but they slow diagnosis)

### HTTP trackers starved this run

`max_tracker_announces_per_tick = 1` plus long blocking peer-connect batches meant **nyaa** and **acgnx** never got `started_sent=true` in ~10 minutes (still pending in `state.json`). UDP already supplied 183 candidates, so missing HTTP peers does not explain zero data — but it does shrink the reachable subset and delays known-good HTTP peer lists from earlier handoffs.

**Follow-up:** default raised to `4` so a typical multi-tracker magnet clears the initial UDP wave and reaches HTTP within one or two ticks instead of waiting behind every UDP `started` announce.

### Control socket blocked during connect batch

`show` can hang while the engine tick runs outbound connect+handshake work. Attempt count alone still allowed up to `max_peer_connect_attempts_per_tick` × (10s connect + handshake reads).

**Follow-up:** `network.peer_connect_batch_budget_ms` (default `15000`) caps wall time after the first attempt so ticks return sooner; remaining candidates are tried on later ticks.

### Tracker noise

- `tracker.tiny-vps.com` → `UnknownHostName` (unchanged)
- Intermittent opentrackr UDP timeouts before eventual success

## Fixes landed this session (supporting, not sufficient)

| Fix | Why it matters once a peer is reachable |
|-----|----------------------------------------|
| Send our extended handshake first; skip bitfield/have while waiting for theirs | Avoids ext-handshake deadlock / zombie peers with `ut_metadata_id == null` |
| Always `requestMetadataPiece` after connect | Leftover recv bytes no longer skip piece 0 |
| `connected_peer_count` includes `metadata_peers` | `show` / projection no longer hides metadata connections |
| MSE errors: `MsePe2Short` / `MseVcNotFound` / `MseVcEof` / `MsePe4Parse` / `MseHandshakeEof` | Live residual encryption failures are actionable |

Do **not** reintroduce non-MSE plaintext fallback under `prefer`.

## How to reproduce

```sh
zig build -Doptimize=Debug
# config: logging.level=debug, network.encryption.policy=prefer,
#         peer_connect_timeout_ms=10000, max_peer_connect_attempts_per_tick=5,
#         max_tracker_announces_per_tick=4 (was 1; raises HTTP past initial UDP wave)
./zig-out/bin/torrentd --config /tmp/nix-torrent/config.toml > /tmp/nix-torrent/daemon.log 2>&1 &
./zig-out/bin/torrent --config /tmp/nix-torrent/config.toml add 'magnet:?xt=urn:btih:EB91484E28CBB4A6BFBBD2D34EB3203F335CEA56&dn=...&tr=...'

# Prefer logs over show while metadata fetch is busy:
rg 'announce ok|merged|connected metadata peer|received metadata piece|metadata complete' /tmp/nix-torrent/daemon.log
rg 'metadata peer connect failed' /tmp/nix-torrent/daemon.log | sed 's/.*: //;s/"\}//' | sort | uniq -c | sort -rn
```

Success signals (none seen this run):

```text
connected metadata peer ...
received metadata piece ...
metadata complete ...
# state.json: metadata_complete=true, total_bytes > 0
```

## Suggested next steps

1. **Confirm network class** — From the same host, compare with a known-working client (Transmission/libtorrent) on this magnet. If that client also cannot connect outbound to the swarm, treat as environment (CGNAT / firewall / ISP). If it can, capture which peer IPs succeed and diff against our candidate drain order / encryption policy.
2. **Reachability probe** — Optional one-shot TCP dialer against the candidate list (no MSE) to measure accept rate independent of encryption; use that to decide whether further MSE work is worth it on this network.
3. Manual acceptance unchanged: `metadata_complete=true`, then content download of the single-file `.mkv`.

Done in follow-up (this branch): announce budget default `4`; `MseVcEof` split from `MseVcNotFound`; `peer_connect_batch_budget_ms` wall-clock cap on connect batches.

## Bottom line

**No payload is received because no peer completes the connect → MSE → `ut_metadata` path.** Tracker discovery is fine. From this network, most swarm addresses never accept TCP; the few that do still die in MSE. Until `connected metadata peer` appears in the log, there is nothing for the metadata or piece layers to read.
