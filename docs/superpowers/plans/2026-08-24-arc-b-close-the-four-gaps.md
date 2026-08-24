# Arc B — close the four gaps Arc A measured

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or
> superpowers:executing-plans. Steps use `- [ ]` checkboxes.

**Goal:** take the `chunk_remote` journey suite from **6 pass / 4 fail** to **10 / 10**, then promote
`test-chunk-remote` from a deliberately-red separate workflow into a real `bin/ci` gate.

**Architecture:** four independent fixes, one per measured gap. Each is verified by a journey test
that already exists and already fails for the right reason — so unlike most work, the acceptance
criterion was written before the fix and cannot be tuned to match it.

**Branch:** off `claude/stage-5-arc-a` (PR #226), because the journey suite is the verification.

**Work-list:** `docs/superpowers/plans/2026-08-23-arc-b-worklist.md` — the measured record, produced
by running the thing rather than reading it.

---

## The rule that makes this arc trustworthy

**Do not touch `test/integration/chunk_remote_journey_test.rb` except where a task says so.**

Those ten tests were written against what the system *should* do, before anyone knew what it did,
and four of them fail. That is the only reason they are worth anything. A fix that adjusts the test
until it passes has proved nothing — and the temptation is real, because three of these assertions
are strict. If a test looks wrong, **stop and say so**; do not quietly relax it.

---

## Task 1: gap (a) — the mirror never refreshes except after this app's own writes

**Files:**
- Create: `app/jobs/file_layer/remote_changelog_pull_job.rb`
- Modify: `config/recurring.yml`
- Test: `test/jobs/file_layer/remote_changelog_pull_job_test.rb`

**The defect.** `ChangelogSync` has exactly one caller, `FileLayer::ChunkRemote#refresh!`, reached
only from `mkdir`/`move`/`delete`/`undelete`/`finalize_upload` — all writes by *this* app. A node
another device pushed is invisible until this app happens to write something. `GET /files` never
refreshes.

- [ ] **Step 1: Write the failing test.** A job that, for each user, pulls the changelog when the
  backend is `chunk_remote` and does nothing otherwise. Assert the gate BOTH ways — that it pulls
  on chunk_remote and that it does NOT on share/s3/chunk. A gate asserted in one direction is half
  a gate.
- [ ] **Step 2: Run it, watch it fail.**
- [ ] **Step 3: Implement the job.** Per user, `ChangelogSync.new(user, transport:).call`.
  **A raising user must not stop the sweep** — one unreachable library is not every library's
  problem. Follow `Library::ScanJob.scan_all!`'s existing shape for the fan-out.
- [ ] **Step 4: Wire `recurring.yml`.** `command:`, not `class:` — Solid Queue resolves a `class:`
  at load and reads ONE file with no merge mechanism (§14j), so the backend gate must live in a
  class method. `library_scan` and `project_folder_intake` are the precedents.
- [ ] **Step 5: Pick the interval, and say why in the file.** `library_scan` polls at 15 minutes
  because a NAS scan is expensive; a changelog pull that finds nothing is one cheap GET. State the
  number you chose and the reasoning, and note that the real fix for latency is the sync→maker
  webhook, which is out of scope here.
- [ ] **Step 6: Green, then run the journey test.**
  ```bash
  bin/sync-server prepare && set -a && . tmp/sync-server.env && set +a && bin/sync-server start &
  LIBRARY_BACKEND=chunk_remote bin/rails db:test:prepare test TEST=test/integration/chunk_remote_journey_test.rb
  ```
  Gap (a)'s test must now PASS and the other three must still fail unchanged. If a different test
  changed state, say so loudly.
- [ ] **Step 7: Mutation-check the gate.** Make the job run on every backend and confirm the
  wrong-backend assertion goes RED. Restore.
- [ ] **Step 8: Commit.**

---

## Task 2: gap (b) — every addon save raises `NameError`

**Files:**
- Modify: `app/services/file_layer/chunk.rb`, `chunk_remote.rb`, `capabilities.rb` (if needed)
- Modify: `app/services/maker/addons/library_output.rb`
- Modify: `test/architecture_invariants_test.rb`
- Test: the adapter contract files under `test/services/file_layer/`

**The defect.** `port_writable: false` sends `LibraryOutput#write` down `#write_chunk`, which calls
`Sync::Storage::ChunkStore.current.put` — a constant that does not exist when the engine is not
loaded. Every addon save on `chunk_remote` is a `NameError`.

- [ ] **Step 1: Add `put_chunk` to the port.** Signature `put_chunk(user, begun:, hash:, bytes:)`,
  where `begun` is the `UploadBegun` the caller already holds — it carries `missing` (what the
  caller iterates) and `put_urls` (what only the remote adapter reads), so neither adapter is
  handed a field the other cannot use.
- [ ] **Step 2: Implement it per adapter.** `Chunk` → `Sync::Storage::ChunkStore#put`.
  `ChunkRemote` → an HTTP PUT to `begun.put_urls[hash]`.

  **The asymmetry is why this is a port verb and not one shared implementation, and it must be
  commented as such.** On embedded chunk a presigned URL for the memory or local store points at
  *Rails itself*, so a server-side PUT to it is a loopback call into the same Puma pool — §14e's
  recorded reentrancy bug, measured at 14–24 second stalls and outright 404s. The adapter must
  decide; the caller cannot.
- [ ] **Step 3: Rewrite `LibraryOutput#write_chunk` to call it**, deleting the direct
  `Sync::Storage::ChunkStore` reference.
- [ ] **Step 4: Update `architecture_invariants_test.rb`.** It currently pins the count of direct
  chunk-internals references at **exactly one** and names `library_output.rb`. That count becomes
  **zero**. **This is the arc's headline measurement** — §14c's "one sanctioned exception" ceases to
  exist, and the maker layer names no chunk internals at all.

  Update §14c and §14d in `CLAUDE.md` in the same commit. Do not leave a rule describing an
  exception that is gone.
- [ ] **Step 5: Mutation-check the new zero.** Plant a direct `Sync::Storage::ChunkStore` call in a
  maker file, confirm the invariant test goes RED naming it, restore.
- [ ] **Step 6: All three backend legs.** `bin/ci test test-share test-s3` — identical run counts.
  Addon saves must still work on share and s3; this touched their shared door.
- [ ] **Step 7: Journey.** Gap (b)'s test passes; (c) and (d) still fail unchanged.
- [ ] **Step 8: Commit.**

---

## Task 3: gap (c) — a batch of N moves costs N changelog pulls

**Files:**
- Modify: `app/services/library_broadcast.rb`, `app/services/file_layer/chunk_remote.rb`
- Test: `test/services/library_broadcast_test.rb`

**The defect.** `LibraryBroadcast.batch` returns a bare `yield` when the engine is absent, and
`ChunkRemote#move` calls `refresh!` unconditionally — so `Maker::ProjectIntake`'s eager sweep costs
**two WAN round-trips per file inside a browser request**.

- [ ] **Step 1: Give `batch` a real job on `chunk_remote`:** suppress intermediate `refresh!`, pull
  once at the end. Its current comment argues `yield` is honest for share/s3 — that stays true, and
  the comment must now distinguish the two cases rather than being replaced.
- [ ] **Step 2: The deferral must survive an exception.** If a move raises mid-batch, the mirror is
  stale and the next read is wrong. Pull in an `ensure`, and TEST that path — a deferral that only
  works on the happy path is worse than none, because it fails exactly when state is already odd.
- [ ] **Step 3: Journey.** Gap (c)'s test asserts 3 moves cost 1 pull. It must pass.
- [ ] **Step 4: Then MEASURE before choosing an eager cap.** §14f sets `EAGER_MAX_MOVES = 25` and
  `EAGER_MAX_MOVES_S3 = 5`, the latter because one S3 move is three sequential network calls. Time a
  batched chunk_remote move against a real server and report the number. **Do not add a constant
  without a measurement** — §14f's own recorded failure is a bullet that named an asymmetry and left
  the number the same on all three backends for months.
- [ ] **Step 5: Commit.**

---

## Task 4: gap (d) — an orphaned restore succeeds on chunk and is refused on chunk_remote

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/controllers/trash_controller.rb`
- Modify: `CLAUDE.md` §14a
- Test: `test/services/file_layer/adapter_mutation_contract.rb` or equivalent

**The decision, already made: BOTH BACKENDS REFUSE.** `FileLayer::Chunk#undelete` stops passing
`to_root: true`; an orphaned restore is refused on both, and the user is told to restore the folder
first.

**Why this reverses a recorded decision, which the commit must say plainly.** §14a currently
documents the scatter and closes with *"Not fixed: top-down restore already preserves structure, and
ordering restores is a caller's job, not this adapter's."* That is being overturned on §14a's own
evidence: the same bullet says a bottom-up restore **"permanently scatters that folder's contents to
the root — restoring the parent afterward does not reunite them"**, and that this is **the mainline
case**, because one folder delete tombstones every descendant. An irreversible outcome reached
silently, on the common path, is worth refusing. A refusal is recoverable; a scatter is not.

- [ ] **Step 1: Change `Chunk#undelete`** to stop forcing `to_root: true`.
- [ ] **Step 2: Surface it.** `TrashController` already rescues `UnsupportedOperation`; the message
  must tell the user what to DO — restore the containing folder first — not merely that it failed.
- [ ] **Step 3: Rewrite §14a's bullet.** Not an addendum. State the new rule, that it reverses the
  old one, and why the evidence in the old bullet is what overturned it.
- [ ] **Step 4: The cross-backend contract.** An orphaned restore must now be the SAME answer on
  chunk, chunk_remote, share and s3. Add it to the shared adapter contract so a future divergence
  fails a test rather than being discovered by a corpus two repos over.
- [ ] **Step 5: Journey.** Gap (d)'s test asserts the §14a behaviour that is now being reversed, so
  **this is the one place a journey test legitimately changes.** Rewrite it to assert the refusal —
  and say in the commit that you did, because "the test changed" is exactly what this arc's rules
  otherwise forbid.
- [ ] **Step 6: Update the sync repo's `05-trash.yml`?** NO. The server's behaviour is unchanged;
  only the maker app's use of it changes. The corpus pins both `to_root` arms and stays correct.
- [ ] **Step 7: Commit.**

---

## Task 5: promote `test-chunk-remote` to a real gate

- [ ] **Step 1: Confirm 10/10.** The journey suite must be fully green against a real server.
- [ ] **Step 2: Add the gate to `config/ci.rb` AND a job to `.github/workflows/ci.yml`, together.**
  `test/ci_hygiene_test.rb` asserts SET EQUALITY between `bin/ci --list-ci` and ci.yml's gate jobs;
  one without the other is red.
- [ ] **Step 3: Retire `sync-contract.yml`**, whose entire purpose was carrying a red signal a gate
  could not. Delete it rather than leaving two things running the same suite.
- [ ] **Step 4: The three-legs rule becomes four.** §15 says the legs report identical counts.
  Confirm, and record the numbers.
- [ ] **Step 5: `bin/ci` bare, green, all gates.**
- [ ] **Step 6: STATUS.md + CLAUDE.md**, same branch, same PR (§15).
