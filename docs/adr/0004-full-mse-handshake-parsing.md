# Full MSE handshake parsing (spec-first)

MSE responder and initiator frame handling will implement full spec compliance—VC verification, RC4-decrypted frames, variable pads, and `crypto_select` validation—rather than the simplified fixed-offset layout in the initial implementation. Pragmatic framed reads with fixed `crypto_provide` offsets were considered but rejected: they are smaller to build yet diverge from the de facto MSE document and may mis-parse real peers. Initiator outbound frames use the same VC/pad/encrypt rules as the receive path (full parity). The approach is spec-first; behavior will be refined against live swarms (e.g. Anirena) if interoperability gaps appear.

**Status:** accepted

**Considered options:** (A) pragmatic minimum-length read + fixed offset parsing; (B) full spec compliance with real-world refinement.

**Consequences:** More implementation surface in `encryption.zig` / `peer.zig` and in integration fake peers; fake peers must speak full MSE to test negotiation paths.
