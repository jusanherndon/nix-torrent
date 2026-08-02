# MSE `prefer` vs public-swarm connect failures

Research for [#4](https://github.com/jusanherndon/nix-torrent/issues/4) (map [#2](https://github.com/jusanherndon/nix-torrent/issues/2)).

**Question:** Against primary BitTorrent/MSE sources and this repo's Encryption Policy semantics (`prefer` / plaintext fallback / `PeerNotMse` skip): which live-swarm connect-failure patterns is `prefer` expected to cause or avoid, and what observable signals distinguish an MSE-policy problem from a generic dial/handshake failure?

## Sources

| Kind | Source |
| --- | --- |
| MSE wire format (de facto) | [Message Stream Encryption](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption) (VuzeWiki; TheoryOrg points here as the Connection Obfuscation doc) |
| Classic peer handshake | [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) peer protocol |
| Peer wire detail | [BitTorrentSpecification (TheoryOrg)](https://wiki.theory.org/BitTorrentSpecification) handshake section |
| Client policy comparison | [libtorrent `settings_pack` enc_policy](https://www.libtorrent.org/reference-Settings.html) (`pe_enabled` / `pe_forced`) |
| Repo policy / terms | `CONTEXT.md` (Encryption Policy, MSE terms); [ADR 0004](../adr/0004-full-mse-handshake-parsing.md) |
| Repo behavior | `src/mse.zig`, `src/peer.zig`, `src/peer_pool.zig`, `src/encryption.zig`, `src/tracker.zig`, `src/integration.zig` |

## Spec baseline (what MSE is and is not)

1. **MSE wraps the stream before the BitTorrent handshake.** Initiator and responder exchange DH pubs (`Ya`/`Yb` + pads), then negotiate `crypto_provide` / `crypto_select`. Defined bits: `0x01` plaintext (header obfuscation only), `0x02` RC4 continued on the payload stream. ([MSE format specification](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption))

2. **SKEY for BitTorrent is the info hash.** Wrong/unknown torrent → early terminate on SKEY / VC. ([MSE](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption))

3. **Classic BitTorrent handshake is distinguishable by first byte `19` (`pstrlen`) and `"BitTorrent protocol"`.** ([BEP 3](https://www.bittorrent.org/beps/bep_0003.html); [TheoryOrg handshake](https://wiki.theory.org/BitTorrentSpecification))

4. **MSE does not mandate a single client policy.** Implementation Notes list three operational modes: (1) outbound always classic BT; (2) try obfuscation first, **retry with BT headers if that fails**; (3) crypto-only, treat inbound as DH. Tracker extensions `supportcrypto` / `requirecrypto` / `crypto_flags` help avoid useless dials to crypto-only peers. ([MSE Implementation Notes / Tracker Extension](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption))

5. TheoryOrg notes the MSE page is incomplete on **when** to attempt encryption and **when** to fall back. ([TheoryOrg Connection Obfuscation](https://wiki.theory.org/BitTorrentSpecification)) Local Encryption Policy fills that gap.

## This repo's `prefer` (authoritative semantics)

From `CONTEXT.md` **Encryption Policy**:

- Outbound/inbound under `prefer`: complete MSE; select **RC4 when offered**, else **plaintext-within-MSE (`0x01`)**.
- Peers that **cleanly speak only plain BitTorrent (`PeerNotMse`) are skipped** — not accepted as a Plaintext Peer Connection on that attempt.
- After a **mid-MSE abort** (`MsePe2Short` / `MseVcEof` / `MseVcNotFound`) on outbound, **one** reconnect with plaintext (`.disable` handshake) on a fresh TCP connection — ADR 0004 live-swarm refinement.
- `require` is RC4-only; `disable` is Plaintext Peer Connection only.
- Inbound under `prefer`/`require`: MSE demux by probing eligible info hashes; **do not** accept a raw BitTorrent handshake (`docs/V3_PLAN.md` inbound notes align with CONTEXT).

Code mirrors that:

| Behavior | Where |
| --- | --- |
| `crypto_provide` under `prefer` = `0x01 \| 0x02`; scheme prefers RC4 | `encryption.cryptoProvideForPolicy` / `selectScheme` |
| First PE2 byte `19` → `PeerNotMse` | `mse.establishInitiator` |
| `PeerNotMse` under `prefer` → `UnsupportedEncryption` (no plaintext retry) | `peer.performHandshake` |
| Plaintext retry only for `MsePe2Short` / `MseVcEof` / `MseVcNotFound` | `peer_pool.isPreferPlaintextRetry` + `dialWithPreferPlaintextRetry` |
| Integration: prefer rejects plaintext-only fake peer | `integration: prefer skips non-mse plaintext peer` |
| Tracker announce under `prefer`: `supportcrypto=1` (not `requirecrypto`) | `tracker.buildAnnouncePath` |
| Candidate filter: `prefer` keeps all peers; only `require` filters on `crypto_required` | `tracker.peerAllowedForEncryption` |
| Under `prefer`, crypto-required peers sorted first when flags present | `tracker.sortPeersForEncryption` |

**Relation to MSE mode #2:** Mode #2 retries classic BT on **any** obfuscated-handshake failure. nix-torrent `prefer` is narrower: it retries plaintext only for **ambiguous mid-MSE aborts**, and **skips** peers that answer with a clean classic handshake (`PeerNotMse`). That is intentionally stricter than libtorrent `pe_enabled` (“if an outgoing encrypted connection fails, a non-encrypted connection will be tried”) and closer to “prefer crypto, refuse known plaintext-only” with a limited ambiguous-abort escape hatch. ([libtorrent enc_policy](https://www.libtorrent.org/reference-Settings.html))

ADR 0004 commits to full VC/pad/`crypto_select` parsing and allows live-swarm refinement when interop gaps appear — the mid-MSE → plaintext retry is that refinement, not a blanket mode-#2 fallback.

## Patterns `prefer` is expected to **cause**

These are expected live-swarm outcomes of the policy itself, not necessarily bugs.

1. **Candidates present, many connects fail with `UnsupportedEncryption`.**
   - Cause: peer responds to MSE `Ya` with classic BT (`pstrlen == 19`) → `PeerNotMse` → skip. Public swarms still contain many non-MSE peers; MSE mode #1/#2 clients and trackers without useful `crypto_flags` will hand out those addresses. ([MSE modes](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption); `CONTEXT.md`; `mse.zig` / `peer.zig`)
   - Map symptom “peer candidates exist, connections fail” is **compatible with** this pattern when failures cluster on `UnsupportedEncryption`.

2. **Inbound plaintext-only peers rejected under `prefer`.**
   - Same policy for inbound: raw BT handshake is not accepted; demux is MSE. ([`CONTEXT.md`](../../CONTEXT.md); `peer.performInboundHandshake`)

3. **Does not cause failure against MSE-capable peers that offer `0x01` and/or `0x02`.**
   - `prefer` advertises both and selects RC4 if present, else plaintext-within-MSE. ([MSE crypto_provide rules](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption); `encryption.selectScheme`)

4. **May still fail after the one mid-MSE plaintext retry** if the retry path hits classic handshake errors (`ShortMessage`, `InfoHashMismatch`, timeouts, etc.). That is “ambiguous peer / dead endpoint,” not the PeerNotMse skip path.

## Patterns `prefer` is expected to **avoid**

1. **Permanent give-up on mid-MSE aborts alone** (`MsePe2Short` / `MseVcEof` / `MseVcNotFound`) without trying classic BT once — those map to short/EOF/missing `ENCRYPT(VC)` windows that can look like a non-MSE or confused peer without a clean `19` first byte. ([MSE early termination / sync on `ENCRYPT(VC)`](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption); `peer_pool.dialWithPreferPlaintextRetry`)

2. **Refusing peers that only negotiate plaintext-within-MSE (`0x01`).** That would be `require`-like behavior; `prefer` provides `0x01|0x02`. ([`CONTEXT.md`](../../CONTEXT.md); MSE `0x01`/`0x02` definitions)

3. **Blindly dialing only classic BT to crypto-only peers** when trackers honor `supportcrypto` / `crypto_flags` — `prefer` advertises support and sorts crypto-required peers first (does not filter them out). ([MSE Tracker Extension](https://web.archive.org/web/20161231215426/http://wiki.vuze.com/w/Message_Stream_Encryption); `tracker.zig`)

## Observable signals: MSE-policy vs generic dial/handshake

Failures are logged as:

```text
{content|metadata} peer connect failed {addr} for {info_hash}: {errorName}
```

(`peer_pool.logConnectFailure`)

### MSE-policy / MSE-handshake signals

| Signal | Meaning |
| --- | --- |
| `UnsupportedEncryption` | Under `prefer`: clean non-MSE peer (`PeerNotMse`) or scheme negotiation rejected. **Strong policy signal.** Confirmed by integration test for plaintext-only peers. |
| `EncryptionRequired` | Typically `require` path (or PeerNotMse mapped under require). Not the default `prefer` skip name. |
| `MsePe2Short` / `MseVcEof` / `MseVcNotFound` | Mid-MSE abort **before** plaintext retry. If these appear alone in logs without a later success, either retry also failed (different error) or logging only captured the first err — still MSE-stage. Covered by prefer's one plaintext retry. |
| `MsePe4Parse` / `MseHandshakeEof` / `MalformedEncryption` | MSE parse / post-VC / handshake truncation. **Not** in the plaintext-retry set — prefer will **not** fall back. Points to MSE interop / ADR 0004 parsing issues, not “skipped plaintext peer.” |
| `InfoHashMismatch` after MSE progress | Wrong torrent or bad SKEY path; can be MSE or classic. |
| Connected peers with encryption mode `obfuscated` / `encrypted` (daemon status counters) | Prefer is succeeding for MSE peers; remaining failures elsewhere are not “MSE completely broken.” |

### Generic dial / non-MSE handshake signals

| Signal | Meaning |
| --- | --- |
| `ConnectionRefused` / `Timeout` / `ConnectionFailed` | TCP dial fail in `tcp.connectStreamAddr` — **before** Encryption Policy matters. |
| `ShortRead` / `ShortMessage` / `ReadFailed` without prior `PeerNotMse` / `Mse*` | Truncated read / timeout during handshake I/O; not specifically the PeerNotMse skip. |
| Failures under `policy = "disable"` at same rates | Isolates dial/NAT/dead peers / classic handshake bugs from `prefer` skips. |
| Failures under `prefer` dominated by `UnsupportedEncryption`, dropping under `disable` | Isolates **prefer's PeerNotMse skip** as the cause of “candidates but no connects.” |

### Practical distinguisher (for the map smoke / diagnosis)

1. Inspect `peer_pool` connect-failure `@errorName` histogram while default `prefer` is on.
2. If mass `UnsupportedEncryption` → **MSE-policy skip of plaintext-only peers** (expected for `prefer`). Try `disable` as a diagnostic, not as a product fix.
3. If mass `ConnectionRefused` / `Timeout` / `ConnectionFailed` → **generic dial**, not Encryption Policy.
4. If mass `MsePe4Parse` / `MalformedEncryption` (no plaintext retry) → **MSE interop / parsing**, revisit ADR 0004 live-swarm refinement — distinct from PeerNotMse skip.
5. If `MsePe2Short`/`MseVc*` appear but connects still succeed via retry, prefer is doing the intended ambiguous-abort recovery.

## Bottom line

- **`prefer` is expected to cause** live “candidates exist, connects fail” when many returned peers are plaintext-only: those fail with **`UnsupportedEncryption`** (`PeerNotMse` skip), by design — not with a classic BT fallback. ([`CONTEXT.md`](../../CONTEXT.md); MSE mode notes; `peer.zig` / `integration.zig`)
- **`prefer` is expected to avoid** sticking on ambiguous mid-MSE aborts without one plaintext reconnect, and to accept MSE peers on either `0x01` or `0x02`. ([`peer_pool.zig`](../../src/peer_pool.zig); MSE scheme bits)
- **Distinguish policy from dial** by error name: dial errors (`ConnectionRefused`/`Timeout`/`ConnectionFailed`) vs policy skip (`UnsupportedEncryption`) vs mid-MSE (`MsePe2Short`/`MseVcEof`/`MseVcNotFound`) vs non-retried MSE parse (`MsePe4Parse`/`MalformedEncryption`). Cross-check with a temporary `disable` run.
