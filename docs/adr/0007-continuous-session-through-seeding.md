# Continuous Torrent Session through Handoff and Seeding

Handoff moves verified content to the Final Destination and records Completion History, but keeps the same Torrent Session open for Seeding from that path. Completion History is a Handoff event that coexists with a live Session — not a terminal “daemon ownership ended” flag. Soft remove drops the Session and keeps files/history (re-add may re-Seed after verify); purge is a separate Control Surface verb that also deletes Final Destination content and prunes history. Inbound peers attach and may upload while Seeding. Cold start restores Seeding Sessions from persistence.

**Considered options:** (A) continuous Session through Seeding; (B) separate seed Session after handoff; (C) Completion History as terminal with no post-handoff Session (v2 / V3 non-goal).

**Consequences:** Supersedes the v2 “completed means no pause/remove/re-add” policy and the former V3 “inbound listen, no seeding” roadmap non-goal. Roadmap for a usable home-lab client lives in GitHub map [#2](https://github.com/jusanherndon/nix-torrent/issues/2), not a static V3 plan file.
