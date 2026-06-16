# Torn writes (partial-upload corruption) & change-batching

**Status:** research note · **Date:** 2026-06-15 · **Scope:** read-only investigation

The question: when a file is mid-edit and only **some** of its chunks reach the
server, can the file be left torn/corrupt (a current version whose manifest points at
chunks that don't all exist)? And do mature systems **batch** rapid edits on an
interval to cut requests — should we?

**Bottom line:**
1. **We are already torn-write-safe.** `finalize` is a single atomic transaction and
   is the *only* place a version becomes current/visible. A partial upload that never
   finalizes produces nothing a pulling device can see. (Confirmed in code.)
2. The competitor pattern is uniform: **write content-addressed blobs first, flip the
   pointer last; orphaned blobs are GC'd, never corrupt.** Our model is the same shape.
3. **Batching: worth a small debounce/coalesce on the outbox, but it is an
   optimization, not a correctness fix.** Recommended as a low-priority enhancement.
4. **One real residual gap** — and it is a *storage-cost leak*, not corruption:
   chunk bytes uploaded for a commit that never finalizes are never reclaimed (the
   orphan sweep only walks DB rows, and a never-finalized chunk has no row). Fix
   described in §5.

---

## 1. Our current behavior (ground truth)

### The commit is two-phase; finalize is the atomic commit point

`Sync::Commit` (`app/services/sync/commit.rb`) splits a content commit into `begin`
and `finalize`.

**`begin`** (`commit.rb:21-41`) writes **only** a `pending_commits` row (the manifest
JSON + node/parent/name/base_version/size/mode/mtime), computes which chunk hashes the
user is missing, and returns presigned PUT URLs for those:

```ruby
pending = user.pending_commits.find_or_initialize_by(commit_id:)
pending.assign_attributes(..., manifest_json: manifest.to_json)
pending.save!
present = user.chunks.where(chunk_hash: hashes).pluck(:chunk_hash).to_set
missing = hashes.reject { |h| present.include?(h) }
put_urls = missing.index_with { |h| store.presign_put(user.id, h) }
```

Critically, `begin` creates **no** `nodes`, `versions`, `manifests`, or `chunks` rows.
The new version does not exist yet. Nothing in the tree or changelog references it.

**`finalize`** (`commit.rb:44-118`) does everything else **inside a single
`ApplicationRecord.transaction`** (`commit.rb:59-116`):

```ruby
ApplicationRecord.transaction do
  upsert_manifest!(user, manifest_id, manifest)   # manifest_chunks rows
  upsert_chunks!(user, manifest)                  # chunks rows + refcount++
  node = user.nodes.find_or_initialize_by(node_id: pending.node_id)
  version = user.versions.create!(...)            # the immutable version
  ...
  node.current_version_id = version.version_id     # ← the pointer flip
  seq = user.next_seq!
  user.changelog_entries.create!(seq:, op: "put", version_id: version.version_id, ...)
  pending.destroy!
end
```

So the manifest rows, the chunk-refcount bump, the version, the `current_version_id`
flip, and the changelog append **all commit or roll back together**. There is no
intermediate DB state where `current_version_id` points at a version whose
`manifest_chunks` rows are half-written.

### What a pulling device can see

A pulling device only learns about a version through:
- `Sync::Changes` (`app/services/sync/changes.rb`) — reads `changelog_entries.since`
  and, per entry, the node + the version's `manifest_chunks`. The changelog row is
  written *inside* the finalize transaction (`commit.rb:111`).
- `Sync::Tree` (`app/services/sync/tree.rb`) — reads `node.current_version` +
  manifest. `current_version_id` is set *inside* the finalize transaction
  (`commit.rb:104`).

Both surfaces read state that only exists after the transaction commits. Therefore:

> **If the pusher uploads only some chunks and dies before finalize, the new version
> is INVISIBLE.** No changelog entry, no `current_version_id` flip — pulling devices
> keep seeing the prior version. There is no window in which a *committed/visible*
> manifest references a missing chunk.

### Client push path (matches the protocol)

`SyncEngine::push_node` (`client/sync-engine/src/lib.rs:469-511`) does
`commit_begin` → upload each `missing` chunk via presigned PUT → `commit_finalize`,
strictly in that order:

```rust
let begin = client.commit_begin(&CommitBegin { commit_id, ..., manifest, ... })?;
for hash in &begin.missing {
    let bytes = provider.chunk_get(hash)?;
    io.put(hash, &begin.put_urls, bytes)?;     // direct to storage
}
let fin = client.commit_finalize(&commit_id)?; // the commit point
```

If the client dies after uploading some-but-not-all chunks, `commit_finalize` is never
called → no version. The whole `push_node` is left queued in the outbox
(`push_outbox`, `lib.rs:157-191`: on error the entry is left queued and retried). On
retry, `commit_begin` is idempotent (keyed by `commit_id`, reuses the pending row —
`commit.rb:27`) and chunk PUTs are content-addressed no-ops, so the retry simply
finishes the missing uploads and finalizes. Clean.

### The `verify` flag — present but OFF by default

`finalize` takes `verify: false` (`commit.rb:44`). When `verify: true`, it checks
every manifest hash exists (in `chunks` or in storage via `store.exists?`) and raises
`ChunksMissing` before creating the version (`commit.rb:49-55`). **But the controller
calls it with no `verify` arg** (`app/controllers/v1/commits_controller.rb:20`) and the
client's `commit_finalize` (`client/sync-client/src/lib.rs:344`) sends no such param —
so **verification is currently disabled in production.**

This is *not* a torn-write hole today, because of how chunks get into the manifest:
the client only ever finalizes after `io.put` has succeeded for every hash in
`begin.missing` (`lib.rs:500-504`), and any hash *not* in `missing` is one the server
already has a `chunks` row for. So under the normal client, every manifest hash is
present at finalize. `verify` would only catch a **buggy or hostile client** that
finalizes without uploading. See §5 for the recommendation.

### Summary table (our side)

| Property | Status | Cite |
|---|---|---|
| Commit atomic (all-or-nothing) | ✅ Yes — single txn | `commit.rb:59-116` |
| Version visible only after finalize | ✅ Yes | `changes.rb:30`, `tree.rb:19`, `commit.rb:104,111` |
| Partial upload + crash → torn/visible version | ✅ No — invisible | `commit.rb` (begin writes only pending) |
| Manifest-references-missing-chunk window (committed) | ✅ None | finalize upserts manifest+chunks before the flip, same txn |
| Finalize verifies chunks present | ⚠️ Capable but OFF | `commit.rb:44`, `commits_controller.rb:20` |
| Retry-safe | ✅ Yes — idempotent begin + CAS PUTs | `commit.rb:27`, protocol §"Idempotency" |

---

## 2. How mature systems prevent torn writes

Every one of these uses the same invariant we do: **write content-addressed,
immutable blobs first; flip a single pointer last; orphaned blobs are harmless and
GC'd.**

### Dropbox
The client "commits" a **blocklist** to the metadata server; the commit returns
"need blocks" naming the missing blocks; the client uploads those directly to the
block server, then re-commits. Blocks are immutable 4 MB content-addressed (CAS)
objects in Magic Pocket; "all metadata operations… around mutations and revision
history are handled by the metadata layers on top." → The metadata commit is the
atomic flip; blocks exist independently and an incomplete blocklist simply isn't
committed. **This is precisely our `begin` (returns `missing`) → upload → `finalize`
flow.**
Sources: [Streaming File Synchronization (dropbox.tech)](https://blogs.dropbox.com/tech/2014/07/streaming-file-synchronization/),
[Inside the Magic Pocket](https://dropbox.tech/infrastructure/inside-the-magic-pocket).

### Seafile (git-like model)
Internally Repo / **Commit** / **FS** / **Block** objects, content-addressed, "similar
to GIT's." The client commits to a `local` branch, then the server **fast-forwards its
`master` branch to the head commit** of the uploaded branch. A commit object only
becomes the branch head after its fs-objects and blocks are written; blocks/fs-objects
that aren't referenced by the head are harmless (and `seaf-fsck` detects/ignores them).
→ The branch-head pointer flip = our `current_version_id` flip. Orphan blocks = our
orphan chunks.
Sources: [Seafile Data Model (manual)](https://manual.seafile.com/latest/develop/data_model/),
[Seafile FS management (DeepWiki)](https://deepwiki.com/haiwen/seafile/3-file-system-management),
[Seafile FSCK](https://haiwen.github.io/seafile-admin-docs/12.0/administration/seafile_fsck/).

### Nextcloud / ownCloud (chunked upload v2)
Client `MKCOL`s a **temporary uploads directory**, PUTs numbered chunks (00001…) into
it, then issues a single **`MOVE` to `…/.file`** which triggers server-side assembly
and atomic relocation to the destination. "The destination file only appears after
this MOVE completes successfully — it doesn't exist during the upload phase." Abandoned
uploads: `DELETE` the temp dir, or it auto-expires in 24 h. → The `MOVE` is their
atomic commit point; the temp dir is their staging area (analogous to our
`pending_commits` + uploaded-but-unreferenced chunks).
Source: [Nextcloud chunked upload v2 (developer manual)](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/chunking.html).

### Git (the canonical pattern)
Objects (blobs/trees/commits) are written to the object store **before** any ref is
updated; loose objects that no ref reaches are *dangling*, not corrupting. GC prunes
them **only after a grace period** (default two weeks) precisely because "there is a
brief period between writing the new objects and making them reachable… if objects
would be pruned without a grace period it could… cause repository corruption."
→ Write blob, flip ref last, GC unreferenced blobs **with a grace window** so an
in-flight commit isn't reaped mid-write. This is the exact discipline our chunk GC
needs (§5).
Sources: [git-gc docs (grace period rationale)](https://git-scm.com/docs/git-gc/2.12.5),
[Git Internals — Maintenance & Recovery](https://git-scm.com/book/en/v2/Git-Internals-Maintenance-and-Data-Recovery).

### Mapping back to us

| System | Immutable blob | Atomic pointer flip | Orphan handling |
|---|---|---|---|
| **Us** | chunk (FastCDC, `chunks/<user>/<hash>`) | `current_version_id` + changelog (one txn) | `Sync::Gc.sweep_orphans!` (refcount 0, grace 1 h) |
| Dropbox | 4 MB CAS block | metadata commit of blocklist | block GC |
| Seafile | block / fs-object | `master` fast-forward to head commit | `seaf-fsck` / GC |
| Nextcloud | numbered chunk in temp dir | `MOVE → .file` assemble+relocate | temp-dir DELETE / 24 h expiry |
| git | loose/packed object | ref update | `git gc --prune` after grace |

We already implement the same invariant. The only place we diverge is **orphan
reclamation completeness** (§5).

---

## 3. Change-batching / debounce in the wild

Yes — mature clients deliberately **coalesce rapid successive edits** rather than
react to every save, both to cut request volume and to avoid uploading a file that's
still being actively written.

- **ownCloud desktop client:** the folder watcher historically gathered changes for
  **1 s** before acting; [PR #10825](https://github.com/owncloud/client/pull/10825)
  raised that coalescing window to **10 s** — "if a file changes 50 times within that
  window, the system evaluates it just once." Separately, a **30 s** server-poll
  backstop catches server-side changes, and detecting a local change does **not** mean
  an instant upload — "it will evaluate the file and queue it for the next sync run"
  ([owncloud/client#4082 discussion](https://github.com/owncloud/client/issues/4082)).
  There is an open proposal to add **per-path debounce** (only re-sync a
  frequently-changing file every 5–10 min) for hot files.
- **OneDrive:** default SharePoint-side sync cadence ~30 min; user-facing pause
  windows (2/8/24 h) ([MS Learn](https://learn.microsoft.com/en-us/answers/questions/1516797/onedrive-sync-with-sharepoint-online-delay)).
  (Confirmed cadence exists; exact debounce internals not public — *inference* that
  it coalesces.)
- **Dropbox:** uses streaming sync + a metadata commit; public docs don't state a
  precise debounce window, but the architecture is queue-then-commit, not
  commit-per-keystroke (*inference* from the blocklist-commit model above).
- **Seafile / Nextcloud:** both queue detected changes for the next sync run rather
  than committing per write event (same "evaluate + queue" model as ownCloud).

**The common heuristics:** (1) a short **coalesce/debounce window** (order of 1–10 s)
so a burst of saves collapses to one sync; (2) **quiescence** — don't commit a file
whose mtime is still changing / that's still open; (3) a periodic **poll backstop** so
nothing is lost if a watcher event is missed.

### How we compare

Our model pushes essentially **per close/flush**: FUSE `flush`/`mkdir`/`unlink`/
`rename` enqueue the node into `fs-provider`'s `outbox`, and `push_outbox` drains it
on the sync tick (CLAUDE.md §12 step 1). On Windows CfAPI it's `NOTIFY_FILE_CLOSE` →
ingest → push. So we already coalesce *within a single open* (we push on close, not on
every `write`), and the outbox table naturally de-dupes by node (it stores one row per
`node_id` — `outbox_clear(&node_id)`, `lib.rs:183`). What we do **not** have is a
*time-based* debounce that waits for a burst of close→reopen→close cycles to settle, or
a coalesce of N quick saves of the same file into one commit.

---

## 4. Recommendation: batching

**Verdict: implement a small debounce/coalesce on the outbox drain — but as a
low-priority optimization, not a correctness fix.** It is genuinely useful for the
maker workload and cheap to add given the outbox already exists.

Why it helps *our* workload specifically: large CAD saves (Fusion/SolidWorks/FreeCAD)
and slicers tend to **write-temp → rename → sometimes re-save within seconds**, and
some apps do periodic autosave. Each close currently triggers a full
`commit_begin` + chunk diff + `finalize` round-trip. Coalescing a 2–5 s burst into one
commit cuts redundant commits and, more importantly, **avoids committing an
intermediate state** of a file the user is still actively saving (which would create
extra versions and extra conflict surface).

**Design (fits the existing outbox/changelog model, no schema change required):**

1. **Debounce window per node.** When a node is enqueued, record/refresh a
   `last_enqueued_at` (in-memory map keyed by `node_id`, or an existing `outbox`
   column). `push_outbox` skips a node whose `last_enqueued_at` is younger than the
   debounce window `D` (suggest **D = 2–3 s**), leaving it queued for the next tick.
2. **Coalesce same-node edits** — already free: the outbox holds one row per
   `node_id`, so multiple saves before a drain collapse to a single push of the latest
   content. Just don't drain too eagerly (that's what (1) buys).
3. **Flush on quiescence** — push a node once it has been quiet for `D`. A burst of
   saves keeps pushing the deadline out; the commit fires after the user stops.
4. **Max-batch / max-age cap** — never hold a node longer than `M` (suggest
   **M = 30 s**) so a file saved every second still eventually syncs (mirrors
   ownCloud's per-path debounce-with-cap idea).
5. **Leave the immediate path for explicit events** — deletes/renames should still
   push promptly (low volume, user-visible); debounce is most valuable for content
   commits of large files.

This is purely client-side (`sync-engine` + the `outbox` drain). The server protocol,
atomicity, and idempotency are unchanged. Sizing: trivial — a timestamp check in
`push_outbox`. Risk: none to correctness; the only tunable is "how stale can a sync
be," bounded by `M`.

**If you'd rather not:** skipping it is defensible. Per-close pushing already coalesces
the common case (one save = one commit), and our nudge/poll loop is efficient. The win
is marginal except under autosave-heavy apps. Treat it as a §12-step-6 robustness
nicety, not a blocker.

---

## 5. The one real residual gap (storage leak, not corruption)

> **RESOLVED (G4, 2026-06-16) — see §7.** `Sync::ChunkReaper` + the weekly `ChunkReaperJob` +
> `bin/rails chunks:reap` now implement the storage-orphan reaper described below (the first
> "Suggested fix"). The `gc.rb` stale comment is also corrected. This section is kept for the
> analysis; the gap itself is closed.

**Orphan chunk bytes from never-finalized commits are never reclaimed.**

`Sync::Gc.sweep_orphans!` (`app/services/sync/gc.rb:70-86`) reclaims chunks by
iterating **DB rows**: `user.chunks.where(refcount: ..0).where("updated_at <= cutoff")`.
But `chunks` rows are created **only in `finalize`** (`upsert_chunks!`, `commit.rb:146`).
A commit that uploads bytes via presigned PUT and then **never finalizes** leaves the
bytes in object storage with **no `chunks` row at all** — so the orphan sweep can't see
them. There is no storage-side enumeration anywhere (confirmed: no `list_objects`/
`each_object` in `app/services/storage/` or `gc.rb`).

This is **not** a torn-write/corruption issue — those bytes are unreferenced and
invisible to every device. It is a **cost/space leak** (most relevant to the managed
R2 deployment). Severity: low-to-moderate, grows with abandoned-upload frequency.

Note also a **stale doc comment**: `gc.rb:11` claims `sweep_orphans!` "also catches
uploaded-but-never-finalized chunks, which are never inserted." Per the code that is
false — a never-inserted chunk has no row to sweep. The comment should be corrected.

**Suggested fixes (any one):**
- **Storage-orphan reaper:** a periodic job that lists `chunks/<user>/` in object
  storage and deletes keys with no corresponding `chunks` row **and** older than a
  grace window (mirror git's grace-period discipline so an in-flight upload isn't
  reaped). This is the most complete fix and matches Nextcloud's temp-dir-expiry idea.
- **Pending-commit TTL sweep:** expire `pending_commits` older than N hours and delete
  the chunk keys they reference that never gained a row. Cheaper; targets exactly the
  abandoned-commit case without a full bucket listing.

**Separately, recommended hardening (defense-in-depth, not a current hole):** turn on
**`verify: true` at finalize** for content commits (`commit.rb:44` already supports it;
just thread it through `commits_controller.rb:20`). Today a correct client can't
produce a manifest with a missing chunk, but `verify` makes the server *guarantee*
all-chunks-present at the commit point regardless of client behavior — closing the door
on a buggy/hostile client finalizing a manifest whose bytes aren't all there. Cost: one
extra existence check per unique hash at finalize (cheap; mostly DB-side via the
`chunks` table, falling back to `store.exists?`).

---

## 6. Answers to the owner's questions

- **(a) How do mature systems prevent torn writes?** Write immutable
  content-addressed blobs first; make a new version visible via a **single atomic
  pointer flip** (metadata commit / branch fast-forward / `MOVE` / ref update) only
  after all blobs are present; treat unreferenced blobs as harmless and GC them with a
  grace period. **We already do exactly this** — `finalize` is the atomic flip and the
  only thing that makes a version visible.
- **(b) Do they batch on an interval — should we?** Yes, they coalesce rapid edits
  (ownCloud 1 s → 10 s watcher window; queue-then-sync; per-path debounce proposals).
  We already coalesce per-close and per-node via the outbox. A small **2–3 s debounce
  with a 30 s cap** on the outbox drain is a worthwhile, low-risk optimization for the
  large-CAD-save workload — recommended but not urgent.
- **Are we torn-write-safe today?** **Yes.** A partial upload that never finalizes is
  invisible; there is no committed manifest-references-missing-chunk window.
- **Real gap + fix:** orphan **chunk bytes** from abandoned commits are never reclaimed
  (the sweep walks DB rows; abandoned chunks have none) — a storage *leak*, not
  corruption. Fix with a storage-orphan reaper or a `pending_commits` TTL sweep, and
  optionally enable `verify: true` at finalize for belt-and-suspenders. **(The reaper is now
  built — §7 / G4.)**

---

## 7. Implemented: G4 (orphan reaper), G5 (debounce), G8 (special-file guardrail), G10 (delta audit)

Landed 2026-06-16 (branches `g4-orphaned-chunk-reaper`, `g5-g8-g10-file-layer-polish`).

### G4 — orphaned-chunk reaper (the §5 gap, closed)

`Sync::ChunkReaper.reap!(user, grace:, dry_run:)` enumerates the per-user `chunks/<user>/`
keyspace via a new **`ChunkStore#list`** (implemented on s3/local/memory) and deletes an object
**only** when all hold: (1) no committed `chunks` row references its hash, (2) no in-flight
`pending_commits` references it, and (3) it is older than `grace` (default
`PENDING_COMMIT_TTL = 24.hours`, mirroring git-gc's prune grace so an in-flight upload is never
reaped). Per-user scoped, idempotent, dry-run supported. **`ChunkReaperJob`** runs **weekly**
(Sunday 5am, `config/recurring.yml`) — conservative because `list_objects_v2` is billed per
request and the grace window makes weekly plenty timely for a cost leak. Manual:
`bin/rails chunks:reap` (`lib/tasks/chunks.rake`). The stale `gc.rb` comment (§5) is corrected.
Tests: `test/services/sync/chunk_reaper_test.rb`, `test/jobs/chunk_reaper_job_test.rb` (server
suite → **154/0**).

### G5 — change-batching / outbox debounce (the §4 recommendation, built; opt-in, default OFF)

The outbox now carries two unix-millis timestamps (`enqueued_at` = last touch, refreshed on every
re-enqueue; `first_enqueued_at` = the max-age floor, set once; both migrated on older DBs).
`SqliteProvider::outbox_ready_topo(window_ms, max_age_ms)` **holds** a still-hot `upsert` (last
touched `< window_ms` ago AND under the `max_age_ms` cap) and its queued children (parents-first
invariant preserved), so a burst of saves to one big CAD file coalesces into ONE push of the
final bytes. **Deletes are never held; `window_ms == 0` is identical to the eager
`outbox_list_topo`.** The engine drains via `SyncEngine::push_outbox_debounced` /
`sync_tick_debounced`; `DaemonConfig::with_debounce` opts in (**default = off**;
`Debounce::MAKER_DEFAULT` = 2.5 s window / 30 s cap, per §4's D=2–3 s, M=30 s). Unmount drains
with window 0 (a debounced final edit can't be left un-pushed). Tests:
`client/fs-provider/tests/debounce.rs` (5).

### G8 — special-file guardrail

Symlinks / FIFOs / sockets / block+char device nodes stay a deliberate non-goal (the tree models
only `File`/`Dir`). The guardrail makes attempts fail **deterministically (`EPERM`)** instead of
`fuser`'s default `ENOSYS`: new `FsError::NotSupported` → `EPERM` in the FUSE errno map; the FUSE
adapter implements `mknod` (`S_IFREG`/untyped → regular file; every special type → `EPERM`) and
`symlink` (always `EPERM`). The tree is never mutated for a rejected type → cannot be corrupted.
WebDAV (macOS) is inherently safe — the protocol has no special-file verb.

### G10 — delta-on-wire audit: VERDICT — already minimal ✔

`push_node` uploads exactly `commit_begin.missing`, and FastCDC localizes an edit to a few chunks,
so the wire delta is already optimal — **no gap.** Locked in with a PUT-counting regression test
(`client/sync-engine/tests/integration.rs`): a 60 KB file = **194 chunks**; an initial push
uploads all 194 and a **one-byte middle edit re-uploads exactly 1 chunk**. The test asserts the
delta push stays `<= total/4 + 2`, so a regression to whole-file uploads fails CI.
