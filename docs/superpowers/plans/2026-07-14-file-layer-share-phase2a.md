# FileLayer Share Adapter — Phase 2a (read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `LIBRARY_BACKEND=share` boots and serves a **read-only** library indexed from a plain mounted directory — point it at `/mnt/nas/models`, it scans, and the maker layer browses/previews/downloads those files with attachments that survive a reorganization.

**Architecture:** `FileLayer::Share` implements the same port as `Chunk` (`stat`/`read`/`capabilities`), so the maker layer is untouched. `Library::Scanner` walks the root incrementally and `Library::Reconciler` matches disk state to `nodes` — by path first, then by `(content_hash, size)` so a rename keeps its `node_id` and every attachment survives. `nodes` stays the one catalog; directory nodes are synthesized from paths so `parent_node_id` still forms the tree and browse/search/tags keep working unmodified.

**Tech Stack:** Rails 8, Minitest (`ActiveSupport::TestCase`, parallel forked workers, no fixtures — tests create records directly), SQLite in test, Zeitwerk autoloading from `app/services`, Ruby 3.2+ (`Data.define`), rubocop rails-omakase.

**Source spec:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md`. Phase 1 (`…-file-layer-port-phase1.md`) built the port; it is merged, deployed, and live.

---

## Scope

**This plan (2a) — read-only:**
- The two §9a prerequisites (they gate everything else — see below)
- The `nodes` migration
- `FileLayer::Share` — `capabilities`, `stat`, `read`
- `Library::Scanner` + `Library::Reconciler` + the mass-deletion guard
- Boot guard + `LIBRARY_BACKEND=share` factory wiring
- `Library::ScanJob` on `recurring.yml`
- The `LIBRARY_BACKEND=share` CI leg + the headline end-to-end test

**Deferred to 2b (a separate plan) — the write path:** `write`/`delete`/`move` on the port, trash → `<root>/.trash/<node_id>/<name>`, `TrashPurgeJob`, `LIBRARY_TRASH_DAYS`, and the boot guard's writability check.

**Why the split:** spec §9 lumps trash into Phase 2, but trash implies a write path, and Phase 1 deliberately shipped only `stat`/`read`/`capabilities` (YAGNI). Adding the write path *and* the scanner *and* the reconciler in one plan is unexecutable. 2a is independently shippable and is the actual "index my existing NAS library" MVP: everything a user needs to point us at 2TB of STLs and get previews, search, projects, and BOM links. 2b then makes it writable.

**Deferred to Phase 4:** `download`/`Delivery` (spec §3.2). 2a's `read` returns bytes server-side, which is all the preview pipeline needs. Browser-bound byte delivery (X-Accel/`send_file` vs. presigned redirect) is a controller concern and belongs with the UI/capability-gating phase.

**Non-negotiable:** every commit leaves `bin/rails test` green. Baseline **523 runs, 0 failures, 0 errors, 5 skips**.

**Tripwire (spec §10):** this plan must not touch sync, the changelog, conflicts, locks, or the mount adapters. If a task seems to need that, the boundary is wrong — STOP and report rather than reaching into the sync engine.

## Naming warning

This codebase already has a *sharing* feature — `app/models/share_link.rb`, `app/controllers/v1/share_controller.rb` — meaning **public links to a file**. That is unrelated to `FileLayer::Share` (**backing the library with a mounted directory**). Do not conflate them, and do not modify any `share_link` code in this plan.

## Learn from Phase 1 (this plan's most important instruction)

Two real bugs shipped past per-task review in Phase 1, both originating in the *plan*:
1. A test-move list undercounted the source file by two cases — including a **tenant-isolation** test that would have been silently deleted. Caught only because the task told the implementer to audit the source first.
2. A wholesale test rewrite silently dropped **the only guard on multi-chunk ordered assembly**. Proven later by mutation: flipping `.order(:seq)` to `.order(seq: :desc)` — which corrupts every file over one chunk — passed the entire suite.

So: **any task that deletes, moves, or rewrites an existing test must enumerate the source first and account for every case.** And where a guard's value is non-obvious, prove it by mutation: break the code, confirm the test fails, revert. Tasks 6 and 7 below require this explicitly — the reconciler *is* the "attachments survive reorganization" promise, and the mass-deletion guard is what stands between an unmounted NAS and tombstoning a whole library.

## File structure

| File | Responsibility |
|---|---|
| `db/migrate/*_add_share_columns_to_nodes.rb` (create) | `size`, `content_hash`, `storage_path` + indexes |
| `app/services/file_layer/share.rb` (create) | the mounted-directory adapter |
| `app/services/library/scanner.rb` (create) | incremental namespace walk → observations |
| `app/services/library/reconciler.rb` (create) | observations + DB → creates/updates/moves/tombstones |
| `app/jobs/library/scan_job.rb` (create) | schedules the scan |
| `lib/library_backend_check.rb` (create) | boot guard: refuse to start on a bad root |
| `config/initializers/library_backend_check.rb` (create) | invokes the guard |
| `app/services/file_layer.rb` (modify) | factory: build `Share` |
| `app/services/file_layer/chunk.rb` (modify) | §9a-1: `read` requires a live node |
| `test/services/file_layer/adapter_contract.rb` (modify) | §9a-1 + §9a-2 contract tests + 2 new hooks |
| `test/services/file_layer/chunk_test.rb` (modify) | implement the 2 new hooks |
| `test/services/file_layer/share_test.rb` (create) | Share vs. the shared contract |
| `test/services/library/{scanner,reconciler}_test.rb` (create) | the matching algorithm + scan safety |
| `test/integration/library/share_library_test.rb` (create) | the headline E2E |
| `test/jobs/maker/generate_preview_job_test.rb` (modify) | §9a-1 fallout: make the setup realistic |
| `test/integration/v1/maker/previews_test.rb` (modify) | §9a-1 fallout: same |

---

### Task 1: §9a-1 — tombstoned means gone

**Why first:** `Chunk#stat` excludes tombstoned nodes; `Chunk#read` does not. Harmless with one adapter — fatal with two. Share's trash (2b) moves the file to `.trash/`, so `Share#read` on a tombstoned node *physically cannot* return bytes and raises `NotFound`, while `Chunk#read` happily returns them. Same call, opposite answers, contract silent. Decide it now, before a second adapter exists to diverge.

**Decision: tombstoned = gone.** `read` requires a live node — including the by-token path, which today resolves through `user.versions` and never consults `nodes` at all.

**Files:**
- Modify: `test/services/file_layer/adapter_contract.rb`
- Modify: `test/services/file_layer/chunk_test.rb`
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `test/jobs/maker/generate_preview_job_test.rb`
- Modify: `test/integration/v1/maker/previews_test.rb`

- [ ] **Step 1: Add the contract test + document the new hook**

In `test/services/file_layer/adapter_contract.rb`, extend the header's hook list with `delete_file!(node_id)` — described as: *remove the file from the backend the way a user would (chunk: tombstone the node; share: move it out of the indexed tree). It must NOT be the port's `delete`, which does not exist yet.* Then append:

```ruby
  # Tombstoned means GONE, on every backend. Chunk could technically still serve a trashed
  # node's bytes (its versions live in the DB), but Share physically cannot — its trash is a
  # real filesystem move — so an adapter that answers differently is a divergence the maker
  # layer would see as "the file is still there" on one deployment and "missing" on another.
  def test_contract_read_raises_not_found_for_a_deleted_node
    id = create_file!(name: "gone.stl", bytes: "bye")
    delete_file!(id)
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: id) }
  end

  def test_contract_stat_raises_not_found_for_a_deleted_node
    id = create_file!(name: "gone2.stl", bytes: "bye")
    delete_file!(id)
    assert_raises(FileLayer::NotFound) { adapter.stat(@user, node_id: id) }
  end
```

- [ ] **Step 2: Implement the hook in the chunk adapter's test**

In `test/services/file_layer/chunk_test.rb`, next to `create_file!`:

```ruby
    # Chunk's "delete" is the tombstone the v1 API sets (Sync::Mutation op "delete"); the
    # versions stay in the DB for restore, which is exactly why read must check the node.
    def delete_file!(node_id)
      @user.nodes.find_by!(node_id:).update!(deleted: true)
    end
```

- [ ] **Step 3: Run it and watch it fail for the right reason**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: `test_contract_read_raises_not_found_for_a_deleted_node` FAILS — `read` returns bytes instead of raising. (`test_contract_stat_...` already passes; `stat` uses the `present` scope.) This failure IS the bug §9a-1 describes.

- [ ] **Step 4: Make `read` require a live node**

In `app/services/file_layer/chunk.rb`, replace the version-resolution head of `read`:

```ruby
    def read(user, node_id:, content_token: nil)
      # A tombstoned node is GONE on every backend (contract:
      # test_contract_read_raises_not_found_for_a_deleted_node). Checked BEFORE resolving the
      # version, because the by-token path below queries `versions` and would otherwise never
      # consult `nodes` at all — leaving the asymmetry inside this very method.
      node = user.nodes.present.find_by(node_id:)
      raise NotFound, "no live node #{node_id.inspect}" unless node

      version =
        if content_token.present?
          user.versions.find_by(node_id:, version_id: content_token)
        else
          node.current_version
        end
      raise NotFound, "no version for node #{node_id.inspect}" unless version
```

Leave the rest of `read` (the manifest walk, `fetch`, `MAX_BYTES`) untouched.

- [ ] **Step 5: Run the adapter suite**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: PASS — 22 runs, 0 failures (20 existing + the 2 new contract tests).

- [ ] **Step 6: Fix the fallout — and enumerate it, don't guess**

Run: `bin/rails test` and expect failures in `test/jobs/maker/generate_preview_job_test.rb` and `test/integration/v1/maker/previews_test.rb`. **Read both files fully before editing.** They stage `Version` rows with **no `Node` row**, which cannot happen in production — a preview always belongs to a real node. Making them realistic is the fix, not a workaround.

In `test/jobs/maker/generate_preview_job_test.rb`, `stage_version` is the single helper every test uses. Add the node it was missing:

```ruby
    def stage_version(node_id:, version_id:, bytes:, manifest_id: "m")
      hash = "h-#{version_id}"
      @store.write_blob(@user.id, hash, bytes)
      ManifestChunk.create!(user_id: @user.id, manifest_id:, chunk_hash: hash,
                            seq: 0, offset: 0, length: bytes.bytesize)
      version = Version.create!(user_id: @user.id, version_id:, node_id:, manifest_id:)
      # A preview always belongs to a real, live node in production — FileLayer#read now
      # enforces that (tombstoned = gone), so the fixture has to reflect reality.
      node = @user.nodes.find_or_initialize_by(node_id:)
      node.update!(name: node_id, kind: "file", deleted: false, current_version_id: version_id)
      version
    end
```

In `test/integration/v1/maker/previews_test.rb`, the same shape around the `::Version.create!(… node_id: "ready.svg" …)` line — add the matching live node:

```ruby
        ::Version.create!(user_id: user.id, version_id: "vr", node_id: "ready.svg", manifest_id: "m")
        user.nodes.create!(node_id: "ready.svg", name: "ready.svg", kind: "file",
                           deleted: false, current_version_id: "vr")
```

**If any OTHER test fails, do not paper over it — report it.** A failure elsewhere means this behavior change has wider blast radius than the plan predicted, which is information worth having before the Share adapter depends on it.

- [ ] **Step 7: Full suite**

Run: `bin/rails test`
Expected: **525 runs, 0 failures, 0 errors, 5 skips** (523 + the 2 new contract tests). Report the ACTUAL number.

- [ ] **Step 8: Commit**

```bash
git add -A -- app/services/file_layer/chunk.rb test/services/file_layer/adapter_contract.rb \
  test/services/file_layer/chunk_test.rb test/jobs/maker/generate_preview_job_test.rb \
  test/integration/v1/maker/previews_test.rb
git commit -m "$(cat <<'EOF'
fix(file-layer): a tombstoned node is gone on every backend

Chunk#stat excluded tombstoned nodes but Chunk#read did not, so a trashed file's bytes
stayed readable. Harmless with one adapter; a divergence with two — Share's trash is a real
filesystem move, so Share#read on a tombstoned node cannot return bytes. Pinned in the shared
contract so no future adapter can answer differently.

The check lands before version resolution on purpose: read's by-token path queries `versions`
and would otherwise never consult `nodes`, leaving the asymmetry inside read itself.

Two preview tests staged Version rows with no Node row — impossible in production, where a
preview always belongs to a real node. They now create the node they always implied.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: §9a-2 — pin retryability in the contract

**Why:** the contract asserts `NotFound` in six places and `FetchError` in zero, so an adapter could answer a transient failure with `NotFound` and pass. For Share that is spec §6's headline failure: **an unmounted NAS must never read as "the user deleted 40,000 files."** Pin it now, while the only adapter already has the machinery.

**Files:**
- Modify: `test/services/file_layer/adapter_contract.rb`
- Modify: `test/services/file_layer/chunk_test.rb`

- [ ] **Step 1: Add the contract test + document the hook**

Extend the header's hook list with `with_transient_backend_failure { }` — *make the backend fail in a way that is temporary and not the file's fault (a 403/5xx/network blip; an unmounted share), then yield.* Append:

```ruby
  # The single most consequential distinction in the port. A transient backend failure must
  # NEVER read as "the file is gone": NotFound is terminal (a preview is marked failed
  # forever), FetchError retries. This exists because a 403 during a credentials outage was
  # once swallowed as "missing chunk", permanently failing previews for healthy files — and
  # for Share the same mistake means an unmounted NAS looks like the user deleted the library.
  def test_contract_transient_backend_failure_raises_fetch_error_not_not_found
    id = create_file!(name: "flaky.stl", bytes: "still here")
    with_transient_backend_failure do
      assert_raises(FileLayer::FetchError) { adapter.read(@user, node_id: id) }
    end
  end
```

- [ ] **Step 2: Implement the hook for chunk**

`chunk_test.rb` already has `PresignOnlyStore` and `with_http_get_raising`. Add:

```ruby
    # Chunk's transient failure: a presign-only store whose GET returns 403 — the exact
    # credentials-outage shape that caused the original incident.
    def with_transient_backend_failure(&block)
      Storage::ChunkStore.current = PresignOnlyStore.new
      with_http_get_raising(http_error(403), &block)
    end
```

- [ ] **Step 3: Run it**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: PASS — 23 runs, 0 failures. (It should pass immediately: chunk already maps 403 → `FetchError`. The value is the tripwire for Share, not a chunk fix.)

- [ ] **Step 4: Prove the tripwire actually works**

Temporarily change `app/services/file_layer/chunk.rb`'s `fetch` so the 403 branch returns `nil` instead of raising `FetchError` (i.e. reintroduce the original production bug). Run the suite: the new test MUST fail. Revert exactly (`git checkout app/services/file_layer/chunk.rb`) and confirm green. **Report the mutation result** — a contract test that cannot fail is decoration.

- [ ] **Step 5: Commit**

```bash
git add test/services/file_layer/adapter_contract.rb test/services/file_layer/chunk_test.rb
git commit -m "$(cat <<'EOF'
test(file-layer): the contract pins retryability, not just absence

The contract asserted NotFound six times and FetchError zero times, so an adapter could
answer a transient failure with "the file is gone" and pass. Terminal-vs-retryable is the
port's most consequential distinction: for Share, getting it wrong means an unmounted NAS
reads as the user deleting 40,000 files.

Verified by mutation: making chunk's 403 branch return nil (the original production bug)
fails this test.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: The `nodes` migration

**Files:**
- Create: `db/migrate/<timestamp>_add_share_columns_to_nodes.rb`
- Test: none (schema only; Task 4 exercises it)

- [ ] **Step 1: Generate and write the migration**

Run: `bin/rails generate migration AddShareColumnsToNodes`, then replace its body:

```ruby
class AddShareColumnsToNodes < ActiveRecord::Migration[8.1]
  # Share/S3-backed libraries index files that live in the user's own storage, so a node needs
  # to know where its bytes are (storage_path, relative to the configured root) and what they
  # are (content_hash, which doubles as the content_token — those backends keep no history).
  # `size` moves onto the node because it lived on `versions`, which share mode has none of.
  #
  # Chunk mode leaves all three NULL and is unaffected.
  def change
    add_column :nodes, :size, :bigint
    add_column :nodes, :content_hash, :string
    add_column :nodes, :storage_path, :string

    # Move detection: the reconciler pairs a vanished path with a new one by (content_hash,
    # size), which is what lets a rename keep its node_id and its attachments.
    add_index :nodes, [ :user_id, :content_hash ]

    # One node per path. NULLs are distinct in a unique index on both SQLite and Postgres, so
    # chunk mode's NULL storage_paths do not collide with each other.
    add_index :nodes, [ :user_id, :storage_path ], unique: true
  end
end
```

- [ ] **Step 2: Migrate and confirm the schema**

Run: `bin/rails db:migrate`
Then: `grep -E '"(storage_path|content_hash|size)"' db/schema.rb | head`
Expected: all three columns present on `nodes`.

- [ ] **Step 3: Full suite (chunk mode must be untouched)**

Run: `bin/rails test`
Expected: **525 runs, 0 failures, 0 errors, 5 skips** — unchanged. New nullable columns must not affect chunk mode at all.

- [ ] **Step 4: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): nodes gain size, content_hash, storage_path for share-backed libraries

A share/S3-backed node must know where its bytes live (storage_path) and what they are
(content_hash, which is also the content_token — those backends keep no history). size moves
onto the node because it lived on `versions`, which share mode has none of.

The (user_id, content_hash) index powers the reconciler's move detection — the thing that
lets a rename on the NAS keep its node_id and every attachment. Chunk mode leaves all three
NULL and is unaffected.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `FileLayer::Share` — capabilities, stat, read

**Files:**
- Create: `app/services/file_layer/share.rb`
- Create: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/file_layer/share_test.rb`. Note `create_file!` writes a real file then indexes it via the reconciler — which does not exist until Task 6, so this suite is RED until then. That is expected and stated in Step 3.

```ruby
require "test_helper"
require_relative "adapter_contract"

module FileLayer
  # The Share adapter over a plain mounted directory: no chunks, no versions, no history —
  # the file on disk IS the truth, and content_token is its content hash.
  class ShareTest < ActiveSupport::TestCase
    include FileLayerAdapterContract

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-test"))
      @user = User.create!(email: "share-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def adapter = FileLayer::Share.new(root: @root.to_s)

    # Write a real file, then index it the way a scan would. The contract requires a real
    # current mtime; the filesystem provides it.
    def create_file!(name:, bytes:)
      path = @root.join(name)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      Library::Scanner.call(@user, root: @root.to_s)
      @user.nodes.find_by!(storage_path: name).node_id
    end

    # Share's "delete" is the user removing the file from the indexed tree; the next scan
    # tombstones the node.
    def delete_file!(node_id)
      node = @user.nodes.find_by!(node_id:)
      FileUtils.rm_f(@root.join(node.storage_path))
      Library::Scanner.call(@user, root: @root.to_s)
    end

    # Share's transient failure: the bytes are there, we just can't read them right now —
    # an unmounted NAS, a permissions blip. Must NOT read as "the user deleted the file".
    def with_transient_backend_failure
      original = File.method(:binread)
      File.define_singleton_method(:binread) { |*| raise Errno::EACCES, "simulated" }
      yield
    ensure
      File.define_singleton_method(:binread, original)
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `bin/rails test test/services/file_layer/share_test.rb`
Expected: FAIL — `NameError: uninitialized constant FileLayer::Share`.

- [ ] **Step 3: Implement the adapter**

Create `app/services/file_layer/share.rb`:

```ruby
module FileLayer
  # A plain mounted directory (SMB/NFS) the user owns and manages. There are no chunks and no
  # versions: the file on disk IS the truth, so `content_token` is its content hash — it
  # identifies the bytes but does NOT imply they are recoverable (spec decision 3: share-backed
  # libraries are current-state only; restore stays a chunk-mode feature).
  #
  # `nodes` is still the catalog — the scanner indexes into it — so browse/search/tags and the
  # maker layer work unmodified.
  class Share
    def initialize(root: ENV.fetch("LIBRARY_PATH"))
      @root = Pathname.new(root).expand_path
    end

    attr_reader :root

    def capabilities
      # No history (nothing to restore), no sync engine (web-only), nothing to presign (a
      # mounted directory has no URL signer). The UI reads this to hide Restore/History.
      Capabilities.new(versioned: false, syncable: false, presignable: false)
    end

    def stat(user, node_id:)
      node = live_node!(user, node_id)
      FileInfo.new(
        node_id: node.node_id,
        name: node.name,
        kind: node.kind,
        size: node.size.to_i,
        mtime: node.mtime,
        content_token: node.content_hash
      )
    end

    def read(user, node_id:, content_token: nil)
      node = live_node!(user, node_id)

      # Share keeps no history, so a token that isn't the current content is simply gone. This
      # must raise rather than silently serving current bytes: previews key on this token, so
      # answering with different content than was asked for is a correctness bug.
      if content_token.present? && content_token != node.content_hash
        raise NotFound, "content #{content_token.inspect} is not current (share keeps no history)"
      end

      path = absolute_path(node)
      size = File.size(path)
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if size > MAX_BYTES
      File.binread(path)
    rescue Errno::ENOENT => e
      # The file is genuinely gone. Terminal.
      raise NotFound, "#{node_id.inspect}: #{e.class}"
    rescue Errno::EACCES, Errno::EIO, Errno::ESTALE, Errno::EBUSY, Errno::ETIMEDOUT => e
      # The bytes probably exist; we just can't read them right now — an unmounted NAS, a
      # stale NFS handle, a permissions blip. TRANSIENT: the caller must retry, NOT conclude
      # the user deleted their library (spec §6).
      raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
    end

    # Resolve a node's path and refuse anything that escapes the root. Belt and braces: paths
    # come from our own scanner, but the audit that preceded this work found exactly this bug
    # class in client-supplied chunk hashes used as storage keys.
    def absolute_path(node)
      path = @root.join(node.storage_path.to_s).expand_path
      unless path.to_s == @root.to_s || path.to_s.start_with?("#{@root}/")
        raise NotFound, "path escapes the library root: #{node.storage_path.inspect}"
      end
      path
    end

    private

    def live_node!(user, node_id)
      node = user.nodes.present.find_by(node_id:)
      raise NotFound, "no live node #{node_id.inspect}" unless node
      node
    end
  end
end
```

- [ ] **Step 4: Run — expect RED until Task 6**

Run: `bin/rails test test/services/file_layer/share_test.rb`
Expected: FAIL — `NameError: uninitialized constant Library::Scanner` (from `create_file!`). **This is correct for this task.** The adapter cannot be exercised until the scanner indexes files for it. Do NOT stub the scanner to make this green — Tasks 5-6 build it.

- [ ] **Step 5: Confirm nothing else broke, then commit**

Run: `bin/rails test 2>&1 | tail -3` — the pre-existing suites must be unaffected; `share_test.rb`'s failures are expected at this commit.

```bash
git add app/services/file_layer/share.rb test/services/file_layer/share_test.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): Share adapter over a plain mounted directory

stat/read/capabilities against a real directory: no chunks, no versions, content_token is the
content hash. Reading a non-current token raises rather than silently serving current bytes —
previews key on that token, so answering with different content than was asked for is a
correctness bug.

The errno mapping is the load-bearing part: ENOENT is terminal (genuinely gone) while
EACCES/EIO/ESTALE are transient, because an unmounted NAS must never read as the user deleting
their library.

The suite is red until the scanner lands (its create_file! indexes a real file) — deliberately
not stubbed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `Library::Scanner` — observe the tree

**Files:**
- Create: `app/services/library/scanner.rb`
- Create: `test/services/library/scanner_test.rb`

The scanner OBSERVES; Task 6's reconciler DECIDES. Splitting them keeps the matching algorithm — the risky part — testable without a filesystem.

- [ ] **Step 1: Write the failing test**

Create `test/services/library/scanner_test.rb`:

```ruby
require "test_helper"

module Library
  class ScannerTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("scan-test"))
      @user = User.create!(email: "scan-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def write!(rel, bytes)
      p = @root.join(rel)
      FileUtils.mkdir_p(p.dirname)
      File.binwrite(p, bytes)
      p
    end

    test "indexes a new file with size, hash, and NANOSECOND mtime" do
      write!("a.stl", "hello")
      Library::Scanner.call(@user, root: @root.to_s)

      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal "a.stl", node.name
      assert_equal "file", node.kind
      assert_equal 5, node.size
      assert_equal Digest::SHA256.hexdigest("hello"), node.content_hash
      # mtime is unix NANOSECONDS end-to-end (nanos-as-seconds shipped as a real bug twice).
      # A seconds value would be ~1.7e9; nanos are ~1.7e18.
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"
    end

    test "synthesizes directory nodes so the tree still has parents" do
      write!("cad/brackets/b.stl", "x")
      Library::Scanner.call(@user, root: @root.to_s)

      file = @user.nodes.find_by!(storage_path: "cad/brackets/b.stl")
      brackets = @user.nodes.find_by!(storage_path: "cad/brackets")
      cad = @user.nodes.find_by!(storage_path: "cad")
      assert_equal "dir", cad.kind
      assert_equal "dir", brackets.kind
      assert_equal brackets.node_id, file.parent_node_id
      assert_equal cad.node_id, brackets.parent_node_id
      assert_nil cad.parent_node_id
    end

    test "is incremental: an unchanged file is not re-hashed" do
      write!("big.stl", "unchanged")
      Library::Scanner.call(@user, root: @root.to_s)
      before = @user.nodes.find_by!(storage_path: "big.stl")

      # If the scanner re-hashed unchanged files, a 2TB archive would be re-read every pass.
      calls = 0
      original = Digest::SHA256.method(:file)
      Digest::SHA256.define_singleton_method(:file) { |*a| calls += 1; original.call(*a) }
      begin
        Library::Scanner.call(@user, root: @root.to_s)
      ensure
        Digest::SHA256.define_singleton_method(:file, original)
      end

      assert_equal 0, calls, "unchanged (path, mtime, size) must be skipped without hashing"
      assert_equal before.content_hash, @user.nodes.find_by!(storage_path: "big.stl").content_hash
    end

    test "an edited file gets a new hash and keeps its node_id" do
      write!("e.stl", "v1")
      Library::Scanner.call(@user, root: @root.to_s)
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      sleep 0.01
      write!("e.stl", "v2-longer")
      Library::Scanner.call(@user, root: @root.to_s)

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id, "an edit is not a new file"
      assert_equal Digest::SHA256.hexdigest("v2-longer"), node.content_hash
      assert_equal 9, node.size
    end

    test "excludes the trash prefix" do
      write!(".trash/n1/old.stl", "deleted")
      Library::Scanner.call(@user, root: @root.to_s)
      # Indexing .trash would resurrect deleted files as new ones on the next scan — the same
      # bug class as the pull_snapshot ghosts fixed on 2026-07-14.
      assert_nil @user.nodes.find_by(storage_path: ".trash/n1/old.stl")
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    test "skips unreadable files rather than tombstoning them" do
      p = write!("locked.stl", "secret")
      Library::Scanner.call(@user, root: @root.to_s)
      id = @user.nodes.find_by!(storage_path: "locked.stl").node_id

      sleep 0.01
      File.write(p, "changed-so-it-needs-rehash")
      File.chmod(0o000, p)
      begin
        Library::Scanner.call(@user, root: @root.to_s)
      ensure
        File.chmod(0o644, p)
      end

      node = @user.nodes.find_by(node_id: id)
      assert node, "a permission error must never delete the node"
      assert_not node.deleted, "a permission error is not a deletion"
    end
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `bin/rails test test/services/library/scanner_test.rb`
Expected: FAIL — `NameError: uninitialized constant Library::Scanner`.

- [ ] **Step 3: Implement**

Create `app/services/library/scanner.rb`:

```ruby
module Library
  # Walks a share-backed library's root and reconciles it into `nodes`.
  #
  # Incremental by design: a file whose (path, mtime, size) is unchanged is SKIPPED without
  # hashing, so a 2TB archive is not re-read on every pass. Only new/changed files are hashed.
  #
  # This observes; Library::Reconciler decides. Keeping them apart lets the matching algorithm
  # — the part that makes attachments survive a reorganization — be tested without a filesystem.
  class Scanner
    # Never index the trash: doing so re-indexes deleted files as new ones and resurrects them.
    TRASH_PREFIX = ".trash".freeze

    Observation = Data.define(:rel_path, :size, :mtime, :dir)

    def self.call(user, root:, backend: nil)
      new(user, root:).call
    end

    def initialize(user, root:)
      @user = user
      @root = Pathname.new(root).expand_path
    end

    def call
      observations = observe
      Library::Reconciler.new(@user, observations:).call
    end

    private

    # Walk the tree, yielding one Observation per entry. Symlinks are not followed (a loop
    # would hang the scan, and a symlink out of the root would index files the user did not put
    # in their library).
    def observe
      out = []
      @root.find do |path|
        rel = path.relative_path_from(@root).to_s
        next if rel == "."
        if rel == TRASH_PREFIX || rel.start_with?("#{TRASH_PREFIX}/")
          Pathname.prune if path.directory?
          next
        end
        next if path.symlink?

        begin
          st = path.lstat
          out << Observation.new(rel_path: rel, size: st.size, mtime: nanos(st), dir: path.directory?)
        rescue Errno::ENOENT
          next # vanished mid-scan; the next pass will see the truth
        rescue Errno::EACCES, Errno::EIO, Errno::ESTALE => e
          # Skip and log. NEVER treat an unreadable entry as absent — that is how an unmounted
          # NAS turns into a mass tombstone.
          Rails.logger.warn("library scan: skipping #{rel.inspect}: #{e.class}")
          next
        end
      end
      out
    end

    # mtime in unix NANOSECONDS — the sync engine's convention (nodes.mtime is a bigint of
    # nanos). A stat gives seconds + nanosecond fraction; passing st.mtime.to_i straight
    # through is the nanos-as-seconds bug that already shipped twice.
    def nanos(stat)
      stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec
    end
  end
end
```

- [ ] **Step 4: Run — RED until Task 6**

Run: `bin/rails test test/services/library/scanner_test.rb`
Expected: FAIL — `NameError: uninitialized constant Library::Reconciler`. Correct for this task; Task 6 lands it. Do not stub it.

- [ ] **Step 5: Commit**

```bash
git add app/services/library/scanner.rb test/services/library/scanner_test.rb
git commit -m "$(cat <<'EOF'
feat(library): Scanner observes a share-backed root

Incremental by design — unchanged (path, mtime, size) is skipped without hashing, so a 2TB
archive is not re-read every pass. Excludes .trash (indexing it resurrects deleted files),
does not follow symlinks (loops hang; escapes index files the user never added), and skips
unreadable entries rather than treating them as absent — that is how an unmounted NAS becomes
a mass tombstone.

mtime is converted to unix nanoseconds at the stat boundary; passing seconds through is the
bug that already shipped twice in the mount adapters.

Observes only; the Reconciler decides. Red until it lands — deliberately not stubbed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `Library::Reconciler` — the promise

**This task is the whole point of the phase.** The reconciler is what makes a project's attachment survive someone reorganizing their NAS in Finder. Its matching algorithm is the highest-risk code in the plan.

**Files:**
- Create: `app/services/library/reconciler.rb`
- Create: `test/services/library/reconciler_test.rb`

- [ ] **Step 1: Write the failing tests — table-driven over the real cases**

Create `test/services/library/reconciler_test.rb`:

```ruby
require "test_helper"

module Library
  # The matching algorithm: path first, then (content_hash, size) to recover moves. A rename
  # that loses its node_id breaks every project attachment, BOM link, tag, and preview pointing
  # at that file — so these cases ARE the product promise.
  class ReconcilerTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "rec-#{SecureRandom.hex(4)}@example.com") }

    def obs(rel, bytes, dir: false)
      Library::Scanner::Observation.new(
        rel_path: rel, size: bytes.bytesize, mtime: 1_700_000_000_000_000_000, dir:
      )
    end

    # The reconciler hashes on demand via an injected reader, so these tests need no filesystem.
    def reconcile(observations, contents)
      Library::Reconciler.new(@user, observations:, reader: ->(rel) { contents.fetch(rel) }).call
    end

    test "a new file becomes a node" do
      reconcile([ obs("a.stl", "aaa") ], { "a.stl" => "aaa" })
      node = @user.nodes.find_by!(storage_path: "a.stl")
      assert_equal Digest::SHA256.hexdigest("aaa"), node.content_hash
      assert_equal 3, node.size
    end

    test "a RENAME keeps the node_id — the attachment survives" do
      reconcile([ obs("old.stl", "same bytes") ], { "old.stl" => "same bytes" })
      id = @user.nodes.find_by!(storage_path: "old.stl").node_id

      reconcile([ obs("new.stl", "same bytes") ], { "new.stl" => "same bytes" })

      node = @user.nodes.find_by!(storage_path: "new.stl")
      assert_equal id, node.node_id, "a rename must keep node_id or every attachment breaks"
      assert_not node.deleted
      assert_nil @user.nodes.find_by(storage_path: "old.stl")
    end

    test "a MOVE to another directory keeps the node_id" do
      reconcile([ obs("a.stl", "payload") ], { "a.stl" => "payload" })
      id = @user.nodes.find_by!(storage_path: "a.stl").node_id

      reconcile([ obs("cad/a.stl", "payload") ], { "cad/a.stl" => "payload" })

      assert_equal id, @user.nodes.find_by!(storage_path: "cad/a.stl").node_id
    end

    test "an EDIT in place keeps the node_id and updates the hash" do
      reconcile([ obs("e.stl", "v1") ], { "e.stl" => "v1" })
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      reconcile([ obs("e.stl", "v2") ], { "e.stl" => "v2" })

      node = @user.nodes.find_by!(storage_path: "e.stl")
      assert_equal id, node.node_id
      assert_equal Digest::SHA256.hexdigest("v2"), node.content_hash
    end

    test "a DELETE tombstones the node rather than destroying it" do
      reconcile([ obs("d.stl", "bye") ], { "d.stl" => "bye" })
      id = @user.nodes.find_by!(storage_path: "d.stl").node_id

      reconcile([], {})

      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted, "row is kept so a project shows 'file missing', not a vanished attachment"
    end

    test "a move AND edit at once degrades to delete+create — documented, not silent" do
      reconcile([ obs("x.stl", "before") ], { "x.stl" => "before" })
      id = @user.nodes.find_by!(storage_path: "x.stl").node_id

      reconcile([ obs("moved/x.stl", "after") ], { "moved/x.stl" => "after" })

      assert @user.nodes.find_by!(node_id: id).deleted
      assert_not_equal id, @user.nodes.find_by!(storage_path: "moved/x.stl").node_id
    end

    test "ambiguous identical files tie-break deterministically, never crash" do
      reconcile([ obs("dup/a.stl", "same"), obs("dup/b.stl", "same") ],
                { "dup/a.stl" => "same", "dup/b.stl" => "same" })
      assert_equal 2, @user.nodes.present.where(kind: "file").count

      # Both vanish, both reappear elsewhere: pairing is non-unique. Any deterministic answer
      # is acceptable; a crash or a lost file is not.
      reconcile([ obs("moved/a.stl", "same"), obs("moved/b.stl", "same") ],
                { "moved/a.stl" => "same", "moved/b.stl" => "same" })
      assert_equal 2, @user.nodes.present.where(kind: "file").count
    end
  end
end
```

- [ ] **Step 2: Run to see it fail**

Run: `bin/rails test test/services/library/reconciler_test.rb`
Expected: FAIL — `NameError: uninitialized constant Library::Reconciler`.

- [ ] **Step 3: Implement**

Create `app/services/library/reconciler.rb`:

```ruby
module Library
  # Turns "what's on disk now" into creates / updates / moves / tombstones on `nodes`.
  #
  # The matching order is the product promise: match by PATH first, then pair whatever is left
  # by (content_hash, size) to recover a rename or move. A rename that loses its node_id breaks
  # every project attachment, BOM link, tag, and preview pointing at that file — users
  # reorganize a NAS constantly, so this is not an edge case.
  class Reconciler
    def initialize(user, observations:, reader: nil)
      @user = user
      @observations = observations
      @reader = reader # injectable for tests; defaults to reading the file
    end

    def call
      dirs, files = @observations.partition(&:dir)
      ensure_dirs(dirs)

      by_path = @user.nodes.present.where.not(storage_path: nil).index_by(&:storage_path)
      seen = []
      unmatched_obs = []

      files.each do |o|
        node = by_path[o.rel_path]
        if node.nil?
          unmatched_obs << o
        elsif node.mtime == o.mtime && node.size == o.size
          seen << node.id # unchanged — skip, do NOT hash
        else
          node.update!(size: o.size, mtime: o.mtime, content_hash: hash_for(o))
          seen << node.id
        end
      end

      vanished = @user.nodes.present.where(kind: "file").where.not(storage_path: nil)
                      .where.not(id: seen).to_a - unmatched_obs.map { nil }.compact
      vanished.reject! { |n| files.any? { |o| o.rel_path == n.storage_path } }

      pair_moves(vanished, unmatched_obs)
    end

    private

    def hash_for(o)
      @reader ? Digest::SHA256.hexdigest(@reader.call(o.rel_path)) : Digest::SHA256.file(path_of(o)).hexdigest
    end

    def path_of(o) = Pathname.new(FileLayer.current.root).join(o.rel_path)

    # Pair a vanished path with a new one by (content_hash, size) — that's a move. Anything
    # left over is a genuine create or delete.
    def pair_moves(vanished, unmatched_obs)
      remaining = unmatched_obs.map { |o| [ o, hash_for(o) ] }

      vanished.each do |node|
        idx = remaining.index { |(o, h)| h == node.content_hash && o.size == node.size }
        # Tie-break: prefer the candidate sharing the longest directory prefix with the old
        # path, then lexical. Several byte-identical files make pairing non-unique; any
        # deterministic answer beats a crash or a lost file.
        if idx
          cands = remaining.each_index.select { |i| remaining[i][1] == node.content_hash && remaining[i][0].size == node.size }
          idx = cands.min_by { |i| [ -common_prefix_len(node.storage_path, remaining[i][0].rel_path), remaining[i][0].rel_path ] }
          o, _h = remaining.delete_at(idx)
          node.update!(storage_path: o.rel_path, name: File.basename(o.rel_path),
                       parent_node_id: parent_id_for(o.rel_path), mtime: o.mtime, size: o.size)
        else
          node.update!(deleted: true) # tombstone, never destroy: the attachment shows "missing"
        end
      end

      remaining.each do |(o, h)|
        @user.nodes.create!(node_id: SecureRandom.uuid, name: File.basename(o.rel_path),
                            kind: "file", deleted: false, storage_path: o.rel_path,
                            parent_node_id: parent_id_for(o.rel_path),
                            size: o.size, mtime: o.mtime, content_hash: h)
      end
    end

    def common_prefix_len(a, b)
      x = File.dirname(a.to_s).split("/")
      y = File.dirname(b.to_s).split("/")
      i = 0
      i += 1 while i < x.length && i < y.length && x[i] == y[i]
      i
    end

    # Directory nodes are synthesized from paths so parent_node_id still forms the tree — that
    # is what keeps browse/search/tags working unmodified across backends.
    def ensure_dirs(dirs)
      dirs.sort_by { |o| o.rel_path.count("/") }.each do |o|
        node = @user.nodes.find_or_initialize_by(storage_path: o.rel_path)
        node.node_id ||= SecureRandom.uuid
        node.update!(name: File.basename(o.rel_path), kind: "dir", deleted: false,
                     parent_node_id: parent_id_for(o.rel_path), mtime: o.mtime)
      end
    end

    def parent_id_for(rel)
      dir = File.dirname(rel)
      return nil if dir == "."
      @user.nodes.find_by(storage_path: dir)&.node_id
    end
  end
end
```

- [ ] **Step 4: Run until green**

Run: `bin/rails test test/services/library/reconciler_test.rb`
Expected: PASS — 7 runs, 0 failures. **The implementation above is a starting point, not gospel** — if a test fails, fix the implementation to satisfy the test, and report any case where the test itself looks wrong rather than bending it.

- [ ] **Step 5: Prove the rename guard is real (mutation)**

The rename test is the product promise; prove it can fail. Temporarily make `pair_moves` never pair (e.g. force `idx = nil`), run `bin/rails test test/services/library/reconciler_test.rb`, and confirm **"a RENAME keeps the node_id"** FAILS. Revert exactly and confirm green. **Report the mutation result.**

- [ ] **Step 6: Scanner + Share suites should now go green**

Run: `bin/rails test test/services/library/scanner_test.rb test/services/file_layer/share_test.rb`
Expected: both PASS. Share's contract suite now runs end-to-end against a real directory. Report ACTUAL counts. **If a contract test fails, that is a real Share defect — report it, do not weaken the contract.**

- [ ] **Step 7: Full suite + commit**

Run: `bin/rails test` — report ACTUAL counts; 0 failures required.

```bash
git add app/services/library/reconciler.rb test/services/library/reconciler_test.rb
git commit -m "$(cat <<'EOF'
feat(library): Reconciler — a rename on the NAS keeps its node_id

Match by path, then pair the leftovers by (content_hash, size) to recover moves. This IS the
product promise: users reorganize a NAS constantly, and a rename that loses its node_id breaks
every project attachment, BOM link, tag, and preview pointing at that file.

Deletes tombstone rather than destroy, so a project shows "file missing" instead of an
attachment silently vanishing. A move+edit in one interval is indistinguishable from
delete+create — accepted and tested as such. Ambiguous identical files tie-break
deterministically (nearest directory, then lexical) rather than crashing.

Verified by mutation: disabling move pairing fails the rename test.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The mass-deletion guard

**Why:** this is what stands between an unmounted NAS and tombstoning a whole library. Immich, Photoprism, and Plex each learned this the hard way (spec §6).

**Files:**
- Modify: `app/services/library/scanner.rb`
- Modify: `test/services/library/scanner_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/services/library/scanner_test.rb`:

```ruby
    test "an empty or missing root ABORTS rather than tombstoning the library" do
      write!("a.stl", "1"); write!("b.stl", "2"); write!("c.stl", "3")
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 3, @user.nodes.present.where(kind: "file").count

      # Simulate the NAS unmounting: the root exists but is empty.
      FileUtils.rm_f(Dir.glob(@root.join("*")))
      assert_raises(Library::Scanner::UnsafeScan) { Library::Scanner.call(@user, root: @root.to_s) }

      assert_equal 3, @user.nodes.present.where(kind: "file").count,
                   "an unmounted NAS must never read as the user deleting their library"
    end

    test "deleting more than the threshold ABORTS" do
      10.times { |i| write!("f#{i}.stl", "x#{i}") }
      Library::Scanner.call(@user, root: @root.to_s)

      # 5 of 10 gone = 50% > the 20% default.
      5.times { |i| FileUtils.rm_f(@root.join("f#{i}.stl")) }
      assert_raises(Library::Scanner::UnsafeScan) { Library::Scanner.call(@user, root: @root.to_s) }
      assert_equal 10, @user.nodes.present.where(kind: "file").count
    end

    test "a deletion under the threshold proceeds" do
      10.times { |i| write!("g#{i}.stl", "x#{i}") }
      Library::Scanner.call(@user, root: @root.to_s)

      FileUtils.rm_f(@root.join("g0.stl")) # 10% < 20%
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 9, @user.nodes.present.where(kind: "file").count
    end
```

- [ ] **Step 2: Run to see them fail**

Run: `bin/rails test test/services/library/scanner_test.rb`
Expected: the three new tests FAIL — the library is currently wiped instead of the scan aborting. **That failure is the bug this task exists to prevent.**

- [ ] **Step 3: Implement the guard**

In `app/services/library/scanner.rb`, add the error and the check. Insert into `call` between `observe` and the reconcile:

```ruby
    # Refuse to reconcile a scan that would tombstone an implausible share of the library. An
    # unmounted NAS, a wrong LIBRARY_PATH, or a half-mounted share all look identical to "the
    # user deleted everything" — and the tombstones would propagate to every attachment.
    # Immich/Photoprism/Plex all learned this one the hard way (spec §6).
    UnsafeScan = Class.new(StandardError)

    MAX_DELETE_PCT = Integer(ENV.fetch("LIBRARY_SCAN_MAX_DELETE_PCT", "20"))

    def call
      raise UnsafeScan, "library root #{@root} is missing" unless @root.directory?

      observations = observe
      guard_mass_deletion!(observations)
      Library::Reconciler.new(@user, observations:, reader: @reader).call
    end
```

and privately:

```ruby
    def guard_mass_deletion!(observations)
      live = @user.nodes.present.where(kind: "file").where.not(storage_path: nil).count
      return if live.zero?

      seen = observations.reject(&:dir).map(&:rel_path).to_set
      missing = @user.nodes.present.where(kind: "file").where.not(storage_path: nil)
                     .pluck(:storage_path).count { |p| !seen.include?(p) }
      return if missing.zero?

      pct = (missing.to_f / live) * 100
      return if pct <= MAX_DELETE_PCT

      raise UnsafeScan,
            "scan would tombstone #{missing}/#{live} files (#{pct.round(1)}% > #{MAX_DELETE_PCT}%). " \
            "Refusing — is the share mounted? Set LIBRARY_SCAN_MAX_DELETE_PCT to override."
    end
```

Note `MAX_DELETE_PCT` reads ENV at class-load; if the tests need to vary it, read it per-call instead (`Integer(ENV.fetch(...))` inside the method) and say so in your report.

- [ ] **Step 4: Green + full suite**

Run: `bin/rails test test/services/library/scanner_test.rb` then `bin/rails test`.
Expected: all green. Report ACTUAL counts.

- [ ] **Step 5: Commit**

```bash
git add app/services/library/scanner.rb test/services/library/scanner_test.rb
git commit -m "$(cat <<'EOF'
feat(library): refuse a scan that would tombstone the library

An unmounted NAS, a wrong LIBRARY_PATH, and a half-mounted share are indistinguishable from
"the user deleted everything" — and those tombstones propagate to every project attachment.
The scan now aborts if the root is missing or if more than LIBRARY_SCAN_MAX_DELETE_PCT
(default 20%) of the library would disappear at once.

Tested by simulating the unmount: 3 files vanish, the scan raises, and all 3 nodes survive.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Boot guard + factory wiring

**Files:**
- Create: `lib/library_backend_check.rb`
- Create: `config/initializers/library_backend_check.rb`
- Modify: `app/services/file_layer.rb`
- Modify: `test/services/file_layer/factory_test.rb`

- [ ] **Step 1: Write the failing test**

In `test/services/file_layer/factory_test.rb`, REPLACE the `"share and s3 are not yet implemented and say so"` test — **read it first**; it currently asserts BOTH share and s3 raise `NotImplementedError`, and only s3 should keep doing so:

```ruby
    test "LIBRARY_BACKEND=share selects the Share adapter" do
      Dir.mktmpdir do |dir|
        with_backend("share") do
          prior = ENV["LIBRARY_PATH"]
          ENV["LIBRARY_PATH"] = dir
          FileLayer.reset!
          assert_instance_of FileLayer::Share, FileLayer.current
        ensure
          ENV["LIBRARY_PATH"] = prior
          FileLayer.reset!
        end
      end
    end

    # s3 is Phase 3. Until then an operator setting it must get a loud error, never a silent
    # fallback to chunk mode (which would read the WRONG library).
    test "s3 is not yet implemented and says so" do
      with_backend("s3") { assert_raises(NotImplementedError) { FileLayer.current } }
    end
```

- [ ] **Step 2: Run to see it fail**

Run: `bin/rails test test/services/file_layer/factory_test.rb`
Expected: FAIL — share still raises `NotImplementedError`.

- [ ] **Step 3: Wire the factory**

In `app/services/file_layer.rb`'s `build`, replace the `when "share", "s3"` branch:

```ruby
      when "share" then Share.new
      when "s3"
        # Phase 3. Fail loudly: silently falling back to chunk mode would serve an EMPTY
        # library while the operator believes we are reading their bucket.
        raise NotImplementedError, "LIBRARY_BACKEND=s3 is not implemented yet (phase 3)"
```

- [ ] **Step 4: The boot guard**

Create `lib/library_backend_check.rb`:

```ruby
# Refuse to boot a share-backed deployment whose library root is unusable, rather than
# surfacing it as a 500 on the first request. Mirrors lib/postgres_pooler_check.rb, which
# exists for the same reason: a misconfiguration that only shows up under load is worse than
# one that stops the boot.
#
# Read-only for now (phase 2a indexes an existing library); phase 2b adds the write path and
# should extend this to require writability.
module LibraryBackendCheck
  Error = Class.new(StandardError)

  def self.check!(backend: ENV.fetch("LIBRARY_BACKEND", "chunk"), path: ENV["LIBRARY_PATH"])
    return unless backend == "share"

    raise Error, "LIBRARY_BACKEND=share requires LIBRARY_PATH" if path.blank?
    raise Error, "LIBRARY_PATH #{path.inspect} does not exist — is the share mounted?" unless File.exist?(path)
    raise Error, "LIBRARY_PATH #{path.inspect} is not a directory" unless File.directory?(path)
    raise Error, "LIBRARY_PATH #{path.inspect} is not readable" unless File.readable?(path)
  end
end
```

Create `config/initializers/library_backend_check.rb`:

```ruby
require Rails.root.join("lib/library_backend_check")

# Skip in the test env: the suite constructs adapters with explicit tmpdir roots and must not
# depend on a process-wide LIBRARY_PATH.
LibraryBackendCheck.check! unless Rails.env.test?
```

- [ ] **Step 5: Test the guard**

Create `test/lib/library_backend_check_test.rb`:

```ruby
require "test_helper"

class LibraryBackendCheckTest < ActiveSupport::TestCase
  test "chunk mode needs no library path" do
    assert_nothing_raised { LibraryBackendCheck.check!(backend: "chunk", path: nil) }
  end

  test "share mode refuses to boot without a path" do
    assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check!(backend: "share", path: nil) }
  end

  test "share mode refuses to boot on a missing root — is the share mounted?" do
    assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "share", path: "/nonexistent-#{SecureRandom.hex(4)}")
    end
  end

  test "share mode boots on a real directory" do
    Dir.mktmpdir { |d| assert_nothing_raised { LibraryBackendCheck.check!(backend: "share", path: d) } }
  end
end
```

- [ ] **Step 6: Green + commit**

Run: `bin/rails test` — report ACTUAL counts, 0 failures.

```bash
git add lib/library_backend_check.rb config/initializers/library_backend_check.rb \
        app/services/file_layer.rb test/services/file_layer/factory_test.rb \
        test/lib/library_backend_check_test.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): LIBRARY_BACKEND=share boots, with a guard

The factory builds the Share adapter; s3 still raises loudly (phase 3) rather than falling
back to chunk mode and serving an empty library.

The boot guard refuses to start when LIBRARY_PATH is missing, absent, or unreadable —
following the postgres_pooler_check precedent, because a misconfiguration that only appears on
the first request is worse than one that stops the boot. "Is the share mounted?" is the
question it answers.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: `Library::ScanJob` + schedule

**Files:**
- Create: `app/jobs/library/scan_job.rb`
- Create: `test/jobs/library/scan_job_test.rb`
- Modify: `config/recurring.yml`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Library
  class ScanJobTest < ActiveSupport::TestCase
    test "scans every user's library in share mode" do
      Dir.mktmpdir do |dir|
        user = User.create!(email: "job-#{SecureRandom.hex(4)}@example.com")
        File.binwrite(File.join(dir, "j.stl"), "bytes")

        Library::ScanJob.perform_now(user_id: user.id, root: dir)

        assert user.nodes.find_by(storage_path: "j.stl"), "the scan must index the file"
      end
    end

    # A failed scan must not take the whole job down silently, and an UnsafeScan (the
    # unmounted-NAS guard) is a legitimate, expected outcome to surface, not a crash loop.
    test "an unsafe scan is reported, not swallowed" do
      user = User.create!(email: "job2-#{SecureRandom.hex(4)}@example.com")
      assert_raises(Library::Scanner::UnsafeScan) do
        Library::ScanJob.perform_now(user_id: user.id, root: "/nonexistent-#{SecureRandom.hex(4)}")
      end
    end
  end
end
```

- [ ] **Step 2: Implement**

```ruby
module Library
  # Periodic reconcile of a share-backed library. Changes made outside the app (someone drops
  # files on the NAS in Finder) surface within the interval — inotify/FSEvents are unreliable
  # to absent over SMB/NFS for changes made by OTHER machines, which is the actual use case,
  # so polling is the honest mechanism (spec decision 5).
  class ScanJob < ApplicationJob
    queue_as :default

    def perform(user_id:, root: ENV["LIBRARY_PATH"])
      return unless ENV.fetch("LIBRARY_BACKEND", "chunk") == "share"
      user = User.find(user_id)
      Library::Scanner.call(user, root:)
    end
  end
end
```

- [ ] **Step 3: Schedule it**

`config/recurring.yml` nests entries under a `production:` key and each is either `class:` + `args:` or `command:` + `schedule:` (see the existing `version_retention` / `clear_solid_queue_finished_jobs` entries — **read them first and match their shape**).

**A wrinkle you must handle, not paper over:** the existing recurring jobs are all-users sweeps taking no arguments, whereas `ScanJob#perform` above takes `user_id:`. There is no per-user fan-out pattern in this file to copy. Resolve it by giving the job an all-users entry point rather than inventing a scheduler pattern — add to `app/jobs/library/scan_job.rb`:

```ruby
    # recurring.yml has no per-user fan-out pattern (every existing entry is an all-users
    # sweep), so the schedule calls this and it fans out internally. Tenant = user, and a
    # share-backed deployment is single-user in practice, so this stays small.
    def self.scan_all!(root: ENV["LIBRARY_PATH"])
      return unless ENV.fetch("LIBRARY_BACKEND", "chunk") == "share"
      User.find_each { |u| perform_later(user_id: u.id, root:) }
    end
```

and schedule that under `production:`:

```yaml
  # Reconcile share-backed libraries with what's actually on disk. Changes made outside the
  # app (someone drops files on the NAS in Finder) surface within this interval — inotify does
  # not reliably fire for other machines' writes over SMB/NFS, so polling is the honest
  # mechanism (spec decision 5). No-ops unless LIBRARY_BACKEND=share.
  library_scan:
    command: "Library::ScanJob.scan_all!"
    schedule: every 15 minutes
```

Add a test for `scan_all!` asserting it no-ops when `LIBRARY_BACKEND` is not `share` (use the `with_backend`-style ENV save/restore from `factory_test.rb`). If the `production:`-only nesting means this never runs in dev, note it in your report — do not restructure the file.

- [ ] **Step 4: Green + commit**

Run: `bin/rails test` — report ACTUAL counts.

```bash
git add app/jobs/library/scan_job.rb test/jobs/library/scan_job_test.rb config/recurring.yml
git commit -m "$(cat <<'EOF'
feat(library): schedule the share-library scan

Changes made outside the app surface within the interval. Polling is the honest mechanism:
inotify/FSEvents do not reliably fire for changes made by OTHER machines over SMB/NFS, which
is exactly the use case, and S3 cannot be watched at all — one code path for every backend
(spec decision 5).

An UnsafeScan (the unmounted-NAS guard) surfaces rather than being swallowed.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: The headline end-to-end + the CI leg

**This is the test that proves the phase.** Everything else is machinery.

**Files:**
- Create: `test/integration/library/share_library_test.rb`
- Modify: `.github/workflows/rust-client.yml` **or** the Ruby CI workflow — find which workflow runs `bin/rails test` first and add the leg there.

- [ ] **Step 1: Write the E2E**

```ruby
require "test_helper"

module Library
  # The promise, end to end: point us at a folder, attach a file to a project, let the user
  # reorganize their NAS in Finder, and the attachment still resolves.
  class ShareLibraryTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("share-e2e"))
      @user = User.create!(email: "e2e-#{SecureRandom.hex(4)}@example.com")
      @adapter = FileLayer::Share.new(root: @root.to_s)
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    def scan! = Library::Scanner.call(@user, root: @root.to_s)

    test "a project attachment survives the user reorganizing their NAS" do
      FileUtils.mkdir_p(@root.join("stl"))
      File.binwrite(@root.join("stl/bracket.stl"), "solid bracket")
      scan!

      node = @user.nodes.find_by!(storage_path: "stl/bracket.stl")
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")

      # The user reorganizes in Finder: new folder, new name.
      FileUtils.mkdir_p(@root.join("cad/printer"))
      FileUtils.mv(@root.join("stl/bracket.stl"), @root.join("cad/printer/bracket-v2.stl"))
      FileUtils.rmdir(@root.join("stl"))
      scan!

      moved = @user.nodes.find_by!(node_id: attachment.reload.node_id)
      assert_equal "cad/printer/bracket-v2.stl", moved.storage_path
      assert_not moved.deleted
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must still resolve to the bytes after a reorganization"
    end

    test "editing a file on disk gives it a new content token, so previews re-render" do
      File.binwrite(@root.join("e.stl"), "v1")
      scan!
      first = @adapter.stat(@user, node_id: @user.nodes.find_by!(storage_path: "e.stl").node_id).content_token

      sleep 0.01
      File.binwrite(@root.join("e.stl"), "v2 different")
      scan!
      id = @user.nodes.find_by!(storage_path: "e.stl").node_id

      assert_not_equal first, @adapter.stat(@user, node_id: id).content_token
      assert_equal "v2 different", @adapter.read(@user, node_id: id)
      # A preview keyed on the old token must not resolve — it describes content that is gone.
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: id, content_token: first) }
    end
  end
end
```

**Before writing this, check the real model API** — `@user.maker_projects` and `project.file_attachments` are guesses. Read `app/models/maker/project.rb` and `app/models/maker/file_attachment.rb` (it's `belongs_to :attachable, polymorphic: true`) and use whatever is actually there. If the association names differ, use the real ones; do not add associations to make this test compile.

- [ ] **Step 2: Green**

Run: `bin/rails test test/integration/library/share_library_test.rb`
Expected: PASS — 2 runs, 0 failures.

- [ ] **Step 3: Add the CI leg**

The Rails suite runs in `.github/workflows/ci.yml`'s `test:` job (note the command is `bin/rails db:test:prepare test`, not a bare `bin/rails test`). Add a sibling job **after** it, mirroring its exact shape:

```yaml
  # The share-backed backend gets its own run of the whole suite. Cheap — a tmpdir, no external
  # services — and it is the only thing stopping the two backends from silently diverging as
  # phases 2b/3 land.
  test-share-backend:
    runs-on: [self-hosted, linux]
    steps:
      - name: Checkout code
        uses: actions/checkout@v6

      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Run tests with LIBRARY_BACKEND=share
        env:
          RAILS_ENV: test
          LIBRARY_BACKEND: share
        run: |
          export LIBRARY_PATH=$(mktemp -d)
          bin/rails db:test:prepare test
```

**Self-hosted runners only** — never `*-latest` (CLAUDE.md §15: GitHub bills hosted runners; self-hosted are free). Copy `test:`'s `runs-on: [self-hosted, linux]` exactly.

**Note the interaction with Task 8's initializer:** `config/initializers/library_backend_check.rb` skips the guard in the test env, so this job will boot even though `LIBRARY_PATH` points at an empty tmpdir. That is intended — the suite constructs its own adapters with explicit roots. If you find the guard fires here anyway, report it rather than deleting the guard.

- [ ] **Step 4: Full suite + commit**

Run: `bin/rails test` and `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` — both must be green. Report ACTUAL counts for both.

```bash
git add test/integration/library/share_library_test.rb .github/workflows/
git commit -m "$(cat <<'EOF'
test(library): the headline promise — an attachment survives a NAS reorganization

Attach a file to a project, move and rename it on disk the way a user would in Finder,
rescan, and the attachment still resolves to the bytes. Everything else in this phase is
machinery for this one behavior.

Also pins that an edit yields a new content token (so previews re-render) and that the old
token no longer resolves — share keeps no history, so it describes content that is gone.

Adds the LIBRARY_BACKEND=share CI leg: cheap, no external services, and the only thing
stopping the two backends from silently diverging.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

## Definition of done

- [ ] `bin/rails test` green; report the count and the delta from 523
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` green
- [ ] `FileLayer::Share` passes the **entire** shared contract, unmodified
- [ ] `LIBRARY_BACKEND=share bin/rails runner 'puts FileLayer.current.class'` prints `FileLayer::Share`
- [ ] Point it at a real folder with a few STLs, run `Library::Scanner.call(user, root:)`, and confirm the nodes appear with hashes and nanosecond mtimes
- [ ] Mutation results reported for: the retryability contract test (Task 2) and the rename guard (Task 6)
- [ ] No change to chunk mode beyond §9a-1; no migration beyond Task 3; no sync/changelog/conflict/lock/mount edits (spec §10)

## Next

**Phase 2b** (a separate plan): the write path — `write`/`delete`/`move` on the port, trash → `<root>/.trash/<node_id>/<name>`, `TrashPurgeJob` + `LIBRARY_TRASH_DAYS`, the boot guard's writability check, and the scanner's already-present `.trash` exclusion becomes load-bearing.

**Phase 3:** the S3 adapter. **Phase 4:** capability gating + 501s in the web UI, and `download`/`Delivery`.
