# Nix Torrent v3 Plan

Close BitTorrent protocol gaps and home-lab reachability, then harden operability.

## Scope

- **Inbound listen, no seeding:** open a BitTorrent TCP listener; accept inbound peers for download only. Stay choked and close on `request`. Use DHT `announce_peer` so the swarm can find the listen port.
- **Milestone order:** dual-stack + Listen Socket + IPv4 Port Mapping first (so inbound is reachable), then remaining protocol features, then control-plane and observability polish.
- **Control protocol:** bump to version **3** at the first breaking Control Surface change (Milestone 2: Listen Socket / inbound fields in `status`/`show`). Later v3 milestones may add fields under version 3 without further bumps. CLI and daemon must be built together and reject version mismatch.

Domain language lives in [`CONTEXT.md`](../CONTEXT.md). **Listen Socket**, **Listen Port**, **DHT Port**, **Inbound Peer Connection**, **Port Mapping**, and **Tracker Tier** are defined there; Seeding remains out of scope.

## Starting point

The daemon already:

- Runs as `torrentd` with CLI control over a Unix socket (JSON-line protocol).
- Persists staging state, peer ID, and completion history; hands off verified content.
- Announces to HTTP and UDP trackers; discovers peers via DHT `get_peers` (lookup-only).
- Connects outbound over TCP with MSE (`disable` / `prefer` / `require`).
- Adds `.torrent` files and magnets; fetches metadata via `ut_metadata`.
- Downloads, verifies, and writes pieces into the staging area.

Still missing for protocol completeness and home-lab swarm use:

- IPv6 peers and sockets
- Inbound peer accept (download-only) and IPv4 NAT Port Mapping
- DHT `announce_peer`
- Peer exchange (`ut_pex`) and local service discovery (LSD)
- HTTPS trackers and Tracker Tier failover (`announce-list` / magnet `tr=`)
- LTEP on content connections beyond magnet-only metadata
- Non-blocking control plane under connect/announce load
- Stronger swarm observability and MSE interop under adversarial peers

## Goals

1. Expand the BitTorrent surface that blocks real swarms.
2. Accept inbound peers for downloading without uploading piece data.
3. Make the Listen Port reachable on typical IPv4 NAT home labs (Port Mapping).
4. After that, finish remaining protocol features and make multi-torrent operation reliable and operable.

## Non-goals

- Seeding / upload of piece data
- Web UI
- Partial file selection / streaming
- uTP
- Full extension protocol beyond discovery and magnet health
- Replacing the Unix-socket control surface with HTTP/REST
- TLS `insecure_skip_verify` for trackers

---

## Milestone 1: IPv6 peers and dual-stack sockets

Trackers and DHT already return IPv6 peers; ignoring them wastes reachable candidates.

### Tasks

- Parse tracker compact `peers6` and dictionary IPv6 peers; store peer addresses as dual-stack.
- Resolve AAAA for tracker and DHT bootstrap hosts where useful; keep the IPv4 path working.
- Outbound connect to IPv6 endpoints with the same timeouts and budgets as IPv4.
- Dual-stack types and codecs land here so Milestone 2 can bind a dual-stack Listen Socket without revisiting address representation.
- Extend DHT compact node/peer codecs for IPv6 (BEP 32 subset: compact peer and node formats used by public nodes).
- Surface address family in `show` peer details when present.

### Acceptance

- Fake IPv6 tracker peer and fake IPv6 content peer: full download in the integration harness.
- IPv4-only torrents unchanged.

---

## Milestone 2: Inbound peer listener (download-only)

### Design

- Bind one daemon-wide dual-stack TCP **Listen Socket** to the unspecified address (`::` / dual-stack any) on `network.listen_port` at **daemon startup** (not only while torrents are active). Keep it for the daemon lifetime. No per-interface `listen_address` knob in v3. Tracker `port=` and DHT `announce_peer` advertise that **Listen Port** only — never a DHT Port. Inbound connections whose info hash is not an eligible active session still close after handshake.
- Defaults: `listen_port = 6881`, `dht_base_port = 6882`. Keep per-torrent DHT UDP on `dht_base_port + slot`. Config must reject overlap between `listen_port` and the DHT port range `dht_base_port .. dht_base_port + max_active_torrents - 1`.
- TCP and UDP never share a port number; advertised TCP port always equals the bound Listen Port.
- Accept inbound connections under the same Encryption Policy as outbound. For MSE (`prefer` / `require`), after DH probe the sync against each active eligible torrent’s info hash (download or fetching metadata), then finish negotiation with the match; close if none match or the scheme is unacceptable. For `disable`, demux with a plaintext BitTorrent handshake. Do not accept a raw BitTorrent handshake under `prefer` / `require`.
- After a successful handshake, attach only when that session is **active** and either downloading content or fetching metadata. Close for paused, failed, completed/history-only, or unknown info hashes.
- Treat an accepted inbound peer as a normal download peer: send `interested`, request blocks (or `ut_metadata` while fetching metadata), stay choked, close on `request`.
- Cap peers with **split limits**: outbound ≤ `max_peers_per_torrent` (default 50), inbound ≤ `max_inbound_peers_per_torrent` (default **20**). Daemon-global `max_inbound_handshakes` (default **32**) caps concurrent inbound handshake/MSE probes before attach.
- Do not serve piece data.
- ADR: separate Listen Port from DHT Ports (replaces today’s dual-use of `dht_base_port` as tracker announce port).

### Acceptance

- A fake inbound peer initiates to `listen_port` over IPv4 and over IPv6; the daemon downloads and completes a fixture torrent in both cases.
- Tracker announces and `announce_peer` report `listen_port`, not `dht_base_port + slot`.
- Policies `require`, `prefer`, and `disable` behave for inbound MSE consistently with outbound semantics.
- `status` / `show` report Listen Port, inbound counts, and related limits; **control protocol version is 3** from this milestone onward.

---

## Milestone 3: IPv4 port mapping (UPnP / NAT-PMP)

Home-lab IPv4 is usually behind NAT. A Listen Socket without a mapping is unreachable from most of the swarm. This milestone follows Listen Socket immediately so later discovery work advertises a reachable port.

### Tasks

- On daemon startup (with the Listen Socket), request an IPv4 port mapping for the **Listen Port** via **NAT-PMP/PCP first**, then fall back to **UPnP IGD** if that fails.
- When DHT is enabled, also map active **DHT Ports** (UDP) for DHT-eligible torrents as slots are bound, using the same protocol order; remove mappings on pause/remove/shutdown as applicable.
- Renew mappings before lease expiry; clear mappings on clean daemon shutdown.
- Config: `[network.port_mapping] enabled = true` (default on); optional `protocols = ["natpmp", "upnp"]` defaulting to that order. Allow disable for hosts with a public IP or manual forwards.
- Surface mapping state in `status` / `show` (mapped vs failed vs disabled), without requiring log diving.
- IPv6 Listen Socket remains dual-stack bind only for this milestone (no UPnP requirement for v6).

### Acceptance

- Against a fake/local gateway harness (or integration double): Listen Port TCP mapping is created and reported as active.
- DHT UDP mapping created when a DHT socket opens and removed when the slot is released.
- With `port_mapping.enabled = false`, no gateway requests are made.
- Mapping failure does not crash the daemon; inbound from the LAN and outbound download still work.

---

## Milestone 4: DHT `announce_peer`

Without announcing, the inbound listener is mostly invisible to DHT-only peers.

### Tasks

- On DHT-eligible active torrents, send `announce_peer` with the daemon **Listen Port** (explicit port) after a successful `get_peers` when a write token is available. DHT traffic still uses that torrent’s DHT Port.
- Respect private torrents and `network.dht.enabled`.
- Pause stops announce activity and closes the torrent DHT socket; remove releases the slot (existing slot allocator).

### Acceptance

- A fake DHT node receives `announce_peer` advertising `listen_port` for a test info hash, sourced from the daemon’s per-torrent DHT socket.
- Private torrents and DHT-disabled config produce zero announces.

---

## Milestone 5: Peer exchange (`ut_pex`) and LSD

### Tasks

- On metadata and content connections, set the LTEP bit when PEX is enabled; **consume** `ut_pex` on both and merge candidates into the peer candidate set.
- **Emit** `ut_pex` only on content connections (currently connected content peers); do not emit from metadata-only connections.
- Implement BEP 14 LSD multicast announce/listen on the LAN for non-private torrents; merge candidates into the existing peer candidate set.
- Private torrents: no PEX, no LSD, no DHT (including `announce_peer`). Listen Socket may still accept inbound for private torrents learned via Trackers.
- Config toggles: `[network.pex] enabled`, `[network.lsd] enabled` — **both default true**; still forced off for private torrents.

### Acceptance

- A fake metadata peer sends PEX; the daemon dials a new metadata candidate.
- A fake content peer sends PEX; the daemon dials a new content candidate and downloads.
- Two local harness processes discover each other via LSD without trackers.
- Private torrent sessions never send or handle PEX/LSD/DHT.

---

## Milestone 6: HTTPS trackers and Tracker Tier failover

### Tasks

- HTTPS tracker announces (TLS) with configured timeouts. Trust the **system CA store**, plus an optional `network.tracker_ca_file` for an extra CA PEM (home-lab / private trackers). **No** `insecure_skip_verify` in v3.
- Unify announce scheduling on **Tracker Tier** failover (BEP 12):
  - `.torrent` `announce-list` → real tiers; a lone top-level `announce` is one single-URL tier.
  - Magnet `tr=` → one synthetic tier in URI order (same failover rules; not parallel announce-to-all).
- Within the current tier, announce **strictly sequentially**: at most one in-flight announce per torrent for the tier. On failure: **one retry** after `tracker_retry_min_ms`, then fail over to the next URL. On success, prefer that tracker until it fails. When failing over away from a tracker that previously received `event=started`, send best-effort `event=stopped` to it before `started` on the next URL (failover is not blocked if `stopped` fails). Advance to the next tier only when the current tier has no usable tracker. Do not parallel-announce the whole tier.
- Unsupported schemes in a tier are skipped; if a tier has no supported schemes, advance. Reject with `no_discovery_source` when no supported tracker remains and DHT is not available.
- DHT, PEX, and LSD stay independent of Tracker Tier failover (they are separate discovery paths).
- Surface current tier / per-URL state in `show`.

### Acceptance

- A local TLS fake tracker returns peers; the daemon completes a download.
- A torrent with only `announce-list` adds successfully when some tier contains supported `http`/`https`/`udp` URLs.
- Integration: two-tier `.torrent` does not announce to tier 1 while tier 0 still has a working tracker; advances after tier 0 is exhausted under backoff policy.
- Integration: magnet with multiple `tr=` announces in URI order with failover, not to all URLs every tick.

---

## Milestone 7: Extension protocol scope

Keep metadata fetch on dedicated connections (`ut_metadata`). Content connections use LTEP for PEX emit/consume; metadata connections use LTEP for `ut_metadata` plus PEX **consume** only (milestone 5).

### Tasks

- Advertise LTEP on metadata and content connections when those extensions are needed.
- Ignore unknown extension IDs cleanly; never upload piece data via extension messages.
- Document the split: metadata connections (`ut_metadata` + PEX consume) vs content connections (PEX consume + emit).

### Acceptance

- Integration: content peer with LTEP+PEX; magnet metadata path still works and can consume PEX.
- Unknown extension messages do not crash the session.

---

## Milestone 8: Non-blocking control plane

### Tasks

- Run the engine on a **worker thread** with a **command queue**. Control Surface handlers enqueue add/pause/resume/remove/… and wait for a worker ack; they do not run `engine.tick` or peer/tracker I/O on the accept loop.
- Preserve **Registry Projection**: Control Surface reads only projected `TorrentRecord` / history (snapshot or lock around projection publish). Do not read live `TorrentSession` fields from the control thread.
- Guarantee `torrent status` and `show` respond within 500ms under load in integration tests.
- Fair-schedule announce and connect budgets across torrents (still useful under Tracker Tier failover when many torrents are active).

### Acceptance

- Stress test with many slow fake peers: `show` stays under 500ms.
- Under default budgets, active torrents still make announce and connect progress.
- ADR if the queue/snapshot locking model is non-obvious at implement time.

---

## Milestone 9: Swarm reliability and observability

### Tasks

- Harden MSE interop (variable pads, stage-tagged errors); expand harness adversarial cases.
- Peer scoring: deprioritize peers with repeated connect timeouts or refusals.
- Richer `show`: per-tracker success, candidate counts, connect failure histogram, encryption mode counts, listen/inbound stats, DHT announce state, port-mapping state.
- Document a manual smoke procedure for a public magnet (not required in CI).

### Acceptance

- Harness covers adversarial MSE pads and mixed inbound/outbound swarms.
- `show` exposes enough to diagnose stalled downloads without log archaeology.

---

## Milestone 10: Docs and config sync

### Tasks

- Keep README status aligned with shipped behavior.
- Sync `docs/config.example.toml` for `listen_port`, `dht_base_port`, port mapping, `max_inbound_peers_per_torrent`, encryption, listen limits, PEX, LSD, and HTTPS-related timeouts.
- ADR for Listen Port vs DHT Ports (milestone 2); document tracker CA file in config example (no separate ADR unless skip-verify is ever reconsidered).

### Acceptance

- A new operator can configure listen, DHT, port mapping, encryption, PEX, and LSD from the example TOML alone.

---

## Implementation order

1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10

(IPv6 → Listen → Port Mapping → announce_peer → PEX/LSD → HTTPS/tiers → LTEP scope → control plane → observability → docs)

## Definition of done

```sh
torrentd --config /path/to/config.toml
torrent --config /path/to/config.toml add ./dual-stack.torrent
torrent --config /path/to/config.toml add 'magnet:?xt=urn:btih:...'
torrent --config /path/to/config.toml show <info-hash>
```

The daemon can:

- listen for inbound peers on a dual-stack Listen Socket and download from them without uploading pieces,
- map the Listen Port (and DHT Ports) through IPv4 NAT via UPnP/NAT-PMP when enabled,
- announce to DHT so inbound discovery works,
- use IPv6, PEX, and LSD as additional discovery,
- announce to HTTPS trackers with Tracker Tier failover,
- keep the control surface responsive during swarm work,
- hand off verified content with no seeding after completion.
