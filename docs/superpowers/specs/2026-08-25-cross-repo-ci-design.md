# Fix the testing and CI story after the repo separation

**Date:** 2026-08-25
**Branch:** `claude/optimize-claude-md` (continues the CLAUDE.md optimisation arc)
**Status:** design, approved

---

## The problem, measured

The local gate story is **healthy** and is not what broke. Bare `bin/ci` on this tree:

```
✅ Setup 2.54s · Style 8.04s · scan (3 scanners) 2.98s
✅ test (share) 10.81s · test-s3 15.15s · test-chunk-remote 18.40s · system 1m15.16s
✅ Continuous Integration passed in 2m13.07s
```

Three backend legs at **identical run counts (2357)**, 0 failures, 0 errors. Nothing structural
to fix in `config/ci.rb` or `ci.yml`.

What the separation broke is the three workflows that reach across repos. All four findings below
were measured, not inferred.

### F1 — `nightly.yml` points the Rust client at a server that no longer serves sync

Probed on this tree:

```
recognize_path("/v1/commit", :post) -> ActionController::RoutingError
```

The only non-maker `/v1` routes left here are `POST /v1/test/users`, `POST /v1/devices/login`,
`POST /v1/devices`. But `nightly.yml`'s `e2e-macos` still boots `bin/rails server -p 3001` from
**this** repo and sets `SYNC_IT_SERVER_URL=http://localhost:3001`; `two-device-webdav-macos.sh`
and `two-device-fuse.sh` do the same on their own ports. All three get through signup and device
login, then **404 on the first commit**.

**The last green nightly is pre-separation.** It ran at `2026-08-25T08:30Z`; Arc D Part 2 merged
to main at `2026-08-25T11:54:51Z` — 3h24m later. Tonight's run is the first against the
post-separation tree.

`client-contract.yml` *did* receive this exact fix (check out `tinkerex-sync`, boot
`bin/sync-server` on 3002, with a comment saying "pointing the client at this app would 404 on its
first commit"). `nightly.yml` never did. The fix was applied to the workflow that never runs and
withheld from the one that does.

Secondary: these jobs still export `STORAGE_BACKEND=local`, `CHUNK_PUBLIC_URL`, `CHUNK_LOCAL_DIR`,
which per CLAUDE.md §7 no code in this repo reads any more. Inert.

### F2 — `client-contract.yml` has never run once and reports ✅ on every PR

Its only substantive job is `if: ${{ needs.preflight.outputs.linux == 'true' }}` and the repo
variable `CI_RUNNERS` is `macos`. Every run is `preflight: success` + `engine-integration:
skipped` → workflow conclusion **success**. Verified against run `32879690329`.

Its own header calls it "the fast, per-PR proof that the Rust client can still talk to THIS
server… precisely what Stages 3 and 4 of the sync/maker repo split lean on most", and CLAUDE.md
§14j says the wire is now the *only* thing coupling the repos. That check does not exist in
practice.

It also no longer involves this repo's code at all: post-separation it boots `tinkerex-sync` and
tests `tinkerex-client`. A sync↔client contract living in the maker repo.

### F3 — nightly failures notify nobody and block nothing

Four consecutive red nights, `2026-08-21` → `2026-08-24`, all `Input required and not supplied:
token` — the `TINKEREX_CLIENT_TOKEN` secret referenced from extraction day and never created. A
scheduled workflow has no PR to turn red.

### F4 — docs-only changes still run CI

`ci.yml`'s `pull_request` filter correctly excludes `!docs/**` and `!**.md`. But
**`client-contract.yml` has no paths filter at all** (`pull_request: {}`) — it ran on `e4dfe51`, a
`docs/STATUS.md`-only commit. Separately, `ci.yml`'s `push: branches: [main]` leg is unfiltered,
so a docs-only *merge* runs all six jobs.

### Bonus, found while scoping the handoff

`tinkerex-client` has **no `bin/rails`**, yet its own `rust-client.yml` carries a
`two-device-fuse-linux` job that runs `bin/rails db:prepare` and then
`client/test-conformance/two-device-fuse.sh`, whose line 71 is `… bin/rails server -p "$PORT"`.
So `two-device-fuse.sh` is referenced by **two workflows in two repos**, both linux-gated, and has
never run in either. The handoff is a *correction to an existing job slot*, not a new job.

---

## Principle

**This repo keeps only CI it can go red on.** Everything testing sync↔client — where no `tinkerex`
code is involved — leaves, with a corrected recipe handed over rather than dropped.

---

## The work

### 1. Handoff spec (`docs/superpowers/specs/2026-08-25-cross-repo-ci-handoff.md`)

Written **first**, so nothing survives only in git history. It contains the *fixed* recipes, not
pointers:

**→ `tinkerex-sync`** (lands beside its existing `ci.yml` `test` / `conformance` jobs, both
already `[self-hosted, macos]`):
- `engine-integration`, retargeted `linux` → `macos`.
- Drop `ruby/setup-ruby@v1` — banned on macos jobs and unnecessary (the runner's PATH carries mise
  ruby 3.4.7 = `.ruby-version`).
- Drop `apt-get install libfuse-dev` — linux-only, and `nightly.yml`'s `e2e-macos` already proves
  `sync-engine` builds on mac without FUSE (`fuser` is `cfg(linux)`).
- Boot its own app directly rather than through this repo's `bin/sync-server`.
- Keep `SYNC_VERIFY_FINALIZE=0` and its argument (integration.rs moves bytes via `SharedDirIO`).

**→ `tinkerex-client`** (corrects `rust-client.yml`, adds the nightly-only legs):
- Every job that today boots a Rails server must instead check out and boot **`tinkerex-sync`**.
- `two-device-fuse.sh` and `two-device-webdav-macos.sh` each need one line changed: the
  `bin/rails server` boot becomes a `tinkerex-sync` boot.
- Drop the inert `STORAGE_BACKEND` / `CHUNK_PUBLIC_URL` / `CHUNK_LOCAL_DIR` env.
- Note that `two-device-fuse-linux` already exists there and is currently broken (no `bin/rails`);
  this replaces it rather than adding a second.

### 2. Delete from this repo

- `.github/workflows/nightly.yml`
- `.github/workflows/client-contract.yml`
- The `TINKEREX_CLIENT_DEPLOY_KEY` repo secret (its only two consumers are those files).
  **`TINKEREX_SYNC_DEPLOY_KEY` stays** — `ci.yml`'s `test-chunk-remote` uses it.

### 3. Docs-only stops triggering CI

- PRs: solved by removing `client-contract.yml`, the only unfiltered PR trigger.
- Commits: apply `ci.yml`'s existing `paths` list to the `push: branches: [main]` leg too.

**Trade-off, stated because the current comment argues the other way:** that leg is unfiltered
today as a net for paths-filter drift ("the failure surfaced as red on main AFTER the merge").
`ci_hygiene_test`'s `PATHS_THAT_MUST_RUN_CI` / `PATHS_THAT_MUST_SKIP_CI` now pin the filter in
both directions, which is a stronger net than re-running everything on main. Record the swap in
the comment so the reasoning is not silently reversed.

### 4. Two guards go vacuous on deletion — both this repo's recorded failure shape

- **`PATHS_THAT_MUST_RUN_CI` names `.github/workflows/nightly.yml`.** Its own assertion is
  `assert Rails.root.join(path).exist?, "… no longer exists — fix the list, not the filter"`, so
  deletion turns it red with exactly the right message. Retarget the entry to a workflow that
  still exists.
- **`test "every linux or windows job is preflight-gated…"` will scan zero such jobs** and
  `assert_empty` over nothing — CLAUDE.md §14e verbatim ("a guard that scans a directory dies
  silently when the directory leaves"). Keep the guard, since a future linux job needs it, but
  assert the **overall job set is non-empty** so a workflow-dir move cannot silently retire it.
  Mutation-check both: point `WORKFLOW_DIR` at an empty dir and confirm red.

### 5. Reword `preflight`

With no linux/windows jobs left here, `ci/preflight.sh --summary` reports *"absent — its jobs were
SKIPPED"* about jobs that no longer exist. Keep the job (cheap; it documents the §12.6 gap
honestly) and reword the summary to distinguish **"runner absent, jobs skipped"** from **"no jobs
in this repo need this family."**

### 6. Doc corrections — same branch, same PR (§15)

- **CLAUDE.md §13** — the "Two CI legs here still reach into `tinkerex-client`, deliberately"
  paragraph becomes false in full; rewrite.
- **CLAUDE.md §12.6** — restate: this repo now has no linux/windows jobs at all, so "skipped, not
  passing" is about the siblings.
- **CLAUDE.md §15 "CI"** — the `if:`-gated-on-`CI_RUNNERS` sentence no longer describes this repo.
- **`test/ci_hygiene_test.rb`** — two comments (`:18`, `:95`) cite `nightly.yml`'s `e2e-macos` as
  the precedent for the `ruby/setup-ruby` rule. The rule stays; the citation must not name a
  deleted file.
- **`ci/runners/README.md`** — five `nightly` references (lines 26, 167, 190, 208, 214) covering
  the two-device mounts, the interactive-session caveat, and
  `gh workflow run nightly.yml`.
- **`config/ci.rb`** — the header cites "the client-contract.yml precedent".
- **`docs/STATUS.md`** — one entry for this arc.

---

## Verification

- Bare `bin/ci` green, three legs at identical run counts.
- Both new/changed guards mutation-checked (break the thing, confirm red, restore).
- `ci_hygiene_test`'s set-equality between `bin/ci --list-ci` and `ci.yml`'s gate jobs still holds
  — no gate is added or removed, so this should be unchanged; confirm rather than assume.
- Parse-check the `push: main` filter against the same `PATHS_THAT_MUST_*` lists the PR filter uses.

## Explicitly not in scope

- Registering linux/windows runners (§12.6) — unchanged by this work.
- Making `bin/ci` compare the three legs' run counts instead of printing them. Real gap, declined
  for this branch.
- Any commit or PR in `../tinkerex-sync` or `../tinkerex-client`. The handoff doc is the
  deliverable; the siblings execute it.
