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

The daemon remains the only writer of torrent state.

## Suggested Implementation Milestones

### Milestone 1: Project Skeleton

- Create Zig package structure.
- Add daemon executable.
- Add CLI executable.
- Add basic config loading for staging area, final destination, and socket path.
- Add structured logging.
- Add a .nix file, so this project can be easily built on nixos systems

### Milestone 2: Torrent Metadata

- Implement bencode parser/encoder as needed.
- Parse `.torrent` files.
- Compute info hash from the raw `info` dictionary encoding.
- Validate single-file and multi-file metadata.
- Add tests using small fixture torrents.

### Milestone 3: Storage Layout and Verification

- Map torrent files to staging paths.
- Write piece data to the correct file offsets.
- Read pieces back for verification.
- Track verified, missing, and in-progress pieces in memory.
- Recheck staged data on startup.

### Milestone 4: Tracker Client

- Implement HTTP tracker announce.
- Parse compact and non-compact peer lists if practical; compact can be first.
- Handle announce intervals.
- Surface tracker errors in torrent status.

### Milestone 5: Peer Protocol

- Implement TCP peer handshake.
- Implement core peer messages: choke, unchoke, interested, not interested, have, bitfield, request, piece, cancel.
- Maintain per-peer state.
- Download pieces from peers.
- Verify completed pieces before marking them available.

### Milestone 6: Piece Selection and Download Loop

- Start with simple rarest-first or sequential selection; prefer correctness over optimization.
- Avoid duplicate in-flight requests unless recovering from stalled peers.
- Handle peer disconnects and request timeouts.
- Complete a torrent when every piece is verified.

### Milestone 7: Handoff

- Move verified completed content from staging area to final destination.
- Mark the torrent complete.
- Stop peer and tracker activity for that torrent.
- Preserve enough history for `list` / `show` to explain completion.

### Milestone 8: CLI and Daemon Protocol

- Implement Unix domain socket server in daemon.
- Implement JSON request/response protocol.
- Implement initial CLI commands.
- Ensure all state changes go through daemon commands.

### Milestone 9: Hardening

- Add integration tests with local fake tracker and fake peers.
- Test daemon restart and staged-data recheck.
- Test corrupted piece recovery.
- Test duplicate torrent add by info hash.
- Add limits for peers per torrent and active torrents.

## Open Questions

These should be resolved before or during implementation:

1. Which Zig version should this project target?
2. Should configuration use a file, environment variables, CLI flags, or a combination?
3. What exact directory layout should the staging area use?
4. What should `remove` mean for staged data: forget only, delete data, or ask for a mode?
5. Should completed torrent history persist after handoff?
6. What level of tracker compatibility is required for the first home-lab replacement?
7. What observability is required: logs only, status command, metrics endpoint, or all later?
