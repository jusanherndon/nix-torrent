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

**Info Hash**:
The canonical identity of a torrent, derived from its metadata and used to recognize the same torrent across files, sessions, and peers.
_Avoid_: Torrent ID, name, file path
