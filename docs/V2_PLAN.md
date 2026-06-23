# Nix Torrent v2 Plan

## Goal

Implement the first real downloading daemon for Nix Torrent.

The v2 daemon should:

1. Accept CLI commands over a Unix domain socket.
2. Persist active torrent state.
3. Maintain a stable BitTorrent peer ID across daemon restarts.
4. Announce to HTTP trackers.
5. Connect to peers over TCP.
6. Download, verify, and write pieces into the staging area.
7. Hand completed torrents off to the final destination.

Out of scope for v2:

- Magnet links
- DHT
- UDP trackers
- HTTPS trackers
- IPv6 peers
- Inbound BitTorrent peer listener
- Seeding
- Protocol encryption
- BitTorrent extension protocol
- Web UI
- Partial file selection
- Zero-length torrent files

## Milestone 1: Daemon Socket and CLI Transport

Implement the control surface transport so the CLI talks to the daemon instead of printing a mock request.

### Tasks

- Implement a Unix domain socket server in `src/daemon.zig`.
- Implement a real Unix domain socket client in `src/cli.zig`.
- Use JSON-line request/response framing with `src/protocol.zig`.
- Replace hand-written JSON string searching/formatting with safe JSON parsing and string escaping.
- Return structured success results and structured errors instead of only free-form messages.
- Start with one request per connection.
- Ensure stale socket files are handled safely on daemon startup: acquire the staging-area daemon lock first, try connecting to an existing socket path, fail if a daemon responds, otherwise unlink the stale socket and bind.
- Remove the socket file on clean shutdown if it is still owned by this daemon.
- Handle SIGINT/SIGTERM with a controlled shutdown path: stop accepting CLI connections, best-effort send tracker `stopped` for active torrents, close peer sockets, flush state/history, remove the owned socket file, and release the staging-area daemon lock.

### Commands

```sh
torrent add file.torrent
torrent list
torrent show <info-hash>
torrent pause <info-hash>
torrent resume <info-hash>
torrent remove <info-hash>
torrent status
```

For v2, `remove` applies to active, paused, or failed torrents only. It means forget only: stop daemon activity and remove the torrent from the active daemon registry, but preserve the whole `<staging>/<info-hash>/` directory, including `metadata.torrent` and `content/`. Re-adding the same torrent computes the info hash from the provided torrent file, re-adopts the existing staged content directory if present, and rechecks it before downloading. Completed history is not removed by `remove` in v2.

### Acceptance Criteria

- `torrentd` creates and listens on `NIX_TORRENT_SOCKET_PATH`.
- Existing live daemon sockets are not unlinked by a second daemon startup.
- Stale socket files are removed and replaced safely after the staging-area daemon lock is acquired.
- `torrent list` talks to the daemon and returns a real response.
- CLI no longer prints `would send...`.
- `torrent status` returns daemon health and protocol information, including control protocol version.
- Invalid commands return structured errors.
- SIGINT/SIGTERM triggers controlled shutdown without leaving a live-owned socket file behind.
- Paths, torrent names, and error messages containing JSON-special characters round-trip safely.

### Response Shape

Suggested response examples:

```json
{"ok":true,"result":{"torrents":[]}}
{"ok":false,"error":{"code":"unsupported_tracker_scheme","message":"HTTPS trackers are not supported in v2"}}
```

`status` should return daemon health information:

- daemon version
- control protocol version, starting at `1` for v2
- uptime
- active torrent count
- safe configured limit summary, not a raw dump of all config values

`list` should return enough progress information for a control surface summary:

- info hash
- name
- lifecycle status
- verified bytes
- total bytes
- connected peer count

`show` should include the summary fields plus detailed torrent status:

- piece count
- verified piece count
- derived activity
- tracker announce URL
- tracker status or error
- next announce time, when known
- final path, when complete

v2 does not need download/upload rate accounting.

Initial protocol error codes should include:

- `invalid_request`
- `unknown_command`
- `invalid_arguments`
- `torrent_parse_error`
- `unsupported_tracker_scheme`
- `unsupported_tracker_metadata`
- `duplicate_torrent`
- `already_completed`
- `not_found`
- `config_error`
- `storage_error`
- `tracker_error`
- `peer_error`
- `handoff_failed`
- `internal_error`

## Milestone 2: Daemon State and Persistence

Introduce real daemon-owned torrent lifecycle state.

### Configuration File

v2 should introduce a TOML daemon configuration file for operational limits and other tunable daemon settings. Safety limits must be exposed in this file rather than buried as hard-coded values in the implementation.

See `docs/config.example.toml` for a complete example. Decision recorded in `docs/adr/0001-toml-configuration-file.md`.

Suggested shape:

```toml
[paths]
staging_area = "/var/lib/nix-torrent/staging"
final_destination = "/srv/downloads"
socket_path = "/run/nix-torrent.sock"

[limits]
max_peer_message_bytes = 1048576
max_torrent_file_bytes = 16777216
max_content_bytes = 1099511627776
max_files_per_torrent = 10000
max_path_depth = 32
max_path_component_bytes = 255
max_piece_bytes = 67108864
max_piece_count = 1000000
max_active_torrents = 20
max_peers_per_torrent = 50
max_in_progress_pieces_per_torrent = 4
max_in_flight_blocks_per_peer = 8

[engine]
block_request_bytes = 16384

[network]
announce_port = 6881
peer_connect_timeout_ms = 10000
peer_request_timeout_ms = 30000
tracker_request_timeout_ms = 10000
tracker_retry_min_ms = 30000
tracker_retry_max_ms = 300000

[logging]
level = "info"
format = "json"
```

Initial configurable limits:

- maximum peer message size
- maximum torrent file size
- maximum torrent content size
- maximum file count per torrent
- maximum path depth
- maximum path component length
- maximum piece length
- maximum piece count
- maximum active torrents
- maximum connected peers per torrent
- maximum in-progress pieces per torrent
- maximum in-flight block requests per peer

Default configuration path:

```text
$XDG_CONFIG_HOME/nix-torrent/config.toml
```

If `XDG_CONFIG_HOME` is unset, use:

```text
~/.config/nix-torrent/config.toml
```

Both daemon and CLI should accept an explicit config path:

```sh
torrentd --config /path/to/config.toml
torrent --config /path/to/config.toml list
```

The daemon should support config validation without starting the service:

```sh
torrentd --validate-config
torrentd --config /path/to/config.toml --validate-config
```

`--validate-config` should load configuration using normal precedence, validate daemon config values, print success or a clear error, and exit without creating the daemon socket, acquiring a long-running daemon lock, or starting the torrent engine.

The CLI should read configuration only to resolve daemon connection settings, especially `socket_path`. It should not validate daemon-only limits or interpret torrent behavior.

Configuration precedence, from highest to lowest:

1. CLI flags
2. Environment variables
3. TOML configuration file
4. Built-in defaults

If the default configuration file path is missing, the daemon and CLI should continue with environment values and built-in defaults. If `--config /path/to/config.toml` is provided and that file is missing or unreadable, startup should fail with a clear configuration error.

The daemon may still have documented built-in defaults, but every safety limit above must be overrideable from the TOML configuration file. Engine, network, and logging behavior tunables, such as block request size, peer timeouts, tracker retry backoff, and log level, should also be exposed in the TOML configuration file rather than hidden in code.

Configuration acceptance criteria:

- `torrentd` validates daemon config values at startup and fails fast with clear errors for invalid values, such as zero block size, invalid announce port, retry minimum greater than retry maximum, or impossible limit relationships.
- `torrentd --validate-config` validates configuration and exits without starting the daemon.
- The CLI validates only enough configuration to resolve and connect to the daemon socket.
- Missing default config file uses environment values and built-in defaults.
- Missing or unreadable explicit `--config` fails with a clear error.
- Config file values are loaded correctly.
- Environment variables override config file values.
- CLI flags override environment and config file values.
- CLI config loading only needs to resolve the daemon socket path.

### Daemon State

#### Suggested Model

```zig
TorrentSession {
    metadata,
    info_hash,
    layout,
    status,
    tracker_state,
    peer_states,
    piece_picker,
    block_scheduler,
}
```

#### Tasks

- Keep all torrent state inside the daemon.
- Add active torrent sessions keyed by info hash.
- Persist a small lifecycle status: `active`, `paused`, `complete`, or `failed`.
- Expose richer derived activity in `show`, such as `rechecking`, `announcing`, `connecting`, `downloading`, `waiting_for_peers`, or `handing_off`.
- Reject torrents at add time when they do not contain a usable top-level `http://` tracker `announce` URL.
- Accept private torrents when their top-level tracker `announce` URL is otherwise supported; v2 does not use DHT or peer exchange.
- Persist enough state to resume after restart, including whether a torrent is paused.
- Persist daemon-owned JSON state with atomic write-then-rename updates.
- Persist completed torrent history after handoff.
- Acquire an exclusive daemon lock under the staging area, such as `<staging>/daemon.lock`, before loading or mutating daemon state.
- Store original torrent metadata under staging.
- Recheck staged data on daemon startup instead of trusting detailed piece state.
- Do not persist in-progress pieces or block-level download state in v2; restart, pause, or peer failure discards in-memory partial pieces and downloads them again.

Suggested staging layout:

```text
<staging>/daemon.lock
<staging>/client-peer-id
<staging>/history.json
<staging>/<info-hash>/metadata.torrent
<staging>/<info-hash>/state.json
<staging>/<info-hash>/content/...
```

The daemon should generate `client-peer-id` once and reuse it across restarts. A suggested peer ID format is `-NT0002-` followed by 12 random bytes. TOML is for user-editable configuration; daemon-owned state and completion history should be persisted as JSON. State, history, and initial peer ID writes should use atomic write-then-rename updates where practical.

#### Acceptance Criteria

- `torrentd` fails startup if another daemon holds the staging-area lock.
- `torrent add` stores torrent metadata under staging.
- The daemon persists and reuses a stable peer ID across restarts.
- Restarting `torrentd` preserves added torrents.
- Restarting `torrentd` preserves completed torrent history.
- A crash during state update does not leave partially written JSON as the only state copy.
- Duplicate active adds by info hash are rejected.
- Adding a torrent whose info hash is already in completed history is rejected with a clear `already_completed` error.
- Torrents with missing, invalid, `https://`, `udp://`, or only `announce-list` tracker metadata are rejected at add time with a clear error and no daemon session is created.
- Private torrents with supported plain-HTTP top-level tracker metadata are accepted.
- `list` and `show` reflect daemon-owned state.
- `show` reports both persisted lifecycle status and current derived activity when applicable.
- Paused torrents remain paused after daemon restart.

## Milestone 3: Real Storage Read/Write

Current storage code maps piece spans to files. v2 should perform actual staged file IO. Storage must reject unsafe torrent paths before creating staged files.

### Tasks

- Reject zero-length single-file torrents and zero-length files in multi-file torrents for v2.
- Validate torrent paths before storage layout:
  - reject absolute paths
  - reject empty path components
  - reject `.` and `..` components
  - reject components containing `/` or `\`
  - reject duplicate final file paths
  - reject file/directory path collisions
  - reject unsafe single-file torrent names
- Create the staging file tree from torrent metadata.
- Pre-create files or sparse files.
- Write only hash-verified complete pieces to staged files.
- Keep in-progress piece blocks in memory until the complete piece can be verified.
- Write verified pieces to the correct file offsets.
- Read complete pieces back for SHA-1 verification during recheck.
- Mark a piece verified only after its hash matches torrent metadata.
- Recheck staged data at startup.

### Acceptance Criteria

- Unsafe torrent paths are rejected before any staged file is created.
- Single-file verified-piece writes land at correct offsets.
- Multi-file verified-piece writes can span file boundaries.
- Unverified peer data is not written to staged files.
- Corrupt staged data is detected during recheck.
- Verified pieces survive daemon restart.

## Milestone 4: HTTP Tracker Client

Current tracker code can build announce paths and parse responses. v2 should perform real plain-HTTP announces against the torrent file's top-level `announce` URL. v2 does not implement HTTPS trackers or `announce-list` multi-tracker failover.

### Tasks

- Parse the top-level tracker `announce` URL from torrent metadata.
- Accept `http://` tracker URLs only.
- Reject `https://` and other tracker URL schemes at add time with a clear unsupported-tracker-scheme error.
- Preserve tracker URL paths and existing query parameters, including passkeys embedded in the announce URL.
- Do not implement tracker cookies, custom headers, or redirect handling in v2.
- Ignore or explicitly report unsupported `announce-list` multi-tracker metadata for v2.
- Send HTTP GET announces.
- Include:
  - `info_hash`
  - `peer_id`
  - `port`
  - `uploaded`
  - `downloaded`
  - `left`
  - `compact=1`
  - `event=started|stopped|completed`
- Parse compact IPv4 `peers` responses.
- Parse dictionary IPv4 `peers` responses.
- Ignore or explicitly report unsupported `peers6` IPv6 peers for v2.
- Store and respect announce intervals.
- On temporary tracker failure, keep the torrent lifecycle status `active`, surface the latest tracker error in `show`, and retry with configured capped backoff.
- Continue downloading from already-connected peers despite tracker errors.
- Send `event=completed` best-effort after all pieces verify and before handoff.
- Surface tracker failures in torrent status.

### Acceptance Criteria

- A fake local HTTP tracker can return compact IPv4 peers to the daemon.
- Announce URLs with existing query parameters are preserved and extended correctly.
- Dictionary IPv4 peer responses are covered by parser tests.
- The daemon schedules the next announce from the tracker interval.
- Tracker failure does not crash the daemon.
- Temporary tracker failure does not mark the torrent `failed` if the torrent was accepted at add time.
- `torrent show <info-hash>` reports tracker errors and retry timing.

## Milestone 5: Peer TCP Socket Layer

Current peer code contains handshake and message codecs. v2 should add outbound socket behavior. v2 does not accept inbound BitTorrent peer connections; it only dials peers learned from trackers or tests.

### Suggested Model

```zig
PeerConnection {
    socket,
    address,
    state,
    recv_buffer,
    send_queue,
    available_pieces,
    in_flight_blocks,
}
```

### Tasks

- Add outbound TCP peer dialing from tracker peer lists.
- Do not implement a BitTorrent listening socket in v2.
- Send the configured `network.announce_port` in tracker announces, but do not treat that as an opened inbound listener.
- Perform BitTorrent handshakes with all reserved extension bytes set to zero.
- Do not advertise BitTorrent extension protocol support in v2.
- Validate peer info hash.
- Send `interested`.
- Validate peer message lengths strictly before decoding; malformed messages close that peer connection rather than crashing the daemon.
- Enforce the configured maximum peer message size.
- Process core peer messages needed for downloading:
  - `choke`
  - `unchoke`
  - `bitfield`
  - `have`
  - `piece`
  - `cancel`
  - `keepalive`
- Track peer `interested` / `not interested` state if received, but do not upload data in v2.
- Keep our side choking peers.
- Ignore peer `request` messages or close the connection if a peer requires upload behavior.
- Handle disconnects cleanly.

### Acceptance Criteria

- The daemon can connect to a fake peer.
- Handshake succeeds.
- `bitfield` and `have` update peer availability.
- Peer disconnect does not crash the daemon.
- Malformed or oversized peer messages close only that peer connection.
- Peer `request` messages do not cause uploads in v2.
- Unknown or extension peer messages are ignored or cause a clean peer disconnect; v2 does not advertise extension support.

## Milestone 6: Download Engine

Implement a single coordinator loop that manages torrent sessions, trackers, peers, storage, and piece scheduling. Network sockets should be event-driven/nonblocking where practical. v2 may perform bounded disk reads/writes and SHA-1 piece verification inline in the coordinator loop; worker threads are deferred unless tests show the daemon becomes unusable.

v2 pause semantics are persistent hard pause: paused torrents close peer connections, stop scheduling work, stop tracker activity after a best-effort `stopped` announce, and remain paused across daemon restarts.

### Responsibilities

- Maintain active torrents.
- Maintain peers per torrent.
- Bound in-progress piece work so inline hash and disk operations remain small and predictable.
- Pick pieces and schedule standard BitTorrent block requests within each piece.
- Request blocks from unchoked peers.
- Assemble received blocks in memory into full pieces before verification.
- Treat blocks as untrusted transfer slices; only a fully assembled piece whose SHA-1 hash matches metadata may be written to staged files.
- Verify SHA-1 hashes.
- Write only verified pieces to storage.
- Recover timed-out requests.
- Stop work when a torrent completes.
- On pause, drop in-memory in-flight block and partial-piece state, close peer connections for that torrent, and stop scheduling new tracker or peer work.
- On resume, recheck staged data before scheduling new tracker or peer work. If the torrent was `failed`, clear the runtime error and retry after recheck; if the underlying problem remains, it may fail again.
- On remove, stop tracker and peer activity, forget the torrent from the active registry, and preserve the whole per-torrent staging directory on disk.

### Initial Strategy

Prefer correctness over optimization:

- Sequential piece selection is acceptable for v2, but it must be peer-aware.
- Select the next missing piece that a connected unchoked peer advertises via `bitfield` or `have`.
- If the next sequential missing piece is unavailable from current peers, skip to a later missing piece that is available.
- Add a block scheduler inside each selected piece instead of requesting whole pieces.
- Use the configured `engine.block_request_bytes`, with a shorter final block when the piece length is not a multiple of the block size.
- Maintain multiple connected peers per torrent, up to the configured peer limit.
- Assign each active piece to one downloading peer at a time.
- Allow a peer to have several in-flight block requests for its assigned piece.
- Do not assemble a single piece from multiple peers in v2.
- If the assigned peer disconnects or times out, discard that in-memory piece buffer and make the piece eligible for reassignment.
- Use configured peer connect and request timeouts.
- Avoid duplicate block requests unless retrying after failure or timeout.

### Acceptance Criteria

- A torrent can complete from a fake peer.
- Sequential piece selection does not stall when the next missing piece is unavailable but a later missing piece is available from a connected peer.
- A single active piece is downloaded from one peer at a time.
- Peer disconnect or timeout causes the in-memory piece buffer to be discarded and retried later.
- The daemon uses standard `request(index, begin, length)` block requests rather than whole-piece requests.
- Pieces are verified only after all blocks for the piece are assembled.
- Bad piece data is rejected and retried.
- Pausing a torrent closes its peer connections and survives daemon restart.
- Resuming a paused or failed torrent rechecks staged data before downloading or retrying handoff.
- Removing an active, paused, or failed torrent preserves `metadata.torrent` and staged content and allows later re-add/recheck by info hash.
- `remove` does not delete completed history in v2.
- Completion changes torrent status to `complete`.
- Inline hash and disk work is bounded by active piece limits and does not make the daemon unusable in integration tests.

## Milestone 7: Handoff

When all pieces are verified, the daemon should finish ownership of the torrent content.

### Tasks

- Stop tracker and peer activity for the completed torrent.
- After all pieces verify, send a best-effort tracker `event=completed` before handoff.
- Move staged content to the final destination.
- Use standard final destination layout:
  - single-file torrents move to `<final_destination>/<name>`
  - multi-file torrents move to `<final_destination>/<name>/...paths...`
- Do not overwrite existing final destination paths; record a recoverable handoff error instead.
- On handoff failure, preserve staged verified content, persist lifecycle status as `failed`, and report a `handoff_failed` error in `show`.
- Allow `resume <info-hash>` to recheck verified staged content and retry handoff.
- Record persistent completion history with info hash, name, final path, completion time, and total bytes only after handoff succeeds.
- Keep `list` and `show` useful after handoff and daemon restart.

### Acceptance Criteria

- Completion is not blocked if the best-effort `event=completed` announce fails.
- Completed single-file torrent appears at `<final_destination>/<name>`.
- Completed multi-file torrent appears under `<final_destination>/<name>/` and preserves directory structure.
- Existing final destination paths are not overwritten.
- Handoff failure preserves staged content and can be retried with `resume`.
- Daemon no longer downloads completed torrents.
- Re-adding a completed torrent is rejected unless a future explicit re-download mode is added.
- `torrent list` shows completed history.
- Completed history survives daemon restart.

## Milestone 8: Integration Test Harness

Build controlled local components to test the daemon without relying on public torrents. Automated v2 tests should use only local fixtures, fake trackers, and fake peers; public trackers or swarms may be used for manual smoke testing later but must not be required for CI.

### Components

- Fake HTTP tracker
- Fake TCP peer
- Temporary staging and final directories
- Real daemon socket
- Real CLI requests where practical

### Critical Tests

1. Add a torrent through the CLI.
2. Tracker returns a fake peer.
3. Fake peer serves valid piece data.
4. Daemon writes and verifies pieces.
5. Torrent completes and hands off.
6. Restart daemon and resume an incomplete staged torrent.
7. Corrupt piece is re-downloaded.
8. Duplicate info hash add is rejected.

## Suggested Implementation Order

1. Socket server/client.
2. Daemon in-memory session model.
3. Storage IO and recheck.
4. Fake-peer-driven engine test, before tracker integration.
5. Peer TCP layer.
6. HTTP tracker client.
7. Handoff.
8. Persistence and restart hardening.

## Definition of Done

v2 is done when this workflow succeeds:

```sh
torrentd --staging-area /tmp/nix-torrent/staging \
         --final-destination /tmp/nix-torrent/done \
         --socket-path /tmp/nix-torrent.sock

torrent add ./some-single-file.torrent
torrent list
torrent show <info-hash>
```

The daemon must be able to download the torrent from at least a controlled local tracker and fake peer setup, verify all pieces, and move the result to the final destination.
