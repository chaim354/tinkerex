# Arc D Part 2 — retire embedded `chunk`; the separate chunk becomes the third backend

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:executing-plans` or
> `superpowers:subagent-driven-development`. Steps use `- [ ]` for tracking.

**Goal:** Delete embedded `chunk` from this repo. `chunk_remote` takes its place as one of the
three Unraid backends a bare "deploy" targets, so the set becomes **chunk_remote + share + s3**.

**Architecture:** The sync engine gem stops being a dependency of this app. `FileLayer::Chunk`
lives *inside* that gem, so dropping the gem deletes the adapter — there is no adapter file in
this repo to remove. What remains here is engine *wiring* (7 real reference sites) and engine
*assumptions* in the suite (57 test files).

---

## What was measured first, because the headline number is misleading

`CLAUDE.md` §12 item 12 says 68 of 224 test files name `Sync::` or `FileLayer::Chunk`. That is
true and it is the wrong number to plan from. Measured 2026-08-25:

| | files |
|---|---|
| `app/`+`lib/`+`config/` naming `Sync::` | 43 |
| …with a **non-comment** reference | **7** |
| `test/**_test.rb` naming either | 68 |
| …with a **non-comment** reference | **57** |
| …of which, references in `chunk_test.rb` alone | **60 of the total** |

So 36 app-side and 11 test-side "hits" are prose describing the architecture. The real work is
7 wiring sites, one large test file that is simply deleted, and a long tail of 1–4-reference
files.

**The test work and the coverage problem are the same work.** Arc C measured the full suite
against a real remote server at **818/2504 failing, ~all a test-shape problem, zero real adapter
defects** — the failures are tests reaching into `Sync::`, which does not exist in a
`chunk_remote` process. Removing those references *is* what makes the full suite run against
`chunk_remote`. Done in this order, retiring embedded chunk does not cost chunk-family coverage;
it converts 10 journey tests into a full suite.

## Two decisions taken here, with their reasons

1. **The hermetic default becomes `share`, not `chunk_remote`.** After this arc there is no
   in-process chunk-family backend, so a chunk-family test needs a booted sync server and a
   `../tinkerex-sync` sibling checkout. Making that the default for `bin/rails test` would put a
   second Rails app between every developer and their test loop. `share` is filesystem-backed and
   hermetic. **The full suite still runs against `chunk_remote` — as a CI gate that boots the
   server** (Task 6), so the main backend is not tested only by its journey suite.
2. **The base destination becomes `chunk_remote` and `deploy.remote.yml` is deleted.** In Kamal
   the base file *is* the no-`-d` destination, so `LIBRARY_BACKEND` there cannot keep naming a
   backend that no longer exists. Folding `remote` into base restores exactly three destinations,
   makes bare "deploy" cover the chunk-family box again, and retires the §7 drift warning Arc D
   Part 1 had to add. The `chunk.tinkerex.*` hostnames are kept — it is still the chunk backend,
   now remote-backed.

**The chunk box's data is disposable, verified rather than assumed** (2026-08-25): 486 users of
which every non-conformance one is test-shaped (`crossos-*`, `e2e-*`, `deploy-verify-*`,
`demo@*`), **0 projects, 0 models**, and `chaim354@gmail.com` owns **0 nodes**. This matches the
spec's recorded "Migration: None — recreate from scratch."

---

## Task 1: make the suite backend-honest — the shared contracts and `test_helper`

**Files:** `test/test_helper.rb`, `test/services/file_layer/adapter_contract.rb`,
`adapter_write_contract.rb`, `adapter_mutation_contract.rb`

- [ ] Remove the `chunk` arm from each shared contract's backend list, leaving share/s3/chunk_remote.
- [ ] Remove `Sync::` setup from `test_helper.rb`.
- [ ] Run `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test` — must stay green.
- [ ] Commit.

## Task 2: delete `chunk_test.rb`, keep what it proved

**Files:** `test/services/file_layer/chunk_test.rb` (delete)

- [ ] Before deleting, diff its assertions against
      `test/services/file_layer/chunk_remote/*_test.rb`. Anything it proves that chunk_remote's
      own suites do not must move there **first** — deleting a test is only safe when the
      property it pinned is pinned somewhere else.
- [ ] Delete the file. Commit, naming any property that moved.

## Task 3: the long tail — 55 test files with 1–4 references each

**Files:** the remainder of the 57, e.g. `architecture_invariants_test.rb` (8),
`generate_preview_job_test.rb` (6), `concurrency_limits_test.rb` (6), `files_flow_test.rb` (5),
`commit_finalize_hook_test.rb` (5), `dev_blobs_test.rb` (3), `capability_gating_test.rb` (3)

- [ ] Work file by file. A reference is one of three kinds and each has a different fix:
      **(a)** reaching into `Sync::` to set up state → drive the **port** instead;
      **(b)** asserting on engine internals → assert on the port's observable answer;
      **(c)** testing the engine itself → **delete**, it belongs to `chaim354/tinkerex-sync`.
- [ ] `commit_finalize_hook_test.rb` and `capability_gating_test.rb` test the *seam* the engine
      provided. With no engine they have nothing to assert here — check each against
      tinkerex-sync's own suite before deleting rather than after.
- [ ] Green on share after each file. Commit in batches of ~10.

## Task 4: remove the engine wiring — the 7 real sites

**Files:** `app/models/user.rb` (7 `has_many`), `app/controllers/dev_blobs_controller.rb`,
`app/services/library_broadcast.rb`, `config/routes.rb`, `config/recurring.yml`,
`config/initializers/{postgres_pooler_check,sync_hooks,sync_capabilities}.rb`,
`lib/library_backend.rb`, `Gemfile`/`Gemfile.lock`

- [ ] `user.rb`: delete the seven engine associations (already engine-conditional).
- [ ] `dev_blobs_controller.rb`: serves the memory/local chunk store's presigned URLs — an
      **embedded-chunk-only** surface. Delete it and its route.
- [ ] `library_broadcast.rb`: the `engine_wanted?` branch collapses to the non-engine arm.
      **`FileLayer::ChunkRemote#batch` must keep working** — §14a says `batch` branches on
      `engine_wanted?`, not on the adapter, so verify the coalescing still fires after the collapse.
- [ ] `routes.rb`: drop `Sync.draw_v1_routes`. **This removes `/v1/changes`, `/v1/chunks/*`,
      `/v1/commit*`, `/v1/conflicts`, `/v1/locks` from the maker app** — intended, and the reason
      Task 7 exists.
- [ ] `recurring.yml`: delete the three engine jobs.
- [ ] `postgres_pooler_check.rb`: the guard protects `User#next_seq!`, which leaves with the
      engine. Delete the initializer.
- [ ] `sync_hooks.rb` / `sync_capabilities.rb`: delete — both configure a gem that is gone.
- [ ] `library_backend.rb`: delete `engine_wanted?` and the `SYNC_ENGINE` knob; drop `chunk` from
      the valid `LIBRARY_BACKEND` set so `LibraryBackendCheck` refuses it loudly.
- [ ] Remove the gem from the Gemfile; `bundle install`.
- [ ] Delete `db/engine_schema.rb`, `lib/engine_schema.rb`, `test/engine_schema_test.rb` — the
      cross-repo obligation they enforce ends with the dependency. **`db/migrate/` is NOT
      touched** (§14j: rewriting it breaks every already-migrated database).
- [ ] Green on share. Commit.

## Task 5: the architecture guards now assert the opposite

**Files:** `test/architecture_invariants_test.rb`, `test/no_engine_boot_test.rb`, `config/ci.rb`

- [ ] The seam guard asserted "zero `Sync::` outside an allowlist". The allowlist is now empty and
      the claim is stronger: **zero anywhere**. Rewrite it that way and mutation-check it.
- [ ] `test-no-engine` was the leg proving the app boots *without* the engine. That is now the
      only mode, so the gate is redundant — **delete it**, and say so in `config/ci.rb`.
- [ ] Mutation-check: plant a `Sync::` reference in `app/` and confirm RED.

## Task 6: CI — the full suite against a real sync server

**Files:** `config/ci.rb`, `.github/workflows/ci.yml`

- [ ] `test` gate: `LIBRARY_BACKEND=share` (hermetic default, decision 1).
- [ ] Replace the 10-test `test-chunk-remote` journey gate with the **full suite** against a
      booted server via `bin/sync-server`. Arc C measured 818 failures here; Tasks 1–3 are what
      drive that to 0. **If it will not reach 0, stop and report the residue rather than
      narrowing the gate to hide it.**
- [ ] Keep `test-share`/`test-s3`. Confirm run counts match across legs (§15).

## Task 7: the client contract points at the sync server

**Files:** `.github/workflows/client-contract.yml`

- [ ] It boots *this* Rails server and runs sync-engine integration against it. Those routes are
      gone as of Task 4, so the job must boot `../tinkerex-sync`'s host app instead.
- [ ] `bin/sync-server` already does this and already strips `BUNDLE_GEMFILE`/`RUBYOPT` (§14j).
      Reuse it; do not hand-roll a second boot recipe.

## Task 8: deployment — three destinations again

**Files:** `config/deploy.yml`, `config/deploy.remote.yml` (delete), `.kamal/secrets*`,
`CLAUDE.md` §7, `.claude/commands/deploy.md`

- [ ] Base: `LIBRARY_BACKEND: chunk_remote`, `CHUNK_REMOTE_URL: http://tinkerex-sync:3000`; drop
      `STORAGE_BACKEND`/`CHUNK_*` (§14a: a non-embedded deployment sets neither).
- [ ] Delete `deploy.remote.yml`; fold `SYNC_ADMIN_TOKEN` into `.kamal/secrets`.
- [ ] **Reset the base volume** — its `nodes` mirror holds 2192 rows from embedded chunk that no
      longer correspond to anything on the sync server. Back up first (`bin/backup-db chunk`)
      even though the data is disposable.
- [ ] `bin/secrets-preflight --all` must name exactly base/share/s3/ovh.
- [ ] §7 and `.claude/commands/deploy.md`: the fourth-destination warning is **removed**, not
      edited — there are three again and bare "deploy" covers the chunk-family box.

## Task 9: deploy and prove

- [ ] `kamal build push`, then deploy base, share, s3. **OVH untouched.**
- [ ] `/up` 200 on all three, both suffixes.
- [ ] In the base container: `Sync` **undefined**, `FileLayer.current` is `ChunkRemote`.
- [ ] Drive a real upload → read-back byte-identical through the base deployment.

## Task 10: the record

- [ ] `docs/STATUS.md`: amend the Stage 5 entry (§15 — one arc, one entry).
- [ ] `CLAUDE.md`: §12 item 12 is now **done** — rewrite it as such rather than deleting it, since
      code cites §12 by number. §3, §7, §13, §14a, §14j all describe a two-chunk-backend world and
      must stop. §14j's engine-boundary rules largely retire with the dependency.
- [ ] `bin/ci` bare green; three legs identical run counts.
