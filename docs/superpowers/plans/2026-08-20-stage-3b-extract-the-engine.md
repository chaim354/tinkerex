# Stage 3b — extract the sync engine into a mounted Rails engine

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `Sync::*` becomes `tinkerex-sync`, a Rails engine the maker app mounts. One process, one database, chunk mode unchanged throughout — Stage 4 is what makes it remote.

**Design:** `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md` §5, as amended by `…-stage-3-boundary-design.md` §6/§8/§8b. **Prerequisite: Stage 3a, merged (PR #207).** Invariants: CLAUDE.md §14j.

---

## THE DECISION THAT DETERMINES EVERYTHING, AND NEITHER DESIGN DOC NAMES IT

**`isolate_namespace` — yes or no.** `rails plugin new --mountable` calls it, and it forces every model, controller and job under the engine's module. Today **every engine constant is bare and top-level**: `Version`, `Chunk`, `ManifestChunk`, `PendingCommit`, `ChangelogEntry`, `Conflict`, `FileLock`, `ShareLink`, plus `Sync` and `Storage` themselves.

**Isolate. And use `Sync` as the namespace.** The argument, and the measurements behind it:

- **A gem that squats `Version`, `Chunk` and `Conflict` at top level cannot be given to anyone.** Those are among the most common class names in Ruby. Goal 1 of the whole arc is a sellable standalone engine; shipping one that collides with half the hosts it might mount into defeats it. Isolating trades **eight** squatted generic names for **one**.
- **`Sync` is already the de facto engine namespace, so choosing it makes the churn small.** There are **216** `Sync::` references in `app/` and they do not move. What moves under it is the eight bare models, `Storage::*` and `LibraryChannel`.
- **The cost is ~90 edits, not thousands** — measured, not estimated. Bare engine constants: **~25 in `app/`**, **~48 in `test/`**. Plus 7 `has_many` on `User` needing `class_name:`, and 8 `belongs_to :user` inside engine models needing `class_name: "::User"` (with `isolate_namespace`, Rails resolves associations inside the engine's module first, so an unqualified `:user` would look for `Sync::User` and fail). The reason it is this small is that almost everything reaches these tables through associations, not constants.
- **Accepted trade-off, stated plainly:** `Sync` is itself a generic top-level name. It is one name instead of eight, it is what the code already uses, and renaming it later is a mechanical find-and-replace of a single token. If a future host collides, that is the fix.

**And do it IN THE MONOREPO FIRST.** That is the lesson Stages 2, 1 and 3a all taught: change the code in place, green on the existing three-leg CI at every step, and the move afterwards is packaging rather than design. Phase A namespaces; Phase B extracts. A plan that does both at once debugs Zeitwerk load order and a constant rename simultaneously, with no way to tell which broke what.

---

## Measured premises — re-check these; the plan rests on them

**The architecture guard's `SYNC_SIDE_GLOBS` is a scanning convenience, NOT a correct "what moves" list.** Two errors, both found by reading the files rather than the globs:

- **It omits `app/services/storage/**`** — 4 files, 414 lines, engine by every functional measure (every caller of `Storage::ChunkStore.current` in the tree is already sync-side). Worse: those files are in **neither** guard bucket, so a `Maker::` reference planted inside `Storage::S3ChunkStore` is caught by **neither direction** today.
- **It sweeps in two host files** through the blanket `app/controllers/v1/**/*.rb` glob: `devices_controller.rb` (its own comment: *"a Device is not only a sync participant: its token is the ONLY credential the whole v1 API accepts… including /v1/maker/*"*) and `test_users_controller.rb` (a dev-only Devise bootstrap that does not even inherit `V1::BaseController`).

**Migrations are tangled and cannot be moved mechanically.** `db/migrate/20260611010000_create_sync_engine.rb` creates `users`, `devices` and `nodes` (host) **and** five engine tables in one `change`. Three more mix sides in a single method: `20260612040000_add_mode_to_nodes.rb` and `20260612050000_add_mtime_to_nodes.rb` (each touches `nodes` **and** `pending_commits`), and `20260819120000_drop_redundant_prefix_indexes.rb` (drops indexes across **7 engine tables and 3 maker tables**). **`users.head_seq` has been in the original migration since day one** — there is no separate migration to move.

**Other facts the plan uses:**
- **No precedent exists for an engine adding associations to a host model.** The closest prior art is already in the dependency tree: Devise's `ActiveSupport.on_load(:active_record)`.
- **`manifest_chunks` has no `has_many` on `User`** — it is reached by the string `manifest_id` everywhere. So `User` carries 7 engine associations, plus `share_links`.
- **Solid Queue reads exactly ONE `recurring.yml`** (`DEFAULT_RECURRING_SCHEDULE_FILE_PATH`, overridable only by env var or CLI flag). No merge, no fragments. Confirmed against solid_queue 1.6.0's source.
- **Routes have no `/v1/sync/` prefix** — sync and `namespace :maker` are flat siblings under one `namespace :v1`.
- **`test/test_helper.rb` embeds both sides** — `pin_sync_hooks_subscribers` (`Sync::Hooks`) and `with_concurrent_file_attachment` (`Maker::FileAttachment`) in the same shared base class, required by every test.
- **No engine test scaffolding exists.** No dummy app; `bin/ci`'s three backend gates each run the whole flat `test/` tree in one process.
- **The gemspec needs `rails` and `aws-sdk-s3`. That is all.** Every other gem is maker-only or host-infrastructure-only — verified by grepping each one's real call sites.
- **ActiveStorage and ActionText are clean** — no engine table has an attachment. Nothing to drag along.
- **`lib/` is unwatched by every guard** — every scan globs `app/**` only.

---

## Conventions

- **Mutation-check every guard.** Break it, confirm RED, restore. §15.
- **`bin/rubocop` what you touch. Commit with `git commit -F -` and a heredoc.**
- **Revert a mutation with a file copy or targeted edit, NEVER `git checkout <file>`** on a file with uncommitted work.
- `bin/ci` is **7 gates**; three legs must report identical counts. Baseline entering 3b: **2552 runs / 9596 assertions / 3 skips**.

---

# PHASE A — namespace in place

Every task here lands in the monorepo, green on the existing CI.

## Task 1: Make the guard's file set a correct inventory

It is about to become the extraction's shopping list, and it is wrong in two directions.

**Files:** `test/architecture_invariants_test.rb`

- [ ] **Step 1: Add `app/services/storage/**/*.rb` to `SYNC_SIDE_GLOBS`**, with the argument: every caller of `Storage::ChunkStore.current` is sync-side, and until now these four files were in neither bucket, so **neither direction of the guard watched them**.
- [ ] **Step 2: Stop the blanket v1 glob sweeping in the two host controllers.** Replace `app/controllers/v1/**/*.rb` with an explicit list, or add `devices_controller.rb` and `test_users_controller.rb` to the same `/v1/maker/`-style rejection. Comment why each is host — quote `DevicesController`'s own comment, which already says it.
- [ ] **Step 3: Mutation-check all three changes.** A `Maker::` reference in `Storage::S3ChunkStore` must now go RED. A `Version.count` in `devices_controller.rb` must now go RED (it is host, so it is a violation). Both must have been GREEN before your change — **verify that first**, or you have not demonstrated the fix.
- [ ] **Step 4: `bin/ci`, commit.**

## Task 2: Extend the guards to `lib/`

`lib/tasks/chunks.rake` is sync-only and **no guard covers it**, because every scan globs `app/**`. Same for `lib/postgres_pooler_check.rb`.

- [ ] **Step 1: Widen both scans to `lib/**/*.rb` and `lib/tasks/*.rake`**, with the engine-side entries added to `SYNC_SIDE_GLOBS`.
- [ ] **Step 2: Expect `lib/schema_map.rb` to be flagged, and do NOT silence it by moving it.** It describes **both** sides' tables (`LAYOUT`/`EDGES`) and is tested. It belongs to neither side; list it as an exception with that reason, and see Task 8.
- [ ] **Step 3: Mutation-check, `bin/ci`, commit.**

## Task 3: Namespace the eight models under `Sync`

The largest mechanical change, and the one to do while a single-repo test suite can still see everything.

**Files:** the 8 model files, `app/models/user.rb`, ~73 constant references across `app/` and `test/`, the guards.

- [ ] **Step 1: Move the files and add the module**

`app/models/version.rb` → `app/models/sync/version.rb`, `class Sync::Version < ApplicationRecord`. Same for the other seven. Zeitwerk requires the path to match the constant exactly.

**`ApplicationRecord` is the HOST's.** From inside `Sync::Version`, an unqualified `ApplicationRecord` resolves correctly today (top-level fallback), but be explicit — `::ApplicationRecord` — because Phase B's `isolate_namespace` changes lookup and an implicit resolution that works now will fail then, at boot, with a message about the wrong constant.

- [ ] **Step 2: `belongs_to :user, class_name: "::User"` in all eight.** Unqualified `:user` works today and **will not** after `isolate_namespace`. Doing it now means Phase B does not have to.
- [ ] **Step 3: `User`'s seven associations gain `class_name:`**

```ruby
  has_many :versions, class_name: "Sync::Version", dependent: :destroy
```
…and so on for `chunks`, `changelog_entries`, `pending_commits`, `conflicts`, `file_locks`, `share_links`. **Leave `devices` and `nodes` alone — both are host.**

- [ ] **Step 4: Update every bare reference.** ~25 in `app/`, ~48 in `test/`. Find them with Ripper, not grep — a comment naming `Version` is not a reference:

```bash
ruby -rripper -e 'Dir.glob("{app,test}/**/*.rb").each { |f| Ripper.lex(File.read(f)).each { |(p,t,s,_)| puts "#{f}:#{p.first} #{s}" if t == :on_const && %w[Version Chunk ManifestChunk PendingCommit ChangelogEntry Conflict FileLock ShareLink].include?(s) } }'
```

**`Chunk` is the trap.** `FileLayer::Chunk` is a different class and lexes identically. Inside `module FileLayer` a bare `Chunk` means the adapter — `app/services/file_layer.rb:120` (`when "chunk" then Chunk.new`) is exactly this, and it sits **outside** `app/services/file_layer/`, which is why Stage 3a dropped `Chunk` from the guard's model list rather than directory-scoping it. Read each `Chunk` hit before changing it.

- [ ] **Step 5: Update the guards.** `ENGINE_MODELS` becomes unnecessary for the models now under `Sync::` — the `Sync` token already catches them. Say so rather than leaving a list that no longer does anything; and re-check whether `ENGINE_ASSOCIATIONS` still needs to exist (it does — `user.versions` is still association access with no `Sync` token).
- [ ] **Step 6: `bin/ci`, three legs identical. Commit.**

## Task 4: Namespace `Storage` and `LibraryChannel` under `Sync`

- [ ] `app/services/storage/*.rb` → `app/services/sync/storage/*.rb`, `Sync::Storage::ChunkStore` etc. Update all call sites (they are all sync-side already, so the blast radius is inside the engine).
- [ ] `app/channels/library_channel.rb` → `app/channels/sync/library_channel.rb`, `Sync::LibraryChannel`. **Callers include `Maker::ProjectIntake`** (`:243`, `:422`) — that is the deliberate host→engine public API from 3a's Task 4 Step 5, so update it and keep its comment.
- [ ] **Leave `ApplicationCable::{Channel,Connection}` alone** — boilerplate the host owns; `Connection#connect` uses `Device.authenticate`, and `Device` is host.
- [ ] `bin/ci`, commit.

## Task 5: Split the tangled migrations

**Do not skip this to "sort out later."** Four files block a mechanical move.

- [ ] **Step 1: Decide the strategy and write it down.** Two honest options:
  - **(a) Leave history alone; the engine ships ONE consolidated `create_sync_engine` migration** that creates its eight tables from scratch for a *new* host, while this app — whose tables already exist — records it as already-run. Standard `rails engine` practice (`install:migrations` + a schema check).
  - **(b) Split each mixed migration into a host half and an engine half**, rewriting timestamps. Cleaner history; touches migration files this app has already run everywhere, and CLAUDE.md §14i's backup/restore rehearsal exercises real archives against a real schema.
  - **Recommendation: (a).** Migration history is a record of what happened, and rewriting it to match a boundary invented afterwards is the tail wagging the dog. What matters is that a fresh host can install the engine's schema and this host recognises its own.
- [ ] **Step 2: Prove a fresh install works** — `bin/rails db:drop db:create db:schema:load` (or the engine's installer, once it exists) must produce a schema byte-identical to `db/schema.rb`. Diff it.
- [ ] **Step 3: Prove THIS app still migrates from its current state** — `bin/rails db:migrate:status` shows nothing pending, and `bin/ci` is green.

---

# PHASE B — extract

Only start when Phase A is merged and green.

## Task 6: Create the gem skeleton

- [ ] `rails plugin new tinkerex-sync --mountable --skip-*` for everything not needed. **`isolate_namespace Sync`.**
- [ ] The gemspec declares **`rails` and `aws-sdk-s3`**, nothing else. Verified: every other gem in the Gemfile is maker-only or host-infrastructure-only.
- [ ] A `test/dummy` host app — **none exists today**, and the engine's suite needs one.
- [ ] **The engine must declare `User`, `Node` and `Device` as HOST REQUIREMENTS**, not define them. Document it in the gem's README, and fail loudly at boot if they are absent rather than at the first request.

## Task 7: Move the code

Use Task 1 and 2's corrected `SYNC_SIDE_GLOBS` as the inventory. Move with history (`git filter-repo`, as Stage 1 did — 3a's arc proves the pattern and Stage 1's plan documents the exact invocation).

- [ ] **`V1::BaseController` is SPLIT, not moved.** Stage 3a already removed its `Sync::`/`Storage::` references; what remains — `include Authentication`, `include LibraryCapabilities`, and generic JSON `rescue_from`s — is shared v1 infrastructure that all fourteen `v1/maker/*` controllers inherit. The engine's controllers need a base; the host's maker controllers need the same one. **Decide: does the engine ship a base the host also uses, or do both inherit from a small shared thing?** This is the single hardest file in the move.
- [ ] **`app/services/file_layer.rb` stays with the HOST.** Its `build` method constructs `Chunk` (engine), `Share` and `S3` (host) in one `case` — it *is* the seam. The engine ships the adapter; the host's factory chooses it.
- [ ] **`config/initializers/sync_hooks.rb` stays with the host** and becomes the gem's README example. It is what a host writes for itself.
- [ ] **`devices_controller.rb` and `test_users_controller.rb` stay** (Task 1).

## Task 8: The three cross-cutting artifacts

- [ ] **`config/recurring.yml`** — Solid Queue reads one host-owned file, no merge. **The host keeps the three engine entries, naming engine job classes**, and the engine's README documents them as a host obligation. Anything else invents a mechanism Solid Queue does not have. `test/recurring_schedule_test.rb` validates all entries generically and stays with the host.
- [ ] **`lib/schema_map.rb`** — describes both sides; its `LAYOUT` "sync" group is a **diagram-layout label, not the extraction boundary** (it puts `users`, `devices` and `nodes` in that column for adjacency). **Stays with the host**, and its authored half now describes tables whose migrations live in another repo — an authoring-across-repos problem with no existing mechanism. Say so in its header rather than letting the next reader discover it.
- [ ] **`lib/postgres_pooler_check.rb`** — protects engine state, called by a host initializer gated on `Sync.engine_present?`. **Recommendation: it moves to the engine and the host initializer calls it**, because the rule it enforces is the engine's. Replace `Sync.engine_present?`'s body with a real check now that there is an engine object to ask — that is what 3a built the seam for.

## Task 9: The test suite

- [ ] **`test/test_helper.rb` must split.** It embeds `Sync::Hooks` (`pin_sync_hooks_subscribers`) and `Maker::FileAttachment` (`with_concurrent_file_attachment`) in one shared base required by every test.
- [ ] **Six engine models have NO dedicated test file** (`Version`, `Chunk`, `ManifestChunk`, `PendingCommit`, `ChangelogEntry`, `Device`), and `Storage::S3ChunkStore` has no unit test — their coverage rides inside service and adapter tests that also exercise other things. **Do not assume the engine's test directory is self-contained.**
- [ ] **These test files straddle and need decisions**, not moves: `architecture_invariants_test.rb` (its whole premise is one repo), `schema_map_test.rb`, `recurring_schedule_test.rb`, `commit_finalize_hook_test.rb` (tests the seam itself), and three maker tests that build engine rows as fixtures — `files_flow_test.rb` (`PendingCommit.count`), `generate_preview_job_test.rb` (`ManifestChunk.create!`, `Version.create!`), `file_bytes_test.rb` (`Sync::Commit.begin/finalize`).
- [ ] **`bin/ci` gains an engine gate**, and the engine repo gets its own CI. Note Stage 1's lesson: **runners register per repository**, and a workflow with no registered runner is *skipped, not passing*.

## Task 10: Documentation

- [ ] CLAUDE.md §14j gains the namespace decision and the host-requirement list. Do not renumber.
- [ ] `docs/STATUS.md` — one entry.
- [ ] The design doc goes past tense on Stage 3.

---

## Done when

- [ ] `bin/ci` green, three legs identical, in the host repo
- [ ] The engine's own suite is green in its own repo, on a registered runner
- [ ] A fresh `db:schema:load` matches `db/schema.rb` byte-for-byte
- [ ] `Sync::` is the only top-level constant the engine defines
- [ ] The host boots with the engine mounted and chunk mode behaves identically — verified by driving a real upload, not by a green suite
