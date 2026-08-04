# nix-torrent

A headless BitTorrent client experiment for a home lab.

The intended shape is a long-running daemon (`torrentd`) controlled by a CLI (`torrent`). The CLI is only a control surface; torrent state belongs to the daemon.

## Current status

Working today (control protocol version 3):

- Daemon + CLI over a Unix-domain JSON-line control protocol
- TOML configuration (`--config`, XDG path, built-in defaults)
- Staging area, final destination, handoff, and completion history
- Add `.torrent` or magnet; pause / resume / remove / list / show / status
- HTTP and UDP trackers, DHT `get_peers` + `announce_peer`, outbound TCP peers
- **Dual-stack IPv4/IPv6** peers and sockets (tracker `peers6`, DHT `nodes6`/BEP 32)
- **Inbound Listen Socket** (download-only today): a daemon-wide dual-stack
  TCP listener on `::`/`listen_port` accepts inbound peers under the same MSE policy
- **IPv4 port mapping** for the Listen Port via NAT-PMP/PCP, then UPnP IGD (best-effort)
- **Peer Exchange (`ut_pex`)** and **Local Service Discovery (BEP 14)**
- **HTTPS trackers** (system CA + optional `tracker_ca_file`) and BEP 12 Tracker Tier failover
- **Non-blocking control plane**: engine worker thread + command queue; `status`/`show` read Registry Projection only
- MSE encryption policies (`disable` / `prefer` / `require`), inbound and outbound
- Magnet metadata via `ut_metadata`; piece download, verify, and staging writes
- Unit and local integration tests with fake trackers/peers (IPv4 and IPv6)

Active product direction is the MVP map on GitHub (issue [#2](https://github.com/jusanherndon/nix-torrent/issues/2)): public magnets and ordinary downloads that progress, hand off, and **seed from the Final Destination**. Domain language is in [`CONTEXT.md`](CONTEXT.md). See [Known limitations](#known-limitations) for what the code still does not implement.

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

## Extension protocol scope (LTEP)

Nix Torrent keeps metadata fetch on dedicated connections and separates extension use by connection type:

- **Metadata connections** advertise `ut_metadata` (BEP 9) to fetch the info dictionary, plus `ut_pex` for PEX **consume** only.
- **Content connections** advertise `ut_pex` (BEP 11): PEX peers are consumed into the candidate set, and emitting is reserved for content connections.
- Unknown extension IDs are ignored cleanly; piece data is never uploaded via extension messages.

## Known limitations

- **Seeding (implementation gap):** domain model and MVP map include continuous Session Seeding after Handoff (see ADR 0007 and issue [#7](https://github.com/jusanherndon/nix-torrent/issues/7)). Code still handoff-ends ownership: inbound peers download only, stay choked, and close on `request`; completed hashes refuse pause/remove/re-add.
- **Port mapping** is best-effort: DHT UDP lease renewal is simplified relative to a production client; mapping failures are surfaced in `status`/`show` without stopping the daemon.
