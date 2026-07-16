# FileLayer S3 Adapter — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `LIBRARY_BACKEND=s3` boots and serves a library backed by **the user's own S3-compatible bucket** — index what is already in it, write new objects into it, and satisfy **both** adapter contracts, with bytes moving by presigned URL rather than through Rails.

**Architecture:** `FileLayer::S3` implements the same port as `Share` — current-state only, no versions, no restore — over `Aws::S3::Client`. `Library::Reconciler` is **reused unchanged in its decision logic** (it is deliberately filesystem-free); `Library::Scanner` is **not** reusable (it is irreducibly `Dir`/`lstat`/`Pathname`), so S3 gets its own observer feeding the same Reconciler. The one Reconciler change is structural and is this plan's first task: an `Observation` may carry an observer-supplied `content_hash`, because S3 gets identity free from the listing and can never lazily hash the way a share can.

**Tech Stack:** Rails 8, Minitest (`ActiveSupport::TestCase`, parallel forked processes, no fixtures), SQLite in test, Zeitwerk from `app/services`, Ruby 3.4, rubocop rails-omakase, `aws-sdk-s3` (already a dependency — `Gemfile:62`, `gem "aws-sdk-s3", require: false`, resolved at 1.226.0; **this plan adds no gem**).

**Source spec:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md` (§2 decision 3 current-state-only, §3.2 the port, §3.5 config + boot guard, §5.1 scan/reconcile, §6 trash + copy-then-tombstone + mass-deletion guard, §9 phasing).
**Predecessors:** `2026-07-14-file-layer-share-phase2a.md` (merged `63544ee`), `2026-07-16-file-layer-share-phase2b.md` (the write path + `adapter_write_contract.rb`).

> **This plan was written while 2b was still being executed**, and 2b's plan was revised under it (`8d9501a`, *"harden phase 2b against the real code — four defects found by executing it"*). So **every reference here to `adapter_write_contract.rb`, `Share#write/delete/move/undelete`, or the trash layout is a claim about a file that moved after it was read.** Read the real files first; where they disagree with this plan, **the files are right and this plan is a finding.** That is the normal outcome, not an exception — it is what happened to 2a's plan in all ten tasks.

**Read before starting:** `app/services/file_layer/share.rb`, `app/services/library/reconciler.rb`, `app/services/library/scanner.rb`, `app/services/storage/s3_chunk_store.rb`, `app/jobs/library/scan_job.rb`. Their comments carry reasoning this plan depends on and does not repeat.

---

## Scope

**This plan (3):**
- The **object-identity ladder** — what `content_hash`/`content_token` mean for an S3 object
- `Library::Observation` + the Reconciler honoring an observer-supplied hash (the prerequisite; see Landmine 1)
- `LIBRARY_S3_*` config + `lib/library_backend_check.rb` extended to s3
- `FileLayer::S3` — `capabilities`/`stat`/`read` (the **read** contract) and `write`/`delete`/`move`/`undelete` (the **write** contract)
- `Library::S3Observer` + wiring `Library::ScanJob` (its `is_a?(FileLayer::Share)` gate is a documented trap — see Landmine 5)
- `Library::TrashPurgeJob` extended to an S3 trash
- The E2E + the `LIBRARY_BACKEND=s3` CI leg

**Deferred to Phase 4 (do not do here):** `download`/`Delivery` — including the `Redirect(url)` variant, which is the reason §15 survives on this backend. Phase 3's `read` returns bytes server-side, which is all the preview pipeline needs. **No controller wiring.** If a task here seems to need a controller, stop.

**Deferred — spec §5.1's scan checkpointing, and it deserves a paragraph because this plan appears to contradict the spec.** §5.1 says the scanner *"checkpoints progress (last completed path / **S3 continuation token**) so a multi-hour first scan of a 2TB archive survives a restart"*. **2a did not build it** (verified: `Scanner#observe` collects every observation into an array, then reconciles once; there are no incremental writes and no checkpoint), so there is nothing here to extend, and Landmine 4 pushes the other way — reconciling a *partial* listing is the mass-deletion bug itself.

The tension resolves, and the resolution is worth writing down for whoever picks this up: **a checkpoint is only safe on a scan that cannot tombstone.** On a *first* scan the library is empty, so a partial listing can create nodes but can delete nothing, and resuming from a continuation token is pure win. On every *later* scan, the tombstone decision needs the whole picture, and a checkpoint is a loaded gun. So the feature is "resumable **first** scan", not "resumable scan" — a different, narrower thing than §5.1 implies. **Out of scope here; do not smuggle it in.**

**Deferred (spec §5.2, §8), and stated so nobody re-derives them:**
- **Presigned upload.** Spec §5.2 already settled it: uploads stream through Rails in s3 mode too, because presigning the PUT means the bytes never pass us, so we would have to trust an ETag we did not compute. Documented later optimization. **This is the one place §15 is knowingly relaxed for s3, and it is a deliberate, pre-existing decision — do not "fix" it.**
- Version history / restore / conflicts / locks (decision 3). Multiple sources per account (decision 1). Migrating a chunk library to a bucket, or back.

**Non-negotiable:** every commit leaves `bin/rails test` green, and `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` stays **identical** to it. **Record both baselines before Task 1 and put the numbers in your report** — 2b is landing concurrently, so this plan deliberately does not hard-code a count it cannot know. A plan that asserts a stale number teaches the implementer to ignore counts.

**Tripwire (spec §10):** must not touch sync, the changelog, conflicts, locks, or the mount adapters. **The specific temptation here:** `Storage::S3ChunkStore` is prior art you must READ (SigV4, `force_path_style`, `list_objects_v2` pagination, presign) and must **not** modify, extend, or subclass. It serves the sync engine's chunk keyspace (`chunks/<user>/<hash>`); this adapter serves the user's own object namespace. Two S3 clients with two different jobs. Sharing a base class to avoid ~20 duplicated lines would couple the port to the sync engine's storage — the exact leak the split exists to prevent, and the mirror of the reasoning in `Share#live_node!`'s header ("three duplicated lines is the cheaper trade").

---

## Learn from 2a and 2b — read this before Task 1

**2a's plan supplied an implementation for all ten tasks and was wrong in all ten**, twice in ways that would have shipped silent data loss: a dead no-op expression; a `FileLayer.current.root` that simply crashes (`Chunk` has no `root`); an errno whitelist that failed open; and a mass-deletion guard whose design refused the phase's own headline test. Its **tests**, by contrast, were mostly right.

**So this plan gives you complete tests and NO implementations.** The tests are the specification — read them as the definition of done. Implementations are given as **constraints and seams**, derived against the real files. If a constraint here turns out to be wrong, **that is the expected outcome — report it.** That was the highest-value output of every 2a and 2b task.

**The process lessons, which cost real rework — they apply verbatim here:**
- **A test that cannot fail is decoration.** ~11 times in 2a a test stayed green while its coverage evaporated. **Assert the message, not just the class**, whenever the class is generic or reachable two ways. `FileLayer::NotFound` is reachable from four places in this adapter alone.
- **Verify every mutation actually applied, byte-exactly, or you will report a false green.** Known traps: multiline `grep -F` treats the newline as an **OR of two patterns**; `<<~` strips indentation so anchors miss; **a non-UTF-8 `File.read` blows up on em-dashes and silently skips the substitution**; `%q{...\n}` is a literal backslash-n. Use `grep -c` with an **expected count**. (While writing this plan an em-dash pasted into a `ruby -e` killed the process outright — the trap is live, not folklore.)
- **NEVER `git checkout` to revert a mutation** — an agent destroyed its own uncommitted implementation that way. File backup + `cmp`.
- **The plan can be wrong. Report it.**

**And the 2a defect that this phase reproduces most directly:** `Pathname#find` silently swallowed `EACCES`, so an unreadable folder tombstoned its whole subtree — an incomplete observation rendering as absence, shipped through two reviews. **`list_objects_v2` pagination is the same bug with a different spelling** (Landmine 4). The Scanner's answer — hand-roll the walk so every error decision is explicit and local — is the answer here too.

---

## Verified facts this plan rests on

Every one was checked against the real code or the real SDK in this worktree. Re-verify anything you are about to depend on; do not extend trust to the ones you do not use.

| # | Fact | How it was checked |
|---|---|---|
| 1 | **`aws-sdk-s3` is already a dependency** and loadable (1.226.0). No new gem. | `Gemfile:62`; `require "aws-sdk-s3"` |
| 2 | **`list_objects_v2` `Contents[]` carries `key, last_modified, etag, checksum_algorithm, checksum_type, size, storage_class, owner, restore_status`** — the checksum *algorithm* but **never the checksum value**. | SDK shape introspection |
| 3 | **`head_object` returns `checksum_sha256` (and crc32/crc64nvme/…) plus `checksum_type` and `metadata`** — but only if the uploader set one. | SDK shape introspection |
| 4 | **ETag comes back wrapped in literal double quotes**: `"\"d41d8cd9…\""`. From both list and head. | stubbed `list_objects_v2` |
| 5 | **`list_objects_v2` `last_modified` is second-granularity** (nsec 0). | stubbed response round-trip |
| 6 | **All S3 errors share `Aws::S3::Errors::ServiceError < Aws::Errors::ServiceError < RuntimeError < StandardError`**; network failures are `Seahorse::Client::NetworkingError < StandardError`. `NoSuchKey`, `NotFound`, `AccessDenied`, `NoSuchBucket` are distinct classes. | `.ancestors` |
| 7 | **Presigning is fully offline** (local HMAC) — no network, no credential validation. Matches CLAUDE.md §14. | `Presigner#presigned_url` with `stub_responses` |
| 8 | **`copy_object` accepts `copy_source_if_match`; `delete_object` accepts `if_match`/`if_match_size`.** | SDK shape introspection |
| 9 | **`stub_responses` accepts a lambda**, giving a stateful, hermetic fake with real SDK types, real serialization, and real error classes. | verified round-trip: put→get→list→NoSuchKey |
| 10 | **`nodes` already has every column this phase needs** (`content_hash`, `storage_path`, `size`, `mtime`), and a **partial** unique index `(user_id, storage_path) WHERE deleted = false`. **Phase 3 needs no migration.** | `db/schema.rb` |
| 11 | **The Reconciler drops a nil-hash observation entirely** — it is never indexed. | executed probe (Landmine 1) |
| 12 | **`ScanJob.scan_all!` gates on `is_a?(FileLayer::Share)`** and its own comment names this the "PHASE 3 TRAP". | `app/jobs/library/scan_job.rb:69` |

---

## The identity decision — settle it before Task 1

An S3 object has no content hash you can get for free, and this is the phase's central problem. Work it in this order.

**What the value is actually for.** Two jobs, and they have different requirements:

1. **`content_token`** (spec §3.1) — a *content-state* token. Previews key on it; it must change **iff** the bytes change. The spec's own word is **opaque**. It does **not** have to be a hash.
2. **`content_hash`** — the move-pairing key. The Reconciler pairs a vanished path with a new one by `(content_hash, size)`. This one must be **content-determined**: the same bytes at a new key must produce the same value, or a rename is not recoverable and every attachment on it breaks.

**ETag answers (1) perfectly and (2) only sometimes.** It changes whenever the object is replaced — so it is a sound state token. But for a multipart upload it is `md5-of-part-md5s + "-N"`, so **the same bytes uploaded with a different part size produce a different ETag**. Move detection then fails.

Note the direction of that failure, because it is what makes this acceptable: an ETag collision requires an MD5 collision, so you get **false negatives (a missed move → delete+create), never false positives (two unrelated files fused into one identity)**. Pairing also requires equal `size`. The safe direction.

**The decision: one column, one namespaced value, a documented strength ladder.**

`content_hash` **is** `content_token` (exactly as in `Share`), and the S3 adapter resolves it by the first rung that applies:

| Rung | Value | Content-determined? | Cost |
|---|---|---|---|
| 1 | ETag with **no** `-N` suffix → it **is** the MD5 → `"md5:<hex>"` | **yes** | free (in the listing) |
| 2 | `checksum_sha256` from a HEAD **when `checksum_type == "FULL_OBJECT"`** → `"sha256:<b64>"` | **yes** | 1 HEAD/object |
| 3 | otherwise → `"etag:<raw>"` | **no** (moves degrade to delete+create) | free |

**The ladder must be total — it must never return nil.** That is Landmine 1, and it is the difference between "this object's moves are not detectable" and "this object does not exist."

**Why rung 2 is opt-in, not default** (`LIBRARY_S3_HEAD_FOR_CHECKSUM`, default **off**): it costs one billed HEAD per object on every first sight — 2M requests on a 2M-object bucket — to buy move detection for objects that both are multipart *and* were uploaded with a SHA-256 full-object checksum. Most existing buckets have neither. Default off; the operator turns it on if their tooling sets checksums. **Do not** put rung 2 in the hot path by default and discover the bill in production.

**Namespacing is not decoration.** `"etag:abc-5"` in a column named `content_hash` is a lie unless it says what it is. A future reader must not compare an `md5:` against a `sha256:` and conclude the bytes differ, nor mistake `etag:` for a content hash. The prefix makes the strength legible at a glance and in a DB dump.

**Deliberately rejected:** *download-and-hash everything.* It is the only way to get a true SHA-256 for every object, and it costs a full egress of the bucket on first scan — 2TB, billed — to index a library the user already has. That is precisely the cost the "point it at my existing storage" on-ramp exists to avoid (spec §1). Rejected on the spec's own terms, not on taste.

---

## Cross-task landmines

2a's two worst defects were **cross-task** — each commit fine alone, broken in combination, invisible to per-task review. These are Phase 3's. Each names the task that pins it.

### Landmine 1 — a nil hash makes an object permanently invisible (VERIFIED)

`Library::Reconciler#plan_moves` (line ~275):

```ruby
candidates = unmatched.filter_map { |o| (h = hash_for(o)) && [ o, h ] }
```

An observation whose hash comes back nil is **dropped from `candidates`** — and `candidates` is what becomes `leftovers`, which is what `create_or_revive!` indexes. So a nil-hash observation is **never indexed at all**. The in-code comment states the assumption out loud:

> *"Leaving it out entirely means the next pass indexes it properly."*

**That is true for a share** (a nil hash is an `EACCES` blip; the next pass succeeds) **and permanently false for S3** (an object with no derivable checksum has no checksum on the next pass either). Reuse the Reconciler unchanged and every such object is **silently absent from the library forever** — no error, no log, no node.

Proven, not reasoned — this probe was run in this worktree:

```
indexed: ["hashable.stl"]
LANDMINE CONFIRMED: a nil-hash observation is never indexed
```

**Therefore the identity ladder must be total (never nil), and `Observation` must carry an observer-supplied hash** so the Reconciler never lazily hashes an S3 object at all. **Pinned in Task 1 and again in Task 2.**

Two further reasons the same fix is forced, so nobody "simplifies" it back to injecting a `reader:`:
- `hash_for` does `Digest::SHA256.hexdigest(@reader.call(o.rel_path))` — **the whole object in memory**. The share path uses `Digest::SHA256.file` (streaming) precisely to avoid that. A `reader:` that downloads makes a 2GB STEP file 2GB of RAM *and* 2GB of egress.
- The incremental skip is `node.mtime == o.mtime && node.size == o.size`. S3's `last_modified` is **second**-granularity (verified), so that comparison is coarser than the share's nanoseconds. With an observer-supplied hash the skip can compare the identity directly — free, exact, and no granularity question at all.

### Landmine 2 — the quoted ETag (VERIFIED)

S3 returns ETags **wrapped in literal double quotes**: `"\"d41d8cd98f00b204e9800998ecf8427e\""`. Verified from a stubbed `list_objects_v2`; `head_object` and `put_object` do the same.

Strip it in one place or this happens: the observer stores the quoted form, some other path (a `put_object` response, a HEAD) produces the unquoted form, and they **never compare equal**. Consequences, in order of nastiness:
- every object looks changed on every scan (re-index churn), and
- **move-pairing never pairs** — so **every rename becomes delete+create, and every attachment on it breaks, on every scan**. The phase's headline promise, silently inverted.

It is a pair of quotes and it is a silent-data-loss-shaped bug. **Pinned in Task 1** (the ladder normalizes; a test asserts the raw quoted input) **and Task 4** (the write path's `put_object` response goes through the same normalizer).

### Landmine 3 — copy → delete → **tombstone**; the spec's ordering is necessary but not sufficient

Spec §6 says: *"S3: copy+delete — **tombstone only after the copy confirms**."* Correct, and **not enough**. Trace it against 2b's Landmine 2 (a trash tombstone **nulls `storage_path`**, so `create_or_revive!`'s revive-by-path cannot fire for it):

| Order | Copy | Delete | Result |
|---|---|---|---|
| copy → **tombstone** → delete | ok | **fails** | Object still live at its original key. Node tombstoned with `storage_path` NULL → the next scan observes the key, no live node claims it, **no tombstone at that path to revive** → it **creates a NEW node with a NEW `node_id`**. **Every attachment orphaned.** |
| copy → delete → **tombstone** | ok | **fails** | No tombstone. Object still at its key, node still live and matching by path → the next scan is a no-op. The delete simply did not happen; the user retries. **Consistent.** |

So the rule is **tombstone only after the *delete* confirms**, and the failure is only visible when you read §6 together with a landmine settled in a *different phase*. That is exactly the cross-task shape.

The complementary half: a tombstone with the bytes still in place is a file the user cannot see but the scan resurrects. Both halves say the same thing — **the tombstone goes last**.

Also: **`copy_object` is capped at 5GB.** Over that it errors (it does not truncate). **Verify the exact error class against your target store** — do not trust this plan's guess. Map it to a clear error and **do not tombstone**, mirroring 2b's Landmine 3 (`EXDEV` → clear error, never a silent half-delete). Do not reach for multipart copy here.

**Pinned in Task 6.**

### Landmine 4 — a partial listing is indistinguishable from a mass deletion

`list_objects_v2` paginates at 1000 keys. **A multi-page listing is not a snapshot**, and a failure on page 7 of 40 yields a listing that is a perfectly well-formed *lie*: it looks exactly like the user deleting 82% of their library. The mass-deletion guard trusts its input completely — by design, since `vanished_paths` is computed from the observations it is handed.

This is **2a's `Pathname#find`/`EACCES` bug with a different spelling**: an incomplete observation rendering as absence. That one shipped through two reviews.

**Therefore: an S3 listing that does not run to completion must abort the whole scan (`Scanner::UnsafeScan`) — never reconcile a partial listing.** Note why the share's mechanism does not transfer: `unreadable_dirs` scopes a gap to a *subtree*, and a page boundary is an **arbitrary key range**, not a subtree. There is nothing to scope. Aborting is the only honest answer, and it is louder than `unreadable_dirs: ["."]` (which would make the guard's `observable_count.zero?` early-return silently no-op the entire reconcile).

**On eventual consistency specifically** — because the question will come up and the folklore is out of date: **AWS S3 has been strongly read-after-write consistent, including LIST, since December 2020**; R2 is strongly consistent. So on the two stores this product actually targets for *managed* use, list-after-write is not the risk. **But `LIBRARY_BACKEND=s3` is aimed at self-hosters pointing at SeaweedFS/MinIO/whatever they run**, where guarantees vary and are not ours to assume. The guard should not be argued away on AWS's behalf. And in any case pagination — which is a property of the API, not of the store's consistency model — is the sharper edge.

**Pinned in Task 7.**

### Landmine 5 — the ScanJob gate silently stops scanning (VERIFIED, and already flagged in-code)

`app/jobs/library/scan_job.rb:69`:

```ruby
adapter = FileLayer.current
return unless adapter.is_a?(FileLayer::Share)
```

Today an s3 deployment raises `NotImplementedError` out of `FileLayer.current` — loud and correct. **The moment `FileLayer::S3` exists, this `is_a?` quietly answers false and the scan silently stops.** The job's own comment names this and asks whoever builds S3 to decide here deliberately:

> *"PHASE 3 TRAP: … the moment FileLayer::S3 exists, this is_a? quietly answers false and the scan SILENTLY STOPS — the exact silent-no-op this job's design argues against."*

The instant Task 3 lands, Tasks 1–6 all pass while an S3 library is never indexed. **Pinned in Task 8** — and the gate must key on a **capability the adapter answers**, not a growing `is_a?` disjunction that the next backend breaks the same way.

### Landmine 6 — S3 has no directories, and the shapes people use instead break the catalog

Keys are flat. `nodes` needs a tree (`parent_node_id`), and `ensure_dirs` builds it from dir observations the *Scanner* emits from real directories. The S3 observer must **synthesize** them from key prefixes — and two real-world shapes bite:

- **Directory-marker objects.** The S3 console (and many tools) create a zero-byte object with a **trailing slash**: `cad/`. Emit it as a file and you index a phantom: `File.basename("cad/")` is `"cad"`, so you get a **file node named `cad` at `storage_path: "cad/"` living alongside the real dir node `cad`** — two live nodes, distinct `storage_path` strings, so the partial unique index permits both. A phantom file in every browse view.
- **Non-UTF-8 keys.** S3 keys are **bytes**. This is 2a's exact trap — a non-UTF-8 filename bricked every scan, and it was caught only by the final whole-branch review because macOS cannot create the fixture. The Scanner's answer (`next unless name.valid_encoding?`, skip and log, **skip in the observer so it can never reach `vanished_paths`**) transfers verbatim. **An S3 key is far easier to write than a non-UTF-8 filename, so this is more likely here, not less.**

**Pinned in Task 7.**

---

## File structure

| File | Responsibility |
|---|---|
| `app/services/library/observation.rb` (create) | the shared value; `Scanner::Observation` keeps resolving to it |
| `app/services/library/scanner.rb` (modify) | emit the shared `Observation`; hand `content_hash: nil` |
| `app/services/library/reconciler.rb` (modify) | honor an observer-supplied hash; never lazily hash when one is given |
| `app/services/file_layer/s3/object_identity.rb` (create) | the ladder + ETag normalization — **pure, no client** |
| `app/services/file_layer/s3.rb` (create) | the adapter: read + write + trash |
| `app/services/library/s3_observer.rb` (create) | `list_objects_v2` → `[Observation]`, complete-or-abort |
| `app/jobs/library/scan_job.rb` (modify) | Landmine 5: gate on a capability, not `is_a?` |
| `app/jobs/library/trash_purge_job.rb` (modify) | purge an S3 trash prefix |
| `lib/library_backend_check.rb` (modify) | the s3 boot guard |
| `app/services/file_layer.rb` (modify) | factory: build `S3` |
| `test/support/fake_s3.rb` (create) | the stateful stub client |
| `test/services/file_layer/s3/object_identity_test.rb` (create) | the ladder, exhaustively |
| `test/services/file_layer/s3_test.rb` (create) | S3 vs **both** contracts + S3-specific |
| `test/services/library/s3_observer_test.rb` (create) | listing → observations; the landmines |
| `test/services/library/reconciler_test.rb` (modify) | the supplied-hash path |
| `test/services/file_layer/factory_test.rb` (modify) | s3 no longer raises |
| `test/lib/library_backend_check_test.rb` (modify) | s3 boot guard |
| `test/integration/library/s3_library_test.rb` (create) | the headline E2E |
| `.github/workflows/ci.yml` (modify) | the `LIBRARY_BACKEND=s3` leg |

---

### Task 1: The object-identity ladder

**Why first:** it is the phase's central decision, it is **pure logic with no client**, and both Landmine 1 (totality) and Landmine 2 (quoting) live in it. Settle it before anything depends on it.

**Files:**
- Create: `app/services/file_layer/s3/object_identity.rb`
- Create: `test/services/file_layer/s3/object_identity_test.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/services/file_layer/s3/object_identity_test.rb`:

```ruby
require "test_helper"

module FileLayer
  class S3
    # The identity ladder: what content_hash/content_token MEAN for an S3 object.
    #
    # Pure logic, no client, no network -- which is the point. This is where both of the
    # phase's silent-data-loss shapes live, so it is tested exhaustively and in isolation.
    class ObjectIdentityTest < ActiveSupport::TestCase
      # S3 wraps every ETag in LITERAL double quotes, in list, head, AND put responses.
      # Store the quoted form once and the unquoted form somewhere else and they never
      # compare equal: every object looks changed on every scan, move-pairing never pairs,
      # and every rename becomes delete+create -- breaking every attachment, every pass.
      # A pair of quotes; the phase's headline promise, silently inverted.
      test "a single-part ETag IS the md5, and the quotes S3 wraps it in are stripped" do
        id = ObjectIdentity.for(etag: %q{"d41d8cd98f00b204e9800998ecf8427e"})
        assert_equal "md5:d41d8cd98f00b204e9800998ecf8427e", id
        assert_not_includes id, '"', "the quotes must never reach the database"
      end

      test "an unquoted ETag is accepted too - normalization is not quote-dependent" do
        assert_equal "md5:d41d8cd98f00b204e9800998ecf8427e",
                     ObjectIdentity.for(etag: "d41d8cd98f00b204e9800998ecf8427e")
      end

      # A multipart ETag is md5-of-part-md5s + "-N". It is NOT content-determined: the same
      # bytes with a different part size give a different ETag. So it is demoted to the
      # etag: rung, which is a sound content-STATE token (it changes iff the bytes change)
      # but an unsound content IDENTITY (moves degrade to delete+create).
      test "a multipart ETag is demoted to the etag rung, not passed off as an md5" do
        id = ObjectIdentity.for(etag: %q{"9bb58f26192e4ba00f01e2e7b136bbd8-5"})
        assert_equal "etag:9bb58f26192e4ba00f01e2e7b136bbd8-5", id
        assert_not id.start_with?("md5:"), "a part-checksum must never be labelled a content hash"
      end

      # Rung 2: a FULL_OBJECT sha256 IS content-determined, so it outranks the ETag.
      test "a FULL_OBJECT sha256 checksum outranks the ETag" do
        id = ObjectIdentity.for(etag: %q{"9bb58f26192e4ba00f01e2e7b136bbd8-5"},
                                checksum_sha256: "n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg=",
                                checksum_type: "FULL_OBJECT")
        assert_equal "sha256:n4bQgYhMfWWaL+qgxVrQFaO/TxsrC4Is0V1sFbDwCgg=", id
      end

      # A COMPOSITE sha256 is a checksum-of-checksums -- the SAME shape problem as a
      # multipart ETag, wearing a more trustworthy name. Using it as an identity would
      # reintroduce the exact bug the multipart demotion above exists to prevent.
      test "a COMPOSITE sha256 is NOT an identity and must not be used as one" do
        id = ObjectIdentity.for(etag: %q{"9bb58f26192e4ba00f01e2e7b136bbd8-5"},
                                checksum_sha256: "abc123=",
                                checksum_type: "COMPOSITE")
        assert_equal "etag:9bb58f26192e4ba00f01e2e7b136bbd8-5", id
        assert_not id.start_with?("sha256:")
      end

      # A single-part object's md5 ETag is content-determined and free; a FULL_OBJECT
      # sha256 is content-determined and costs a HEAD. Both are valid identities, so
      # rung order between them is arbitrary EXCEPT that it must be deterministic --
      # two scans disagreeing about one object's identity would unpair every move.
      test "the ladder is deterministic when several rungs apply" do
        args = { etag: %q{"d41d8cd98f00b204e9800998ecf8427e"},
                 checksum_sha256: "n4bQ=", checksum_type: "FULL_OBJECT" }
        assert_equal ObjectIdentity.for(**args), ObjectIdentity.for(**args)
      end

      # LANDMINE 1, at its source. The Reconciler DROPS a nil-hash observation entirely --
      # verified by probe: it is never indexed, no error, no log. That is survivable on a
      # share (a nil hash is an EACCES blip; the next pass succeeds) and permanent for S3.
      # So the ladder must be TOTAL: every object gets an identity, or it does not exist.
      test "the ladder is TOTAL - an object with only an ETag still gets an identity" do
        assert ObjectIdentity.for(etag: %q{"abc-99"}).present?
        assert ObjectIdentity.for(etag: "abc").present?
      end

      # An object with NO etag at all should not happen (S3 always sends one), but if a
      # store omits it, returning nil would silently un-index the object. Refuse loudly:
      # a bug we can see beats a file that quietly is not there.
      test "an object with no ETag raises rather than returning nil" do
        err = assert_raises(ArgumentError) { ObjectIdentity.for(etag: nil) }
        assert_match(/etag/i, err.message)
        assert_raises(ArgumentError) { ObjectIdentity.for(etag: "") }
      end

      test "content-determined identities are distinguishable from weak ones" do
        assert ObjectIdentity.content_determined?("md5:d41d8cd98f00b204e9800998ecf8427e")
        assert ObjectIdentity.content_determined?("sha256:n4bQ=")
        assert_not ObjectIdentity.content_determined?("etag:abc-5")
      end
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/services/file_layer/s3/object_identity_test.rb`
Expected: `NameError: uninitialized constant FileLayer::S3` (or `ObjectIdentity`).

- [ ] **Step 3: Implement**

Create `app/services/file_layer/s3/object_identity.rb`. **Constraints, each pinned by a test above:**
- `ObjectIdentity.for(etag:, checksum_sha256: nil, checksum_type: nil) -> String`. **Never nil**; raise `ArgumentError` on a blank etag.
- Strip surrounding `"` from the etag **exactly once, in this method**. It is the only normalizer; every caller goes through it.
- Rung order: `FULL_OBJECT` sha256 → single-part etag (`md5:`) → `etag:`.
- "Single-part" = the normalized etag has **no `-`**. A multipart etag is `<hex>-<n>`.
- `content_determined?(identity)` → true for `md5:`/`sha256:`, false for `etag:`. It exists so the observer and the diagnostics can tell a user "moves are not detectable for N objects in this bucket" instead of leaving them to discover it.
- **Zeitwerk:** `FileLayer::S3::ObjectIdentity` at `app/services/file_layer/s3/object_identity.rb` requires `FileLayer::S3` to be a **class or module that can hold a nested constant**. Task 3 creates `app/services/file_layer/s3.rb` as a class. Until then this file defines the namespace. **Confirm the load order works before Task 3 rather than discovering it there** — `bin/rails runner 'puts FileLayer::S3::ObjectIdentity'` is the check.

- [ ] **Step 4: Green**

Run: `bin/rails test test/services/file_layer/s3/object_identity_test.rb` — expect 9 runs, 0 failures. Report ACTUAL.

- [ ] **Step 5: Prove the quote-stripping guard is real (mutation)**

Remove the quote-strip. The md5 test must fail. **Byte-exact abort-if-unchanged guard; `grep -c` with an expected count; revert by file backup + `cmp`, never `git checkout`.** Report the result.

- [ ] **Step 6: Full suite + commit** — report ACTUAL counts.

```bash
git add app/services/file_layer/s3/object_identity.rb test/services/file_layer/s3/object_identity_test.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): the S3 object-identity ladder

An S3 object has no content hash you can get for free. content_token only needs to be an
opaque content-STATE token (spec 3.1), which an ETag satisfies exactly; content_hash needs to
be content-DETERMINED, which a multipart ETag is not. One namespaced value serves both, by a
strength ladder: a FULL_OBJECT sha256, else a single-part ETag (which IS the md5), else the
raw ETag with moves degrading to delete+create.

The namespacing is load-bearing: "etag:abc-5" in a column called content_hash is a lie unless
it says what it is. A COMPOSITE sha256 is demoted for the same reason a multipart ETag is --
it is a checksum of checksums wearing a more trustworthy name.

The ladder is TOTAL by construction. The Reconciler drops a nil-hash observation entirely
(verified by probe: never indexed, no error), which is survivable on a share and permanent
here. And the quotes S3 wraps every ETag in are stripped exactly once, here: mixing the
quoted and unquoted forms would unpair every move and break every attachment on every scan.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Observation` carries a hash — the Reconciler prerequisite

**Why second:** Landmine 1. Everything downstream depends on the Reconciler being able to accept an identity rather than compute one.

**Files:**
- Create: `app/services/library/observation.rb`
- Modify: `app/services/library/scanner.rb`, `app/services/library/reconciler.rb`
- Modify: `test/services/library/reconciler_test.rb`

- [ ] **Step 1: Read the source first, and enumerate**

`Library::Scanner::Observation` is referenced in exactly **five** places (verified): `scanner.rb:108`, `scanner.rb:111`, and `reconciler_test.rb:19,25,226`. **Confirm that yourself** (`grep -rn "Observation" app test`) before moving anything — 2a's worst rework came from a test-move list that undercounted its source by two cases, one of them a tenant-isolation test that would have been silently deleted.

Keep `Library::Scanner::Observation` **resolving** (a constant alias) so no call site is forced to change in this task. Moving the definition and updating call sites are two changes; do the first here.

- [ ] **Step 2: Write the failing tests**

Append to `test/services/library/reconciler_test.rb`:

```ruby
    # LANDMINE 1. An observer that already KNOWS the identity (S3 gets it free in the
    # listing) must be able to say so. Without this the Reconciler lazily hashes, which for
    # S3 means downloading the object -- a full egress of the bucket on first scan, and
    # Digest::SHA256.hexdigest(reader.call(...)) loads the whole thing into memory besides.
    test "an observation may supply its own content_hash, and the reader is never called" do
      called = false
      obs = [ Library::Observation.new(rel_path: "a.stl", size: 3, mtime: T0, dir: false,
                                       content_hash: "md5:supplied") ]
      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [],
                              reader: ->(_) { called = true; "aaa" }).call

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "md5:supplied", node.content_hash, "the supplied identity must be stored verbatim"
      assert_not called, "a supplied hash must never be recomputed -- for S3 that is an egress bill"
    end

    test "a supplied hash pairs a move exactly as a computed one does" do
      obs1 = [ Library::Observation.new(rel_path: "old.stl", size: 4, mtime: T0, dir: false,
                                        content_hash: "md5:same") ]
      Library::Reconciler.new(@user, observations: obs1, unreadable_dirs: [], reader: ->(_) { "xxxx" }).call
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      obs2 = [ Library::Observation.new(rel_path: "new/moved.stl", size: 4, mtime: T0, dir: false,
                                        content_hash: "md5:same") ]
      Library::Reconciler.new(@user, observations: obs2, unreadable_dirs: [], reader: ->(_) { "xxxx" },
                             max_delete_pct: 100).call

      assert_equal id, @user.nodes.find_by!(storage_path: "new/moved.stl").node_id,
                   "move-pairing must not care WHERE the identity came from"
    end

    # The incremental skip compares (mtime, size). S3's last_modified is SECOND-granularity
    # (verified), so that pair is coarser there than a share's nanoseconds. When the observer
    # supplies an identity, comparing it directly is free, exact, and closes the window.
    test "a supplied hash that CHANGED is applied even when mtime and size did not" do
      obs = ->(hash) { [ Library::Observation.new(rel_path: "e.stl", size: 3, mtime: T0,
                                                  dir: false, content_hash: hash) ] }
      Library::Reconciler.new(@user, observations: obs.call("md5:v1"), unreadable_dirs: [],
                              reader: ->(_) { "aaa" }).call
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      Library::Reconciler.new(@user, observations: obs.call("md5:v2"), unreadable_dirs: [],
                              reader: ->(_) { "bbb" }).call

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id, "an edit in place is not a new file"
      assert_equal "md5:v2", node.content_hash,
                   "an identical (mtime, size) must not mask a changed identity"
    end

    # The share path is UNCHANGED: no supplied hash means hash lazily, skip on (mtime, size).
    # This is the regression guard for the whole 2a design, which this task edits underneath.
    test "with no supplied hash the lazy path is untouched: unchanged means not hashed" do
      calls = 0
      reader = ->(_) { calls += 1; "aaa" }
      obs = [ Library::Observation.new(rel_path: "b.stl", size: 3, mtime: T0, dir: false) ]

      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader:).call
      assert_equal 1, calls, "a new file is hashed once"

      Library::Reconciler.new(@user, observations: obs, unreadable_dirs: [], reader:).call
      assert_equal 1, calls, "unchanged (path, mtime, size) must still be skipped without hashing"
    end
```

`T0` is already defined in this file (verify its name before use — read the file).

- [ ] **Step 3: Run to see them fail** — `NameError: uninitialized constant Library::Observation`.

- [ ] **Step 4: Implement**

**Constraints:**
- `Library::Observation = Data.define(:rel_path, :size, :mtime, :dir, :content_hash)` with `content_hash` **defaulting to nil** (`Data.define` has no default syntax — give it one via a `def self.new` override or keyword default in a wrapper; **pick one and say which in your report**, because the four-arg call sites in `scanner.rb` must keep working).
- `Library::Scanner::Observation = Library::Observation` — the alias, so existing call sites resolve.
- Reconciler: `hash_for(o)` returns `o.content_hash` when present, **without calling the reader**. Pinned above.
- Reconciler `match_live_paths`: when `o.content_hash` is present, the skip compares **identity**, not `(mtime, size)`. When absent, the existing `(mtime, size)` skip is **untouched** — pinned by the last test.
- **Do not** change `plan_moves`'s `filter_map`. It is correct for the lazy path (a transient blip → skip → next pass). Task 1's totality is what keeps S3 out of it. Note this in the comment so the next reader does not "fix" the filter_map and silently re-arm Landmine 1 for the share.
- The class header explains **why** the field exists (an observer that gets identity free must not be forced to pay for it twice) — not merely that it does.

- [ ] **Step 5: Green — both suites**

Run: `bin/rails test test/services/library/ test/services/file_layer/` then `bin/rails test`.
Then: `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`. **Both green, identical counts.** Report ACTUAL. This task edits the code path 2a's headline promise runs on — if the share suite moves at all, stop and report.

- [ ] **Step 6: Prove the supplied-hash path is real (mutation)**

Make `hash_for` ignore `o.content_hash` (always use the reader). The "reader is never called" test must fail. Byte-exact guard; revert by backup + `cmp`. Report.

- [ ] **Step 7: Commit**

```bash
git add app/services/library/observation.rb app/services/library/scanner.rb \
        app/services/library/reconciler.rb test/services/library/reconciler_test.rb
git commit -m "$(cat <<'EOF'
feat(library): an observation may carry the identity its observer already knows

The Reconciler was built to hash lazily, which is right for a share: identity costs a read, so
a file whose (path, mtime, size) is unchanged is skipped and a 2TB archive is not re-read every
pass. S3 inverts both halves. Identity is FREE in the listing, so lazily "saving" a read means
downloading the object instead -- a full egress of the bucket on first scan, and hexdigest of
the reader's return loads it all into memory besides. And S3's last_modified is second-
granularity, so the (mtime, size) skip is coarser there than a share's nanoseconds.

So an Observation may now supply content_hash. When it does, the reader is never called and the
skip compares identity directly: free, exact, no granularity question. When it does not, the
share path is bit-for-bit what it was.

This is also the prerequisite for the phase's worst landmine. plan_moves' filter_map DROPS a
nil-hash observation entirely -- verified by probe, it is never indexed, no error, no log --
on the stated assumption that "the next pass indexes it properly". True for an EACCES blip on a
share; permanently false for an S3 object with no derivable checksum. Task 1's ladder is total
so nothing from S3 ever reaches that branch, and the filter_map stays as it is for the share.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Config, the boot guard, and the factory

**Files:**
- Modify: `lib/library_backend_check.rb`, `app/services/file_layer.rb`
- Modify: `test/lib/library_backend_check_test.rb`, `test/services/file_layer/factory_test.rb`
- Create: `app/services/file_layer/s3.rb` (the shell — `initialize`/`capabilities` only)

- [ ] **Step 1: Read `lib/library_backend_check.rb` first.** Its header documents *what it does not catch*, and 2b added the writability probe. That comment is load-bearing and must stay true.

- [ ] **Step 2: Write the failing tests**

In `test/lib/library_backend_check_test.rb`:

```ruby
  test "s3 mode refuses to boot without a bucket" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "s3", env: { "LIBRARY_S3_REGION" => "us-east-1" })
    end
    assert_match(/LIBRARY_S3_BUCKET/, err.message), "the operator must be told WHICH knob is missing"
  end

  test "s3 mode names every missing knob at once, not one per restart" do
    err = assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check!(backend: "s3", env: {}) }
    %w[LIBRARY_S3_BUCKET LIBRARY_S3_ACCESS_KEY_ID LIBRARY_S3_SECRET_ACCESS_KEY].each do |knob|
      assert_match(/#{knob}/, err.message, "a boot guard that reveals one missing knob per restart is a bad guard")
    end
  end

  test "s3 mode boots with the required knobs" do
    assert_nothing_raised do
      LibraryBackendCheck.check!(backend: "s3", env: {
        "LIBRARY_S3_BUCKET" => "b", "LIBRARY_S3_ACCESS_KEY_ID" => "ak",
        "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk", "LIBRARY_S3_REGION" => "us-east-1"
      })
    end
  end

  # The s3 guard must NOT reach the network. The share guard probes a real write because
  # File.writable? lies under NFS/SMB ACLs -- but a boot guard that does a live S3 round-trip
  # makes the app's boot depend on a third party being up, and turns a transient blip into a
  # crash loop. Config presence is what boot can honestly check; credential validity surfaces
  # on first use as a FetchError, which is retryable BY DESIGN.
  test "the s3 guard does not touch the network" do
    assert_nothing_raised do
      LibraryBackendCheck.check!(backend: "s3", env: {
        "LIBRARY_S3_BUCKET" => "definitely-not-a-real-bucket-#{SecureRandom.hex(6)}",
        "LIBRARY_S3_ACCESS_KEY_ID" => "ak", "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk",
        "LIBRARY_S3_REGION" => "us-east-1", "LIBRARY_S3_ENDPOINT" => "http://127.0.0.1:1"
      })
    end
  end
```

In `test/services/file_layer/factory_test.rb`, **read the existing s3 test first** — it asserts `NotImplementedError` and must be REPLACED, not appended to:

```ruby
    test "LIBRARY_BACKEND=s3 selects the S3 adapter" do
      with_backend("s3") do
        prior = ENV.to_h.slice("LIBRARY_S3_BUCKET", "LIBRARY_S3_ACCESS_KEY_ID",
                               "LIBRARY_S3_SECRET_ACCESS_KEY", "LIBRARY_S3_REGION")
        ENV["LIBRARY_S3_BUCKET"] = "b"
        ENV["LIBRARY_S3_ACCESS_KEY_ID"] = "ak"
        ENV["LIBRARY_S3_SECRET_ACCESS_KEY"] = "sk"
        ENV["LIBRARY_S3_REGION"] = "us-east-1"
        FileLayer.reset!
        assert_instance_of FileLayer::S3, FileLayer.current
      ensure
        prior.each { |k, v| ENV[k] = v }
        %w[LIBRARY_S3_BUCKET LIBRARY_S3_ACCESS_KEY_ID LIBRARY_S3_SECRET_ACCESS_KEY
           LIBRARY_S3_REGION].each { |k| ENV.delete(k) unless prior.key?(k) }
        FileLayer.reset!
      end
    end

    # Constructing the adapter must not reach the network either -- the factory runs at boot.
    test "building the S3 adapter does not require the bucket to be reachable" do
      assert_nothing_raised do
        FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                          secret_access_key: "sk", endpoint: "http://127.0.0.1:1")
      end
    end
```

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement**

**Constraints:**
- Config, mirroring `S3ChunkStore.from_env`'s **shape** without touching that class: `LIBRARY_S3_BUCKET` (required), `LIBRARY_S3_ACCESS_KEY_ID` / `LIBRARY_S3_SECRET_ACCESS_KEY` (required), `LIBRARY_S3_REGION` (default `"auto"` — R2's value, matching the chunk store's default), `LIBRARY_S3_ENDPOINT` (optional; set for R2/SeaweedFS/MinIO), `LIBRARY_S3_PREFIX` (optional; the library's root within the bucket).
- `FileLayer::S3.new(bucket:, region:, access_key_id:, secret_access_key:, endpoint: nil, prefix: nil, client: nil)`. **`client:` is the test seam** — Task 5 depends on it. Default it from the other args.
- `capabilities` → `versioned: false, syncable: false, presignable: **true**`. **This is the one backend where `presignable` is true AND `versioned` is false**, and it is the whole point: §15 survives here (Phase 4's `Redirect`) while §5 does not (decision 3). If a future capability change makes those two co-vary, this adapter is the counterexample.
- The boot guard takes an **injectable `env:`** (defaulting to `ENV`) so the tests above need no process-wide mutation. Check `backend == "s3"`; **collect every missing knob and name them all in one message.**
- **A wart you are inheriting, and must resolve deliberately rather than trip over:** 2a's real signature is `check!(backend:, path:)` — verified, and the existing share tests pass `path:`. Adding `env:` means **two ways to inject config into one method**: `path:` for share, `env:` for s3. That is genuinely ugly. Options: (a) add `env:` alongside `path:` and accept the asymmetry; (b) fold `path:` into `env:` (`{"LIBRARY_PATH" => …}`) and update 2a's four tests — **which means enumerating them first**, per the "Learn from" rule; (c) something better. **Pick one, argue it, and report it.** Do not silently break the share tests' `path:` — a green share leg is non-negotiable, and it is the thing that would tell you.
- **No network at boot.** Argued in the test comment above; keep that reasoning in the code.
- The factory's `when "s3"` currently raises `NotImplementedError, "…(phase 3)"`. Replace it. **Keep `LibraryBackendCheck.check!` before construction**, exactly as `"share"` does — read the comment there; it explains why the factory asks even though the initializer already did.
- Extend `Share`'s constructor? **No.** Do not touch it.

- [ ] **Step 5: Green + full suite** — report ACTUAL counts for `bin/rails test` and the share leg.

- [ ] **Step 6: Commit.**

---

### Task 4: `FileLayer::S3` — `stat`/`read` and the read contract

**Files:**
- Create: `test/support/fake_s3.rb`
- Modify: `app/services/file_layer/s3.rb`
- Create: `test/services/file_layer/s3_test.rb`

- [ ] **Step 1: Build the fake — the stateful stub client**

**Verified:** `stub_responses` accepts a **lambda**, giving state with real SDK types, real serialization, and real error classes (`Aws::S3::Errors::NoSuchKey` etc.). That is strictly better than a hand-rolled double, which would let a signature drift past the suite. Create `test/support/fake_s3.rb`:

```ruby
require "aws-sdk-s3"

# A stateful, hermetic S3 for the suite: real Aws::S3::Client, real request/response
# serialization, real error classes -- backed by a Hash instead of a network.
#
# stub_responses accepts a lambda (verified), so this is the SDK doing its own marshalling
# rather than a double that would happily accept a call signature the real client rejects.
# No network, no credentials, no SeaweedFS in CI.
#
# It models ONLY what the adapter uses. A method the adapter calls but this does not stub
# raises from the SDK -- which is the correct, loud outcome: extend the fake deliberately.
class FakeS3
  Obj = Struct.new(:body, :last_modified, :etag, :checksum_sha256, :checksum_type)

  attr_reader :objects, :calls

  def initialize
    @objects = {}
    @calls = Hash.new(0)
    @faults = {}
  end

  # Force an operation to fail. `error` is an SDK error name ("NoSuchKey", "AccessDenied",
  # "InternalError") or an exception instance -- the transient/terminal split is what the
  # contract's most consequential test turns on.
  def fault!(operation, error) = @faults[operation] = error
  def clear_faults! = @faults.clear

  def client
    @client ||= Aws::S3::Client.new(
      stub_responses: true, region: "us-east-1",
      access_key_id: "ak", secret_access_key: "sk"
    ).tap { |c| stub_all(c) }
  end

  # Seed an object as if some other tool had put it there -- which is the whole premise of
  # this backend: the bucket already has the user's files in it.
  def seed!(key, body, last_modified: Time.at(1_700_000_000), checksum_sha256: nil, checksum_type: nil)
    @objects[key] = Obj.new(body.b, last_modified, %Q{"#{Digest::MD5.hexdigest(body)}"},
                            checksum_sha256, checksum_type)
  end

  private

  def stub_all(c)
    c.stub_responses(:put_object, ->(ctx) { guard(:put_object) || do_put(ctx) })
    c.stub_responses(:get_object, ->(ctx) { guard(:get_object) || do_get(ctx) })
    c.stub_responses(:head_object, ->(ctx) { guard(:head_object) || do_head(ctx) })
    c.stub_responses(:delete_object, ->(ctx) { guard(:delete_object) || do_delete(ctx) })
    c.stub_responses(:copy_object, ->(ctx) { guard(:copy_object) || do_copy(ctx) })
    c.stub_responses(:list_objects_v2, ->(ctx) { guard(:list_objects_v2) || do_list(ctx) })
  end

  def guard(op)
    @calls[op] += 1
    @faults[op]
  end

  def do_put(ctx)
    body = ctx.params[:body]
    body = body.read if body.respond_to?(:read)
    seed!(ctx.params[:key], body.b, last_modified: Time.now)
    { etag: @objects[ctx.params[:key]].etag }
  end

  def do_get(ctx)
    o = @objects[ctx.params[:key]] or return "NoSuchKey"
    { body: o.body, content_length: o.body.bytesize, etag: o.etag, last_modified: o.last_modified }
  end

  def do_head(ctx)
    o = @objects[ctx.params[:key]] or return "NotFound"
    { content_length: o.body.bytesize, etag: o.etag, last_modified: o.last_modified,
      checksum_sha256: o.checksum_sha256, checksum_type: o.checksum_type }
  end

  def do_delete(ctx)
    @objects.delete(ctx.params[:key])
    {}
  end

  def do_copy(ctx)
    src = ctx.params[:copy_source].to_s.split("/", 2).last
    src = CGI.unescape(src)
    o = @objects[src] or return "NoSuchKey"
    # copy_source_if_match is the conditional that makes the trash copy safe against a
    # concurrent overwrite. Honor it, or the test that pins it would pass vacuously.
    if (want = ctx.params[:copy_source_if_match]) && want != o.etag
      return "PreconditionFailed"
    end
    @objects[ctx.params[:key]] = o.dup
    { copy_object_result: { etag: o.etag } }
  end

  # Pagination is REAL here, at 2 keys a page: a fake that returns everything in one page
  # cannot exercise the partial-listing landmine, which is the whole risk of the observer.
  def do_list(ctx)
    prefix = ctx.params[:prefix].to_s
    keys = @objects.keys.select { |k| k.start_with?(prefix) }.sort
    page = Integer(ctx.params[:continuation_token] || 0)
    per = ctx.params[:max_keys] || 2
    slice = keys[page, per] || []
    { contents: slice.map { |k|
        o = @objects[k]
        { key: k, size: o.body.bytesize, etag: o.etag, last_modified: o.last_modified,
          checksum_algorithm: (o.checksum_sha256 ? [ "SHA256" ] : nil),
          checksum_type: o.checksum_type }
      },
      is_truncated: (page + per) < keys.size,
      next_continuation_token: ((page + per) < keys.size ? (page + per).to_s : nil) }
  end
end
```

**Check how `test/support` is loaded** — read `test/test_helper.rb`. If it does not autoload `test/support/**`, `require_relative` it from the test file rather than restructuring the helper.

- [ ] **Step 2: Write the failing test**

Create `test/services/file_layer/s3_test.rb`:

```ruby
require "test_helper"
require_relative "adapter_contract"
require_relative "../../support/fake_s3"

module FileLayer
  # The S3 adapter over the user's own bucket: no chunks, no versions, no history -- the
  # object IS the truth, and content_token is its identity (FileLayer::S3::ObjectIdentity).
  #
  # Runs the SAME read contract as Chunk and Share. That is the anti-divergence mechanism,
  # and it is the reason this adapter needs so few tests of its own.
  class S3Test < ActiveSupport::TestCase
    include FileLayerAdapterContract

    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3-#{SecureRandom.hex(4)}@example.com")
    end

    def adapter
      @adapter ||= FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                     secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end

    # Seed the object as another tool would have, then index it the way a scan does. This is
    # the backend's actual premise: the bucket already has the user's files in it.
    def create_file!(name:, bytes:)
      @fake.seed!("#{PREFIX}/#{name}", bytes, last_modified: Time.now)
      Library::S3Observer.call(@user, adapter:)
      @user.nodes.find_by!(storage_path: name).node_id
    end

    # S3's "delete" as a USER would do it: the object leaves the bucket (deleted in the
    # console, by another tool), and the next scan tombstones the node. NOT the port's
    # delete -- that is the adapter under test.
    def delete_file!(node_id)
      node = @user.nodes.find_by!(node_id:)
      @fake.objects.delete("#{PREFIX}/#{node.storage_path}")
      Library::S3Observer.call(@user, adapter:, max_delete_pct: 100)
    end

    # S3's transient failure: the bytes are there, we cannot read them right now -- an
    # expired credential, a 5xx, a network blip. Must NOT read as "the user deleted it".
    # Faults the TRANSPORT (the client), never the adapter's own classification.
    #
    # BOTH get and put, because this ONE hook serves BOTH contracts: the read contract's
    # transient test reads, and the write contract's (2b Task 5) WRITES. Faulting only
    # get_object would leave put_object succeeding, so the write contract's
    # assert_raises(FetchError) would fail -- and the obvious "fix" is to weaken the contract,
    # which is exactly backwards. 2b's plan flagged this same seam for Share and asked the
    # implementer to decide; the decision here is to widen the one hook rather than add a
    # second, because the contracts describe one notion of "the backend is having a moment".
    def with_transient_backend_failure
      @fake.fault!(:get_object, "InternalError")
      @fake.fault!(:put_object, "InternalError")
      yield
    ensure
      @fake.clear_faults!
    end

    # --- S3-specific --------------------------------------------------------------

    test "stat reports the identity as the content token" do
      id = create_file!(name: "a.stl", bytes: "hello")
      info = adapter.stat(@user, node_id: id)
      assert_equal "md5:#{Digest::MD5.hexdigest('hello')}", info.content_token
      assert_equal 5, info.size
    end

    # The prefix is what lets a bucket hold a library WITHOUT owning the whole bucket.
    # A node's storage_path is relative to it; the key is prefix + path. Getting this
    # wrong reads and writes the wrong keyspace -- silently, on someone else's data.
    test "the prefix scopes the keyspace and never leaks into storage_path" do
      id = create_file!(name: "cad/gear.stl", bytes: "g")
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: id).storage_path
      assert @fake.objects.key?("#{PREFIX}/cad/gear.stl"), "the key is prefix + storage_path"
      assert_equal "g", adapter.read(@user, node_id: id)
    end

    # The mirror of Share#library_present?. An empty/wrong bucket makes EVERY object 404
    # at once -- indistinguishable from "this one was deleted" if we only look at the key.
    # NotFound is terminal (a preview burns to permanently failed), so when the whole
    # library appears to have evaporated, prefer the retryable answer. Same trade, same
    # reasoning, same direction as the share (spec 6).
    test "a missing object in an EMPTY library reads as transient, not as a deletion" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      @fake.objects.clear # the bucket is gone/wrong/empty, not "one file deleted"
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    test "a missing object in a POPULATED library is genuinely gone: terminal" do
      id = create_file!(name: "vanish.stl", bytes: "b")
      create_file!(name: "other.stl", bytes: "still here")
      @fake.objects.delete("#{PREFIX}/vanish.stl")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end

    # AccessDenied is the credentials-outage shape that caused the original production
    # incident. It is NOT NoSuchKey, so it must never read as absence.
    test "AccessDenied is transient, never NotFound" do
      id = create_file!(name: "denied.stl", bytes: "b")
      @fake.fault!(:get_object, "AccessDenied")
      err = assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
      assert_match(/AccessDenied/, err.message, "the operator needs to know WHICH failure")
    end

    test "a networking error is transient, never NotFound" do
      id = create_file!(name: "net.stl", bytes: "b")
      @fake.fault!(:get_object, Seahorse::Client::NetworkingError.new(Errno::ECONNREFUSED.new))
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end

    # The escape guard, at the key layer. A storage_path is written by our own observer, but
    # the audit that preceded this work found exactly this bug class in client-supplied
    # values used as storage keys. update_column bypasses validation -- a poisoned row.
    test "a storage_path that escapes the prefix is refused" do
      id = create_file!(name: "a.stl", bytes: "b")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "../../etc/passwd")
      assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
    end
  end
end
```

- [ ] **Step 3: Run — RED until Task 7**

Expected: `NameError: uninitialized constant Library::S3Observer` (from `create_file!`). **This is correct for this task.** The adapter cannot be exercised until something indexes objects for it — exactly as `share_test.rb` was red until 2a's Task 6. **Do NOT stub the observer to make this green.**

- [ ] **Step 4: Implement `stat`/`read`**

**Constraints:**
- `stat` mirrors `Share#stat` exactly: from the **node**, not the bucket. `content_token: node.content_hash`, `mtime: node.mtime` (already nanos — the observer converts, per `FileInfo`'s contract).
- `read`: resolve `key_for(node)` = `[prefix, node.storage_path].compact.join("/")`, `get_object`, return `.body.read`. Enforce `MAX_BYTES` from `content_length` **before** reading the body — do not stream 2GB into memory to then reject it. (Note the port's §9a-5 taxonomy gap: "too big" is terminal-but-present, and the port has no name for it. `Share` answers `NotFound`; **match `Share` and note the shared wart rather than inventing a third answer here.**)
- **Error mapping — read `Share#read`'s header and mirror its reasoning, which is the hardest-won thing in the file:**
  - `Aws::S3::Errors::NoSuchKey` / `NotFound` → **check whether the library looks present first** (the `library_present?` mirror: `list_objects_v2(prefix:, max_keys: 1)` — one billed request, on the error path only). Empty → `FetchError`; populated → `NotFound`.
  - **Everything else transient.** `Aws::S3::Errors::ServiceError` and `Seahorse::Client::NetworkingError` both descend from `StandardError` (verified), so `rescue Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError => e` → `FetchError`. **Fail safe rather than enumerate** — you cannot list every error an S3-compatible store emits, so the DEFAULT must be recoverable. Only `NoSuchKey`/`NotFound` are terminal. Share's header argues this at length; do not re-derive it, and do not "improve" it into a whitelist (2a's errno whitelist failed open).
  - `library_present?`'s own failure → treat as **not present** → transient. Same as Share.
- The escape guard: a `key_for` that refuses a `storage_path` containing `..` or a leading `/`. **Not** `Pathname#expand_path` — an S3 key is not a filesystem path, and `expand_path` would happily normalize `a/../b` into a *valid* key, silently reading the wrong object. Reject the input; do not normalize it.

- [ ] **Step 5: Commit** (the suite stays red for `s3_test.rb`; say so in the message, as 2a's Task 4 did).

---

### Task 5: `Share`-shaped writes — `write` and the write contract

**Files:**
- Modify: `app/services/file_layer/s3.rb`, `test/services/file_layer/s3_test.rb`

- [ ] **Step 1: Read `test/services/file_layer/adapter_write_contract.rb`** (2b, Task 5) and `app/services/file_layer/share.rb`'s `write`. **The write contract is the specification for this task** — S3 must satisfy it unmodified. That is the contract's entire purpose: it was written in 2b *so that* this adapter could not answer differently, and if it needs changing to accommodate S3, that is a finding to report, not a licence to edit it.

- [ ] **Step 2: Include the write contract + add the S3-specific tests**

In `s3_test.rb`, add `include FileLayerWritableContract` next to the read contract, plus:

```ruby
    test "write puts the object under the prefix and indexes a node the scan agrees with" do
      info = adapter.write(@user, parent_node_id: nil, name: "new.stl", io: StringIO.new("fresh"))

      assert_equal "fresh", @fake.objects["#{PREFIX}/new.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "new.stl", node.storage_path
      assert_equal "md5:#{Digest::MD5.hexdigest('fresh')}", node.content_hash
      assert_equal 5, node.size
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"

      # The scan must AGREE with what write recorded -- same node_id, no duplicate. A write
      # the next scan treats as a new file orphans the attachment the caller just made.
      Library::S3Observer.call(@user, adapter:)
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      assert_equal info.node_id, @user.nodes.find_by!(storage_path: "new.stl").node_id
    end

    # LANDMINE 2, on the write side. put_object's response ETag is quoted exactly like the
    # listing's. If write stores the quoted form and the observer stores the stripped one,
    # the very next scan sees every written file as changed -- and move-pairing never pairs.
    # One normalizer, or the phase's promise inverts.
    test "write and the observer agree on the identity, byte for byte" do
      info = adapter.write(@user, parent_node_id: nil, name: "agree.stl", io: StringIO.new("x"))
      written = @user.nodes.find_by!(node_id: info.node_id).content_hash

      Library::S3Observer.call(@user, adapter:)
      observed = @user.nodes.find_by!(storage_path: "agree.stl").content_hash

      assert_equal written, observed, "write and scan must produce the SAME identity"
      assert_not_includes written, '"', "the quotes S3 wraps ETags in must never reach the DB"
    end

    test "write into a subdirectory addressed by parent_node_id" do
      @fake.seed!("#{PREFIX}/cad/existing.stl", "e")
      Library::S3Observer.call(@user, adapter:)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")

      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("g"))

      assert_equal "g", @fake.objects["#{PREFIX}/cad/gear.stl"].body
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
    end

    # Assert the MESSAGE, not just the class. Every fixture below contains a separator, so it is
    # the LEAF check that refuses them — the escape guard is never reached. 2b shipped exactly
    # this test asserting `NotFound` by class alone, and it pinned nothing: NotFound was reachable
    # two ways and the guard it named was dead code as far as the test was concerned. Same trap,
    # same fix.
    test "write rejects a name that is not a leaf" do
      [ "cad/gear.stl", "../outside.stl", "/etc/passwd", "a/../../outside.stl", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal 0, @fake.objects.keys.count { |k| !k.start_with?("#{PREFIX}/") },
                   "nothing may be written outside the prefix"
    end

    # THE escape guard, reached the only way it can be: through the PARENT. A separator-free leaf
    # cannot escape once `.`/`..` are refused above, so `name` never gets here. This mirrors 2b's
    # Share test, which had to be rewritten for the same reason — see Share#write's poisoned-parent
    # test. Note key_for must REJECT `..`, not normalize it: `expand_path` would turn `a/../b` into
    # a valid key and silently read the wrong object.
    test "write through a parent whose storage_path escapes the prefix is refused" do
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 storage_path: "../escaped", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: evil.node_id, name: "pwned.stl", io: StringIO.new("x"))
      end
      assert_match(/escapes/, err.message)
      assert_equal 0, @fake.objects.keys.count { |k| !k.start_with?("#{PREFIX}/") }
    end

    # The WRITABLE CONTRACT requires this, and 2b's Task 5 found this plan was missing it — which
    # is the contract earning its keep before S3 exists. Share#write refuses an occupied
    # destination (share.rb:88); an S3 adapter that put_object'd straight over it would diverge
    # from its sibling on the one axis this port cannot tolerate. It matters MORE here than in
    # chunk mode: every backend this contract covers is current-state-only (spec decision 3), so a
    # clobber is the user's file permanently gone from a name collision in an upload form.
    #
    # This pins the CHECK, not atomicity neither backend offers: exist?-then-put is TOCTOU, and S3
    # has no portable conditional put — the same race this plan already documents for `move`.
    test "write refuses to clobber an existing object" do
      adapter.write(@user, parent_node_id: nil, name: "keep.stl", io: StringIO.new("original"))
      assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "keep.stl", io: StringIO.new("clobber"))
      end
      assert_equal "original", @fake.objects["#{PREFIX}/keep.stl"].body,
                   "the user's bytes must survive a colliding upload"
    end

    # A failed PUT must not leave an indexed node pointing at an object that is not there:
    # the attachment would resolve to a permanent NotFound. Index only after the put lands.
    test "a failed write indexes nothing" do
      @fake.fault!(:put_object, "InternalError")
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "doomed.stl", io: StringIO.new("x"))
      end
      assert_nil @user.nodes.find_by(storage_path: "doomed.stl"), "a failed put must index nothing"
    end
```

- [ ] **Step 3: Run to see them fail.**

- [ ] **Step 4: Implement `write`**

**Constraints:**
- **Order: put the object, THEN index.** Pinned above. The share writes to a temp file and renames because a half-written file is visible in Finder; **S3 needs no equivalent — `put_object` is atomic, an object appears whole or not at all.** Do not port the temp-and-rename dance; there is nothing to protect against. (Say this in the comment, or a reader who knows `Share#write` will "restore" the missing step.)
- The identity comes from `put_object`'s response ETag → **through `ObjectIdentity.for`**, the same normalizer the observer uses. Landmine 2.
- `mtime`: **nanos**, from the put response / a HEAD — *not* `Time.now`. `FileInfo`'s contract pins the unit and the next scan compares against what the store reports, not against what we guessed.
- `name` is a **leaf**; the directory is `parent_node_id`. Same escape guard as `read`. Refuse `.` and `..` explicitly — they are separator-free, so a `File.basename`-style check passes them, and they are the only leaf values that could otherwise reach outside the prefix. That is also what makes it true that `name` can never reach the escape guard, which is why the guard's test has to come through a poisoned **parent**.
- **Refuse an occupied destination** (`head_object` → exists → `NotFound`). **The writable contract requires this** and this plan was originally missing it — 2b's Task 5 caught the gap, which is the contract doing its job before this adapter exists. `Share#write` refuses (`share.rb:88`); an S3 adapter that put straight over the user's object would diverge from its sibling on the one axis this port cannot tolerate, and every backend here is **current-state-only**, so a clobber is the user's file permanently gone. This pins the *check*, not atomicity: `head`-then-`put` is TOCTOU and S3 has no portable conditional put — the same race this plan already documents for `move`. Say so in the comment rather than implying the check is a lock.
- A failed put → `FetchError` (transient — the caller retries), never `NotFound`.
- Return `FileInfo`.

- [ ] **Step 5: Prove the identity-agreement test can fail (mutation)**

Make `write` store the raw quoted ETag (skip `ObjectIdentity.for`). The agreement test must fail. Byte-exact guard, `grep -c` with expected count, revert by backup + `cmp`. **Report.**

- [ ] **Step 6: Full suite + commit** — report ACTUAL.

---

### Task 6: `delete` → trash, `undelete`, `move` — the landmine task

**This is Phase 3's highest-risk task.** Landmine 3 lands here.

**Files:**
- Modify: `app/services/file_layer/s3.rb`, `test/services/file_layer/s3_test.rb`

- [ ] **Step 1: Write the failing tests — the ordering first**

```ruby
    test "delete copies to the trash prefix keyed by node_id, then removes the original" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)

      assert_nil @fake.objects["#{PREFIX}/bracket.stl"], "the object leaves the indexed keyspace"
      assert_equal "solid", @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"].body
      assert @user.nodes.find_by!(node_id: id).deleted, "the node is tombstoned, never destroyed"
    end

    test "two deleted objects of the SAME NAME do not collide in the trash" do
      @fake.seed!("#{PREFIX}/a/bracket.stl", "one")
      @fake.seed!("#{PREFIX}/b/bracket.stl", "two")
      Library::S3Observer.call(@user, adapter:)
      x = @user.nodes.find_by!(storage_path: "a/bracket.stl").node_id
      y = @user.nodes.find_by!(storage_path: "b/bracket.stl").node_id
      adapter.delete(@user, node_id: x)
      adapter.delete(@user, node_id: y)

      assert_equal "one", @fake.objects["#{PREFIX}/.trash/#{x}/bracket.stl"].body
      assert_equal "two", @fake.objects["#{PREFIX}/.trash/#{y}/bracket.stl"].body
    end

    # LANDMINE 3, half one. Spec 6 says "tombstone only after the copy confirms". A failed
    # copy that tombstoned would hide a file that is still there -- and the next scan, finding
    # no live node and (2b landmine 2) no tombstone at that path to revive, CREATES A NEW NODE
    # with a new node_id. Every attachment orphaned, silently.
    test "a failed COPY tombstones nothing and loses nothing" do
      id = create_file!(name: "x.stl", bytes: "b")
      @fake.fault!(:copy_object, "InternalError")

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }

      assert_not @user.nodes.find_by!(node_id: id).deleted, "a failed copy must not tombstone"
      assert_equal "b", @fake.objects["#{PREFIX}/x.stl"].body, "and must not lose the object"
    end

    # LANDMINE 3, half two -- the half spec 6 does NOT say, and the one that bites. Tombstoning
    # after the copy but before the delete leaves the object live at its original key with the
    # node tombstoned and storage_path NULL. The next scan observes the key, no live node claims
    # it, revive-by-path cannot fire (2b nulls storage_path on a trash tombstone), so it creates
    # a NEW node. The attachment is orphaned by a scan that did nothing wrong.
    #
    # Tombstone LAST -- after the delete confirms. Then a failed delete is merely a delete that
    # did not happen: the object is at its key, the node is live and matches by path, the next
    # scan is a no-op, and the user retries.
    test "a failed DELETE after a successful copy tombstones nothing" do
      id = create_file!(name: "y.stl", bytes: "b")
      @fake.fault!(:delete_object, "InternalError")

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted, "the tombstone goes LAST -- after the delete confirms"
      assert_equal "y.stl", node.storage_path, "and the path is not released either"
      assert_equal "b", @fake.objects["#{PREFIX}/y.stl"].body

      # And the state is CONSISTENT: the next scan is a no-op, not a resurrection.
      @fake.clear_faults!
      assert_nothing_raised { Library::S3Observer.call(@user, adapter:) }
      assert_equal id, @user.nodes.find_by!(storage_path: "y.stl").node_id
    end

    # 2b LANDMINE 1, inherited. delete tombstones in the same breath as the move, so
    # vanished_paths (which uses the `present` scope) never sees it. Without that, deleting
    # most of a library through the UI makes the very next scan refuse itself with UnsafeScan
    # -- the guard firing on the app's own deliberate action.
    test "deleting most of the library does NOT trip the mass-deletion guard on the next scan" do
      ids = 5.times.map { |i| create_file!(name: "f#{i}.stl", bytes: "x#{i}") }
      ids.first(4).each { |id| adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { Library::S3Observer.call(@user, adapter:) }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    # 2b LANDMINE 2, inherited. A trash tombstone releases its path, so revive-by-path cannot
    # hand a NEW object the trashed node's identity -- and with it every attachment and tag --
    # while the old bytes sit in .trash awaiting an undelete that would then collide.
    test "a NEW object at a trashed path is a NEW node, not the trashed one revived" do
      old = create_file!(name: "bracket.stl", bytes: "original")
      adapter.delete(@user, node_id: old)
      assert_nil @user.nodes.find_by!(node_id: old).storage_path,
                 "a trash tombstone must release its path"

      @fake.seed!("#{PREFIX}/bracket.stl", "a completely different file")
      Library::S3Observer.call(@user, adapter:)

      fresh = @user.nodes.find_by!(storage_path: "bracket.stl")
      assert_not_equal old, fresh.node_id, "the new object must not inherit the trashed identity"
      assert @user.nodes.find_by!(node_id: old).deleted
    end

    test "the scan never indexes the trash prefix" do
      id = create_file!(name: "t.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      Library::S3Observer.call(@user, adapter:, max_delete_pct: 100)
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    test "move copies to the new key and keeps the node_id" do
      id = create_file!(name: "old.stl", bytes: "same")
      adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "new.stl")

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "new.stl", node.storage_path
      assert_equal "same", @fake.objects["#{PREFIX}/new.stl"].body
      assert_nil @fake.objects["#{PREFIX}/old.stl"], "S3 has no rename: the original is removed"

      Library::S3Observer.call(@user, adapter:)
      assert_equal id, @user.nodes.find_by!(storage_path: "new.stl").node_id, "the scan must agree"
    end

    test "move refuses to overwrite an existing object" do
      a = create_file!(name: "a.stl", bytes: "aaa")
      create_file!(name: "b.stl", bytes: "bbb")
      assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_equal "bbb", @fake.objects["#{PREFIX}/b.stl"].body, "the destination is untouched"
      assert_equal "aaa", @fake.objects["#{PREFIX}/a.stl"].body, "and the source survives"
    end

    test "move refuses a destination that escapes the prefix" do
      id = create_file!(name: "a.stl", bytes: "aaa")
      assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "../escaped.stl")
      end
    end

    test "undelete copies the bytes back and revives the node with its node_id" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      adapter.undelete(@user, node_id: id)

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted
      assert_equal "bracket.stl", node.storage_path
      assert_equal "solid", @fake.objects["#{PREFIX}/bracket.stl"].body
      assert_nil @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"], "the trash entry is consumed"
    end

    test "undelete refuses when something else now occupies the key" do
      id = create_file!(name: "bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      @fake.seed!("#{PREFIX}/bracket.stl", "someone else's file")

      assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_equal "someone else's file", @fake.objects["#{PREFIX}/bracket.stl"].body,
                   "undelete must never clobber a live object"
      assert @fake.objects["#{PREFIX}/.trash/#{id}/bracket.stl"], "the trashed bytes survive"
    end

    # The conditional copy: if the object changed between our listing and our copy, we would
    # trash bytes the user did not mean to lose. copy_source_if_match makes the copy refuse.
    # Best-effort by design -- an S3-compatible store that IGNORES the header just gets the
    # unconditional behavior it would have had anyway, so this is free where it works.
    test "a concurrent overwrite makes the trash copy refuse rather than trash the wrong bytes" do
      id = create_file!(name: "raced.stl", bytes: "original")
      @fake.fault!(:copy_object, "PreconditionFailed") # what if-match failing looks like

      assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }
      assert_not @user.nodes.find_by!(node_id: id).deleted
    end
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**Constraints:**
- Trash key: `<prefix>/.trash/<node_id>/<name>`. Keyed by `node_id` — that is why two same-named deletes cannot collide.
- **`delete` order, and nothing else: `copy_object` → confirm → `delete_object` → confirm → tombstone.** The tombstone is **last**. Both halves pinned above.
- The tombstone sets `deleted: true` **and `storage_path: nil`** (2b Landmine 2), in one transaction.
- `copy_source_if_match:` the node's identity **when the identity is an `md5:`/`etag:` rung** (i.e. when we hold the ETag). A `sha256:` identity is not an ETag — **do not pass it as one**; either HEAD for the current ETag first or skip the precondition. **Say which you chose and why in your report.**
- Failures: **any** S3 failure in `delete` → `FetchError`, and **nothing is tombstoned**. `copy_object`'s 5GB cap errors — **verify the class against your store** and map it to a clear error; do **not** attempt a multipart copy, and do **not** tombstone (2b's Landmine 3 shape).
- `move` = copy + delete + update the node in place (same `node_id`). Refuse an existing destination — check before copying. **Note the race honestly in a comment:** check-then-copy is not atomic on S3 and there is no conditional-put that is portable across R2/SeaweedFS. A concurrent create at the destination can be clobbered. Say so rather than implying an atomicity S3 does not offer.
- `undelete` restores to `node.name` under its original parent; refuse rather than clobber.
- A `copy_object` over 5GB, and the `copy_source` encoding (`"#{bucket}/#{key}"`, **URL-encoded** — the fake unescapes it, so a plan that skips the encoding will pass the fake and fail live). Flag this in your report if the fake and the real store disagree.

- [ ] **Step 4: Prove both halves of Landmine 3 can fail (mutation)**

- Move the tombstone to **before** the `delete_object`. The "failed DELETE tombstones nothing" test must fail.
- Move the tombstone to **before** the `copy_object`. The "failed COPY" test must fail.

Byte-exact guards, `grep -c` with expected counts, revert by backup + `cmp`. **Report both.**

- [ ] **Step 5: Full suite + commit** — report ACTUAL.

---

### Task 7: `Library::S3Observer`

**Files:**
- Create: `app/services/library/s3_observer.rb`, `test/services/library/s3_observer_test.rb`

**The conclusion this task rests on, so you do not re-derive it:** `Library::Scanner` is **not** reusable — `Dir.children`, `lstat`, the symlink dispatch, `Pathname`, `TRASH_PREFIX` on a path: every line is filesystem. `Library::Reconciler` **is** reusable and always was; its header says so out loud (*"The Scanner OBSERVES; this DECIDES. The split is what lets the matching algorithm be tested without a filesystem"*), it takes `observations:` + `unreadable_dirs:` + an injected `reader:`, and Task 2 gave it the one thing it was missing. So: **a new observer, the same Reconciler.** Duplicating the Reconciler would duplicate the mass-deletion guard, the pairing, and the revive logic — which is where **every one of 2a's bugs lived**.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"
require_relative "../../support/fake_s3"

module Library
  # Observes a bucket the way Scanner observes a directory: it OBSERVES, the Reconciler
  # DECIDES. Same Reconciler, same guard, same pairing -- which is the point. The listing
  # is the only thing that differs, and it is where this backend's landmines live.
  class S3ObserverTest < ActiveSupport::TestCase
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "obs-#{SecureRandom.hex(4)}@example.com")
    end

    def adapter
      @adapter ||= FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                     secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end
    def scan!(**kw) = Library::S3Observer.call(@user, adapter:, **kw)

    test "indexes an object with size, identity, and NANOSECOND mtime" do
      @fake.seed!("#{PREFIX}/a.stl", "hello", last_modified: Time.at(1_700_000_000))
      scan!

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "a.stl", node.name
      assert_equal "file", node.kind
      assert_equal 5, node.size
      assert_equal "md5:#{Digest::MD5.hexdigest('hello')}", node.content_hash
      # S3's last_modified is SECOND-granularity, but the column and FileInfo's contract are
      # NANOS end-to-end. Passing seconds through is the bug that shipped twice for real in
      # the mount adapters.
      assert_equal 1_700_000_000_000_000_000, node.mtime
    end

    # LANDMINE 6. S3 has no directories -- the tree is synthesized from key prefixes, or
    # parent_node_id resolves to nothing and browse/search/tags stop working.
    test "synthesizes directory nodes from key prefixes so the tree still has parents" do
      @fake.seed!("#{PREFIX}/cad/brackets/b.stl", "x")
      scan!

      file = @user.nodes.find_by!(storage_path: "cad/brackets/b.stl")
      brackets = @user.nodes.find_by!(storage_path: "cad/brackets")
      cad = @user.nodes.find_by!(storage_path: "cad")
      assert_equal "dir", cad.kind
      assert_equal "dir", brackets.kind
      assert_equal brackets.node_id, file.parent_node_id
      assert_equal cad.node_id, brackets.parent_node_id
      assert_nil cad.parent_node_id
    end

    # LANDMINE 6. The S3 console (and most tools) make a "folder" as a ZERO-BYTE object with
    # a TRAILING SLASH. Index it as a file and File.basename("cad/") gives "cad" -- a phantom
    # file node named `cad` at storage_path "cad/", living beside the real dir node `cad`.
    # Distinct strings, so the partial unique index permits both, and the phantom is in every
    # browse view forever.
    test "a zero-byte directory-marker object is a directory, not a phantom file" do
      @fake.seed!("#{PREFIX}/cad/", "")
      @fake.seed!("#{PREFIX}/cad/real.stl", "x")
      scan!

      assert_equal 1, @user.nodes.present.where(kind: "file").count,
                   "the only file is real.stl -- the marker is not a file"
      assert_nil @user.nodes.find_by(storage_path: "cad/"), "no node may carry a trailing slash"
      assert_equal "dir", @user.nodes.find_by!(storage_path: "cad").kind
    end

    # LANDMINE 6. S3 keys are BYTES. This is 2a's exact trap -- a non-UTF-8 filename bricked
    # every scan, caught only by the final whole-branch review because macOS cannot create the
    # fixture. An S3 key is far EASIER to write than a non-UTF-8 filename, so this is more
    # likely here, not less. Skip in the OBSERVER so it can never reach vanished_paths and
    # be tombstoned; scrubbing would index a key that no longer resolves to the real object.
    test "a non-UTF-8 key is skipped, and does not brick the scan" do
      @fake.seed!("#{PREFIX}/good.stl", "fine")
      @fake.objects["#{PREFIX}/bad\xFF.stl".b] = @fake.objects["#{PREFIX}/good.stl"]

      assert_nothing_raised { scan! }
      assert @user.nodes.find_by(storage_path: "good.stl"), "one bad key must not lose the others"
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    test "excludes the trash prefix" do
      @fake.seed!("#{PREFIX}/.trash/n1/old.stl", "deleted")
      @fake.seed!("#{PREFIX}/live.stl", "x")
      scan!
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
      assert @user.nodes.find_by(storage_path: "live.stl")
    end

    test "an object outside the prefix is not in this library" do
      @fake.seed!("somewhere-else/other.stl", "not ours")
      @fake.seed!("#{PREFIX}/ours.stl", "ours")
      scan!
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      assert @user.nodes.find_by(storage_path: "ours.stl")
    end

    # The fake paginates at 2 keys a page, so this actually crosses a page boundary.
    test "paginates: every object across several pages is indexed" do
      7.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "body-#{i}") }
      scan!
      assert_equal 7, @user.nodes.present.where(kind: "file").count,
                   "a listing that stops at page 1 silently loses the rest of the library"
    end

    # LANDMINE 4 -- the phase's mass-deletion shape, and 2a's Pathname#find/EACCES bug with a
    # different spelling. A listing that fails on page 3 of 40 is a well-formed LIE: it looks
    # exactly like the user deleting most of their library. The guard trusts its input by
    # design, so an incomplete listing must never BE the input.
    #
    # unreadable_dirs cannot help: it scopes a gap to a SUBTREE, and a page boundary is an
    # arbitrary key range. Aborting is the only honest answer.
    test "a listing that fails mid-pagination ABORTS and tombstones nothing" do
      6.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "body-#{i}") }
      scan!
      assert_equal 6, @user.nodes.present.where(kind: "file").count

      @fake.fault!(:list_objects_v2, "InternalError")
      assert_raises(Library::Scanner::UnsafeScan) { scan! }

      @fake.clear_faults!
      assert_equal 6, @user.nodes.present.where(kind: "file").count,
                   "a partial listing must never be mistaken for a deletion"
    end

    # The mass-deletion guard is the Reconciler's, and this proves the observer is actually
    # WIRED to it rather than reimplementing a laxer one.
    test "a genuinely emptied bucket trips the mass-deletion guard" do
      3.times { |i| @fake.seed!("#{PREFIX}/g#{i}.stl", "x#{i}") }
      scan!
      @fake.objects.clear

      assert_raises(Library::Scanner::UnsafeScan) { scan! }
      assert_equal 3, @user.nodes.present.where(kind: "file").count
    end

    test "a rename in the bucket keeps the node_id -- the attachment survives" do
      @fake.seed!("#{PREFIX}/old.stl", "same bytes")
      scan!
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      body = @fake.objects.delete("#{PREFIX}/old.stl")
      @fake.objects["#{PREFIX}/cad/new.stl"] = body
      scan!(max_delete_pct: 100)

      assert_equal id, @user.nodes.find_by!(storage_path: "cad/new.stl").node_id
    end

    # The identity is FREE in the listing, so the observer must never HEAD or GET to get it.
    # A HEAD per object is a bill; a GET per object is an egress of the whole bucket.
    test "a scan costs listings only -- no HEAD, no GET" do
      5.times { |i| @fake.seed!("#{PREFIX}/f#{i}.stl", "x#{i}") }
      scan!
      assert_equal 0, @fake.calls[:head_object], "a HEAD per object is a bill on every scan"
      assert_equal 0, @fake.calls[:get_object], "a GET per object is an egress of the bucket"
    end
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**Constraints:**
- `Library::S3Observer.call(user, adapter:, max_delete_pct: nil)`. Mirror `Scanner.call`'s shape (it returns the scanner so a caller can ask `#unreadable_dirs`) — **read it and match it** rather than inventing a second idiom.
- **Complete or abort.** Paginate to `is_truncated == false`. **Any** failure mid-pagination → `Library::Scanner::UnsafeScan` (reuse the class — one name, because to an operator these are the same event: "the scan refused"; its header says exactly this). **Never** reconcile a partial listing.
- Emit `Library::Observation` with `content_hash:` from `ObjectIdentity.for(...)` — the listing carries the ETag, so **no HEAD and no GET**. Pinned above.
- `mtime`: `last_modified.to_i * 1_000_000_000 + last_modified.nsec`. **Nanos.** (Second-granularity in practice; the *unit* is still the contract.)
- Strip the prefix from every key → `storage_path` is relative. Skip keys not under the prefix.
- Skip `.trash` (prefix-relative, root-anchored — mirror `Scanner::TRASH_PREFIX`'s reasoning).
- Skip keys ending in `/` as **directory markers**; do not emit them as files.
- **`next unless key.valid_encoding?`** — skip and log. Copy the Scanner's comment; it is the whole explanation.
- Synthesize dir observations from every key's ancestor prefixes, deduped. **Emit parents before children** (the Reconciler sorts shallowest-first anyway — `ensure_dirs` — so this is belt and braces; note it rather than depending on it silently). A synthesized dir has no `mtime`; `nodes.mtime` is nullable — **confirm `ensure_dirs` tolerates nil rather than assuming it.**
- Hand the Reconciler `unreadable_dirs: []` — and note **why that is an honest claim here**: the listing either completed (nothing unobserved) or aborted (nothing reconciled). It is never partial. The Reconciler's comment demands that `[]` be a claim made out loud; this is the argument for it.
- **No `reader:` and no `root:`.** The Reconciler requires one of the two (`raise ArgumentError, "a root: or a reader: is required"` — verified). Every observation supplies its own hash, so neither is ever consulted. **This will raise anyway.** Decide: pass a `reader:` that raises (documenting that it must never be called), or relax the Reconciler's check to accept "every observation carries a hash". **Report which and why** — this is exactly the kind of seam a plan gets wrong, and the tests above are the arbiter.

- [ ] **Step 4: Green — `s3_test.rb` should now go green too**

Run: `bin/rails test test/services/library/s3_observer_test.rb test/services/file_layer/s3_test.rb`. Both must pass; `s3_test.rb`'s contract suites now run end-to-end. **If a CONTRACT test fails, that is a real S3 defect — report it, do not weaken the contract.**

- [ ] **Step 5: Prove the abort is real (mutation)**

Make the pagination loop `break` on an error instead of raising. The mid-pagination test must fail. Byte-exact guard; revert by backup + `cmp`. **Report.**

- [ ] **Step 6: Full suite + commit.**

---

### Task 8: Wire the scan — the Phase 3 trap

**Files:**
- Modify: `app/jobs/library/scan_job.rb`, `app/jobs/library/trash_purge_job.rb`
- Modify: `test/jobs/library/scan_job_test.rb`, `test/jobs/library/trash_purge_job_test.rb`

- [ ] **Step 1: Read `app/jobs/library/scan_job.rb` in full first.** Its comment names this task:

> *"PHASE 3 TRAP: … The moment FileLayer::S3 exists, this is_a? quietly answers false and the scan SILENTLY STOPS … An S3 library needs its own indexer …; whoever builds it must decide here deliberately rather than inherit this false."*

You are that whoever. **Tasks 1-7 all pass while an S3 library is never indexed.**

- [ ] **Step 2: Write the failing tests**

```ruby
    # THE PHASE 3 TRAP, pinned. Before this, scan_all! gated on is_a?(FileLayer::Share) --
    # so the day FileLayer::S3 landed, an S3 deployment's scan silently became a no-op. The
    # job's own comment predicted it. A test is what stops the NEXT backend inheriting it.
    test "scan_all! enqueues for an s3 deployment, not only a share one" do
      with_s3_backend do
        assert_enqueued_with(job: Library::ScanJob) { Library::ScanJob.scan_all! }
      end
    end

    test "scan_all! still no-ops in chunk mode" do
      with_backend("chunk") do
        assert_no_enqueued_jobs(only: Library::ScanJob) { Library::ScanJob.scan_all! }
      end
    end

    test "an s3 scan indexes the bucket" do
      with_s3_backend do |fake|
        user = User.create!(email: "sj-#{SecureRandom.hex(4)}@example.com")
        fake.seed!("library/j.stl", "bytes")
        Library::ScanJob.perform_now(user_id: user.id)
        assert user.nodes.find_by(storage_path: "j.stl"), "the scan must index the object"
      end
    end
```

**`with_s3_backend` does not exist**, and there are already **three** idioms for this — pick one deliberately, do not invent a fourth. Verified:

| Idiom | Where | Mechanism |
|---|---|---|
| `pin_file_layer_backend(name)` | `test_helper.rb:52`, on `ActiveSupport::TestCase`. Used by `previews_test.rb`, `generate_preview_job_test.rb`, `file_bytes_test.rb`. | `ENV["LIBRARY_BACKEND"]` + `FileLayer.reset!`; **a teardown restores it** |
| `FileLayer.current = <adapter>` | `file_bytes_test.rb:30` — injects a fake | the factory's `attr_writer :current` |
| `with_backend(value)` | `factory_test.rb:68`, block-scoped, local to that file | same ENV mechanism |

Your case needs the **fake client injected**, which the ENV-based idioms cannot express (they rebuild from ENV, and `build` constructs a real client). So `FileLayer.current = FileLayer::S3.new(..., client: fake.client)` — with `file_bytes_test.rb:30` as prior art — plus an **explicit `FileLayer.reset!`** on the way out.

**The trap, and it is the reason to say this out loud:** a direct `FileLayer.current =` does **not** set `@file_layer_backend_pinned`, so `test_helper.rb`'s teardown will **not** clean up after it. The `ensure` is load-bearing. Without it the adapter leaks into the next test in that forked worker and fails there as something unrelated — a whole debugging session away from the cause.

- [ ] **Step 3: Implement**

**Constraints:**
- **Do not** replace `is_a?(FileLayer::Share)` with `is_a?(Share) || is_a?(S3)`. That is the same trap with one more branch, and the next backend re-arms it. **Gate on a capability the adapter answers** — e.g. an `indexable?`/`scannable?` predicate on the adapter (`Chunk` false; `Share`/`S3` true), so a new backend must state its own answer instead of inheriting a false. **Argue your choice in the report**; if you add a *capability* rather than a predicate, note that Phase 4 also touches `Capabilities` and coordinate, or say why they are separate questions.
- `ScanJob#perform` must dispatch to the right observer for the deployment's adapter. `root:` is a **share** concept — `S3Observer` takes an adapter, not a root. **Keep `root:` working for share** (the existing tests pass it, and `Pathname` is not ActiveJob-serializable — that lesson is in 2b Task 6). Decide the signature and **report it**.
- `TrashPurgeJob`: an S3 trash is a **key prefix**, not a directory, and there is no directory mtime to age against — the share job backdates the **entry dir's** mtime. For S3 the age must come from the **objects' `last_modified`**. Purge an entry when **every** object under `.trash/<node_id>/` is older than the window. **`LIBRARY_TRASH_DAYS=0` must still mean NEVER purge** (spec §3.5) — `0.days.ago` is `now`, so the obvious implementation purges everything immediately; 2b pinned that and it is a data-loss bug wearing a config knob. **Reuse 2b's test and reasoning.**

- [ ] **Step 4: Green + full suite + commit** — report ACTUAL.

---

### Task 9: The headline E2E + the CI leg

**This is the test that proves the phase.** Everything else is machinery.

**Files:**
- Create: `test/integration/library/s3_library_test.rb`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the E2E**

```ruby
require "test_helper"
require_relative "../../support/fake_s3"

module Library
  # The promise, end to end: point us at a bucket, attach an object to a project, let the user
  # reorganize it with any tool they like, and the attachment still resolves.
  class S3LibraryTest < ActiveSupport::TestCase
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3e2e-#{SecureRandom.hex(4)}@example.com")
      @adapter = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                   secret_access_key: "sk", prefix: PREFIX, client: @fake.client)
    end

    def scan!(**kw) = Library::S3Observer.call(@user, adapter: @adapter, **kw)

    test "a project attachment survives the user reorganizing their bucket" do
      @fake.seed!("#{PREFIX}/stl/bracket.stl", "solid bracket")
      scan!

      node = @user.nodes.find_by!(storage_path: "stl/bracket.stl")
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")

      # The user reorganizes with s3 mv / Cyberduck / rclone: new prefix, new name.
      body = @fake.objects.delete("#{PREFIX}/stl/bracket.stl")
      @fake.objects["#{PREFIX}/cad/printer/bracket-v2.stl"] = body
      scan!(max_delete_pct: 100)

      moved = @user.nodes.find_by!(node_id: attachment.reload.node_id)
      assert_equal "cad/printer/bracket-v2.stl", moved.storage_path
      assert_not moved.deleted
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must still resolve to the bytes after a reorganization"
    end

    test "editing an object gives it a new content token, so previews re-render" do
      @fake.seed!("#{PREFIX}/e.stl", "v1")
      scan!
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id
      first = @adapter.stat(@user, node_id: id).content_token

      @fake.seed!("#{PREFIX}/e.stl", "v2 different", last_modified: Time.at(1_700_000_100))
      scan!

      assert_not_equal first, @adapter.stat(@user, node_id: id).content_token
      assert_equal "v2 different", @adapter.read(@user, node_id: id)
      # A preview keyed on the old token must not resolve -- it names content that is gone.
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: id, content_token: first) }
    end

    test "upload, attach, delete to trash, undelete -- the attachment survives all of it" do
      info = @adapter.write(@user, parent_node_id: nil, name: "bracket.stl",
                            io: StringIO.new("solid bracket"))
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: info.node_id, role: "model")

      @adapter.delete(@user, node_id: info.node_id)
      assert_equal info.node_id, attachment.reload.node_id,
                   "a project shows 'file missing', it does not lose the attachment"
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: attachment.node_id) }

      @adapter.undelete(@user, node_id: info.node_id)
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.reload.node_id)
    end

    test "a trash-deleted object stays deleted across a scan, and the trash is never indexed" do
      info = @adapter.write(@user, parent_node_id: nil, name: "gone.stl", io: StringIO.new("bye"))
      @adapter.delete(@user, node_id: info.node_id)

      scan!(max_delete_pct: 100)
      scan!(max_delete_pct: 100) # twice: a resurrection bug often needs a second pass to show

      assert @user.nodes.find_by!(node_id: info.node_id).deleted,
             "the scan must not resurrect a trashed object (the pull_snapshot ghost class, spec 6)"
      assert_equal 0, @user.nodes.present.where(kind: "file").count
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end
```

**Verify the maker API before running** — `@user.maker_projects` and `project.file_attachments.create!(user:, node_id:, role:)` are carried from 2b, which recorded them as verified (`Project` declares `has_many :file_attachments, -> { order(:position) }, as: :attachable`). **Confirm with `bin/rails runner`, not grep** — a single-line grep on a multi-line `has_many` gives a false negative, which has already bitten this project once.

- [ ] **Step 2: Green** — report ACTUAL.

- [ ] **Step 3: The CI leg**

The Rails suite runs in `.github/workflows/ci.yml`'s `test:` job (command: `bin/rails db:test:prepare test`), and 2a added a `test-share-backend:` sibling. Add `test-s3-backend:` mirroring it **exactly**, with `LIBRARY_BACKEND: s3` and the `LIBRARY_S3_*` knobs pointing at nothing real — spec §7 says *"S3 gets a stubbed client"*, and the boot guard makes no network call (Task 3), so this needs **no external service**.

**`runs-on: [self-hosted, linux]` — never `*-latest`** (CLAUDE.md §15: GitHub bills only hosted runners; self-hosted are free). Copy the `test:` job's `runs-on` exactly.

**Be honest about what this leg buys.** The share leg catches tests that silently depend on the ambient backend. The s3 leg catches the same class — but the real anti-divergence mechanism is **both contracts running against `FileLayer::S3` in the default suite**, not this leg. Say so in the comment, as the 2a work concluded.

- [ ] **Step 4: All three suites + commit**

`bin/rails test`, `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`, and the new s3 leg. Report ACTUAL counts for all three.

---

### Task 10: Docs

**Files:** `CLAUDE.md`, `docs/STATUS.md`

- [ ] **Step 1: Update both, grep for now-false claims, commit.**

CLAUDE.md §15 requires it when the architecture moves. Claims that **become false** the moment this lands — find them and fix them, do not append around them:
- §3's FileLayer row and §12 step 10: *"`s3` … still raises `NotImplementedError`"*.
- §12 step 10's *"Phase 3 trap: the moment `FileLayer::S3` exists, `ScanJob.scan_all!`'s `is_a?(FileLayer::Share)` gate quietly no-ops"* — record how it was resolved, or the warning rots into a lie.
- §12 step 10's phase list (Phase 3 done; Phase 4 next).

**Record, because a future reader will otherwise "simplify" them away:**
- The **identity ladder** and why `content_hash` is namespaced — `"etag:abc-5"` is not a content hash and the prefix is what says so.
- **Move detection is best-effort on S3** and degrades to delete+create for multipart objects without a FULL_OBJECT checksum. That is a user-visible behavior difference from share, and it is the honest cost of not egressing the bucket.
- **`presignable: true` with `versioned: false`** — the only backend where §15 holds and §5 does not.
- The **complete-or-abort** listing rule, and that `unreadable_dirs` deliberately cannot express a page gap.
- `LIBRARY_S3_*`, `LIBRARY_S3_PREFIX`, `LIBRARY_S3_HEAD_FOR_CHECKSUM`.

---

## Definition of done

- [ ] `bin/rails test` green; report the count and the delta from the baseline you recorded at Task 1
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` green, **identical count**
- [ ] The `LIBRARY_BACKEND=s3` leg green
- [ ] `FileLayer::S3` passes **both** contracts — read and writable — **unmodified**. If either needed a change, that is a finding: report it and say why it is not S3-specific knowledge leaking into a shared contract.
- [ ] `LIBRARY_BACKEND=s3 … bin/rails runner 'puts FileLayer.current.class'` prints `FileLayer::S3`
- [ ] **Against a real bucket** (SeaweedFS at `192.168.1.8:8333`, or R2 — `docs/r2-migration.md`): point it at a prefix with a few STLs, run the observer, confirm nodes appear with namespaced identities and nanosecond mtimes; write a file, delete it, confirm it is at `.trash/<node_id>/<name>`, undelete it, confirm the bytes come back. **The fake is hermetic, not authoritative** — `copy_source` encoding, ETag quoting, and `copy_source_if_match` support are exactly the things a fake gets wrong. **Report any divergence between the fake and the real store; that divergence is a finding about the fake.**
- [ ] Mutation results reported for: Task 1 (quote stripping), Task 2 (supplied hash), Task 5 (identity agreement), Task 6 (**both halves** of Landmine 3), Task 7 (the partial-listing abort)
- [ ] No migration (the columns already exist — verified). No sync/changelog/conflict/lock/mount edits (spec §10). No controller wiring (Phase 4). `Storage::S3ChunkStore` unmodified.

## Next

**Phase 4:** capability gating + 501s, and `download`/`Delivery` — including `Redirect(url)`, the presigned variant that makes S3 **the one backend where §15 survives**. `docs/superpowers/plans/2026-07-17-file-layer-capability-gating-phase4.md`.

**Carried from 2a and 2b, unresolved, and now due** — the write path and a bucket both give a library ways to grow: `Library::Reconciler` loads every live node into memory (~1M AR objects on a large library) and `best_pairing` is O(n²) (~2s per 10k renames). Both are commented in-code. **A 2TB NAS was the original reason to fix these; a bucket with 2M objects is a cheaper way to get there, so Phase 3 makes them likelier to bite, not less.** Fix before pointing this at either.
