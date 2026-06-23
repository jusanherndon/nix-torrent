# nix-torrent

A headless BitTorrent client experiment for a home lab.

The intended shape is a long-running daemon (`torrentd`) controlled by a CLI (`torrent`). The CLI is only a control surface; torrent state belongs to the daemon.

## Current status

Milestone 1 skeleton:

- Zig package with daemon and CLI executables
- Basic config loading from environment/defaults
- Staging area and final destination directory preparation in the daemon
- JSON-line structured startup logs
- Nix flake for building on NixOS/Nix systems

The torrent protocol, persistence, and daemon socket are not implemented yet.

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

## CLI skeleton

```sh
torrent add file.torrent
torrent list
torrent show <info-hash>
torrent pause <info-hash>
torrent resume <info-hash>
torrent remove <info-hash>
```
