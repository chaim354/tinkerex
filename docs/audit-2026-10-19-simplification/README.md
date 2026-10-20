# Simplification audit, 2026-10-19 — supporting material

The audit itself is `docs/AUDIT-2026-10-19-simplification.md` (read that first). This directory holds
what it cites:

- `reports/S01.md` … `reports/S34.md` — one bounded, read-only review per subsystem row (S30, S31 and
  S35 were explicit skips and have no report).
- `reports/AUDIT-coverage.md`, `AUDIT-overlap.md`, `AUDIT-materiality.md`, `AUDIT-schema.md`,
  `AUDIT-priority.md` — the five independent audit-the-audit passes the coordinator adjudicated.
- `BRIEF.md` — what every subsystem reviewer was told; `AUDIT-PASS-BRIEF.md` — the shared brief of
  the five passes.
- `COORD-summary.md`, `COORD-priorities-draft.md` — the coordinator's adjudication aids (the draft
  was written before the priority pass landed, to reconcile against rather than adopt it).

Everything here was produced read-only against HEAD 75124d67; nothing was executed. Each finding's
8 fields, the coordinator's verification and adjudication, and the final ranking are in the audit
file, not here.
