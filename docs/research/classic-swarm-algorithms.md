# Classic swarm algorithms — primary sources for MVP

**Ticket:** [#6](https://github.com/jusanherndon/nix-torrent/issues/6)  
**Question:** What do primary sources specify (or establish as de facto standard client behavior) for rarest-first, endgame, choke/unchoke, optimistic unchoke, snubbing, and upload rate limiting — including which parts are normative vs conventional?

## Source tiers

| Tier | Source | Role |
| --- | --- | --- |
| Normative wire + “currently deployed” choke | [BEP 3 — The BitTorrent Protocol Specification](https://www.bittorrent.org/beps/bep_0003.html) | Standard BEP. Wire messages, interest/choke state machine, pipelining, endgame/cancel, and an explicit “currently deployed” choking algorithm. |
| Primary algorithm design (endorsed by BEP 3) | [Cohen, *Incentives Build Robustness in BitTorrent* (22 May 2003)](https://bittorrent.org/bittorrentecon.pdf) | Piece selection (strict priority, rarest-first, random-first, endgame) and choking details (tit-for-tat, optimistic unchoke, anti-snubbing, upload-only). BEP 3 Resources: “outlines some request and choking algorithms clients should implement for optimal performance.” |
| De facto conventional client | [libtorrent settings / manual](https://www.libtorrent.org/reference-Settings.html), [rate-based choking](https://www.libtorrent.org/manual-ref.html#rate-based-choking), [piece picker](https://www.libtorrent.org/manual-ref.html) | Widely deployed implementation defaults and extensions. Not a BEP; useful where BEP/Cohen leave knobs unspecified. |

**Not treated as normative:** [wiki.theory.org BitTorrentSpecification](https://wiki.theory.org/BitTorrentSpecification) largely restates BEP 3 / Cohen. Cited only where it records *practice divergence* (especially endgame entry) that primary sources leave open.

**Legend used below**

- **Normative (wire):** must match peer wire semantics in BEP 3 for interoperability.
- **Normative (deployed algorithm):** BEP 3’s “currently deployed” choking text — not a wire encoding, but BEP 3 requires new algorithms to work well against this one.
- **Primary conventional (Cohen):** algorithms in the economics paper; BEP 3 points implementors there for request/choke policy.
- **De facto client:** common modern client defaults (libtorrent), or documented client variance.

---

## Cross-cutting wire semantics (all algorithms rest on these)

From BEP 3 peer protocol / peer messages:

- Connections are **symmetrical**; each side tracks **choked** and **interested**.
- Connections **start choked and not interested**.
- Data transfers only when one side is **interested** and the other is **not choking**.
- Interest must stay accurate even while choked (so peers know who would download immediately if unchoked).
- Downloaders should **pipeline** several piece requests for TCP performance; on choke, queued requests that cannot go out on the TCP buffer should be discardable.
- Message IDs: `0` choke, `1` unchoke, `2` interested, `3` not interested, `4` have, `5` bitfield, `6` request, `7` piece, `8` cancel.
- Request length de facto **16 KiB** (`2^14`); “all current implementations” use that and close peers requesting more.

Cohen §2.3 adds conventional pipeline sizing: sub-pieces typically **16 KiB**, typically **five** requests outstanding.

---

## 1. Rarest-first (and related piece selection)

### What primary sources say

**Cohen §2.4** is the primary piece-selection source:

| Policy | Behavior |
| --- | --- |
| **Strict priority** | Once any sub-piece of a piece is requested, finish that piece before starting another. |
| **Rarest first** | Prefer pieces fewest of *your* peers have (local swarm rarity). Aims to maximize something useful to upload, reduce future “nothing interesting,” and replicate rare pieces before seed/peer loss. |
| **Random first piece** | Exception: until the **first complete piece**, pick **randomly** so a tradeable piece finishes quickly (rare pieces often live on one peer → slow). Then switch to rarest-first. |
| **Endgame** | Separate mode (below). |

**BEP 3** does *not* specify rarest-first in the peer-messages section. It still says downloaders “generally download pieces in **random order**.” That line is thinner / older than Cohen. Treat **rarest-first + random-first + strict priority** as **primary conventional (Cohen)**, endorsed by BEP 3’s Resources pointer—not as wire-normative.

### De facto client notes (libtorrent)

- Normal picker mode is **rarest first**; equal-rarity pieces are shuffled.
- **`initial_picker_threshold` default 4**: first *N* pieces random, then rarest-first (generalizes Cohen’s “until first complete piece”).
- Orthogonal modes exist (sequential, reverse/snubbed) — product choices, not BEP requirements.

### Normative vs conventional

| Claim | Class |
| --- | --- |
| Prefer locally rare pieces after bootstrap | Primary conventional (Cohen); BEP Resources endorse |
| Random until first complete piece | Primary conventional (Cohen) |
| Strict priority within a piece | Primary conventional (Cohen) |
| Bootstrap threshold = 4 pieces | De facto client (libtorrent default) |
| Random order forever | Outdated BEP 3 prose — do not pin for MVP |

---

## 2. Endgame

### What primary sources say

**BEP 3 (peer messages / `cancel`)** — normative wire + algorithm sketch:

- Near the end of a download, last pieces tend to stall on a slow peer.
- Once requests for **all pieces the downloader still lacks** are pending, request **everything from everyone** it is downloading from.
- On each piece arrival, send **`cancel`** to others to limit waste.

**Cohen §2.4.4 Endgame Mode** — same idea at **sub-piece** granularity:

- When all missing sub-pieces are actively requested, request all sub-pieces from all peers; cancel on arrival.
- Claims endgame is short and little bandwidth is wasted.

### What is left open

- **Entry threshold** (when “almost complete”) is not quantified in BEP 3 or Cohen.
- Community practice (theory wiki, non-normative): some clients enter when all pieces are requested; others when blocks left &lt; blocks in transit and ≤ ~20; advice to keep pending duplicates low (1–2) and randomize.

**libtorrent:** `strict_end_game_mode` default **true** — a block may be requested twice only when there is already a request to every remaining piece (stricter duplicate control).

### Normative vs conventional

| Claim | Class |
| --- | --- |
| `cancel` exists; used in endgame | Normative (wire) |
| Broaden requests near completion; cancel duplicates | Normative sketch (BEP 3) + Cohen |
| Exact entry threshold / pending-block budget | Conventional / client-specific |
| Strict “all remaining pieces requested before duplicates” | De facto client (libtorrent default) |

---

## 3. Choke / unchoke (tit-for-tat)

### What primary sources say

**Wire (normative):** choke/unchoke messages; choking means no data until unchoke; see cross-cutting state above.

**Algorithm — BEP 3 “currently deployed” choking algorithm** (normative *deployed* policy for interoperability):

Goals: cap simultaneous uploads (TCP), avoid rapid choke oscillation (“fibrillation”), reciprocate downloaders, try unused peers (optimistic unchoke).

Concrete policy:

1. Re-evaluate who is choked only every **10 seconds**.
2. Unchoke the **four** peers with the **best download rates** from *them* that are **interested** (reciprocation + slot cap).
3. Peers with better rates who are **not interested** may still be unchoked; if they become interested, choke the worst of the four.
4. If the local peer has a **complete file**, rank by **upload** rate to them instead of download rate from them.

**Cohen §3.2** elaborates the same design:

- Fixed unchoke count (**default four**).
- Rank by **current download rate** (implementation: ~**20-second** rolling average — not long-term totals).
- Recalculate every **ten seconds** so TCP can ramp.

BEP 3 states new choking algorithms must work well in a swarm of themselves **and** in a swarm mostly running this deployed algorithm.

### De facto client notes (libtorrent)

- Download-side selection remains tit-for-tat (fastest downloaders).
- Defaults differ from classic “4 / 10s”: `unchoke_slots_limit` **8**, `unchoke_interval` **15** (docs incorrectly say protocol defines 30s; BEP 3/Cohen say **10s** rechoke / **30s** optimistic).
- Optional `rate_based_choker` grows slot count from achieved upload rates (not in BEP 3).
- Seeding algorithms beyond “prefer upload rate”: `round_robin` (default), `fastest_upload`, `anti_leech`.

### Normative vs conventional

| Claim | Class |
| --- | --- |
| Choke/unchoke messages + interest state machine | Normative (wire) |
| ~4 upload slots, 10s rechoke, download-rate tit-for-tat while leeching | Normative (deployed algorithm, BEP 3) + Cohen |
| Complete peer uses upload-rate ranking | Normative (deployed, BEP 3) + Cohen §3.5 |
| 20s rate average | Primary conventional (Cohen implementation detail) |
| 8 slots / 15s rechoke / rate-based choker / seed round-robin | De facto client (libtorrent) |

---

## 4. Optimistic unchoke

### What primary sources say

**BEP 3:**

- Always **one** peer unchoked **regardless of rate** (exploration).
- If that peer is interested, it **counts as one of the four** allowed downloaders.
- Rotate every **30 seconds**.
- **New connections** are **3×** as likely to be chosen as the optimistic unchoke (chance to finish a piece and reciprocate).

**Cohen §3.3:** same — optimistic unchoke rotates every **third** rechoke period (30s), enough for upload + reciprocation + download to ramp.

### De facto client notes (libtorrent)

- `optimistic_unchoke_interval` default **30** (matches classic).
- `num_optimistic_unchoke_slots` default **0** → automatic **20%** of allowed upload slots as optimistic (can be **more than one** optimistic slot even without snubbing).

### Normative vs conventional

| Claim | Class |
| --- | --- |
| Single optimistic unchoke, 30s rotation, 3× bias to new peers, counts toward four | Normative (deployed, BEP 3) + Cohen |
| Multiple optimistic slots as % of upload slots | De facto client (libtorrent) |

---

## 5. Snubbing (anti-snubbing)

### What primary sources say

**Absent from BEP 3’s choking algorithm section.**

**Cohen §3.4 Anti-snubbing** is the primary source:

- If **over a minute** passes with **no piece** from a peer that was downloading from you / that you expected download from, treat that peer as **snubbed**.
- Do **not** upload to them **except** as an **optimistic unchoke**.
- That often yields **more than one concurrent optimistic unchoke** (explicit exception to “exactly one optimistic”).

### De facto client notes (libtorrent)

- Exposes a **snubbed** peer flag and **snubbed** piece-picker path: snubbed peers use **reverse rarity** (prefer common pieces) so slow peers concentrate on fewer pieces.
- Timeouts: `piece_timeout` default **20s**, `request_timeout` default **60s** (block expected within 60s or re-request elsewhere) — related slow-peer handling, not a verbatim Cohen “1 minute → refuse reciprocation upload” rule in the settings surface.

### Normative vs conventional

| Claim | Class |
| --- | --- |
| Anti-snubbing after ~1 minute without a piece; upload only via optimistic | Primary conventional (Cohen only) |
| Extra concurrent optimistic unchokes while snubbed | Primary conventional (Cohen) |
| Reverse-rarity picking / request timeouts for snubbed peers | De facto client (libtorrent) |

---

## 6. Upload rate limiting

Clarify two different ideas primary sources mix under “cap upload”:

### A. Cap concurrent upload *slots* (algorithmic)

**Normative / Cohen:** choke algorithm should **cap the number of simultaneous uploads** so TCP congestion control works; classic **four** unchoke slots (+ optimistic rules above). This is **not** a bytes/sec throttle.

### B. Cap upload *throughput* (bytes/sec)

**Not specified** in BEP 3 or Cohen as a required swarm algorithm. Those texts assume peers try to **utilize available upload capacity** (with slot caps), including after completion (Cohen §3.5 upload-only prefers peers you upload to fastest).

**De facto client:** libtorrent `upload_rate_limit` / `download_rate_limit` default **0** (unlimited), in bytes/second; local-network peers exempt by default; finer control via peer classes. Optional rate-based *slot* choker is still about **how many peers**, not a global B/s cap.

### Normative vs conventional

| Claim | Class |
| --- | --- |
| Limit how many peers you upload to at once (~4 classic) | Normative (deployed choke goals) + Cohen |
| Saturate upload with TCP via few connections | Normative rationale (BEP 3 / Cohen) |
| Operator-facing global upload B/s limit | De facto client configuration (not BEP/Cohen algorithm) |
| Default unlimited B/s | De facto client (libtorrent `0`) |

---

## MVP pinning summary (for grilling #8)

Recommended reading of “must pin full classic algorithms”:

| Behavior | Pin to | Leave for config/grilling |
| --- | --- | --- |
| Piece order | Cohen: strict priority + random-first + rarest-first | Bootstrap count (1 piece vs N); equal-rarity shuffle |
| Endgame | BEP 3 + Cohen: flood remaining requests + `cancel` | Exact entry threshold; strict vs loose duplicate policy |
| Choke while leeching | BEP 3: 4 interested best-download peers, 10s period | Whether to match libtorrent 8/15 instead of classic 4/10 |
| Optimistic | BEP 3: one slot, 30s, 3× new-peer bias, counts in four | Extra optimistic slots (% of uploads) |
| Seeding unchoke | BEP 3 / Cohen: rank by upload rate | round-robin / anti-leech variants |
| Snubbing | Cohen: ~60s no piece → upload only via optimistic (may &gt;1 optimistic) | libtorrent reverse-picker / timeout knobs |
| Upload limiting | Slot cap as part of choke | Global B/s limit as operator config, not swarm algorithm identity |

**Wire musts** (independent of algorithm knobs): choke/interest state machine, pipelined `request`/`piece`/`cancel`, de facto 16 KiB blocks.

---

## Sources

1. BitTorrent.org, **BEP 3: The BitTorrent Protocol Specification** — https://www.bittorrent.org/beps/bep_0003.html  
2. Bram Cohen, **Incentives Build Robustness in BitTorrent** (22 May 2003) — https://bittorrent.org/bittorrentecon.pdf  
3. libtorrent, **settings_pack reference** — https://www.libtorrent.org/reference-Settings.html  
4. libtorrent, **manual** (piece picker; rate-based choking) — https://www.libtorrent.org/manual-ref.html  
5. (Practice-only) wiki.theory.org, **BitTorrentSpecification** — https://wiki.theory.org/BitTorrentSpecification  
