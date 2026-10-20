# Audit-the-audit passes (dispatched 2026-10-19, after all 31 rows reached a terminal status)

Five fresh, independent, read-only passes over AUDIT.md + reports/S*.md + the repo at HEAD 75124d67:

| pass | question | output |
|---|---|---|
| coverage | repository coverage and missing subsystem boundaries (dispatched earlier, while the last review lanes ran) | reports/AUDIT-coverage.md |
| overlap | duplication and ownership overlap between findings; cross-subsystem notes not carried into AUDIT.md | reports/AUDIT-overlap.md |
| materiality | materiality and over-abstraction: KEEP / NARROW / DEMOTE / REJECT per finding | reports/AUDIT-materiality.md |
| schema | schema completeness: every F-entry's 8 fields, citations resolve, scope files exist, validation names real tests + a mutation | reports/AUDIT-schema.md |
| priority | dependency-aware priority ranking and best first slices | reports/AUDIT-priority.md |

Shared constraints (identical to BRIEF.md's): repo read-only; one output file each; re-verify cited lines rather than trusting the coordinator's notes; CLAUDE.md §14 + docs/invariants/*.md define intentional semantics; evidence on every claim; the pass recommends and the coordinator adjudicates into AUDIT.md.
