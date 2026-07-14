# Nix Torrent

Nix Torrent is a home-lab torrenting client context for managing torrent downloads as a long-running service.

## Language

**Torrent Client**:
A long-running service that manages torrent downloads in a home-lab environment and is controlled through external interfaces.
_Avoid_: Desktop app, GUI client, one-shot downloader

**Control Surface**:
An external interface used to inspect or command the torrent client without owning torrent state.
_Avoid_: Frontend, client app

**Torrent File**:
A metadata file that describes the content to be downloaded, the piece hashes used to verify it, and how peers may be discovered.
_Avoid_: Download file

**Magnet Link**:
A URI that identifies a torrent by info hash and optional discovery hints before Torrent File metadata is available.
_Avoid_: Torrent file, torrent URL

**Tracker**:
A peer discovery service identified by an announce URL that tells the torrent client which peers may have content for an info hash.
_Avoid_: Search engine, indexer, peer, tracker set

**Tracker Tier**:
An ordered group of Tracker announce URLs. For `.torrent` files, tiers come from `announce-list` (BEP 12). For magnets, all `tr=` URLs form one synthetic tier in URI order. After metadata exists, the client announces sequentially within the current tier, prefers a working tracker, and advances tiers only when the current tier is exhausted. While fetching magnet metadata, the client may announce multiple due trackers per tick (up to `max_tracker_announces_per_tick`) for peer diversity before metadata exists.
_Avoid_: Tracker list, unordered magnet bag

**Private Torrent**:
A torrent whose metadata forbids distributed peer discovery such as DHT; it may only use Trackers named in its metadata.
_Avoid_: Public torrent, unlisted torrent

**DHT**:
Distributed peer discovery used to find peers for an info hash without relying on a Tracker. The daemon shares one routing table but each DHT-eligible torrent uses its own UDP socket on a DHT Port.
_Avoid_: Tracker, magnet link, per-torrent routing table, Listen Port

**Listen Socket**:
The daemon-owned TCP socket that accepts inbound BitTorrent peer connections on the Listen Port for the lifetime of the Torrent Client process.
_Avoid_: DHT socket, per-torrent listen socket, control socket

**Listen Port**:
The TCP port bound by the Listen Socket and advertised to Trackers and in DHT `announce_peer`. It is never a DHT Port.
_Avoid_: DHT Port, announce port as a DHT bind, UDP port

**DHT Port**:
The UDP port bound for one torrent's DHT socket (`dht_base_port + slot`). It is never advertised as the BitTorrent TCP Listen Port.
_Avoid_: Listen Port, shared TCP/UDP port number

**Inbound Peer Connection**:
A Peer that dialed the Listen Socket and, after handshake, joins an active Torrent Session that is downloading or fetching metadata. Download only — no uploaded piece data. Connections for paused, failed, completed, or unknown info hashes are closed.
_Avoid_: Seeding peer, outbound peer, Listen Socket

**Port Mapping**:
A gateway-granted IPv4 NAT forwarding of a Listen Port (TCP) or DHT Port (UDP) so peers outside the LAN can reach the Torrent Client, typically via UPnP or NAT-PMP.
_Avoid_: Listen Socket, manual firewall rule as the only concept, IPv6 address assignment

**Staging Area**:
The client-owned location where incomplete torrent content is kept before it is ready for handoff.
_Avoid_: Final destination, downloads folder

**Staging Provisioning**:
Filesystem preparation of a torrent's staging area — directories, metadata on disk, staged content files, and piece recheck — before the engine attaches a Torrent Session.
_Avoid_: Session attach, registry update, DHT slot allocation

**Torrent Session**:
Engine-owned runtime for one torrent under active download — peers, piece progress, tracker protocol state, and DHT handles — whose tick is the unit of progress for that torrent.
_Avoid_: Torrent record, registry entry, completion history, engine tick phase

**Registry Projection**:
Materialization of live Torrent Session fields onto the registry `TorrentRecord` at the end of each Session tick (or equivalent publish point). Control Surface reads use the projected record only — not a parallel session lookup — including when the engine runs on a worker thread. Ephemeral fields (connected peer count, downloading, DHT last error) are projected each tick but not persisted in `state.json`; the Engine owns persistence after the tick returns.
_Avoid_: Dual lookup, live session DTO, sync glue

**Final Destination**:
The user-facing location where completed torrent content is placed after handoff.
_Avoid_: Staging area, incomplete folder

**Handoff**:
The daemon-owned transition that moves fully verified torrent content from the staging area to the final destination and ends active daemon ownership of that content.
_Avoid_: Copy, download completion, seeding

**Completion History**:
A daemon-owned record that preserves what torrent completed, where it was handed off, and when, after active daemon ownership has ended.
_Avoid_: Active torrent state, seeding state, final content

**Info Hash**:
The canonical identity of a torrent, derived from its metadata and used to recognize the same torrent across files, sessions, and peers.
_Avoid_: Torrent ID, name, file path

**Peer ID**:
The BitTorrent protocol identity presented by this torrent client when announcing to trackers and handshaking with peers.
_Avoid_: Info hash, user ID, process ID

**Peer**:
A remote BitTorrent participant that the torrent client connects to for torrent content exchange.
_Avoid_: Tracker, user, daemon

**Piece**:
A hash-verified unit of torrent content described by torrent metadata.
_Avoid_: File, block, packet

**Block**:
A protocol request and transfer slice within a piece. Blocks are assembled into pieces before hash verification.
_Avoid_: Piece, file chunk, disk block

**Configuration File**:
A user-editable source of torrent client settings that should expose operational limits and daemon behavior without requiring code changes.
_Avoid_: Hidden constants, command script

**Message Stream Encryption (MSE)**:
The BitTorrent peer-connection obfuscation handshake that negotiates how the stream is protected before the standard BitTorrent handshake. Peers exchange key material and select one of the defined encryption schemes.
_Avoid_: TLS, HTTPS, transport-layer encryption

**MSE Handshake**:
The key-exchange and scheme-negotiation between two peers that completes when they agree on an Encryption Scheme via `crypto_select`, carrying the BitTorrent handshake as MSE initial payload. Success yields an Encrypted or Obfuscated Peer Connection — never a Plaintext Peer Connection.
_Avoid_: Plain BitTorrent handshake, encryption policy, plaintext fallback

**Encryption Scheme**:
A mutually agreed MSE stream-protection option identified by a `crypto_provide` / `crypto_select` bit. The de facto schemes are plaintext-within-MSE (`0x01`, handshake only — stream not RC4-encrypted) and RC4 (`0x02`, stream encrypted after negotiation).
_Avoid_: Encryption policy, cipher suite, AES

**Encrypted Peer Connection**:
A peer connection with RC4 stream encryption active after MSE negotiation.
_Avoid_: Obfuscated peer connection, encryption policy

**Obfuscated Peer Connection**:
A peer connection that completed MSE negotiation with plaintext-within-MSE. The BitTorrent stream after negotiation is not RC4-encrypted, but the MSE handshake obfuscated the initial exchange.
_Avoid_: Encrypted peer connection, plaintext peer connection, encryption policy

**Plaintext Peer Connection**:
A peer connection that uses the standard BitTorrent handshake without MSE.
_Avoid_: Obfuscated peer connection, encrypted peer connection, encryption policy

**Encryption Policy**:
A torrent-client setting that controls Message Stream Encryption for outbound and inbound Peer connections. `disable` uses a Plaintext Peer Connection (standard BitTorrent handshake, no MSE). `prefer` completes MSE and selects RC4 when offered, otherwise plaintext-within-MSE (`0x01`). Peers that cleanly speak only plain BitTorrent (`PeerNotMse`) are skipped. After a mid-MSE abort (`MsePe2Short` / `MseVcEof` / `MseVcNotFound`) on outbound connects, `prefer` retries once on a fresh TCP connection with plaintext (ADR 0004 live-swarm refinement). `require` accepts only peers that negotiate RC4 (`0x02`). On inbound MSE, the daemon probes active eligible torrents’ info hashes to finish key derivation, then demuxes onto the matching session.
_Avoid_: Encryption scheme, crypto flag, tracker announce parameter, outbound-only policy

**Tracker MSE Signaling**:
Optional HTTP tracker announce parameters that tell a tracker whether this torrent client supports MSE peer connections. `supportcrypto` advertises MSE capability; `requirecrypto` advertises that only MSE peers should be returned.
_Avoid_: Encryption policy, encryption scheme, UDP tracker announce

**Tracker Peer Crypto Flag**:
A per-peer hint in some HTTP tracker responses indicating whether that peer requires MSE. Used to filter or order peers before outbound connect attempts.
_Avoid_: Encryption policy, encryption scheme, tracker announce parameter
