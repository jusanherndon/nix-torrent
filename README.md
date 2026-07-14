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
- **Inbound Listen Socket** (download-only, no seeding): a daemon-wide dual-stack
  TCP listener on `::`/`listen_port` accepts inbound peers under the same MSE policy
- **IPv4 port mapping** for the Listen Port via NAT-PMP/PCP, then UPnP IGD (best-effort)
- **Peer Exchange (`ut_pex`)** and **Local Service Discovery (BEP 14)**
- **HTTPS trackers** (system CA + optional `tracker_ca_file`) and BEP 12 Tracker Tier failover
- **Non-blocking control plane**: engine worker thread + command queue; `status`/`show` read Registry Projection only
- MSE encryption policies (`disable` / `prefer` / `require`), inbound and outbound
- Magnet metadata via `ut_metadata`; piece download, verify, and staging writes
- Unit and local integration tests with fake trackers/peers (IPv4 and IPv6)

The full roadmap lives in [`docs/V3_PLAN.md`](docs/V3_PLAN.md). Seeding remains out of
scope. See [Known limitations](#known-limitations) for intentional gaps.

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

- **Seeding** is intentionally out of scope: inbound peers download only, stay choked, and the connection is closed if a peer sends `request`.
- **Port mapping** is best-effort: DHT UDP lease renewal is simplified relative to a production client; mapping failures are surfaced in `status`/`show` without stopping the daemon.
