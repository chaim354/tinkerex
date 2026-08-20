# Stage 3a — decouple the sync engine, in place

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the sync engine separable — every bidirectional dependency between it and the maker layer resolved — **without moving a single file into a gem.** When this lands, extracting the engine is mechanical.

**Design:** `docs/superpowers/specs/2026-08-20-stage-3-boundary-design.md` (authoritative), amending `…-chunk-repo-separation-design.md` §1/§5.

---

## Why this is 3a and not 3

Stage 3 as the parent design frames it — "`Sync::*` becomes a mountable Rails engine" — bundles two
different kinds of work: **resolving dependencies** and **relocating files**. Doing them together is
how you end up debugging a gem's load order when the real problem is that the engine calls
`Maker::Previews::Enqueue`.

Stage 2 already proved the alternative. It widened the port *in place*, in the monorepo, verified by
the existing three-leg CI on every commit — and the eventual move became a question about packaging
rather than about design. Stage 1 then took forty minutes because Stage 2 had done the thinking.

**So: 3a decouples, in this repo, green at every step. 3b extracts.** 3b's step-level plan is
deliberately not written yet — see the end of this file for why that is honesty rather than
laziness.

---

## What the measurements say, before you start

Run these yourself; they are the plan's premises and they are cheap to re-check.

**The moving set is seven models, not eight.** `Device` **stays with the host** (boundary design §3):
it is the v1 API's only credential, including for all fourteen `v1/maker/*` controllers, so an
engine that owned it would make the maker API unable to authenticate without the engine mounted. The
models that move are `Version`, `Chunk`, `ManifestChunk`, `PendingCommit`, `ChangelogEntry`,
`Conflict`, `FileLock` — plus `ShareLink` (see Task 6).

**There is exactly ONE real cross-boundary reference today.** Excluding comments, excluding `Device`,
and excluding the already-sync-side directories:

```bash
grep -rlE "\b(Version|ManifestChunk|PendingCommit|ChangelogEntry|FileLock|Conflict)\b" app --include='*.rb' \
  | grep -vE "^app/(services/sync|controllers/v1|models|channels|jobs/(chunk_reaper|pending_commit_reaper|retention))"
```

→ **three files, of which only one is real.** Do not stop at the raw list; check each:

- `app/services/file_layer/chunk.rb` — the sanctioned adapter, already in `SYNC_SIDE_GLOBS`. Not a
  violation; it is the one door.
- `app/controllers/files_controller.rb` — **comments only** (three lines arguing why it reads the
  PORT rather than `Version`). Confirm with `grep -vE '^\s*[0-9]+:\s*#'` before believing the file
  list; the Ripper detector in Task 1 will not see these at all, which is exactly why it uses Ripper.
- `app/services/sharing/links.rb:60` — **the one real reference** (`ManifestChunk`). **And that file
  moves to the engine anyway.**

So after Task 6, a widened guard needs **zero** exceptions.

That is a much smaller blast radius than the boundary design predicted, and it is the single most
useful thing to know before starting: **the hard part of 3a is not the model references. It is the
four behavioural couplings** — the GC reading `share_links`, the engine calling maker business logic,
`V1::BaseController`, and `head_seq`.

**Sizes:** `app/services/sync/` 1380 lines / 14 files · `app/services/storage/` 414 / 4 ·
`app/channels/` 76 / 3 · `app/services/sync.rb` 63 · 14 v1 sync controllers · 3 reaper jobs.

---

## Conventions (all learned the hard way in Stage 2)

- **Mutation-check every guard.** Break the thing it guards, confirm RED, restore. §15.
- **Assert broadcasts with `assert_broadcast_on`**, never by watching `head_seq` — `Sync::Mutation`
  advances it whether or not anything broadcasts.
- **Nest subtree tests two levels** — a one-level test passes against a one-level implementation.
- **Verify sibling adapters, never assume** — Stage 2 found a latent bug in both share and s3 that way.
- **`bin/rubocop` what you touch. Commit with `git commit -F -` and a heredoc** — backticks in `-m`
  get shell-expanded.
- **Revert a mutation with a file copy or targeted edit, NEVER `git checkout <file>`** on a file with
  uncommitted work. It silently discards it.
- `bin/ci` is **7 gates** since Stage 1; three test legs must report identical counts.

---

## Task 1: Widen the architecture guards to the bare model names

Stage 2's seam guard lexes for the `Sync` constant. **The engine's own models are bare top-level
constants**, so the guard is blind to `Version.find(…)` in a maker file — it would stay green today
if someone added one. That blind spot is how the boundary design's findings stayed invisible.

Do this FIRST: it makes every later task's progress visible, and it prevents a regression while
you are moving things.

**Files:** `test/architecture_invariants_test.rb`

- [ ] **Step 1: Extend the detector to the moving models**

The existing `sync_references(file)` uses `Ripper.lex` and matches `:on_const` tokens equal to
`"Sync"`. Widen it to a set. **Ripper, not a regex** — a bare `/Version/` matches prose, and
`app/jobs/library/trash_purge_job.rb` already proves the point by naming `Sync::Gc` inside an
operator-facing error string.

```ruby
  # THE ENGINE'S OWN MODELS ARE BARE TOP-LEVEL CONSTANTS, which is why this set exists and why the
  # `Sync` token alone was never the boundary. A maker-layer file doing `Version.find(...)` reaches
  # into the engine exactly as much as one calling `Sync::Commit`, and the Stage 2 guard could not
  # see it -- that blind spot is how the Stage 3 boundary findings stayed invisible.
  #
  # `Device` IS DELIBERATELY ABSENT, and this is the entry most likely to be "fixed" by someone
  # counting the eight moving tables. Device STAYS with the host: its token is the only credential
  # the whole v1 API accepts, including all fourteen v1/maker/* controllers, so an engine that owned
  # it would leave the maker API unable to authenticate without the engine mounted. Adding it here
  # would flag ApplicationController and Maker::Addons::LibraryOutput as violations for using a model
  # that is theirs.
  ENGINE_MODELS = %w[Version Chunk ManifestChunk PendingCommit ChangelogEntry Conflict FileLock].freeze
```

**Careful with `Chunk`:** `FileLayer::Chunk` is a different class, and inside `module FileLayer` a
bare `Chunk` resolves to it. Ripper cannot tell them apart from tokens alone. Either scope the
`Chunk` check to files outside `app/services/file_layer/`, or drop `Chunk` from the set and say why
— **its only real reference outside the engine is `Sync::Commit`'s own**, so the coverage cost is
nil. Pick one, argue it in the comment, and mutation-check whichever you picked.

- [ ] **Step 2: Run it and confirm the exception list is exactly one file**

Expect `app/services/sharing/links.rb`, and only it — the other two the raw grep returns are the
sanctioned adapter and a file whose hits are comments (see the premises above). If Ripper finds a
real reference anywhere else, **stop and report**: the premise has changed and the rest of this plan
assumes it.

Add the exception list in Stage 2's shape: named, commented, and asserted to match **exactly** what
is non-compliant, so it goes red both when a new violation appears AND when a listed one is fixed.
Include the `assert_not_empty` that tells whoever empties it to delete the list too.

- [ ] **Step 3: Mutation-check, three ways**

1. Add `Version.first` to a maker file → red, naming that file.
2. Remove `sharing/links.rb` from the exception list → red.
3. Add `Device.register!` to a maker file → **must stay GREEN.** This is the one that pins the
   deliberate `Device` exclusion; without it, a later "tidy-up" adding `Device` to the set looks
   harmless.

- [ ] **Step 4: `bin/ci`, then commit**

---

## Task 2: `Node#current_version` → the adapter

Host model querying an engine table. One method, six call sites, all in `FileLayer::Chunk`.

**Files:** `app/models/node.rb`, `app/services/file_layer/chunk.rb`

- [ ] **Step 1: Confirm the call sites before moving anything**

```bash
grep -rn "current_version\b" app/ --include='*.rb' | grep -v "current_version_id"
```

Everything that reads the raw `current_version_id` **column** is fine and stays — that column is on
`nodes` and touches nothing moving. Only the `#current_version` **method** crosses.

- [ ] **Step 2: Move the lookup into `Chunk` as a private helper, delete the method from `Node`**

```ruby
    # WAS Node#current_version, which is host code querying an engine table. Moved here because this
    # adapter is the one file allowed to know versions exist, and it was the only caller.
    #
    # NOT a convenience wrapper to reuse widely: it is one query per node, and the codebase already
    # routes bulk paths around it for that reason (V1::TrashController uses Sync.load_version_sizes,
    # with a comment saying why). If a second caller ever wants this, that is the signal it should be
    # batched, not shared.
    def current_version_for(user, node)
      return nil if node.current_version_id.blank?
      user.versions.find_by(version_id: node.current_version_id)
    end
```

- [ ] **Step 3: Prove nothing else called it** — `bin/ci` green, three legs identical.

- [ ] **Step 4: Mutation-check** — make `current_version_for` return `nil` unconditionally and
confirm a `stat`/`file_info` test goes red. If none does, the size field is unpinned; add an
assertion that pins it.

---

## Task 3: `head_seq` and `next_seq!` become engine-conditional

`head_seq` is a `bigint` on the shared `users` table; `User#next_seq!` exists solely to serialize
changelog sequence assignment under a row lock; and `lib/postgres_pooler_check.rb` + its initializer
exist **only** to protect that lock — booting for **every** deployment, including share and s3, which
have no changelog at all.

**Files:** `app/models/user.rb`, `config/initializers/postgres_pooler_check.rb`, `lib/postgres_pooler_check.rb`

- [ ] **Step 1: Read the pooler check and establish what it actually refuses**

```bash
sed -n '1,60p' lib/postgres_pooler_check.rb
```

Its rule (CLAUDE.md §14e): `next_seq!` must be the FIRST statement in `Sync::Commit#finalize` /
`Mutation#apply` / `Restore` / `Conflicts`, or concurrent commits deadlock on a
`FOR KEY SHARE`→`FOR UPDATE` upgrade — and a **statement-mode pooler breaks it**, so the guard
refuses to boot behind one.

- [ ] **Step 2: Gate it on the deployment having a changelog**

The honest condition is **not** `LIBRARY_BACKEND == "chunk"` — that is a *library* setting, and §14a
records what happens when one capability is inferred from another. The condition is whether the
sync engine is present. Until 3b there is no engine object to ask, so introduce the seam now:

```ruby
# config/initializers/postgres_pooler_check.rb
# GATED, because this guard protects User#next_seq!'s row lock and NOTHING ELSE -- and a share or s3
# deployment has no changelog, never calls next_seq!, and has been refusing to boot behind a
# statement-mode pooler for a rule that cannot apply to it. Stage 3a introduces the seam; 3b replaces
# the predicate with "is the engine mounted?".
```

**Do not change what the guard checks when it does run.** §12.5 is still open and this is the guard
that keeps it honest.

- [ ] **Step 3: Prove the gate both ways**

A test that boots with the gate off must NOT raise behind a simulated statement-mode pooler; one
with it on must. **Both directions**, mutation-checked — a gate that never fires and a gate that
always fires look identical from a green suite.

- [ ] **Step 4: Leave `head_seq` and `next_seq!` where they are, with a comment**

They move in 3b, via the engine's own migration. Moving the column now means a migration in this
repo that 3b immediately has to undo. Record that in `User`:

```ruby
  # ENGINE STATE ON THE HOST'S OWN ROW. head_seq and next_seq! belong to the sync engine -- they
  # serialize changelog sequence assignment and mean nothing on share/s3. They stay here through
  # Stage 3a and move with the engine's migration in 3b; relocating the column now would be a
  # migration this repo would immediately have to undo.
```

---

## Task 4: `V1::CommitsController`'s maker calls become a host-registered hook

The engine calling host **business logic** — `Maker::Previews::Enqueue.call` (`:41`) and
`Maker::ProjectIntakeJob.nudge` (`:49`).

**Files:** `app/controllers/v1/commits_controller.rb`, a new `app/services/sync/hooks.rb`, `config/initializers/`

- [ ] **Step 1: Read the existing calls and their defending comment (`:44-48`) before changing anything.**
It argues why the controller does this. Your replacement must preserve the *behaviour* that argument protects.

- [ ] **Step 2: Add the extension point**

```ruby
# app/services/sync/hooks.rb
module Sync
  # THE ENGINE'S ONE CALL INTO HOST BUSINESS LOGIC, inverted. V1::CommitsController used to call
  # Maker::Previews::Enqueue and Maker::ProjectIntakeJob directly -- not shared DATA, which the
  # engine legitimately needs, but the host's own FEATURES. An engine that requires a preview
  # pipeline to exist cannot be run standalone, which is goal 1 of the whole separation.
  #
  # A HOST THAT REGISTERS NOTHING MUST STILL WORK. That is the property this file exists to create;
  # a `nil` subscriber is the normal case for a bare sync server, not a misconfiguration.
  module Hooks
    ...
  end
end
```

Three properties, each a decision to state in the comment:

- **Runs AFTER the commit transaction commits, never inside it.** §14e's
  `enqueue_after_transaction_commit` finding is the precedent: a job whose argument is a row id,
  enqueued inside an open transaction, loses the race against the in-Puma Solid Queue worker and is
  **discarded silently** by its own `discard_on RecordNotFound`.
- **A subscriber that raises must not fail the commit.** A preview render failing is not a reason to
  reject bytes the client already uploaded. Rescue, log, continue — the posture
  `Library::Reconciler#enqueue_thumbnail` already takes.
- **A host that registers nothing works.** Assert it.

- [ ] **Step 3: Register the two existing behaviours in a host initializer**, so behaviour is unchanged.

- [ ] **Step 4: Mutation-check all three properties**
1. Make a subscriber raise → the commit must still succeed and the response must be unchanged.
2. Register nothing → a commit must still succeed.
3. Move the hook call inside the transaction → a test must catch it. **If none does, write one** —
   this is the property most likely to be silently undone, and §14e records it costing a real bug.

- [ ] **Step 5: Mark `LibraryChannel.batch` as engine PUBLIC API, in the other direction**

The hook above is the engine calling the host. `LibraryChannel.batch` is the reverse and is easy to
miss because it already works: `Maker::ProjectIntake` calls it at `:243` and `:422` to coalesce a
sweep's nudges — the difference, per its own comment, between one broadcast and five hundred.

Nothing needs to move in 3a. What is needed is that **3b must not make it private**, and a comment
is the only thing standing between here and that. Add one to `LibraryChannel.batch` saying the host
calls it, naming `Maker::ProjectIntake` as the caller and what breaks without it, and add
`LibraryChannel` to whatever the engine's public surface is recorded as.

Note for 3b, so it is not rediscovered: once the engine is remote (Stage 4), maker's own moves go
through the port anyway, so coalescing becomes the remote adapter's concern. The embedded answer is
correct but **not permanent** — do not design it as though it were.

---

## Task 5: Split `V1::BaseController`

It names `Sync::Commit::InvalidManifest`, `Sync::Commit::KindConflict`, `Storage::ChunkStore` and
`Storage::LocalChunkStore` at **class-definition time**, and all fourteen `v1/maker/*` controllers
inherit it. So the maker app's own v1 API cannot parse without the engine loaded.

**Files:** `app/controllers/v1/base_controller.rb`, the sync v1 controllers, possibly a new concern

- [ ] **Step 1: Separate the two jobs it does**

Auth (`Authentication`, `Device`) is **host** and stays. The `Sync::`/`Storage::` rescues and the
`stash_request_base_url` presign-base stashing are **engine** concerns.

- [ ] **Step 2: Move the engine half down**

Either into the sync controllers that need it, or into an engine-provided concern the host includes
only when the engine is mounted. **Stage 2 set the precedent**: `FileLayer::Chunk`'s port verbs
re-raise through `FileLayer`'s own vocabulary so callers never name a sync class. The same move
works here.

**Watch `stash_request_base_url`.** Its comment (§14a) records that resolving a chunk store on a v1
request once made a **share deployment's entire v1 API answer 500** — `KeyError: CHUNK_BUCKET` —
including login. It is `syncable`-gated for that reason. Whatever you do, that gate must survive.

- [ ] **Step 3: Prove a maker v1 request works with the engine's rescues absent**

The test that matters: a `v1/maker/*` request succeeding when nothing has loaded `Sync::Commit`.
Hard to stage in a monorepo — if you cannot do it honestly, **say so and pin what you can** (e.g.
that `V1::BaseController` no longer names a `Sync::` constant, via Task 1's guard extended to it).
Do not claim a decoupling you have not demonstrated.

- [ ] **Step 4: `bin/ci`, three legs identical.** The share and s3 legs are the ones that matter here.

---

## Task 6: `share_links` moves to the engine side

The highest-severity finding. `Sync::Gc.apply_retention!` reads `share_links` to protect the versions
live share links point at (`gc.rb:106-114`); split them and **nightly retention silently destroys the
bytes behind URLs users have already sent to other people.**

**Files:** `app/models/share_link.rb`, `app/services/sharing/links.rb`, `app/controllers/v1/share_controller.rb`, `app/controllers/v1/share_links_controller.rb`, `test/architecture_invariants_test.rb`

- [ ] **Step 1: Re-confirm the feature is chunk-only before relocating it**

```bash
grep -n "require_capability" app/controllers/v1/share_links_controller.rb   # expect :versioned
grep -n "user.versions" app/services/sharing/links.rb                        # expect find_by!
```

`versioned` is true on chunk, false on share and s3 (§14a). **Share links cannot exist on the other
two backends at all** — that is what makes this a relocation rather than a feature migration.

- [ ] **Step 2: Move the four files under the engine's ownership**

In 3a that means the directory the guard treats as sync-side, not a gem. Put `Sharing::Links` under
`app/services/sync/` or add `app/services/sharing/**` and the two share controllers to
`SYNC_SIDE_GLOBS` **with the argument written in the guard file** — the reader will otherwise assume
sharing is a maker feature, because it looks like one.

- [ ] **Step 3: Remove `sharing/links.rb` from Task 1's exception list**

It should now be sync-side. `assert_not_empty` should fire, telling you to delete the list. **Delete
it.** That is Task 1's design working.

- [ ] **Step 4: Pin the GC dependency so it cannot be split by accident**

A test asserting `Sync::Gc.apply_retention!` does **not** prune a version a live share link points
at. **Mutation-check it** by removing the `user.share_links` line from `referenced_version_ids` and
confirming red. This is the guard that stands between a future refactor and silent data loss; if it
does not go red, it is not a guard.

- [ ] **Step 5: `bin/ci`, three legs identical.**

---

## Task 7: Two schema corrections

- [ ] **Step 1: Fix `lib/schema_map.rb`'s two false edges**

It labels `maker_previews.version_id` and `maker_file_attachments.version_id` as edges into
`versions` (lines ~110, ~112). The runtime treats that column as a backend-polymorphic
`content_token` — a version UUID on chunk, a **content hash** on share/s3 (`FileLayer::FileInfo`).
**A foreign key that points at a different table depending on deployment is not a foreign key**, and
recording it as one would make 3b move two maker tables it must not move.

`schema_map.rb` is tested (`bin/rails schema:map:check`), so fix the map and its test together.

- [ ] **Step 2: `conflicts` and `file_locks` have no FK to `users`**

They use `t.integer :user_id, null: false` where every sibling uses
`t.references :user, foreign_key: true`. No comment explains it. **Add the FKs, or record the
omission deliberately** — an unenforced ownership edge is exactly what gets violated once the
database is no longer shared. A migration adding two FKs is cheap; discovering a cross-tenant row
after the split is not.

If adding them turns anything red, **that is a finding** — it means such rows already exist. Report
rather than working around it.

---

## Task 8: Documentation

- [ ] **Step 1: CLAUDE.md** — §14a gains the `Device`-stays and hook-inversion invariants, one line
each with the consequence named. Do not renumber sections.
- [ ] **Step 2: `docs/STATUS.md`** — one entry for 3a.
- [ ] **Step 3: Amend the boundary design** to past tense on what 3a resolved, so 3b's author reads
the current state rather than the diagnosis.

---

## Done when

- [ ] `bin/ci` green at 7 gates, three legs identical
- [ ] The widened guard has **zero** exceptions and its list constant is deleted
- [ ] `Sync::Gc`'s share-link protection is pinned and mutation-checked
- [ ] A commit succeeds with no hook subscribers registered
- [ ] `postgres_pooler_check` no longer boots for a deployment with no changelog
- [ ] Every guard written here has been broken once and seen to go red

---

## Why 3b is not written yet

**Because 3a changes the code 3b moves.** Stage 2's plan was written from reading and was wrong in
four places — a "create" that was an extraction, a guessed `Sync::Commit.begin` signature, two
vacuous broadcast assertions, and a mis-cited section that propagated into three code comments. Every
task that survived contact unchanged was one where the implementer was told to read the real call
sites first.

3b's shape is known and its decisions are already recorded in the boundary design §8: the engine's
gem skeleton and mount point; `config/recurring.yml`'s split (Solid Queue reads one host-owned file
and there is no engine-contributed-schedule mechanism); `config/initializers/`'s lack of any boundary
structure; `dev_blobs_controller.rb`, which touches `Storage::` and is in no controller count
anywhere; and the migration story for the seven moving tables plus `head_seq`.

**Write 3b when 3a is green**, against the code as it will then be — not against this description of it.
