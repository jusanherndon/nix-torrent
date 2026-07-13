# nix-torrent

A headless BitTorrent client experiment for a home lab.

The intended shape is a long-running daemon (`torrentd`) controlled by a CLI (`torrent`). The CLI is only a control surface; torrent state belongs to the daemon.

## Current status

Working today:

- Daemon + CLI over a Unix-domain JSON-line control protocol
- TOML configuration (`--config`, XDG path, built-in defaults)
- Staging area, final destination, handoff, and completion history
- Add `.torrent` or magnet; pause / resume / remove / list / show / status
- HTTP and UDP trackers, DHT `get_peers`, outbound TCP peers
- MSE encryption policies (`disable` / `prefer` / `require`)
- Magnet metadata via `ut_metadata`; piece download, verify, and staging writes
- Unit and local integration tests with fake trackers/peers

Next work is tracked in [`docs/V3_PLAN.md`](docs/V3_PLAN.md) (IPv6, inbound listen without seeding, DHT announce, PEX/LSD, HTTPS/`announce-list`, control-plane responsiveness).

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

Both executables accept `--config /path/to/config.toml`; otherwise they try `$XDG_CONFIG_HOME/nix-torrent/config.toml` and fall back to built-in defaults. See [`docs/config.example.toml`](docs/config.example.toml).

```sh
torrentd --config /tmp/nix-torrent/config.toml
torrent --config /tmp/nix-torrent/config.toml list
torrentd --validate-config
```

## Tests

```sh
zig build test
```

## CLI control surface

```sh
torrent add file.torrent
torrent add 'magnet:?xt=urn:btih:...'
torrent list
torrent show <info-hash>
torrent pause <info-hash>
torrent resume <info-hash>
torrent remove <info-hash>
torrent status
```

The CLI sends JSON-line requests to `torrentd` over the configured Unix domain socket and prints the structured JSON response.
