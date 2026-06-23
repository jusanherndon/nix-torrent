# Nix Torrent Plan

## Goal

Build a headless BitTorrent client in Zig for a home-lab environment. The first version should prioritize correct, resumable downloading over broad protocol coverage or UI polish.

## Product Shape

Nix Torrent is a long-running daemon controlled by external tools. The first control surface is a CLI that talks to the daemon; the CLI must not mutate torrent state directly.

Out of scope for v1:

- Desktop GUI
- Web UI
- Magnet links
- DHT
- Peer exchange
- UDP trackers
- Protocol encryption
- Seeding after completion
- Partial file selection

## v1 Protocol Scope

The first usable version supports:

- `.torrent` files as the only input format
- Single-file torrents
- Multi-file torrents
- HTTP trackers
- TCP peer protocol
- Piece download and SHA-1 hash verification

The client identifies torrents by info hash, not by display name, original file path, or internal UUID.

## Storage Model

The daemon owns an internal staging area for incomplete content. Completed content is moved to a configured final destination only after every piece has been downloaded and hash-verified.

For v1, handoff ends daemon ownership of the torrent. The daemon does not continue seeding completed torrents.

## Persistence and Restart Behavior

The daemon persists the active torrent list. On startup, it rechecks staged data before resuming downloads.

This avoids trusting detailed piece-state persistence too early while still supporting automatic recovery after daemon restarts.

## Concurrency Model

Start with a single-threaded event loop:

- Tracker requests
- Peer sockets
- Peer protocol state
- Piece selection
- Torrent lifecycle state
- Storage scheduling

Hashing and disk work can be moved to worker threads later if profiling shows the event loop is blocked too often.

## Daemon Control Protocol

The CLI communicates with the daemon over a Unix domain socket using a small JSON protocol.

Initial CLI commands:

- `add <torrent-file>`
- `list`
- `show <info-hash>`
- `pause <info-hash>`
- `resume <info-hash>`
- `remove <info-hash>`
- `status`

The daemon remains the only writer of torrent state.

## Suggested Implementation Milestones

Current implementation status: milestones 1 and 2 are complete. Later milestones have skeletons, codecs, parsers, or unit-level helpers, but the real socket, tracker networking, peer networking, download engine, handoff flow, and integration hardening are planned for v2. See `docs/V2_PLAN.md`.

### Milestone 1: Project Skeleton — Done

- [x] Create Zig package structure.
- [x] Add daemon executable.
- [x] Add CLI executable.
- [x] Add basic config loading for staging area, final destination, and socket path.
- [x] Add structured logging.
- [x] Add a .nix file, so this project can be easily built on nixos systems.

### Milestone 2: Torrent Metadata — Done

- [x] Implement bencode parser/encoder as needed. Current need is parsing only.
- [x] Parse `.torrent` files.
- [x] Compute info hash from the raw `info` dictionary encoding.
- [x] Validate single-file and multi-file metadata.
- [x] Add tests using small fixture torrents.

### Milestone 3: Storage Layout and Verification — Partial

- [x] Map torrent pieces to file spans.
- [ ] Validate torrent paths before creating staged files.
- [ ] Create staged file trees.
- [ ] Write verified piece data to the correct file offsets.
- [ ] Read pieces back for verification.
- [x] Track verified, missing, and in-progress pieces in memory.
- [ ] Recheck staged data on startup.

### Milestone 4: Tracker Client — Partial

- [x] Build tracker announce paths.
- [x] Parse compact and dictionary IPv4 peer lists.
- [ ] Implement real plain-HTTP tracker announces.
- [ ] Handle announce intervals in the daemon engine.
- [ ] Surface tracker errors in torrent status.

### Milestone 5: Peer Protocol — Partial

- [x] Implement peer handshake codec.
- [x] Implement core peer message codecs: choke, unchoke, interested, not interested, have, bitfield, request, piece, cancel.
- [x] Maintain basic per-peer protocol state.
- [ ] Implement outbound TCP peer sockets.
- [ ] Download blocks from peers.
- [ ] Verify completed pieces before marking them available.

### Milestone 6: Piece Selection and Download Loop — Partial

- [x] Start with simple sequential piece selection; prefer correctness over optimization.
- [x] Avoid duplicate in-flight piece requests in the current scheduler skeleton.
- [ ] Add peer-aware piece selection.
- [ ] Add block-level request scheduling.
- [ ] Handle peer disconnects and request timeouts in the real engine.
- [ ] Complete a torrent when every piece is verified.

### Milestone 7: Handoff — Partial

- [x] Add helper for final destination paths.
- [x] Add completion history data structure.
- [ ] Move verified completed content from staging area to final destination as part of the daemon lifecycle.
- [ ] Mark the torrent complete.
- [ ] Stop peer and tracker activity for that torrent.
- [ ] Persist enough history for `list` / `show` to explain completion after restart.

### Milestone 8: CLI and Daemon Protocol — Partial

- [ ] Implement Unix domain socket server in daemon.
- [x] Implement initial JSON request/response skeleton.
- [ ] Replace hand-written JSON parsing with safe JSON handling.
- [x] Implement initial CLI command parsing.
- [ ] Implement real CLI socket transport.
- [ ] Ensure all state changes go through daemon commands.

### Milestone 9: Hardening — Planned

- [ ] Add integration tests with local fake tracker and fake peers.
- [ ] Test daemon restart and staged-data recheck.
- [ ] Test corrupted piece recovery.
- [x] Test duplicate torrent add by info hash at registry unit level.
- [x] Add registry-level limits for peers per torrent and active torrents.
- [ ] Enforce peer and active torrent limits in the daemon engine.

## Decisions

- Target the Zig 0.16.0 release.
- v2 introduces a TOML daemon configuration file for operational safety limits rather than hiding those limits as hard-coded implementation constants. See `docs/adr/0001-toml-configuration-file.md`.

## Open Questions

These should be resolved before or during implementation:

1. What level of tracker compatibility is required beyond the v2 scope?
2. What observability is required after v2: logs and status command only, metrics endpoint, or all later?
