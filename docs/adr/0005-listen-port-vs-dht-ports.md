# Listen port vs. per-torrent DHT ports

Nix Torrent V3 introduces an inbound TCP Listen Socket for BitTorrent peers. We split the single advertised port that V2 used (`dht_base_port + slot`, dual-use for tracker announces and DHT binding) into two distinct concerns:

- `network.listen_port` (default `6881`): a single daemon-wide TCP port bound on `::` (dual-stack, `ip6_only=false`) for the daemon's lifetime. This is the port advertised to trackers (`&port=`), to UDP trackers, and in DHT `announce_peer`.
- `network.dht_base_port` (default `6882`): the base for per-torrent DHT **UDP** sockets, each bound to `dht_base_port + slot` (see [ADR 0004]/[ADR 0002]). These ports are no longer advertised to peers.

**Why:** In V2 the port advertised to trackers was `dht_base_port + slot`, which (a) changed per torrent, (b) advertised a UDP DHT port as if it were a TCP peer port, and (c) could not be mapped/forwarded coherently. A single, stable, dual-stack TCP listen port is what peers, trackers, and NAT port-mapping all expect for inbound connections.

**Legacy `announce_port`:** the V2 `[network] announce_port` key is retained as an alias that now sets `listen_port` (not `dht_base_port`), because V3 advertises the listen port. Existing configs therefore keep advertising a sensible TCP port.

**Overlap rule:** configuration is rejected if `listen_port` falls within `dht_base_port .. dht_base_port + max_active_torrents - 1`, since that range is reserved for per-torrent DHT UDP sockets. With the defaults (`6881` listen, `6882` DHT base, `20` torrents) the ranges are disjoint.

**Considered options:** (A) keep the dual-use `dht_base_port + slot` and bind the listener there — rejected because the listen port must be stable and mappable; (B) bind one listen port and keep advertising DHT ports — rejected because peers connect to the advertised port over TCP; (C) split into `listen_port` (TCP, advertised) and `dht_base_port` (UDP, internal) — chosen.

**Consequences:** trackers and DHT `announce_peer` advertise `listen_port`. The DHT socket still binds `dht_base_port + slot` and is reported in `show` as `dht_port`. Seeding remains out of scope: inbound peers are accepted download-only (we may leech from them, never upload pieces).
