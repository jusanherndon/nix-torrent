# Nix Torrent v2 Plan — Network and Discovery

Program v2 is split across two plans. This document covers milestones 9–13: UDP trackers, mainline DHT, protocol encryption, and magnet links. The download daemon foundation (daemon transport, persistence, storage, HTTP trackers, peer TCP, engine, handoff, and initial integration tests) is in [V2_PLAN.md](V2_PLAN.md) as milestones 1–8.

## Goal

Complete program v2 by extending the download daemon with network and discovery features that were deferred from the initial v2 foundation.

The full v2 program should:

1. Accept CLI commands over a Unix domain socket.
2. Persist active torrent state.
3. Maintain a stable BitTorrent peer ID across daemon restarts.
4. Announce to HTTP and UDP trackers.
5. Discover peers through mainline DHT when allowed by torrent metadata.
6. Connect to peers over TCP with optional protocol encryption.
7. Add torrents from `.torrent` files or magnet links.
8. Download, verify, and write pieces into the staging area.
9. Hand completed torrents off to the final destination.

Milestones 1–8 are defined in [V2_PLAN.md](V2_PLAN.md) and are assumed complete before starting here.

Current implementation progress:

- Milestones 1–8 foundation work is implemented or in final integration: daemon Unix socket, CLI client, JSON-line protocol, TOML configuration, active torrent registry, stable peer ID, metadata/state persistence, storage IO and recheck, HTTP tracker client, outbound peer TCP, download engine, handoff, and local integration tests.
- Milestones 9–13 in this document are pending.

Out of scope for v2:

- HTTPS trackers
- IPv6 peers
- Inbound BitTorrent peer listener
- Seeding
- Full BitTorrent extension protocol beyond what magnet metadata exchange requires
- Peer exchange (`ut_pex`)
- Web UI
- Partial file selection
- Zero-length torrent files
- uTP transport
- Local peer discovery (LSD)
- Tracker scrape support
- Fetching metadata from magnet `xs=` URLs

## Resolved design decisions

These decisions apply across milestones 9–13:

- **Control protocol version 2.** Network milestones change `show`/`list` shapes and add magnet `add`. `torrent status` reports `control_protocol_version: 2`. CLI and daemon must be built together; CLI checks version on connect and errors clearly on mismatch. No v1-shaped response compatibility shim.
- **Multiple trackers per torrent.** Magnet `tr=` parameters name multiple Trackers; `.torrent` files still use one top-level `announce` URL only (no `announce-list` failover). The daemon announces to all supported tracker URLs in parallel, each with its own schedule and error state, and merges peer results into one deduplicated candidate set.
- **Tracker persistence and `show`.** Replace singular `tracker_url` / `tracker_error` with `tracker_announce_urls: []` and per-URL runtime state (`url`, `last_error`, `next_announce_ms`). `show` returns a `trackers` array (`url`, `status`, `last_error`, `next_announce`). On load, migrate legacy `tracker_url` into a one-element array.
- **Pause/resume/remove with multiple trackers.** Pause sends best-effort `event=stopped` to every tracker that previously sent `event=started`; resume sends best-effort `event=started` to all URLs in `tracker_announce_urls`. Remove sends best-effort `stopped` to all started trackers.
- **`network.dht_base_port`.** Replace separate `announce_port` and `dht.bind_port` with one base port (default `6881`). DHT-eligible torrents bind `dht_base_port + dht_slot`; tracker announces for that torrent use the same port. Private torrents and DHT-disabled config use static `dht_base_port` in announces only (no UDP bind). Validate `dht_base_port + max_active_torrents <= 65535` at config load.
- **Info hash normalization.** Accept 40-character hex or 32-character base32 magnet `btih` values; store and path-key everything as lowercase hex. CLI commands accept either encoding but resolve to canonical hex.
- **Magnet add rejection.** Reject at add with `no_discovery_source` when no supported `tr=` URL remains after filtering (`http://` and `udp://` only) and DHT is disabled in config. If DHT is enabled and no supported `tr=` URLs exist, accept the magnet and rely on DHT. Unsupported `tr=` / `xs=` schemes warn in `show` but do not block add when another discovery path exists.
- **Magnet staging before metadata.** Create `<staging>/<info-hash>/state.json` immediately with `source: "magnet"`, `metadata_complete: false`, and decomposed fields (not the full URI). Do not create `metadata.torrent` or `content/` until assembled metadata passes validation. Display name falls back to info hash hex when `dn=` is absent.
- **Tracker announces during metadata fetch.** Before `metadata_complete`, announce with `uploaded=0`, `downloaded=0`, `left=1`. Do not send `event=completed` when metadata alone arrives.
- **Extension protocol scope.** Set the extension protocol bit only on connections opened for `fetching_metadata` (`ut_metadata`). Content-download connections use zero reserved bytes and no extensions. Close metadata connections when metadata exchange finishes; open fresh connections for piece download.
- **DHT lookup-only.** Do not send `announce_peer` in v2. Use DHT only for `get_peers` lookups. See `docs/adr/0002-per-torrent-dht-sockets-shared-routing-table.md`.
- **Per-torrent DHT sockets, shared routing table.** DHT-eligible torrents each bind their own UDP socket on `dht_base_port + dht_slot`. One daemon-wide routing table and DHT node ID (derived from stable Peer ID). One daemon-level bootstrap when DHT is enabled; per-torrent sockets do not re-bootstrap independently. Encapsulate each torrent's DHT I/O in a `TorrentDhtSocket` (or similar) with a `tick()` entry point for future concurrency.
- **DHT slot allocation.** Assign stable `dht_slot` in `0 .. max_active_torrents - 1` at add time; persist in `state.json`. Paused torrents keep their slot (socket closed, slot not reused until `remove`). Private torrents at add time and DHT-disabled config allocate no slot. Magnets before metadata allocate a slot; metadata revealing `private:1` closes the socket and releases the slot.

## Prerequisites

Before starting milestone 9:

- `torrent add file.torrent` accepts supported plain-HTTP tracker metadata and downloads through the existing engine.
- Fake HTTP tracker and fake TCP peer integration tests pass.
- Handoff, completion history, pause/resume/remove semantics, and daemon restart behavior match the foundation acceptance criteria.

## Milestone 9: UDP Tracker Client

Extend tracker support beyond plain HTTP. v2 should perform real UDP tracker announces using BEP 15 against `udp://` announce URLs.

### Tasks

- Parse `udp://` tracker announce URLs into host, port, and optional path components.
- Accept both `http://` and `udp://` top-level tracker `announce` URLs at add time for `.torrent` files (one URL, stored as a one-element `tracker_announce_urls` list).
- Accept multiple `http://` and `udp://` URLs from magnet `tr=` parameters.
- Reject `https://` and other unsupported tracker URL schemes at parse time; unsupported magnet `tr=` entries warn in `show` instead of blocking add when another discovery path exists.
- Store announce URLs exactly as provided.
- Implement UDP tracker connection setup per tracker URL:
  - send `connect` action
  - receive `connect` response with `connection_id`
  - cache `connection_id` per UDP tracker endpoint with refresh before expiry
  - time out and retry with configured capped backoff on failure
- Implement UDP tracker announce:
  - send `announce` action with `connection_id`
  - include `info_hash`, `peer_id`, `port`, `uploaded`, `downloaded`, `left`, and `event`
  - use the torrent's DHT slot port (`dht_base_port + dht_slot`) when allocated, otherwise `dht_base_port`
  - before magnet metadata is known, use `left=1`
  - parse compact IPv4 `peers` from the announce response
  - parse `interval` and optional `failure reason`
- Maintain one tracker session state machine per URL for announce scheduling, success intervals, and capped exponential retry backoff.
- Share peer discovery output with the download engine using the same IPv4 peer list shape as HTTP trackers.
- Send `event=started`, `event=stopped`, and `event=completed` over UDP when applicable.
- Ignore or explicitly report unsupported `announce-list` multi-tracker failover for `.torrent` files in v2.
- Ignore or explicitly report unsupported `peers6` IPv6 peers for v2.

### Acceptance Criteria

- A fake local UDP tracker can return compact IPv4 peers to the daemon.
- `udp://` announce URLs with non-default ports are parsed and announced correctly.
- A magnet with multiple `tr=` URLs announces to each supported tracker independently.
- Temporary UDP tracker failure keeps the torrent lifecycle status `active`, surfaces per-tracker errors in `show`, and retries with configured backoff.
- `torrent show <info-hash>` reports a `trackers` array with per-URL errors and next announce timing.
- HTTP tracker behavior from the foundation milestones remains unchanged for single-tracker `.torrent` adds.

## Milestone 10: Mainline DHT

Add BEP 5 mainline DHT peer discovery for non-private torrents. DHT supplements tracker peer lists and is lookup-only in v2 (no `announce_peer`). Architecture is recorded in `docs/adr/0002-per-torrent-dht-sockets-shared-routing-table.md`.

### Configuration

Extend the TOML configuration file:

```toml
[network]
dht_base_port = 6881

[network.dht]
enabled = true
bootstrap_nodes = [
    "router.bittorrent.com:6881",
    "router.utorrent.com:6881",
    "dht.transmissionbt.com:6881",
]
request_timeout_ms = 5000
refresh_interval_ms = 900000
```

Initial configurable values:

- `network.dht_base_port` — base UDP port for DHT-eligible torrents and static advisory port for others
- whether DHT is enabled
- bootstrap node list
- DHT RPC timeout
- routing-table refresh interval

Validate at config load: `dht_base_port + max_active_torrents <= 65535`.

If DHT is disabled in config, non-private torrents continue to work through trackers only; no DHT sockets are opened.

### Suggested Model

```zig
DhtRoutingTable {
    node_id,
    buckets,
}

TorrentDhtSocket {
    slot,
    bind_port,
    socket,
    outstanding_queries,
    last_error,
}
```

### Tasks

- Derive one daemon-wide DHT `node_id` from the stable Peer ID.
- Maintain one shared `DhtRoutingTable` for the daemon.
- Bootstrap the shared routing table once when DHT is enabled (daemon startup or first DHT-eligible add if empty) using configured `bootstrap_nodes` and `ping`.
- For each DHT-eligible torrent, open a nonblocking UDP socket bound to `dht_base_port + dht_slot`.
- Encapsulate per-torrent DHT I/O in `TorrentDhtSocket` with a `tick(now_ms)` entry point; no shared mutable query state between torrents.
- Stagger torrent socket bring-up on daemon restart to avoid a bind burst.
- Implement shared Kademlia codecs and per-torrent query handling for:
  - `ping`
  - `find_node`
  - `get_peers`
- Issue `get_peers` lookups for active non-private torrent info hashes through that torrent's socket.
- Parse compact IPv4 peer lists from `get_peers` responses; update the shared routing table from responses on any socket.
- Do not implement `announce_peer` in v2.
- Respect torrent `private` metadata: no DHT slot or socket for private torrents at add; close socket and release slot if metadata later reveals `private:1`.
- Respect daemon config: no DHT activity when `[network.dht] enabled = false`.
- Merge DHT-learned peers into the same per-torrent peer candidate set used by the engine.
- Deduplicate peers learned from HTTP trackers, UDP trackers, and DHT.
- On pause, stop DHT queries and close the torrent's DHT socket; keep `dht_slot` until `remove`.
- Surface DHT in `torrent status` as daemon-global enabled/bootstrap state; per-torrent `show` reports eligibility (`private` or not), slot/port when allocated, bootstrap/lookup state, and last lookup error.

### Acceptance Criteria

- A fake local DHT node can answer `get_peers` with compact IPv4 peers for a test info hash.
- Two active DHT-eligible torrents bind distinct UDP ports (`dht_base_port`, `dht_base_port + 1`).
- Non-private torrents can discover peers from DHT without a working tracker.
- Private torrents never perform DHT lookups and never bind DHT sockets.
- A magnet that becomes private after metadata fetch closes its DHT socket and releases its slot.
- DHT peer results are deduplicated against tracker-learned peers.
- DHT failure does not mark a torrent `failed`.
- Disabling DHT in config prevents all DHT socket binds and lookups.
- Daemon performs one bootstrap sequence into the shared routing table, not one per torrent.

## Milestone 11: Protocol Encryption

Add outbound Message Stream Encryption (MSE) per BEP 10 so peer connections can use encrypted handshakes when supported. v2 remains download-only and does not accept inbound peer connections. Encryption policy applies to both metadata and content peer connections.

### Configuration

Extend the TOML configuration file with encryption settings:

```toml
[network.encryption]
policy = "prefer"
```

Supported `policy` values:

- `prefer` — try encrypted handshake first, fall back to plaintext when the peer does not support encryption
- `require` — only complete handshakes with encryption; disconnect peers that do not support encryption
- `disable` — use plaintext BitTorrent handshakes only

Default policy for v2: `prefer`.

### Tasks

- Perform the MSE DH key exchange and crypto provide/select negotiation before the BitTorrent handshake when policy is not `disable`.
- Support both plaintext and encrypted handshake paths behind one peer-connection API.
- Encrypt and decrypt the BitTorrent handshake and subsequent peer messages when encryption is active.
- Preserve the existing plaintext handshake path for peers that do not support encryption when policy is `prefer`.
- Reject or disconnect peers that do not complete encryption when policy is `require`.
- For **content-download** connections, keep reserved extension bytes at zero (no extension protocol in v2).
- For **metadata-fetch** connections (milestone 12), set the extension protocol bit after encryption negotiation; see milestone 12.
- Enforce the configured maximum peer message size on decrypted plaintext before decode.
- Surface encryption mode per peer in detailed torrent status when useful, such as `plaintext`, `encrypted`, or `encryption_required`.

### Acceptance Criteria

- The daemon can download from a fake peer that requires encrypted handshakes.
- With `policy = "prefer"`, encrypted peers complete successfully and plaintext-only fake peers still work.
- With `policy = "require"`, plaintext-only fake peers are rejected without crashing the daemon.
- With `policy = "disable"`, behavior matches the foundation plaintext peer milestone.
- Malformed or oversized encrypted peer messages close only the affected peer connection.

## Milestone 12: Magnet Links

Allow adding torrents from magnet URIs per BEP 9. Magnet support requires fetching metadata from peers using the minimal `ut_metadata` extension on dedicated metadata connections.

### Commands

```sh
torrent add 'magnet:?xt=urn:btih:<info-hash>&dn=<name>&tr=...'
```

For v2:

- `torrent add` accepts either a local `.torrent` file path or a `magnet:` URI.
- Magnet URIs must include `xt=urn:btih:` with a 40-character hex or 32-character base32 info hash; normalize to lowercase hex internally.
- `dn`, `tr`, and `xs` parameters are parsed when present.
- `tr` tracker URLs populate `tracker_announce_urls` using HTTP and UDP tracker support from milestones 9 and foundation work.
- `xs=` is parsed for display/logging only; do not fetch from it in v2.
- Unsupported tracker schemes in `tr` warn in `show` but do not block add when DHT is enabled or another supported `tr=` URL exists.
- Reject at add with `no_discovery_source` when no supported `tr=` URL remains and DHT is disabled.

### Tasks

- Parse magnet URIs into normalized info hash, display name, and zero or more tracker URLs.
- Create an active torrent session before the `.torrent` info dict is known.
- Write `<staging>/<info-hash>/state.json` immediately with `source: "magnet"`, `metadata_complete: false`, `tracker_announce_urls`, optional display name, and `dht_slot` when DHT-eligible.
- Open metadata-fetch connections with encryption per policy and the extension protocol bit set.
- Implement `extended` message framing and `ut_metadata` request/reject/data messages only on metadata connections.
- Do not multiplex metadata exchange and piece download on the same peer connection.
- Select metadata peers from tracker and DHT peer lists.
- Download and assemble the info dictionary from metadata blocks.
- Validate assembled metadata against the magnet info hash.
- Write validated metadata to `<staging>/<info-hash>/metadata.torrent`, set `metadata_complete: true`, create `content/`, then run normal recheck/download.
- Reject assembled metadata that violates configured safety limits before creating staged files.
- Close metadata connections when metadata exchange completes or the peer is no longer useful.
- Open fresh content-download connections with zero reserved extension bytes.
- Expose derived activity `fetching_metadata` while metadata is incomplete.
- If metadata fetch fails temporarily, keep the torrent `active`, surface the latest metadata error in `show`, and retry from newly discovered peers.
- Mark metadata fetch failure as `failed` only for persistent metadata corruption or limit violations.
- If metadata reveals `private:1`, stop DHT activity, close the DHT socket, and release the DHT slot.

### Acceptance Criteria

- `torrent add magnet:...` creates an active session keyed by canonical hex info hash.
- A fake metadata peer can serve a valid info dictionary that matches the magnet info hash.
- Recovered metadata is persisted as `metadata.torrent` before content download begins.
- Unsafe or limit-violating recovered metadata is rejected before staged files are created.
- Non-private magnet torrents can fetch metadata using peers learned from DHT when trackers are absent or failing.
- `show` reports `fetching_metadata` and then normal tracker, DHT, and peer activity after metadata is known.
- Restarting the daemon resumes an incomplete magnet torrent from `state.json` and retries metadata fetch or content download as appropriate.
- Base32 and hex magnet info hashes resolve to the same torrent session.

## Milestone 13: Integration Test Harness Extensions

Extend the local integration harness so automated v2 tests cover the new network features without public trackers, public DHT, or public swarms.

### Components

- Fake HTTP tracker
- Fake UDP tracker
- Fake DHT node
- Fake plaintext peer
- Fake encrypted peer
- Fake metadata peer
- Temporary staging and final directories
- Real daemon socket
- Real CLI requests where practical

### Critical Tests

1. Add a torrent with a `udp://` top-level announce URL and download from a fake UDP tracker peer.
2. Add a non-private torrent and discover a fake DHT peer without a working tracker.
3. Two active DHT-eligible torrents bind distinct `dht_base_port + slot` UDP ports.
4. Download from a fake peer that requires protocol encryption with `policy = "require"`.
5. Add a magnet URI, fetch metadata from a fake metadata peer, and complete the torrent.
6. Magnet add with no `tr=` and DHT enabled succeeds; same magnet with DHT disabled is rejected with `no_discovery_source`.
7. Private torrent does not bind a DHT socket or perform DHT lookup.
8. DHT-disabled config does not bind DHT sockets.
9. Restart daemon and resume an incomplete magnet torrent before metadata is complete.
10. Restart daemon and resume an incomplete magnet torrent after metadata is known.
11. CLI checks control protocol version 2 and rejects mismatched daemon responses in tests where practical.

## Suggested Implementation Order

Complete [V2_PLAN.md](V2_PLAN.md) milestones 1–8 first, then:

1. UDP tracker client and multi-tracker state/`show` shape (control protocol version 2).
2. Mainline DHT (shared routing table, per-torrent sockets, slot allocation).
3. Protocol encryption.
4. Magnet links and minimal `ut_metadata` support.
5. Integration harness extensions.

## Definition of Done

Program v2 is done when this workflow succeeds:

```sh
torrentd --config /tmp/nix-torrent/config.toml

torrent --config /tmp/nix-torrent/config.toml add ./some-single-file.torrent
torrent --config /tmp/nix-torrent/config.toml add 'magnet:?xt=urn:btih:<info-hash>&tr=udp%3A%2F%2Ftracker.example%3A80%2Fannounce'
torrent list
torrent show <info-hash>
```

The daemon must be able to:

- download a `.torrent` file through at least one supported HTTP or UDP tracker and a controlled fake peer setup,
- download a magnet link by fetching metadata and content from controlled fake metadata and content peers,
- discover peers through DHT for non-private torrents in controlled tests (lookup-only, per-torrent UDP ports),
- use protocol encryption when configured,
- verify all pieces, and
- move the result to the final destination.
