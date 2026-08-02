# Diagnosis-oriented BitTorrent reading path

**Ticket:** [#5](https://github.com/jusanherndon/nix-torrent/issues/5) (map [#2](https://github.com/jusanherndon/nix-torrent/issues/2))  
**Question:** What short, ordered reading path (primary specs/BEPs/reference docs only) should an operator follow to diagnose stalls and reason about seeding — covering peer wire messages, piece selection, tracker/DHT/PEX roles, and choke/unchoke — without turning into a full BEP encyclopedia?

## Verdict

Read **seven primary documents in this order** (about one focused sitting). Stop after step 7 unless a stall clearly points at magnet metadata or private-torrent rules. Do **not** walk the BEP index; each step below names the diagnosis questions it unlocks.

Domain terms below match `CONTEXT.md` (Peer, Piece, Block, Tracker, Tracker Tier, DHT, Seeding, Info Hash).

---

## Ordered path

### 1. [BEP 3 — The BitTorrent Protocol Specification](https://www.bittorrent.org/beps/bep_0003.html)

**Read:** metainfo / Info Hash; tracker HTTP announce; peer handshake; length-prefixed messages; choke/interest state; piece/block transfer; the “currently deployed” choking algorithm (including complete-file / Seeding unchoke).

**Diagnosis it unlocks**

| Stall / symptom | What BEP 3 fixes in your mental model |
| --- | --- |
| Candidates exist but no useful transfer | Transfer only when one side is **interested** and the other is **not choking**; connections start choked and not interested. ([BEP 3, peer protocol](https://www.bittorrent.org/beps/bep_0003.html)) |
| Handshake fails / wrong torrent | Handshake carries the 20-byte info-hash; mismatch → sever. ([BEP 3, peer protocol](https://www.bittorrent.org/beps/bep_0003.html)) |
| “Have peers, still stuck” | Keepalives are length-zero; timeouts can be much shorter when data is expected. ([BEP 3, peer protocol](https://www.bittorrent.org/beps/bep_0003.html)) |
| Wire vocabulary | Message IDs 0–8: choke, unchoke, interested, not interested, have, bitfield, request, piece, cancel. ([BEP 3, peer messages](https://www.bittorrent.org/beps/bep_0003.html)) |
| End-of-download hang | Endgame: outstanding requests for missing pieces, then cancel on arrival. ([BEP 3, peer messages](https://www.bittorrent.org/beps/bep_0003.html)) |
| Seeding unchoke looks “unfair” | When the file is complete, unchoke decisions use **upload** rate, not download rate; four reciprocal slots + one optimistic unchoke on a 10s / 30s cadence. ([BEP 3, choking algorithm](https://www.bittorrent.org/beps/bep_0003.html)) |
| Tracker vs swarm | Tracker returns peer contacts and an `interval`; it does not move Pieces. ([BEP 3, trackers](https://www.bittorrent.org/beps/bep_0003.html)) |

**Skip in this pass:** bencoding deep-dive beyond what you need to recognize metainfo keys; uTP mentions (out of map scope).

BEP 3 also points implementors at the economics paper for request/choking algorithms ([BEP 3, Resources](https://www.bittorrent.org/beps/bep_0003.html)) — that is step 2.

### 2. [Cohen — *Incentives Build Robustness in BitTorrent*](https://bittorrent.org/bittorrentecon.pdf) (May 2003)

Primary companion to BEP 3 for **piece selection** and the operational choking story. BEP 3’s wire text is thinner on rarest-first; this paper owns that algorithm description.

**Read:** §2.3 Pipelining; §2.4 Piece Selection (strict priority, rarest first, random first piece, endgame); §3 Choking (tit-for-tat, 10s rechoke, optimistic unchoke, anti-snubbing, upload-only / Seeding).

**Diagnosis it unlocks**

| Stall / symptom | Claim (cited) |
| --- | --- |
| Connected + unchoked but little progress | Pipelining: keep several Block requests outstanding (paper: typically five × ~16 KiB). ([Cohen §2.3](https://bittorrent.org/bittorrentecon.pdf)) |
| Peer has nothing useful to trade | Rarest-first vs random-first: until the first complete Piece, pick randomly so a Piece finishes quickly; then rarest-first. ([Cohen §2.4.2–2.4.3](https://bittorrent.org/bittorrentecon.pdf)) |
| “Snubbed” / download collapses | After ~1 minute with no Piece from a Peer, treat as snubbed and avoid uploading to them except as optimistic unchoke — can produce multiple concurrent optimistic unchokes. ([Cohen §3.4](https://bittorrent.org/bittorrentecon.pdf)) |
| Seeding after handoff | Upload-only mode: once done downloading, prefer Peers by **upload** rate to them. ([Cohen §3.5](https://bittorrent.org/bittorrentecon.pdf); same rule in [BEP 3](https://www.bittorrent.org/beps/bep_0003.html)) |
| Tracker blamed for piece stalls | Tracker only introduces Peers; piece logistics are peer-to-peer. ([Cohen §2.2](https://bittorrent.org/bittorrentecon.pdf)) |

### 3. [BEP 23 — Tracker Returns Compact Peer Lists](https://www.bittorrent.org/beps/bep_0023.html) (short)

**Read:** compact `peers` as a 6-byte-per-peer string; `compact=0/1` is advisory; clients must accept both formats.

**Diagnosis it unlocks:** empty or unparsable tracker peer lists, “dict list vs compact string” confusion, and why peer id may be absent in modern responses. ([BEP 23](https://www.bittorrent.org/beps/bep_0023.html); BEP 3 notes compact as the common case and points here.)

### 4. [BEP 15 — UDP Tracker Protocol](https://www.bittorrent.org/beps/bep_0015.html) (skim structure + timeouts)

**Read:** connect → announce flow; connection_id lifetime; retransmission schedule `15 * 2^n` seconds; announce response fields (interval, leechers, seeders, compact peers).

**Diagnosis it unlocks:** `udp://` announce stalls that are not HTTP; silent UDP loss vs HTTP `failure reason`; seed/leecher counts as swarm health hints. ([BEP 15](https://www.bittorrent.org/beps/bep_0015.html).) BEP 3 notes UDP announce as common. ([BEP 3, trackers](https://www.bittorrent.org/beps/bep_0003.html))

### 5. [BEP 12 — Multitracker Metadata Extension](https://www.bittorrent.org/beps/bep_0012.html) (short)

**Read:** `announce-list` as tiers; process tiers sequentially; shuffle within a tier; promote a working Tracker to the front of its tier; when `announce-list` is present, ignore bare `announce`.

**Diagnosis it unlocks:** Tracker Tier failover vs “all trackers at once”; why one dead Tracker should not strand a torrent that still has a healthy tier. ([BEP 12](https://www.bittorrent.org/beps/bep_0012.html).) Aligns with this repo’s Tracker Tier language in `CONTEXT.md`.

### 6. [BEP 5 — DHT Protocol](https://www.bittorrent.org/beps/bep_0005.html)

**Read for roles, not every bucket edge case:** peer vs node; `get_peers` / `announce_peer` (+ token); compact peer/node encodings; BitTorrent handshake DHT bit + `PORT` (0x09) for bootstrapping the routing table; private note that DHT stores peer contacts for trackerless Info Hashes.

**Diagnosis it unlocks**

| Question | Claim (cited) |
| --- | --- |
| Tracker empty — is discovery dead? | DHT is an alternate peer-discovery plane: nodes help locate Peers for an Info Hash. ([BEP 5 overview](https://www.bittorrent.org/beps/bep_0005.html)) |
| DHT “working” but no Peers | `get_peers` may return closer **nodes** instead of `values` (Peers); search iterates. ([BEP 5, get_peers](https://www.bittorrent.org/beps/bep_0005.html)) |
| Not findable by others | `announce_peer` needs a recent token from the same node; announces the **TCP Listen Port** (unless `implied_port`). ([BEP 5, announce_peer](https://www.bittorrent.org/beps/bep_0005.html)) |
| Routing table never warms | Peers advertising DHT send `PORT` with the UDP DHT port after handshake. ([BEP 5, BitTorrent Protocol Extension](https://www.bittorrent.org/beps/bep_0005.html)) |

**Skip in this pass:** full Kademlia bucket-split calculus once you understand good/questionable/bad and iterative lookup.

### 7. [BEP 10 — Extension Protocol](https://www.bittorrent.org/beps/bep_0010.html) then [BEP 11 — Peer Exchange (PEX)](https://www.bittorrent.org/beps/bep_0011.html)

**BEP 10 first:** reserved bit for LTEP; message id 20; extended handshake `m` map (local ids). PEX and other extensions ride this transport; BEP 10 deliberately defines no PEX payload. ([BEP 10](https://www.bittorrent.org/beps/bep_0010.html))

**BEP 11 next:** `ut_pex` as swarm-local discovery **after** bootstrap via Tracker or DHT; added/dropped compact contacts; ≤1 message/minute; added peers should be ones you successfully connected to (liveness); seed-dominated swarms can underpopulate PEX lists. ([BEP 11](https://www.bittorrent.org/beps/bep_0011.html))

**Diagnosis it unlocks:** PEX does not replace Tracker/DHT bootstrap; “PEX silent” is expected before enough live connections; PEX peers are untrusted and must not be the sole candidate source. ([BEP 11](https://www.bittorrent.org/beps/bep_0011.html))

---

## Operator checklist (map the stall to a layer)

Use after the reading path — still grounded in the cites above.

1. **Discovery:** Do Tracker (HTTP [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) / UDP [BEP 15](https://www.bittorrent.org/beps/bep_0015.html) / tiers [BEP 12](https://www.bittorrent.org/beps/bep_0012.html)), DHT [`get_peers`](https://www.bittorrent.org/beps/bep_0005.html), or PEX ([BEP 11](https://www.bittorrent.org/beps/bep_0011.html)) yield Peer candidates?
2. **Session / wire:** Handshake Info Hash match? Bitfield/have implying mutual interest? ([BEP 3](https://www.bittorrent.org/beps/bep_0003.html))
3. **Choke:** Am I choked? Are they interested? Am I seeding (upload-rate unchoke) or leeching (download-rate unchoke + optimistic)? ([BEP 3](https://www.bittorrent.org/beps/bep_0003.html); [Cohen §3](https://bittorrent.org/bittorrentecon.pdf))
4. **Piece / Block:** Pipelined requests? Stuck before first Piece (random-first) vs rarest-first mid-swarm vs endgame? ([Cohen §2.4](https://bittorrent.org/bittorrentecon.pdf); [BEP 3](https://www.bittorrent.org/beps/bep_0003.html))
5. **Seeding:** Complete local content; still uploading under upload-only / complete-file choking rules. ([Cohen §3.5](https://bittorrent.org/bittorrentecon.pdf); [BEP 3](https://www.bittorrent.org/beps/bep_0003.html))

---

## Explicitly out of this path (encyclopedia guardrails)

Do **not** pull these in for the MVP diagnosis curriculum unless a concrete stall demands them:

| Doc | Why deferred |
| --- | --- |
| Full BEP index / unrelated extensions | Map learning scope is diagnosis-oriented, not encyclopedic ([#2](https://github.com/jusanherndon/nix-torrent/issues/2)) |
| [BEP 9](https://www.bittorrent.org/beps/bep_0009.html) (`ut_metadata`) | Only if the stall is **magnet before metadata**; not needed to reason about content Peers once the Torrent File / info dict exists |
| [BEP 6](https://www.bittorrent.org/beps/bep_0006.html) Fast Extension | Optional wire acceleration; core choke/request diagnosis does not depend on it |
| [BEP 14](https://www.bittorrent.org/beps/bep_0014.html) LSD, [BEP 32](https://www.bittorrent.org/beps/bep_0032.html) IPv6 DHT, uTP BEPs | Useful later; not required to understand classic stall layers above |
| MSE / encryption policy docs | Important to *this* client’s connect failures (map Notes) but **not** part of the classic wire/choke/discovery curriculum asked in #5 — treat as a separate hypothesis after BEP 3 handshake semantics are clear |
| [BEP 27](https://www.bittorrent.org/beps/bep_0027.html) Private torrents | Read only when metadata sets private and DHT/PEX must stay off |

---

## Source list (primary only)

1. Bram Cohen, [BEP 3: The BitTorrent Protocol Specification](https://www.bittorrent.org/beps/bep_0003.html), BitTorrent.org  
2. Bram Cohen, [*Incentives Build Robustness in BitTorrent*](https://bittorrent.org/bittorrentecon.pdf), 22 May 2003 (linked from BEP 3 Resources)  
3. David Harrison, [BEP 23: Tracker Returns Compact Peer Lists](https://www.bittorrent.org/beps/bep_0023.html)  
4. Olaf van der Spek et al., [BEP 15: UDP Tracker Protocol for BitTorrent](https://www.bittorrent.org/beps/bep_0015.html)  
5. John Hoffman, [BEP 12: Multitracker Metadata Extension](https://www.bittorrent.org/beps/bep_0012.html)  
6. Andrew Loewenstern & Arvid Norberg, [BEP 5: DHT Protocol](https://www.bittorrent.org/beps/bep_0005.html)  
7. Arvid Norberg et al., [BEP 10: Extension Protocol](https://www.bittorrent.org/beps/bep_0010.html)  
8. The 8472, [BEP 11: Peer Exchange (PEX)](https://www.bittorrent.org/beps/bep_0011.html)  

---

## One-line gist

**BEP 3 → Cohen economics (piece + choke/seed) → BEP 23/15/12 (tracker reality) → BEP 5 (DHT roles) → BEP 10+11 (PEX); stop there unless the stall is clearly metadata- or private-torrent-specific.**
