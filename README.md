# nix-torrent

A headless BitTorrent client experiment for a home lab.

The intended shape is a long-running daemon (`torrentd`) controlled by a CLI (`torrent`). The CLI is only a control surface; torrent state belongs to the daemon.

## Current status

Milestones 1 and 2 are implemented:

- Zig package with daemon and CLI executables
- Basic config loading from environment/defaults
- Staging area and final destination directory preparation in the daemon
- JSON-line structured startup logs
- Nix flake for building on NixOS/Nix systems
- Bencode parser for integers, byte strings, lists, and dictionaries
- `.torrent` metadata parser with raw `info` dictionary SHA-1 info-hash calculation
- Validation for v1 single-file and multi-file torrent metadata
- Small fixture torrents covered by unit tests

Persistence, tracker/peer protocol, storage, and the daemon socket are not implemented yet.

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

Both executables understand these environment variables:

- `NIX_TORRENT_STAGING_AREA`
- `NIX_TORRENT_FINAL_DESTINATION`
- `NIX_TORRENT_SOCKET_PATH`

The daemon also accepts:

```sh
torrentd \
  --staging-area /var/lib/nix-torrent/staging \
  --final-destination /srv/downloads \
  --socket-path /run/nix-torrent.sock
```

## Torrent metadata support

Milestone 2 code lives in:

- `src/bencode.zig`
- `src/torrent.zig`
- `src/fixtures/*.torrent`

Run metadata and skeleton tests with:

```sh
zig build test
```

## CLI skeleton

```sh
torrent add file.torrent
torrent list
torrent show <info-hash>
torrent pause <info-hash>
torrent resume <info-hash>
torrent remove <info-hash>
```
