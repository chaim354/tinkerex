# docs/ — what is current, what is history

Fifty-odd files live here because this repository carried the sync engine and the desktop client
until the split of 2026-08-20, and every plan and audit from that era stayed. Each historical file
now opens with a banner saying so. Read the first group as true; read the second for its reasoning
and its measurements, never for what the repository contains today.

## Current

| file | what it is |
|---|---|
| `INSTALL.md` | How a stranger runs the app with docker compose; the environment reference (kept complete by `test/install_docs_test.rb`). |
| `DEPLOY.md` | The author's Kamal runbook for the author's hosts. Not for strangers. |
| `AUDIT-2026-10-12-readiness.md` | The readiness audit: what stood between the app and being presentable, usable and safe, and which sub-projects closed what. |
| `user-stories.md` | The bench maker's stories with an honesty tag per row (works / rough / missing). Living. |
| `sync-protocol.md` | The normative wire spec between this app and the sync server. |
| `addon-api-v1.md` | How to write an addon for the Tools gallery. |
| `adding-a-preview-format.md` | How to add a preview renderer. |
| `roads-not-taken.md` | Approaches considered and rejected, with the why. Read before reviving any of them. |
| `schema-map.html` | Generated map of every table and relationship (`bin/rails schema:map`). |
| `addon-backlog.md` | Ideas for addons. |
| `invariants/` | The area-scoped rules CLAUDE.md §14 points into. Not optional reading inside their areas. |
| `superpowers/specs/`, `superpowers/plans/` | The design and plan documents of every arc, by date. Specs are the written product intent; plans are executed checklists. |
| `adr/` | Architecture decision records. |

## Historical (banner at the top of each)

Pre-split plans, research and audits: `plan-*.md`, `research-*.md`, `AUDIT-2026-07-30.md`,
`AUDIT-2026-08-03.md`, `AUDIT-2026-08-19.md`, `FIX-LOG-2026-08-19.md`, `SYSTEM-AUDIT-2026-07-28.md`,
`security-audit-2026-06-17.md`, `architecture-sync-engine.md`, `building-the-app.md`,
`cfapi-write-path-findings.md`, `conformance-status.md`, `cost-model.md`,
`feature-set-and-workflows.md`, `git-on-mount.md`, `parity-roadmap.md`, `posix-compatibility.md`,
`r2-migration.md`, `torn-writes-and-batching.md`, `user-stories-sync-2026-06.md`, `versioning.md`,
and the redirect stub `SYNC_SERVER.md`.

The canonical record of finished work is not a file here at all: it is the Kaneo project CLAUDE.md
§11 names, read with `bin/log`.
