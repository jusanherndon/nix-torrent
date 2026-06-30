# Per-torrent DHT sockets with a shared routing table

Nix Torrent v2 uses mainline DHT for outbound peer discovery on non-private torrents. We chose per-torrent isolated UDP sockets (each bound to `dht_base_port + slot`) with a single daemon-wide routing table and DHT node ID, rather than one shared DHT socket or fully isolated routing tables per torrent. Socket isolation keeps each torrent's DHT I/O independent for future concurrency work; sharing the routing table avoids redundant bootstrap traffic to public routers and keeps learned contacts available to all torrents. v2 is lookup-only (`get_peers`); we do not send `announce_peer` because there is no inbound peer listener.

**Considered options:** (A) one shared DHT socket and table for the whole daemon; (B) per-torrent sockets with shared table and bootstrap; (C) fully isolated socket and routing table per torrent.

**Consequences:** DHT-eligible torrents consume a port slot from `dht_base_port .. dht_base_port + max_active_torrents - 1`. Config must validate that range fits in 65535. Private torrents and DHT-disabled config use no slot; tracker announces report static `dht_base_port` only. See [V2_NETWORK_PLAN.md](../V2_NETWORK_PLAN.md) milestone 10.
