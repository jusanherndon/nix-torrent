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
_Avoid_: Magnet link, download file

**Staging Area**:
The client-owned location where incomplete torrent content is kept before it is ready for handoff.
_Avoid_: Final destination, downloads folder

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

**Tracker**:
A peer discovery service named by torrent metadata that tells the torrent client which peers may have content for an info hash.
_Avoid_: Search engine, indexer, peer

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
