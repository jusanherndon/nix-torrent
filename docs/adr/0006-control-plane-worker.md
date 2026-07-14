# Control-plane worker and Registry Projection locking

Nix Torrent V3 runs torrent engine work (session ticks, inbound peer accept, LSD,
tracker/peer I/O) on a dedicated **worker thread**. The Unix-socket accept loop
on the control thread only parses JSON-line requests.

**Mutating commands** (`add`, `pause`, `resume`, `remove`) are enqueued onto a
command queue; the control thread waits on an `Io.Event` for a worker ack. The
worker drains the queue between ticks and handles each mutate exclusively with
the engine and registry.

**Read commands** (`status`, `show`, `list`) never enqueue and never wait for a
tick. They take a short-hold **projection mutex**, copy fields from the registry
`TorrentRecord` (and completion history), and release. The worker publishes
projections at the end of each session tick via the existing
`session.projectToRecord` path while holding the same mutex briefly, then
releases it before the next tick's blocking I/O. Control reads therefore stay
responsive under connect/announce load (acceptance: under 500ms).

**Why not one big engine lock?** Holding a mutex across peer-connect budgets
would stall `show` for the full batch timeout. Separating the long-running tick
from the short projection publish is what makes the control surface responsive.

**Fair budgets:** each tick still fair-schedules announce and connect attempts
across active torrents via existing per-tick caps
(`max_tracker_announces_per_tick`, `max_peer_connect_attempts_per_tick`,
`peer_connect_batch_budget_ms`).
