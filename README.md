# nix-torrent

A headless BitTorrent client experiment for a home lab.

The intended shape is a long-running daemon (`torrentd`) controlled by a CLI (`torrent`). The CLI is only a control surface; torrent state belongs to the daemon.

## Current status

Implemented so far:

- Zig package with daemon and CLI executables
- Basic config loading from environment/defaults
- Staging area and final destination directory preparation in the daemon
- JSON-line structured startup logs
- Unix-domain-socket control transport between `torrent` and `torrentd`
- Structured JSON request/response protocol with typed errors
- Daemon lock and safe stale socket replacement
- Stable daemon peer ID persisted under the staging area
- In-memory active torrent registry loaded from per-torrent JSON state
- `torrent add/list/show/pause/resume/remove/status` control commands
- Torrent metadata persistence under `<staging>/<info-hash>/metadata.torrent`
- Storage path safety validation before accepting a torrent
- Bencode parser for integers, byte strings, lists, and dictionaries
- `.torrent` metadata parser with raw `info` dictionary SHA-1 info-hash calculation
- Validation for v1 single-file and multi-file torrent metadata
- Small fixture torrents covered by unit tests

Tracker HTTP I/O, peer TCP I/O, real staged file writes/recheck, the download engine, and handoff are not implemented yet.

## Build

```sh
zig build
```

This project targets the Zig 0.16.0 release. The repository includes a `.zigversion` file for version managers.

With Nix flakes:

```sh
nix build
nix develop
```

## Configuration

v2 configuration is TOML-based. Both executables accept `--config /path/to/config.toml`; otherwise they try `$XDG_CONFIG_HOME/nix-torrent/config.toml` and fall back to built-in defaults.

```sh
torrentd --config /tmp/nix-torrent/config.toml
torrent --config /tmp/nix-torrent/config.toml list
torrentd --validate-config
```

Legacy v1 path flags and `NIX_TORRENT_*` environment variables are ignored.

## Torrent metadata support

Milestone 2 code lives in:

- `src/bencode.zig`
- `src/torrent.zig`
- `src/fixtures/*.torrent`

Run metadata and skeleton tests with:

```sh
zig build test
```

## CLI control surface

```sh
torrent add file.torrent
torrent list
torrent show <info-hash>
torrent pause <info-hash>
torrent resume <info-hash>
torrent remove <info-hash>
torrent status
```

The CLI sends JSON-line requests to `torrentd` over the configured Unix domain socket and prints the structured JSON response.
