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
A Peer that dialed the Listen Socket and, after handshake, joins an active Torrent Session that is fetching metadata, downloading, or Seeding. During Seeding (and upload-capable download peers per algorithm), the Session may serve Piece/Block data subject to choke. Connections for paused, failed, soft-removed / no Session, or unknown info hashes are closed.
_Avoid_: Outbound-only seed myth, permanent download-only listen as Seeding, attaching to history-only info hashes without a Session

**Port Mapping**:
A gateway-granted IPv4 NAT forwarding of a Listen Port (TCP) or DHT Port (UDP) so peers outside the LAN can reach the Torrent Client, typically via UPnP or NAT-PMP.
_Avoid_: Listen Socket, manual firewall rule as the only concept, IPv6 address assignment

**Staging Area**:
The client-owned location where incomplete torrent content is kept before it is ready for Handoff. After successful Handoff the per-torrent staging tree is removed; verified content lives only under Final Destination for that Session’s Seeding.
_Avoid_: Final destination, downloads folder, permanent second copy after handoff

**Staging Provisioning**:
Filesystem preparation of a torrent's staging area — directories, metadata on disk, staged content files, and piece recheck — before the engine attaches a Torrent Session.
_Avoid_: Session attach, registry update, DHT slot allocation

**Torrent Session**:
Engine-owned runtime for one info hash under active management — peer exchange while downloading, through Handoff, then Seeding — peers, piece progress, tracker protocol state, and DHT handles — whose tick is the unit of progress for that torrent. Live Sessions (including Seeding and paused post-Handoff) are restored from persisted state after a daemon restart.
_Avoid_: Torrent record, registry entry, engine tick phase, process-local-only seed ownership

**Registry Projection**:
Materialization of live Torrent Session fields onto the registry `TorrentRecord` at the end of each Session tick (or equivalent publish point). Control Surface reads use the projected record only — not a parallel session lookup — including when the engine runs on a worker thread. Ephemeral fields (connected peer count, peer candidate count, connect diagnostics, downloading, DHT last error) are projected each tick but not persisted in `state.json`; the Engine owns persistence after the tick returns.
_Avoid_: Dual lookup, live session DTO, sync glue

**Final Destination**:
The user-facing location where completed torrent content is placed after Handoff and from which Seeding serves verified Pieces.
_Avoid_: Staging area, incomplete folder

**Handoff**:
The daemon-owned transition that moves fully verified torrent content from the Staging Area to the Final Destination, records Completion History, removes the per-torrent Staging Area tree, and continues the same Torrent Session into Seeding from Final Destination.
_Avoid_: Copy without moving ownership of the content path, download completion alone, ending daemon ownership, removing the session

**Seeding**:
The post-Handoff phase of a Torrent Session that offers verified content from the Final Destination to Peers until the operator pauses or removes the session. Control Surface presents this as live-registry activity `seeding` (not history-only), with Handoff path/time available alongside live peer fields on the same identity. If Final Destination content goes missing or fails verify while Seeding, the Session fails with a visible Control Surface reason, stops serving Peers, and leaves Completion History until soft Remove or Purge.
_Avoid_: Completion history as the only row, incomplete download, one-shot share after exit, activity label `completed` while still managing a Session, silent soft-remove on missing files, auto re-download as the seeding failure path

**Completion History**:
A daemon-owned record of Handoff — info hash, name, Final Destination path, and when — written when Handoff succeeds. It coexists with an active Torrent Session while Seeding. Soft Remove leaves it in place; Purge deletes it with the Final Destination content for that entry.
_Avoid_: Replacing the live registry row, “completed means no session forever”, immutable after handoff

**Remove** (soft):
A Control Surface command that tears down the Torrent Session and live registry row while retaining Final Destination content and Completion History. The same info hash may later be re-added to start a new Seeding Session from Final Destination when content still verifies.
_Avoid_: Delete files, purge, pause, permanent ban on re-add

**Purge**:
A Control Surface command that tears down the Torrent Session and live registry row, deletes that torrent’s Final Destination content for the Handoff, and prunes the matching Completion History entry.
_Avoid_: Soft remove, pause, handoff

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

**Live Swarm Probe**:
An operator- or agent-run exercise that adds a public Magnet Link or Torrent File to a real daemon, exercises Trackers / DHT / peer dials against the public swarm, collects Control Surface output and logs, and posts a redacted diagnosis. It is verification, not CI.
_Avoid_: Integration harness test, unit test, un-redacted ticket dump

**MVP Smoke Pass Bar**:
A Live Swarm Probe used as the MVP definition’s manual acceptance standard: ordered early gates and binary pass/fail through Handoff and Seeding for a public Magnet Link run and a Torrent File run on a NAT home lab. Publish rules are identical to every Live Swarm Probe — ticket artifacts redacted the same way; no separate looser path.
_Avoid_: CI suite, unit test, informal “it downloaded once”, separate unredacted ritual, smoke with weaker redaction than Live Swarm Probe

---

## Live Swarm Probe procedure

This procedure applies to **every** Live Swarm Probe **and** every **MVP Smoke Pass Bar** run. Scored smoke is not a second publish policy.

Every probe that produces public artifacts (GitHub issues, PR comments, research notes, chat paste-back that may be published) **must** follow this pattern. Local-only terminals need not redact, but **anything uploaded to a ticket or leaving the machine is public-ready first** — including full daemon log dumps: redacted only, or do not upload.

### Run

1. Use an isolated config (staging, final destination, socket, listen/DHT ports) so the probe does not touch production paths.
2. Prefer debug-level logging for the duration of the probe; capture daemon logs, `status`, and periodic `show <info-hash>` samples **locally**.
3. Add the Magnet Link or Torrent File; wait long enough to observe stage mix (discovery → dial → MSE/handshake → attach), not only a single `list` snapshot. For MVP Smoke Pass Bar, apply the gate ladder and clocks below.
4. Prefer Control Surface fields for diagnosis when present (`trackers`, `connect_diagnostics`, peer counts, encryption modes, DHT / Port Mapping fields) over raw logs. Smoke greening requires the diagnosis surface from issue #9 so log diving is not required for gate pass/fail.
5. Tear down the daemon and staging data when finished; do not leave the probe torrent running.

### Publish only redacted material

Assume issues, PR comments, map notes, and any **attached logs** are public. **Never** post unredacted full magnets, log dumps, or `show` JSON that still contains the fields below. Unredacted local files may stay on disk; they do not go on tickets.

| Category | Redact to | Examples |
| --- | --- | --- |
| Peer / endpoint IPs | `x.x.x.x` or `x:x:x:x` | compact peers, dial targets, inbound remote addrs |
| Bind / listen / local addresses & ports | `[REDACTED_BIND]`, `[REDACTED_PORT]` | listen, DHT base, socket path host-specific roots |
| Tracker hostnames and full announce URLs | scheme only (`http` / `https` / `udp`) plus **status** and **error class** | `https: ok`, `udp: error / Timeout`, never hostname or path |
| Content identity | omit or placeholder | magnet `dn=`, torrent name, file paths, info-hash if the ticket does not already own a public hash |
| Location / identity | omit | usernames, home directory paths, LAN names, geo-ish DNS, ISP hostnames |
| Full magnet URIs | omit or `magnet:?xt=urn:btih:[REDACTED]` | do not repost the operator’s full magnet with `tr=` list |

### Keep (these are the probe result)

- Stage outcomes and activity (`fetching_metadata`, `downloading`, `seeding`, stuck/never attached).
- Counts and histograms: candidate count, dial attempts, `Timeout` / `ConnectionRefused` / MSE mid-abort / plaintext retry / `handshake_ok` (from logs or `connect_diagnostics`).
- Tracker **outcome classes** without names: success vs failure reason **class** (`missing user agent`, `bad request`, timeout) after redacting any endpoint identity.
- Encryption Policy under test, duration of the sample window, whether metadata completed, and (for smoke) each gate pass/fail.
- Config knobs that matter to the stage mix (timeouts, policy), without machine-local paths.
- Port Mapping outcome classes (Listen / DHT mapped vs failed), without external IPs.

### Ticket write-up shape

Public probe comments should read as diagnosis, not a data dump:

1. Question / purpose of this probe (or “MVP smoke run” + magnet vs torrent leg).
2. Stage table or short mix (what dominated); for smoke, gate table G0–G6 with pass/fail and wall time.
3. Redacted snapshot progression (`show` / `status` shapes).
4. Failure-tag counts or `connect_diagnostics`.
5. Tracker table with **scheme + status + error class only**.
6. What is still open (fix hypothesis vs document-only).

_Cross-check_: if a stranger reading the issue could name your trackers, swarm peers, content title, or home path, redaction failed — rewrite before posting. Same check for smoke and non-smoke Live Swarm Probes.

---

## MVP Smoke Pass Bar procedure

Extends Live Swarm Probe procedure (isolation, Control Surface preference, **identical redaction**). This is the MVP definition’s manual acceptance bar — not CI. Procedure text may be complete before a green run is possible; greening waits on the blockers below.

### Green blockers (must ship before declare pass)

1. Minimum `show`/`status` diagnosis surface — issue #9 (locked + shipped).
2. Continuous Torrent Session Seeding after Handoff — issue #19 / ADR 0007 in code.
3. Port Mapping for Listen Port (TCP) and active torrent DHT Port (UDP) with Control Surface state — issue #20.
4. Enough connect-path fixes that G1–G4 can clear under the clocks — issue #12 residual (#14, #15, #17, #18, related).

### Environment and setup

- Isolated config paths (staging, Final Destination, socket, listen/DHT ports); Encryption Policy **`prefer`** (default). Alternate policy is diagnosis-only, not a second pass bar.
- Outbound IPv4 works.
- Port Mapping enabled; within **2 minutes** of start (Listen) and of active DHT slot (UDP), Control Surface shows **mapped** for both. Fail = G0 fail.
- Public swarm only; operator-chosen content, prefer **≤ ~2 GiB** so G5 stays within budget; no private/auth trackers; no infinite content swap (G1 zero-candidates: reselect **once**, then fail the bar).

### Dual-run order

1. **Magnet Link** run (full G0–G6).
2. Soft Remove (or equivalent) and clear that run’s probe content so progress does not bleed.
3. **Torrent File** run (full G0–G6; G2 still asserted even if true immediately after add).
4. Bar **passes only if both runs pass**. Full probe teardown after both complete or after a hard fail.

### Gate ladder (both runs)

| Gate | Pass (Control Surface, not unredacted logs) | Fail if not met by |
| --- | --- | --- |
| G0 | Daemon up; add accepted; Port Mapping mapped for Listen Port and (when slot held) active DHT Port | Immediate for add; **2 min** for mapping |
| G1 | Peer candidate count > 0 | **5 min** after add |
| G2 | `metadata_complete` (or equivalent) true | **15 min** after G1, or **20 min** wall from add (whichever first) |
| G3 | Connected / content peer ≥ 1 | **15 min** after G2 |
| G4 | Verified piece progress advances after G3 | **10 min** after G3 with progress still 0 |
| G5 | Handoff: content under Final Destination; Completion History written; Staging Area removed; Session continues | Operator budget **≤ 2 h** after progress moving; **30 min** quiet with no piece progress → fail |
| G6 | Activity `seeding`; Final Destination path present; Session still live-managed; no FD fail in observe window | **5 min** observe after Handoff |

G6 does **not** require `uploaded > 0` or a remote leecher finishing a download.

### Fail recording

On any gate fail: stop that run; ticket artifact = redacted diagnosis packet (write-up shape above) using #9 fields when shipped. Do not “rescue” by only watching later gates. Do not attach unredacted logs.

### Pass

Both runs clear G0–G6 under clocks with green blockers satisfied; ticket comment (if any) uses the same redaction rules as any Live Swarm Probe.
