# Moving the record from Forgejo to Kaneo

**Date:** 2026-08-30
**Status:** design, approved for planning
**Touches:** `bin/log`, `test/log_cli_test.rb`, `test/support/stub_forgejo.rb`, CLAUDE.md §11/§13/§15,
`.claude/commands/{deploy,execute-plan,finish-branch}.md`, `config/ci.rb`, `test/docs_hygiene_test.rb`

---

## 1. What is moving, and what is not

CLAUDE.md §11 makes a self-hosted Forgejo the canonical record: every completed arc is a closed
`arc` issue, open work is `open-work`, deploys are `deploy`, and corrections are comments. §13 makes
`bin/log` the single write door onto it. That record moves to **Kaneo**, a self-hosted project
management app, and **Forgejo is decommissioned**.

Forgejo is used here *only* as an issue tracker. Pull requests are on GitHub, and §11 already records
that nothing bridges the two. So this is a tracker swap, not a forge migration — no git data moves.

**Out of scope, decided:** backup. Every destination `ops/backup-db.sh` knows (`chunk|share|s3|sync`)
is SQLite in a Docker volume, dumped by running the app's own image against it; Kaneo is Postgres in
a Portainer stack, which needs a different dump and verify path. The operator has a separate backup
method for this box. **No `bin/backup-*` or `ops/` file is touched by this arc**, and §14i is not in
play.

---

## 2. What was measured

Every figure below was measured on 2026-08-30, not recalled. The commands are named so a later
reader can re-measure rather than trust this paragraph — §15's rule about a doc row being a claim.

**The Forgejo record** (`GET /api/v1/repos/chaim354/tinkerex/issues?state=all&type=issues`, paginated
at the server's 50-per-page cap):

| | |
|---|---|
| issues | **186**, numbered **6–193**, gaps at **116, 117** |
| state | 28 open, 158 closed |
| labels in use | `arc` 135, `open-work` 34, `deploy` 17; **0 unlabelled** |
| comments | 30, across 21 issues |
| body text | 1,050.1 KB total, largest single body 77.6 KB |
| `tinkerex#N` inside bodies | 50 |

Forgejo reports `11.0.16+gitea-1.22.0`, i.e. it is Gitea-API-compatible.

**Citations in the tree** — `grep -rhoE "tinkerex#[0-9]+" app/ lib/ test/ config/ bin/ docs/ .claude/ CLAUDE.md`:
**129 occurrences, 24 distinct issue numbers.** This is the constraint that shapes the whole
migration.

**The box** — `forgejo.home`, `kaneo.home`, `unraid.home` and `tower.home` all resolve to
**192.168.1.7** (wildcard `*.home`). **Portainer 2.39.6** at `portainer.home`. **Nginx Proxy Manager**
is the reverse proxy, admin on `:81`; `kaneo.home` currently falls through to NPM's default site, so
DNS exists but no proxy host does. **Kaneo is not deployed.**

**Kaneo upstream** — MIT (clears §9). Latest stable on ghcr.io is **2.18.0**. The API exposes **114
paths**; the ones this design uses are `POST /task/{projectId}`, `GET /task/{id}`,
`PUT /task/status/{id}`, `POST /comment/{taskId}`, `GET /comment/{taskId}`, `GET /search`,
`POST /label`, `PUT /label/{id}/task`, `GET /task/tasks/{projectId}`, `POST /project`,
`GET /column/{projectId}`, `GET /instance/status`. Auth is `Authorization: Bearer <api-key>`, the key
minted in the UI under Settings → Account → Developer Settings.

**Blast radius** — `bin/log` 566 lines (27 Forgejo mentions), `test/log_cli_test.rb` 868 lines (91),
`test/support/stub_forgejo.rb` 128 lines, CLAUDE.md 11 mentions, three `.claude/commands/` files and
`config/ci.rb` with one each, plus **13 prose comments in `app/` and `test/`** naming "the Forgejo
record" (§8).

**CLAUDE.md is 1,355 lines — exactly `MAX_LINES` in `test/docs_hygiene_test.rb`.** Every doc edit in
this arc must be line-neutral. This is not incidental: the ceiling is a ratchet and that file's own
header forbids raising it to buy headroom for an unrelated change.

---

## 3. The one hard problem, and the decision

**Kaneo assigns task numbers from an atomic per-project counter, and neither
`POST /task/{projectId}` nor `POST /task/import/{projectId}` accepts a `number`.** Forgejo's
numbering starts at 6 and has two holes, so a straight import renumbers everything and all 179
citations (129 in the tree, 50 in bodies) rot at once.

**Decision: force the numbers to line up.** Import in strict ascending Forgejo order, minting seven
placeholder tasks to burn numbers 1–5 and 116–117, so every real issue lands on its own number.

Why this over the alternatives:

- *Renumber and rewrite the tree* was rejected because it only fixes the citations this repo can
  reach. Citations in merged PR bodies, deleted branches and the two sibling repos
  (`tinkerex-sync`, `tinkerex-client`) rot permanently, and nothing would ever go red for it — the
  silent-failure shape §15 names as this repo's dominant mode.
- *Stop citing the tracker's number* was rejected as more machinery than the problem needs, and it
  puts two competing numbers in front of every reader.

**Consequence, and the payoff:** the 129 code citations and 50 body cross-references are **not
touched**. `tinkerex#178` keeps resolving. The only thing that moves is the base URL in §11 — which
is exactly why §11 says that URL is "DEFINED HERE AND NOWHERE ELSE".

**The scheme rests on an unverified assumption** — that the counter starts at 1, increments by one
per created task, and does not reuse a deleted task's number. That is measurable and is measured
before anything is imported; see §6, step 2. §15: probe, do not reason.

---

## 4. The record's shape in Kaneo

**One workspace, one project.** Not a preference — the counter is per-project, so splitting arcs,
open-work and deploys into three projects would shatter `tinkerex#N` into three sequences.

| Forgejo | Kaneo |
|---|---|
| label `arc` / `open-work` / `deploy` | workspace label, same name |
| state `open` / `closed` | column (`status`) `Open` / `Done` |
| issue `number` | task `number` (preserved, §3) |
| issue `body` | task `description` |
| comment | task comment |
| — | `priority: no-priority` on every task (required on create, unused here) |

`bin/log setup` creates all eleven names in `LABELS`, not just the three in use, keeping today's
behaviour: it is idempotent by asking what exists, never by tolerating a duplicate — Kaneo, like
Forgejo, will happily create two labels with the same name.

---

## 5. `bin/log`

The interface does not change. Same nine subcommands, same exit codes (0 ok, 2 usage, 3 unreachable
*and spooled*, 4 unfiled backlog, 5 a bug in the script), same spool file, same no-bundler
stdlib-only constraint, same single-write-door rule — MCP may read and never writes. `/finish-branch`
and `/execute-plan` read those exit codes and must keep working unchanged.

What changes:

- **Auth.** `Authorization: Bearer <key>` replaces `token <key>`. `TOKEN_REF` becomes a Kaneo vault
  item, still resolved through `bin/secret` with `Open3.capture3` keeping the streams apart — any
  rewrite that merges them re-opens the 2026-07-29 leak.
- **Config.** `KANEO_URL` / `KANEO_PROJECT` replace `FORGEJO_URL` / `FORGEJO_OWNER` / `FORGEJO_REPO`.
- **Number → id resolution — the one genuinely new mechanism.** Every Kaneo path takes the opaque
  `{id}`; the citable `number` is not addressable. `show`, `note` and `close` therefore need a lookup
  Forgejo never required. It is a real wire call, so it must be inside the `Unreachable` handling
  that spools, and a number that resolves to nothing must fail as "no such issue", not as a crash.
- **`close` is a column move** (`PUT /task/status/{id}` → `Done`), not a state change.
- **Labels attach as a second call.** `POST /task/{projectId}` has no `labels` field. This makes
  `create_issue` non-atomic in a way the Forgejo version was not: a task can exist unlabelled if the
  second call fails. The failure must be reported, and must not be reported as success.

Tests: `test/support/stub_forgejo.rb` becomes `stub_kaneo.rb`, and `test/log_cli_test.rb` adapts.
The stub must answer the **wire format Kaneo actually uses**, not a round-trip of our own encoder —
§14e's `FakeS3` lesson, where an exact-inverse fake kept 79 of 80 tests green over silent data loss.

---

## 6. Order of work

The sequence is chosen so the irreversible step comes after the step that proves it will work.

1. **Export first, before anything is created.** All 186 issues and 30 comments to one JSON file,
   verified by issue count, number set, and per-issue body byte length against the live API. This is
   the only copy of the record; every step after it is redoable from this file. Forgejo was never
   covered by the backup tooling, so nothing else stands behind it.
2. **Deploy Kaneo** (§7) and **probe the counter** on a throwaway project: create three tasks and
   confirm they number 1, 2, 3; delete one and create another to see whether the number is reused.
   If the assumption in §3 does not hold, stop here — nothing has been imported and the fallback to
   renumbering is still open.
3. **Create the real project and the labels.**
4. **Import** in strict ascending Forgejo number, placeholders included.
5. **Verify all 186**: Kaneo `number` == Forgejo `number` and titles match, read back from the API.
   A mismatch aborts to a clean project and retries from the export — cheap, because of step 1.
6. **Import the comments**, keyed by resolved task id.
7. **Rewrite `bin/log`** and its tests; `bin/ci` green.
8. **Update the docs** (§8).
9. **Retire Forgejo** — last, and only once 1–8 are done and the export is archived off-box.

---

## 7. The Portainer stack

Adapted from upstream's compose, with three deliberate departures:

- **`ghcr.io/usekaneo/kaneo:2.18.0`, pinned — not `:latest`.** A floating tag on the box holding the
  canonical record upgrades it without anyone deciding to.
- **Postgres publishes no port.** Upstream publishes 5432; nothing off-box needs it.
- **No MinIO.** Object storage is optional upstream and powers only image uploads in descriptions and
  comments. The record is pure markdown, so the whole service is omitted rather than configured.

Required env: `KANEO_CLIENT_URL=http://kaneo.home`, `DATABASE_URL`, `POSTGRES_{DB,USER,PASSWORD}`,
`AUTH_SECRET` (≥32 bytes, `openssl rand -hex 32`). `KANEO_API_URL` defaults to
`KANEO_CLIENT_URL/api` and is left unset. `TRUSTED_PROXIES` already covers `192.168.0.0/16` by
default, which is correct for NPM on this LAN.

**First-run order is load-bearing.** `GET /instance/status` reports `hasUsers: false`, and the next
signup becomes instance admin. So: deploy → sign up immediately → then set `DISABLE_REGISTRATION=true`
and `DISABLE_GUEST_ACCESS=true` and redeploy. Leaving registration open on a LAN-reachable instance
holding the canonical record is the failure this ordering exists to prevent.

Then: NPM proxy host for `kaneo.home` → the stack's published port; mint the API key in the UI; store
`AUTH_SECRET`, `POSTGRES_PASSWORD` and the API key in 1Password, read through `bin/secret` per §14g,
never `export`ed.

---

## 8. Docs

Word-swaps only, and **line-neutral** — CLAUDE.md is at its ceiling (§2).

- **§11** — the base URL and repo path. This is the section the whole citation-preserving scheme pays
  off in: because numbers are preserved, this is the *only* place the address of the record changes.
- **§13** — the `bin/log` cheatsheet block.
- **§15** — the close-out rules that name Forgejo ("the record is a self-hosted Forgejo, nothing
  bridges them").
- Prose references at CLAUDE.md lines 9, 318, 430, 501, 565, 860, 1322.
- `.claude/commands/{deploy,execute-plan,finish-branch}.md`, `config/ci.rb:111`,
  `test/docs_hygiene_test.rb:98`.

**13 code comments name the product, and the fix is to stop naming it.** `app/` and `test/` carry
thirteen prose references of the form "the Forgejo record (CLAUDE.md §11)" — in
`maker/inventory_item.rb`, `concerns/maker/text_only_rich_text.rb`, `maker/project_intake.rb`,
`maker/previews/{enqueue,missing_backfill}.rb`, `test_helper.rb`, `ci_hygiene_test.rb`,
`docs_hygiene_test.rb`, `chunk_remote_journey_test.rb`, `system/{code_viewer,importer}_test.rb`, and
`services/maker/previews/missing_backfill_test.rb`.

§11's stated design is that "code comments cite a bare `tinkerex#N`, so the instance can move without
touching them" — but these name the product, so they did not get that protection. **Rewrite them to
"the record (CLAUDE.md §11)", dropping the product name rather than swapping it.** A Forgejo→Kaneo
swap leaves the identical trap set for the next migration; removing the name discharges it
permanently, and §11 remains the one place the instance is identified.

**Historical documents are NOT rewritten.** `docs/superpowers/specs/2026-08-26-status-to-forgejo-design.md`
and the dated plans under `docs/superpowers/plans/` are records of finished work. They were true when
written and rewriting them falsifies the history this repo is careful about. They keep saying Forgejo.

**One pre-existing defect to fix while here:** CLAUDE.md:374 names the vault item
`op://tinkerex/Forgejo/token`, while `bin/log`'s `TOKEN_REF` is
`op://tinkerex/forgejo key/credential`. They disagree today; one of them has always been wrong. The
Kaneo equivalents must agree, and the doc must name what the code actually reads.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| The counter does not behave as assumed | Probed on a throwaway project *before* any import (§6.2). Fallback to renumbering is still open at that point. |
| Import fails partway, leaving a half-populated project | Every step is redoable from the step-1 export. Verification (§6.5) is read-back from the API, not from what we believe we sent. |
| Placeholder tasks are deleted later and shift numbers | Placeholders stay in place, closed and labelled, rather than being deleted. A visible hole is safer than a shift. |
| Label attach fails after task create | Reported as a failure; §5. Not silently swallowed. |
| A doc edit trips the CLAUDE.md ceiling | All edits are word-swaps; `bin/ci` runs `docs_hygiene_test`. |
| Forgejo is retired before Kaneo is proven | Retirement is step 9, after the export is archived off-box. |

---

## 10. Definition of done

- `bin/log` writes only to Kaneo; all nine subcommands work against the live instance.
- All 186 issues present in Kaneo at their original numbers, with labels, state and comments.
- `tinkerex#178` resolves — the 129 tree citations are untouched and still correct.
- `bin/ci` green, all three backend legs reporting identical run counts.
- No `FORGEJO_*` name and no `forgejo.home` reference remains in `app/ lib/ test/ config/ bin/ .claude/ CLAUDE.md`.
- The 13 "the Forgejo record" code comments say "the record" — naming no product, so the next move is free.
- `docs/superpowers/{specs,plans}/` still say Forgejo, deliberately: they are dated history.
- The export file is archived off-box.
- Forgejo is stopped.
