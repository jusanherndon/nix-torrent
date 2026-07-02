# Engine-owned Torrent Sessions with registry projection

The engine owns authoritative runtime state in Torrent Sessions (peers, piece layout, tracker protocol handles, DHT sockets). The registry holds `TorrentRecord` as a persistence and Control Surface DTO — limits enforcement, `show`/`list` responses, and `state.json` serialization. Tracker fields on the record are a projection written at tick boundaries, not a parallel live copy synced by hand.

**Considered options:** (A) engine owns sessions, registry projects; (B) registry owns a unified active-torrent aggregate that the engine borrows during tick.

**Consequences:** Call sites that need live tracker or peer state consult the engine session when attached, otherwise the record. `syncTrackerRecord` and similar glue should disappear as tracker state collapses into `TrackerEndpoint`. Staging Provisioning stays in daemon-driven `staging.zig`; the engine assumes the staging area is prepared before session attach.
