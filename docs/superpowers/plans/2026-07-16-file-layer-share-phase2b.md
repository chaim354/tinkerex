# FileLayer Share Adapter — Phase 2b (the write path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a share-backed library becomes **writable** — `write`/`delete`/`move` on the port, with delete going to `<root>/.trash/<node_id>/<name>` for a bounded undo, a purge job, and a boot guard that refuses to start when the share isn't writable.

**Architecture:** the write path lands on `FileLayer::Share` only. `Chunk` **refuses it loudly** — chunk-mode writes go through the sync engine's two-phase `Sync::Commit` (client-driven, presigned), which this plan must not touch (§10). A **second contract module** (`adapter_write_contract.rb`) pins the cross-adapter write rules; `share_test.rb` includes it now, `s3_test.rb` will in Phase 3. Delete is a **rename into `.trash/`** plus a tombstone in one transaction, and it **nulls `storage_path`** so the scanner's revive-by-path can never resurrect a trashed node into a different file's identity.

**Tech Stack:** Rails 8, Minitest (`ActiveSupport::TestCase`, parallel forked *processes*, no fixtures — tests create records directly), SQLite in test, Zeitwerk from `app/services`, Ruby 3.4, rubocop rails-omakase.

**Source spec:** `docs/superpowers/specs/2026-07-14-maker-file-layer-split-design.md` (§3.2 the port, §3.5 config/boot guard, §6 delete→trash→purge, §7 testing).
**Predecessor:** `docs/superpowers/plans/2026-07-14-file-layer-share-phase2a.md` — merged as `63544ee`. **Read `app/services/file_layer/share.rb`, `app/services/library/scanner.rb`, and `app/services/library/reconciler.rb` before starting; their comments carry reasoning this plan depends on.**

---

## Scope

**This plan (2b) — the write path:**
- The port's shape: `write`/`delete`/`move`; `Chunk` refuses them loudly
- `FileLayer::Share#write` / `#delete` (→ trash) / `#move` / `#undelete`
- The writable-adapter contract (a *second* module, not the existing read contract)
- `Library::TrashPurgeJob` + `LIBRARY_TRASH_DAYS` + `recurring.yml`
- The boot guard's writability check
- The E2E, including the three cross-task landmines below

**Deferred to Phase 3:** the S3 adapter (it inherits the write contract — that is the contract's whole point).
**Deferred to Phase 4:** capability gating + 501s in the web UI, and `download`/`Delivery`. **2b wires no controller.** `FilesController` keeps using `Sync::Commit` for chunk mode; routing the web UI to the port is Phase 4's job. A write path with only tests as consumers is the plan's deliberate decomposition — do not "helpfully" wire the UI.

**Non-negotiable:** every commit leaves `bin/rails test` green. Baseline at the start of 2b was **635 runs, 1814 assertions, 0 failures, 0 errors, 5 skips**; **Task 1 has landed (`63a330c`) and the measured baseline for Tasks 2–9 is now 636 runs, 1823 assertions, 0 failures, 0 errors, 5 skips.** `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` must stay **identical** — the suite is backend-independent and must remain so.

**Tripwire (spec §10):** must not touch sync, the changelog, conflicts, locks, or the mount adapters. **This plan brushes right against it:** chunk-mode writes and chunk-mode trash live in `Sync::Commit` and `Sync::Trash`. If a task seems to need either, the boundary is wrong — STOP and report. The correct answer is always "Chunk refuses; Share implements."

---

## The settled seam decision — do not relitigate

**The write path is NOT in the shared read contract.** `test/services/file_layer/adapter_contract.rb` runs against **both** adapters and is the anti-divergence mechanism. Putting `write` in it would force `Chunk#write` to exist — meaning a server-side FastCDC chunking + version + manifest + changelog + broadcast path. That is `Sync::Commit` reimplemented, it trips §10, and **nothing would call it** (devices push; the web UI uses the two-phase presigned flow).

So: a **second** module, `FileLayerWritableContract`, included only by adapters that implement the port's write path. Share includes it now. S3 includes it in Phase 3. That preserves the anti-divergence guarantee exactly where it applies.

`Chunk` still grows the three methods — raising `NotImplementedError` naming `Sync::Commit`. A `NoMethodError` from the port would be an ugly lie; the port should say what it means.

---

## Learn from 2a — this plan's most important section

**2a's plan was wrong in every single task**, twice in ways that would have shipped silent data loss. The three that matter here, because 2b inherits their fixes:

1. **The mass-deletion guard counts the POST-pairing tombstone set**, never vanished paths. A rename vanishes its old path; a guard reading the pre-pairing number refuses the reorganization the phase exists for.
2. **The reconciler revives a tombstone by `storage_path`.** 2a chose this so a delete-in-Finder-then-restore keeps its `node_id` and attachments. **2b's trash collides with it** — see Landmine 2.
3. **`Pathname#find` silently swallows `EACCES`.** The Scanner hand-rolls its walk and exposes `#unreadable_dirs`, which is excluded from *both* sides of the guard's fraction *and* from `vanished_paths`.

And the process lessons, which cost real rework:
- **A test that cannot fail is decoration.** ~11 times in 2a a test stayed green while its coverage evaporated — including an `assert_raises(ArgumentError)` passing on a *missing keyword* rather than the check it named, and a test named `..._through_the_chunk_adapter` that didn't pin the adapter. **Assert the message, not just the class, whenever the class is generic or reachable two ways.**
- **Verify every mutation actually applied**, byte-exactly, or you will report a false green. Guards fired for real across six agents. Known traps: multiline `grep -F` treats the newline as an **OR of two patterns**; `<<~` heredocs strip indentation so anchors miss; **a non-UTF-8 `File.read` blows up on em-dashes and silently skips the substitution**; `%q{...\n}` is a literal backslash-n. Use `grep -c` with an **expected count**.
- **NEVER `git checkout` to revert a mutation** — an agent destroyed its own uncommitted implementation that way. File backup + `cmp`.
- **The plan can be wrong. Report it.** That was the highest-value output of every 2a task.

### Why this plan's code is different from 2a's — read before trusting a snippet

2a's plan supplied a full implementation for every task, **and every one of them was wrong** — a dead `- unmatched_obs.map { nil }.compact`, a `FileLayer.current.root` that simply crashes (`Chunk` has no `root`), an errno whitelist that failed open, a guard whose design refused the phase's own headline test, and two that would have shipped silent data loss. The implementers' best work came from treating those snippets as suspect and deriving against the real code; their worst came from transcribing faithfully.

This plan first responded by withholding implementations entirely. **That has now changed, and the reason matters:** the code below was not written from memory of the codebase — it was **executed against it**. Every method here was prototyped by reopening `FileLayer::Share` in a `bin/rails runner` process on this worktree at `63a330c`, run against the real `Library::Scanner`, the real `Library::Reconciler`, the real `nodes` table and the real `Maker::FileAttachment`, and observed to pass the tests in this plan. Both landmine mutations were run and **observed to fail the right test for the right reason**. What killed 2a's snippets was that they were plausible; what is different here is not confidence, it is a transcript.

**That verification is per-task and is stated per-task.** Each task below carries a `**Verified:**` line saying what was actually executed. Where a claim could not be executed, the task says so instead of guessing.

**What this does NOT buy you:** the prototype ran in one process against a rolled-back transaction, not under the real suite's parallel forked processes, and not through Zeitwerk-autoloaded source. **Rubocop has not seen it.** Treat the code as a verified starting point that still has to go RED-then-GREEN under `bin/rails test` — not as something to paste and commit. And the standing rule holds: **if a snippet here turns out to be wrong, that is a finding, and reporting it is worth more than fixing it quietly.**

The tests remain the specification — read them as the definition of done. **Six of them were wrong as first written and are corrected below**; each correction carries a note saying what was wrong, because the correction is less valuable than the reason.

---

## The three cross-task landmines

2a's two worst defects were **cross-task** — each commit fine alone, broken in combination, invisible to per-task review. These three are 2b's equivalents. Each has a task that must pin it.

### Landmine 1 — a UI delete must not trip the mass-deletion guard

`Share#delete` moves the file out of the indexed tree. The next scan sees it gone. If the node were still live, `vanished_paths` would include it, and **a user deleting 30% of their library through the UI would have their next scan refused with `UnsafeScan`** — the guard firing on the app's own deliberate action.

**Therefore `delete` MUST tombstone the node in the same transaction as the move.** `vanished_paths` uses the `present` scope, so a tombstoned node is invisible to it and the guard never sees it. Pinned in Task 3 and again in Task 9.

### Landmine 2 — revive-by-path would resurrect a trashed node into a different file

2a's reconciler revives a tombstone **by `storage_path`**. After a trash-delete the node is tombstoned; if it kept `storage_path`, then a *new, unrelated* file later dropped at that same path would **revive the trashed node** — handing the new file the old node's `node_id`, and with it every project attachment, BOM link, and tag. Meanwhile the old bytes still sit in `.trash`, so an undelete would then collide with the new file.

**Therefore `delete` MUST null `storage_path`.** This creates two meaningfully different tombstones, and the distinction is the point:

| Tombstone | Means | Revivable by |
|---|---|---|
| **scan** tombstone (`storage_path` retained) | "it vanished from disk; it may come back" | the reconciler's revive-by-path (2a's behavior — keep it) |
| **trash** tombstone (`storage_path` NULL) | "we deliberately moved it to `.trash/`" | `undelete` only |

The trash path stays derivable from the node alone: `.trash/<node_id>/<name>`. No column needed. Pinned in Task 3.

### Landmine 3 — `.trash` on a different filesystem

`File.rename` across filesystems raises `Errno::EXDEV`. A NAS root with a submount, or a `.trash` someone symlinked elsewhere, breaks the atomic-rename assumption the spec's design rests on. **Do not paper over it with a copy+delete fallback** — that turns delete into a non-atomic operation with a half-state (spec §6 reserves copy-then-tombstone for S3, where there is no rename). Map it to a clear error. Pinned in Task 3.

---

## File structure

| File | Responsibility |
|---|---|
| `app/services/file_layer/chunk.rb` (modify) | refuse `write`/`delete`/`move`, naming `Sync::Commit` |
| `app/services/file_layer/share.rb` (modify) | `write`/`delete`/`move`/`undelete` + trash pathing |
| `app/jobs/library/trash_purge_job.rb` (create) | purge `.trash/*` older than `LIBRARY_TRASH_DAYS` |
| `lib/library_backend_check.rb` (modify) | the writability check |
| `config/recurring.yml` (modify) | schedule the purge |
| `test/services/file_layer/adapter_write_contract.rb` (create) | the writable-adapter contract |
| `test/services/file_layer/share_test.rb` (modify) | include the write contract + Share-specific write tests |
| `test/services/file_layer/chunk_test.rb` (modify) | Chunk refuses the write path |
| `test/jobs/library/trash_purge_job_test.rb` (create) | purge semantics |
| `test/lib/library_backend_check_test.rb` (modify) | writability |
| `test/integration/library/share_library_test.rb` (modify) | the E2E + the landmines |

---

### Task 1: The port's shape — Chunk refuses the write path

**Why first:** it is the seam decision. Settle what the port means before a second adapter implements it.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `test/services/file_layer/chunk_test.rb`

- [ ] **Step 1: Write the failing test**

In `test/services/file_layer/chunk_test.rb`, next to the other Chunk-specific tests:

```ruby
    # Chunk writes do NOT go through this port. A device pushes a commit (Sync::Commit's
    # two-phase presigned flow) and the web UI reuses that same machinery; a server-side
    # FastCDC-chunk-and-commit path does not exist and has no caller. The port says so out
    # loud rather than answering NoMethodError, which would read as an oversight.
    test "the write path is not chunk mode's — it refuses, naming the real path" do
      %i[write delete move].each do |op|
        err = assert_raises(NotImplementedError) do
          case op
          when :write  then adapter.write(@user, parent_node_id: nil, name: "x.stl", io: StringIO.new("b"))
          when :delete then adapter.delete(@user, node_id: "n1")
          when :move   then adapter.move(@user, node_id: "n1", new_parent_node_id: nil, new_name: "y.stl")
          end
        end
        assert_match(/Sync::Commit/, err.message, "#{op} must name the path a caller should use")
      end
    end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/services/file_layer/chunk_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'write'`. That NoMethodError **is** the thing this task fixes.

- [ ] **Step 3: Implement**

In `app/services/file_layer/chunk.rb`, after `read`:

```ruby
    # The port's write path is share/s3 only. Chunk-mode writes are the sync engine's:
    # Sync::Commit's two-phase flow (begin -> presigned PUT of the missing chunks -> finalize),
    # which a device drives and the web UI reuses. Implementing these here would mean a
    # server-side chunk-and-commit path that duplicates Sync::Commit, has no caller, and
    # reaches into the sync engine this port exists to stay out of (spec §10).
    #
    # They exist, rather than being absent, so the answer is an honest error instead of a
    # NoMethodError that reads as an oversight.
    def write(_user, parent_node_id: nil, name: nil, io: nil)
      raise NotImplementedError, WRITE_MSG
    end

    def delete(_user, node_id: nil)
      raise NotImplementedError, WRITE_MSG
    end

    def move(_user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      raise NotImplementedError, WRITE_MSG
    end
```

and near the top of the class:

```ruby
    WRITE_MSG = "chunk-mode writes go through the sync engine (Sync::Commit's two-phase " \
                "commit), not through FileLayer".freeze
```

- [ ] **Step 4: Green + full suite**

Run: `bin/rails test test/services/file_layer/chunk_test.rb` then `bin/rails test`.
Report ACTUAL counts. The full suite must be **636 runs** (635 + 1), 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/services/file_layer/chunk.rb test/services/file_layer/chunk_test.rb
git commit -m "$(cat <<'EOF'
feat(file-layer): the port's write path exists, and chunk mode refuses it

Chunk-mode writes are the sync engine's: Sync::Commit's two-phase presigned flow, which a
device drives and the web UI reuses. A server-side chunk-and-commit path through this port
would duplicate that, have no caller, and reach into the sync engine the port exists to stay
out of.

The methods exist rather than being absent so the answer is an honest error naming the real
path, instead of a NoMethodError that reads as an oversight.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `Share#write`

**Files:**
- Modify: `app/services/file_layer/share.rb`
- Modify: `test/services/file_layer/share_test.rb`

**Verified:** every test and the implementation below were executed against the real `Library::Scanner` and `nodes` table on this worktree and observed green — including the stubbed-`MAX_BYTES` case and the poisoned-parent escape case.

**Two corrections to this task's first draft, both found by running it:**

1. **The escape test was dead coverage.** Its fixtures were `["../outside.stl", "/etc/passwd", "a/../../outside.stl"]` — *every one contains a separator*, so the leaf-name check in the test above it refuses all three and **the escape guard is never reached**. `NotFound` raised two ways, asserted by class only: 2a's exact "a test that cannot fail is decoration" pattern. Corrected below by splitting it: separator-free `.`/`..` fixtures for the leaf check, and a **poisoned parent node** (a `dir` node whose `storage_path` is `../evil`) for the escape guard — which mirrors how `share_test.rb`'s existing read-side escape test reaches it, via `index!(path: "../…")`. **A separator-free leaf name cannot escape the root once `.`/`..`/`""` are refused, so the parent is the only real route — that is why the guard has to stay anyway.**
2. **The scan-agreement test did not pin scan agreement.** A `Time.now`-nanos mtime passes it: the next scan re-hashes the file but still matches it *by path*, keeps the node_id, and the count stays 1. The incremental-skip property — the whole reason a 2TB archive isn't re-read every pass — was unpinned. Corrected by asserting `node.mtime` equals **the file's own stat**, not merely that it is nanos-shaped.

- [ ] **Step 1: Write the failing tests**

Append to `share_test.rb`'s Share-specific section:

```ruby
    test "write stores the bytes and indexes a node the scan agrees with" do
      info = adapter.write(@user, parent_node_id: nil, name: "new.stl", io: StringIO.new("fresh"))

      assert_equal "fresh", File.binread(@root.join("new.stl")), "the bytes must be on disk"
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "new.stl", node.storage_path
      assert_equal Digest::SHA256.hexdigest("fresh"), node.content_hash
      assert_equal 5, node.size
      assert node.mtime > 1_000_000_000_000_000, "mtime must be nanos, got #{node.mtime}"

      # ...and it is the FILE's mtime, not the clock's. `assert mtime > 1e15` above passes for
      # Time.now-in-nanos, and so does everything below it (the scan re-matches by PATH and keeps
      # the node_id either way) — so without this line the incremental-skip property is unpinned,
      # and that property is the only reason a 2TB archive is not re-hashed on every pass.
      st = File.stat(@root.join("new.stl"))
      assert_equal st.mtime.to_i * 1_000_000_000 + st.mtime.nsec, node.mtime,
                   "write must record the file's own stat — Scanner#nanos compares against it"

      # The scan must AGREE with what write recorded — same node_id, no duplicate, no churn.
      # A write that the next scan treats as a new file would orphan the attachment the caller
      # just made.
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 1, @user.nodes.present.where(kind: "file").count
      assert_equal info.node_id, @user.nodes.find_by!(storage_path: "new.stl").node_id
    end

    # `name` is a LEAF; the directory is addressed by parent_node_id. So a write into `cad/`
    # requires cad's node to exist — which a scan produces. This is the maker layer's actual
    # shape: the UI uploads into a folder it is already browsing, so it holds that node_id.
    test "write into a subdirectory addressed by parent_node_id" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")

      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("g"))

      assert_equal "g", File.binread(@root.join("cad/gear.stl"))
      node = @user.nodes.find_by!(node_id: info.node_id)
      assert_equal "cad/gear.stl", node.storage_path
      assert_equal parent.node_id, node.parent_node_id
    end

    # A leaf name is a leaf: the directory is parent_node_id's job. `.` and `..` are separator-FREE
    # and are the only names that could otherwise reach the root or its parent, so they belong to
    # this check and not to the escape guard. The MESSAGE is asserted because NotFound is reachable
    # from both, and a class-only assertion is how the first draft of this test came to pin nothing.
    test "write rejects a name that is not a leaf" do
      [ "cad/gear.stl", "/etc/passwd", "../outside.stl", "a/../../outside.stl", ".", "..", "" ].each do |bad|
        err = assert_raises(FileLayer::NotFound, "#{bad.inspect} must be refused") do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_match(/leaf name/, err.message, bad.inspect)
      end
      assert_equal [], Dir.children(@root), "nothing may be created for a refused name"
    end

    # THE escape guard, reached the only way it can be: through the PARENT. A separator-free leaf
    # cannot escape once `.`/`..` are refused above, so `name` never gets here — but a `dir` node
    # carrying a poisoned storage_path resolves the destination outside the root, which is exactly
    # the bug class the audit preceding this work found (and the same route share_test.rb's
    # read-side escape test uses).
    test "write through a parent whose storage_path escapes the root is refused" do
      outside = Pathname.new(Dir.mktmpdir("outside"))
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 storage_path: "../#{outside.basename}", mtime: 1)

      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: evil.node_id, name: "pwned.stl", io: StringIO.new("x"))
      end
      assert_match(/escapes the library root/, err.message)
      assert_equal [], Dir.children(outside), "nothing may be written outside the root"
    ensure
      FileUtils.remove_entry(outside) if outside&.exist?
    end

    # A 256MB fixture is not the way to pin a 256MB cap. Stub the constant instead — the cap's
    # BEHAVIOR is what matters, and it is identical at 4 bytes. (share_test.rb already stubs the
    # read side's File.size for the same reason; this stubs one layer up because `write` is handed
    # an io, not a path, so there is no File.size call to fault.)
    test "write refuses bytes over MAX_BYTES rather than filling the NAS" do
      original = FileLayer::MAX_BYTES
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, 4)

      err = assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "big.stl", io: StringIO.new("12345"))
      end
      assert_match(/exceeds/, err.message)
      assert_not File.exist?(@root.join("big.stl")), "a refused write leaves no partial file"
      assert_nil @user.nodes.find_by(storage_path: "big.stl"), "and no node"
    ensure
      FileLayer.send(:remove_const, :MAX_BYTES)
      FileLayer.const_set(:MAX_BYTES, original)
    end
```

The `MAX_BYTES` skip is **resolved, not deferred**: stubbing the constant pins the behavior at 4 bytes with no allocation. `remove_const` + `const_set` (rather than `const_set` alone) is what keeps Ruby from printing an "already initialized constant" warning on every run. The suite forks *processes*, so the stub cannot leak into a parallel test — but the `ensure` restores it anyway, because it can leak into the rest of *this* process.

- [ ] **Step 2: Run to see them fail** — `NoMethodError: undefined method 'write'`.

- [ ] **Step 3: Implement**

**Verified against the real Scanner/Reconciler; still has to go green under the real suite.** The `nanos` helper duplicates `Library::Scanner#nanos` deliberately — that formula is the one the scan compares against, and reaching into the Scanner for it would couple the adapter to the indexer.

```ruby
    def write(user, parent_node_id: nil, name: nil, io: nil)
      leaf!(name)
      rel = join_rel(parent_dir_rel!(user, parent_node_id), name)
      dest = resolve_inside!(rel)
      raise NotFound, "#{rel.inspect} already exists" if File.exist?(dest)

      bytes = read_capped!(io)
      FileUtils.mkdir_p(dest.dirname)
      # Temp-then-rename: the 15-minute scan may be walking this directory right now, and a
      # half-written file would be indexed with a hash of its own torn state. The temp name is a
      # DOTFILE so a racing scan skips it (Scanner only skips `.trash` by name, but a dotfile is
      # at least not a plausible STL) — and the rename is atomic within the directory.
      tmp = dest.dirname.join(".maker-tmp-#{SecureRandom.hex(8)}")
      begin
        File.binwrite(tmp, bytes)
        File.rename(tmp, dest)
      rescue SystemCallError => e
        FileUtils.rm_f(tmp)
        # Same reasoning as `read`'s rescue: a full NAS, a permissions blip, an unmounted share.
        # Every one of them is retryable, and NONE of them means "this file is gone".
        raise FetchError, "#{rel.inspect}: #{e.class} (#{e.message})"
      end

      # stat the DESTINATION after the rename — that is the mtime the next scan will stat, and
      # the incremental-skip test above pins that these two agree exactly.
      st = File.stat(dest)
      node = user.nodes.create!(
        node_id: SecureRandom.uuid, name:, kind: "file", deleted: false,
        storage_path: rel, parent_node_id:,
        size: st.size, mtime: nanos(st), content_hash: Digest::SHA256.hexdigest(bytes)
      )
      stat(user, node_id: node.node_id)
    end

    private

    # A leaf name is a leaf. `.` and `..` are separator-free, so File.basename passes them — they
    # need naming explicitly, and refusing them here is what makes it true that no `name` value
    # can reach the escape guard.
    def leaf!(name)
      if name.blank? || File.basename(name.to_s) != name.to_s || %w[. ..].include?(name.to_s)
        raise NotFound, "#{name.inspect} is not a leaf name (the directory is parent_node_id's job)"
      end
    end

    def join_rel(dir_rel, name) = dir_rel.blank? ? name.to_s : "#{dir_rel}/#{name}"

    # `live:` is false for undelete only: its node's parent may itself be a tombstoned directory
    # (the scan tombstones an emptied dir), and refusing to restore into it would strand the file.
    def parent_dir_rel!(user, parent_node_id, live: true)
      return nil if parent_node_id.blank?
      scope = live ? user.nodes.present : user.nodes
      parent = scope.find_by(node_id: parent_node_id, kind: "dir") ||
               raise(NotFound, "parent #{parent_node_id.inspect} is not a live directory")
      parent.storage_path
    end

    # The write path's escape guard. It is NOT absolute_path: that one takes a node (there is no
    # node yet) and it ALLOWS a path resolving to the root itself, which is right for a read that
    # can never ask for it and wrong for a write, where the destination must be strictly INSIDE.
    def resolve_inside!(rel)
      path = @root.join(rel.to_s).expand_path
      raise NotFound, "path escapes the library root: #{rel.inspect}" unless path.to_s.start_with?("#{@root}/")
      path
    end

    # Read the cap PLUS ONE byte: reading exactly MAX_BYTES cannot distinguish "exactly at the
    # cap" from "truncated at the cap", so an oversize upload would be silently cut in half and
    # stored as a valid-looking file. Reads at most 256MB+1 into memory, which is the same
    # exposure `read` already accepts (and the same constant caps it).
    def read_capped!(io)
      bytes = io.read(MAX_BYTES + 1).to_s.b
      raise NotFound, "file exceeds #{MAX_BYTES} bytes" if bytes.bytesize > MAX_BYTES
      bytes
    end

    # Duplicated from Library::Scanner#nanos deliberately: this is the exact formula the scan will
    # compare against, and the write path must not depend on the indexer to say what time it is.
    def nanos(st) = st.mtime.to_i * 1_000_000_000 + st.mtime.nsec
```

**Note on "the same transaction":** this task's first draft said to index the node "in the same transaction" as the write. There is no transaction here and there should not be — a filesystem write cannot be rolled back, so wrapping the `create!` in one buys nothing and would only widen the window in which a rename has landed but the row has not. (Task 3's `delete` is different, and says why.) The failure mode this leaves — bytes on disk, no row, because `create!` raised — is **self-healing: the next scan indexes the file.** That is not true of Task 3, which is why only Task 3 gets a transaction.

- [ ] **Step 4: Green, then prove the scan-agreement test can fail**

Mutate: make `write` record `mtime: Time.now.to_i` (seconds, the bug that shipped twice in the mount adapters). The nanos assertion must fail. Then a second, sharper mutation: `mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)` — correct *units*, wrong *source*. **The nanos assertion passes; only the new stat-equality assertion catches it.** That is the whole reason it was added — report both.

Byte-exact abort-if-unchanged guard; `grep -c` with an expected count. Revert via file backup + `cmp`. **Report the results.**

- [ ] **Step 5: Full suite + commit** — report ACTUAL counts.

---

### Task 3: `Share#delete` → trash — the landmine task

**This is 2b's highest-risk task.** All three landmines land here.

**Files:**
- Modify: `app/services/file_layer/share.rb`
- Modify: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Write the failing tests — the landmines first**

```ruby
    test "delete moves the file to trash keyed by node_id and tombstones the node" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)

      assert_not File.exist?(@root.join("bracket.stl")), "the file leaves the indexed tree"
      assert_equal "solid", File.binread(@root.join(".trash/#{id}/bracket.stl"))
      assert @user.nodes.find_by!(node_id: id).deleted, "the node is tombstoned, never destroyed"
    end

    test "two deleted files of the SAME NAME do not collide in the trash" do
      a = index!("a/bracket.stl", bytes: "one", path: "a/bracket.stl")
      b = index!("b/bracket.stl", bytes: "two", path: "b/bracket.stl")
      adapter.delete(@user, node_id: a)
      adapter.delete(@user, node_id: b)

      # Keyed by node_id, which is exactly why the trash is <node_id>/<name> and not <name>.
      assert_equal "one", File.binread(@root.join(".trash/#{a}/bracket.stl"))
      assert_equal "two", File.binread(@root.join(".trash/#{b}/bracket.stl"))
    end

    # LANDMINE 1. delete tombstones in the same transaction as the move, so vanished_paths
    # (which uses the `present` scope) never sees it. Without that, deleting a third of a
    # library through the UI would make the very next scan refuse itself with UnsafeScan —
    # the guard firing on the app's own deliberate action.
    test "deleting most of the library does NOT trip the mass-deletion guard on the next scan" do
      ids = 5.times.map { |i| index!("f#{i}.stl", bytes: "x#{i}") }
      ids.first(4).each { |id| adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { Library::Scanner.call(@user, root: @root.to_s) }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end

    # LANDMINE 2. A trash tombstone nulls storage_path, so the reconciler's revive-by-path
    # cannot fire for it. Otherwise a NEW file at that path would inherit the trashed node's
    # node_id — and with it every project attachment, BOM link and tag — while the old bytes
    # still sat in .trash waiting for an undelete that would then collide.
    test "a NEW file at a trashed path is a NEW node, not the trashed one revived" do
      old = index!("bracket.stl", bytes: "original")
      adapter.delete(@user, node_id: old)
      assert_nil @user.nodes.find_by!(node_id: old).storage_path,
                 "a trash tombstone must release its path"

      File.binwrite(@root.join("bracket.stl"), "a completely different file")
      Library::Scanner.call(@user, root: @root.to_s)

      fresh = @user.nodes.find_by!(storage_path: "bracket.stl")
      assert_not_equal old, fresh.node_id, "the new file must not inherit the trashed identity"
      assert @user.nodes.find_by!(node_id: old).deleted, "and the trashed node stays trashed"
    end

    # LANDMINE 3. Do not paper over EXDEV with copy+delete: that makes delete non-atomic and
    # invents a half-state. Spec §6 reserves copy-then-tombstone for S3, which has no rename.
    test "a cross-filesystem trash is a clear error, not a silent half-delete" do
      id = index!("x.stl", bytes: "b")
      original = File.method(:rename)
      File.define_singleton_method(:rename) { |*| raise Errno::EXDEV, "simulated" }
      begin
        err = assert_raises(FileLayer::FetchError) { adapter.delete(@user, node_id: id) }
        assert_match(/EXDEV|filesystem/i, err.message)
      ensure
        File.define_singleton_method(:rename, original)
      end
      assert_not @user.nodes.find_by!(node_id: id).deleted, "a failed move must not tombstone"
      assert File.exist?(@root.join("x.stl")), "and must not lose the file"
    end

    test "the scan never indexes the trash" do
      id = index!("t.stl", bytes: "b")
      adapter.delete(@user, node_id: id)
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**Verified — and this is the task where that means the most.** Both landmine mechanisms were checked against the real `Library::Reconciler`, not against a reading of it:

- **Landmine 2's premise is CONFIRMED at `app/services/library/reconciler.rb:330`.** `create_or_revive!` opens with `@user.nodes.where(storage_path: o.rel_path, deleted: true, kind: "file")` — revive is **by `storage_path`**, exactly as the landmine states. A `NULL` `storage_path` is therefore unfindable by it (verified by query: the lookup returns `nil`), and `nodes.storage_path` is nullable, and the partial unique index is `(user_id, storage_path) WHERE deleted = false` so tombstones never collide. The landmine is correctly stated and the mechanism is real.
- **`vanished_paths` cannot see a tombstone** — it reads `live_file_paths`, which is `present.where(kind: "file").where.not(storage_path: nil)` (`reconciler.rb:404`). A trash tombstone is excluded **twice over** (deleted *and* NULL path). Landmine 1's mechanism is real.
- **Both mutations were executed and both fail the right test:** skipping the tombstone raises `UnsafeScan` with `scan would tombstone 4/5 observable files (80.0% > 20%)`; retaining `storage_path` revives the trashed `node_id` onto the new file. **Neither test is decoration.**

```ruby
    def delete(user, node_id: nil)
      node = live_node!(user, node_id)
      src = absolute_path(node)
      dest_dir = trash_dir(node.node_id)
      FileUtils.mkdir_p(dest_dir)
      begin
        File.rename(src, dest_dir.join(node.name))
      rescue Errno::EXDEV => e
        # Landmine 3. Do NOT fall back to copy+delete: that invents a half-state (bytes in two
        # places, or in neither) for an operation the spec designed around an atomic rename.
        # Spec §6 reserves copy-then-tombstone for S3, which has no rename to lose. This is a
        # real configuration problem — a .trash symlinked elsewhere, a submount under the root —
        # and it is the operator's to fix, so say so and change nothing.
        raise FetchError, "#{node_id.inspect}: .trash is on a different filesystem (#{e.class}) " \
                          "— it must live under the library root"
      rescue SystemCallError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end

      # ORDER IS LOAD-BEARING, and it is the reverse of the intuitive one. Tombstone-then-move
      # leaves, if the move fails, a file the user cannot see and the next scan RESURRECTS (its
      # path is observed, so create_or_revive! finds the tombstone by storage_path and revives
      # it). Move-then-tombstone leaves, if the update fails, a file whose bytes are in .trash and
      # whose node is live at a path with nothing behind it — which reads as a vanished file and
      # is what the mass-deletion guard is for. The second failure is loud; the first is silent.
      #
      # deleted: true is LANDMINE 1 — vanished_paths reads the `present` scope, so a tombstoned
      # node is invisible to it and a UI delete can never trip the guard.
      # storage_path: nil is LANDMINE 2 — it releases the path so create_or_revive!'s
      # revive-by-path can never hand a NEW file this node's identity. See the tombstone table above.
      node.update!(deleted: true, storage_path: nil)
      nil
    end

    private

    # Derivable from the node alone — no column. Scanner::TRASH_PREFIX rather than a second
    # ".trash" literal: the Scanner's skip and this layout are the SAME fact, and two copies of it
    # is how the trash quietly starts getting indexed.
    def trash_dir(node_id) = @root.join(Library::Scanner::TRASH_PREFIX, node_id)
```

**On the transaction.** The first draft said the move and the tombstone go "in one transaction". They cannot, meaningfully, and pretending otherwise is worse than not trying: `File.rename` is not transactional, so a `transaction` block around both would roll back the *row* while leaving the *file* in `.trash` — manufacturing precisely the silent resurrection the comment above rejects. `node.update!` is a single statement and already atomic, which is the only atomicity this needs. The Reconciler's class header explains why *it* has no transaction (a 2TB hash must not pin one); `delete` has none for a different and simpler reason. **If you find yourself adding `transaction do` here, re-read this paragraph first.**

- [ ] **Step 4: Prove Landmines 1 and 2 can fail (mutation)**

Both were executed while writing this plan and both behave as claimed — reproduce them, do not take this on faith:

- Landmine 1: make `delete` skip the tombstone → the guard test must fail with `UnsafeScan` (`4/5 observable files (80.0% > 20%)`).
- Landmine 2: make the tombstone retain `storage_path` (`update!(deleted: true)` only) → the new-file test must fail by inheriting the node_id.

Byte-exact abort-if-unchanged guard, `grep -c` with expected counts, revert by file backup + `cmp`. **Report both.**

- [ ] **Step 5: Full suite + commit** — report ACTUAL counts.

---

### Task 4: `Share#move` and `#undelete`

**Files:**
- Modify: `app/services/file_layer/share.rb`
- Modify: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
    test "move renames on disk and keeps the node_id — the attachment survives" do
      id = index!("old.stl", bytes: "same")
      adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "new.stl")

      node = @user.nodes.find_by!(node_id: id)
      assert_equal "new.stl", node.storage_path
      assert_equal "same", File.binread(@root.join("new.stl"))
      assert_not File.exist?(@root.join("old.stl"))
      # The scan must agree rather than seeing a delete+create.
      Library::Scanner.call(@user, root: @root.to_s)
      assert_equal id, @user.nodes.find_by!(storage_path: "new.stl").node_id
    end

    test "move refuses to overwrite an existing file" do
      a = index!("a.stl", bytes: "aaa")
      index!("b.stl", bytes: "bbb")
      assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: a, new_parent_node_id: nil, new_name: "b.stl")
      end
      assert_equal "bbb", File.binread(@root.join("b.stl")), "the destination is untouched"
    end

    # Same correction as Task 2's: "../escaped.stl" contains a separator, so it is the LEAF check
    # that refuses it, not the escape guard — assert the message so this test names what it pins.
    test "move refuses a new_name that is not a leaf" do
      id = index!("a.stl", bytes: "aaa")
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "../escaped.stl")
      end
      assert_match(/leaf name/, err.message)
      assert File.exist?(@root.join("a.stl")), "a refused move must not move anything"
    end

    # And the escape guard on move's destination, reached the only way it can be — through a
    # poisoned parent, exactly as in Task 2.
    test "move into a parent whose storage_path escapes the root is refused" do
      id = index!("a.stl", bytes: "aaa")
      evil = @user.nodes.create!(node_id: SecureRandom.uuid, name: "evil", kind: "dir",
                                 storage_path: "../evil-#{SecureRandom.hex(4)}", mtime: 1)
      err = assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: evil.node_id, new_name: "a.stl")
      end
      assert_match(/escapes the library root/, err.message)
      assert File.exist?(@root.join("a.stl")), "the file stays put"
    end

    test "undelete moves the bytes back and revives the node with its node_id" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      adapter.undelete(@user, node_id: id)

      node = @user.nodes.find_by!(node_id: id)
      assert_not node.deleted
      assert_equal "bracket.stl", node.storage_path
      assert_equal "solid", File.binread(@root.join("bracket.stl"))
      assert_not File.exist?(@root.join(".trash/#{id}")), "the trash entry is consumed"
    end

    test "undelete refuses when something else now occupies the path" do
      id = index!("bracket.stl", bytes: "solid")
      adapter.delete(@user, node_id: id)
      File.binwrite(@root.join("bracket.stl"), "someone else's file")

      assert_raises(FileLayer::NotFound) { adapter.undelete(@user, node_id: id) }
      assert_equal "someone else's file", File.binread(@root.join("bracket.stl")),
                   "undelete must never clobber a live file"
      assert File.exist?(@root.join(".trash/#{id}/bracket.stl")), "the trashed bytes survive"
    end

    # A trash tombstone has a NULL storage_path (Landmine 2), so undelete must RECONSTRUCT the
    # destination from parent_node_id + name. Every test above deletes a root-level file, where
    # that reconstruction is indistinguishable from "just use the name" — so without this case the
    # parent leg is unpinned and a file deleted out of cad/ would be restored to the root.
    test "undelete restores into the original subdirectory, not the root" do
      FileUtils.mkdir_p(@root.join("cad"))
      Library::Scanner.call(@user, root: @root.to_s)
      parent = @user.nodes.find_by!(storage_path: "cad", kind: "dir")
      info = adapter.write(@user, parent_node_id: parent.node_id, name: "gear.stl", io: StringIO.new("gg"))

      adapter.delete(@user, node_id: info.node_id)
      adapter.undelete(@user, node_id: info.node_id)

      assert_equal "gg", File.binread(@root.join("cad/gear.stl"))
      assert_equal "cad/gear.stl", @user.nodes.find_by!(node_id: info.node_id).storage_path
    end
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**Verified:** both methods and all six tests were executed against the real code and observed green, including the subdirectory case.

```ruby
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      leaf!(new_name)
      node = live_node!(user, node_id)
      src = absolute_path(node)
      rel = join_rel(parent_dir_rel!(user, new_parent_node_id), new_name)
      dest = resolve_inside!(rel)
      # Refuse rather than replace. POSIX rename() would silently clobber, and the maker layer has
      # no undo for it: the displaced file's node would still point at a path now holding someone
      # else's bytes. (fs-provider's rename DOES replace — it is implementing POSIX for a kernel
      # mount. This is a UI operation, and refusing is the honest answer to a user's typo.)
      raise NotFound, "#{rel.inspect} already exists" if File.exist?(dest)

      FileUtils.mkdir_p(dest.dirname)
      begin
        File.rename(src, dest)
      rescue SystemCallError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end
      # The node_id does not change — that is the port's whole promise, and the write contract
      # (Task 5) pins it as a cross-backend rule.
      node.update!(storage_path: rel, name: new_name, parent_node_id: new_parent_node_id)
      stat(user, node_id: node.node_id)
    end

    def undelete(user, node_id: nil)
      # NOT live_node!: this operates on a tombstone by definition. `deleted: true` in the lookup
      # is what makes undeleting a live node a clean NotFound instead of a confusing rename.
      node = user.nodes.find_by(node_id:, deleted: true) ||
             raise(NotFound, "node #{node_id.inspect} is not in the trash")
      src = trash_dir(node.node_id).join(node.name)
      # The purge job (Task 6) may have taken the bytes, and a scan tombstone never had any in
      # .trash to begin with. Both are terminal and both are the user's answer: it is gone.
      raise NotFound, "#{node_id.inspect}: its trashed bytes are gone (purged?)" unless File.exist?(src)

      # Reconstructed from parent + name, because delete released storage_path (Landmine 2).
      # live: false — the parent directory may itself have been tombstoned by a scan once this
      # file left it (tombstone_vanished_dirs), and refusing to restore into it would strand the
      # file for a reason the user cannot see or fix.
      rel = join_rel(parent_dir_rel!(user, node.parent_node_id, live: false), node.name)
      dest = resolve_inside!(rel)
      raise NotFound, "#{rel.inspect} is occupied — undelete must not clobber" if File.exist?(dest)

      FileUtils.mkdir_p(dest.dirname)
      begin
        File.rename(src, dest)
      rescue SystemCallError => e
        raise FetchError, "#{node_id.inspect}: #{e.class} (#{e.message})"
      end
      # Best-effort: rmdir only succeeds when the entry dir is empty, which is the normal case and
      # the only one where removing it is right. A non-empty one is a surprise worth leaving for
      # the purge job rather than deleting on a guess.
      begin
        FileUtils.rmdir(trash_dir(node.node_id))
      rescue SystemCallError
        nil
      end
      # Re-stat: the bytes are the same, but mtime/size are what the next scan compares against,
      # and a stale pair would make it re-hash the file for nothing.
      st = File.stat(dest)
      node.update!(deleted: false, storage_path: rel, size: st.size, mtime: nanos(st))
      stat(user, node_id: node.node_id)
    end
```

- [ ] **Step 4: Full suite + commit** — report ACTUAL counts.

---

### Task 5: The writable-adapter contract

**Why it exists:** Phase 3's S3 adapter must not answer these differently. This is the same mechanism as the read contract, scoped to adapters that implement the write path.

**Files:**
- Create: `test/services/file_layer/adapter_write_contract.rb`
- Modify: `test/services/file_layer/share_test.rb`

- [ ] **Step 1: Write the contract**

Create `test/services/file_layer/adapter_write_contract.rb`:

```ruby
# The contract EVERY adapter implementing the port's WRITE path must satisfy. Separate from
# adapter_contract.rb (the read contract) on purpose: that one runs against every adapter,
# and Chunk does not implement this path — chunk-mode writes are Sync::Commit's two-phase
# flow, and forcing a server-side write here would duplicate it, have no caller, and reach
# into the sync engine the port exists to stay out of (spec §10).
#
# Include this into a writable adapter's test case. Share includes it now; S3 in Phase 3 —
# that is the point. The read contract's hooks (adapter, @user) are assumed; include this
# alongside it.
#
# One ADDITIONAL hook the including test case must define:
#   with_transient_write_failure { } -> make the WRITE transport fail temporarily and not the
#                                    file's fault (a PUT 5xx; a full or unmounted share), then
#                                    yield. Restore on the way out.
#                                    SEPARATE from the read contract's
#                                    with_transient_backend_failure on purpose: read and write
#                                    are different transports (Share: File.binread vs
#                                    File.binwrite; S3: GET vs PUT), and the read hook's test
#                                    ends by re-reading the file to prove the fault was
#                                    transient — one hook faulting both would stop that
#                                    assertion isolating the read path. Fault the TRANSPORT,
#                                    never the adapter's own error classification.
#
# These assert only what is BACKEND-AGNOSTIC. Share's `.trash/<node_id>/<name>` layout is NOT
# in here: S3 trashes by key prefix, and encoding one backend's storage layout in a shared
# contract is exactly the leak the port exists to prevent. Where the bytes go is Share's test.
module FileLayerWritableContract
  def test_write_contract_bytes_round_trip
    info = adapter.write(@user, parent_node_id: nil, name: "rt.stl", io: StringIO.new("payload"))
    assert_equal "payload", adapter.read(@user, node_id: info.node_id)
  end

  # The port's whole promise. A move that mints a new node_id breaks every project
  # attachment, BOM link and tag pointing at that file — on any backend.
  def test_write_contract_move_keeps_the_node_id
    info = adapter.write(@user, parent_node_id: nil, name: "before.stl", io: StringIO.new("same"))
    adapter.move(@user, node_id: info.node_id, new_parent_node_id: nil, new_name: "after.stl")

    assert_equal "same", adapter.read(@user, node_id: info.node_id),
                 "a move must keep node_id resolving to the same bytes"
    assert_equal "after.stl", adapter.stat(@user, node_id: info.node_id).name
  end

  # Tombstoned = gone is already pinned by the READ contract (§9a-1). This pins the other
  # half: delete gets you there, and it tombstones rather than destroying — the row is what
  # makes a project say "file missing" instead of the attachment vanishing.
  def test_write_contract_delete_tombstones_rather_than_destroying
    info = adapter.write(@user, parent_node_id: nil, name: "bye.stl", io: StringIO.new("gone"))
    adapter.delete(@user, node_id: info.node_id)

    assert @user.nodes.find_by!(node_id: info.node_id).deleted, "the row survives"
    assert_raises(FileLayer::NotFound) { adapter.read(@user, node_id: info.node_id) }
  end

  def test_write_contract_undelete_restores_the_same_node_and_bytes
    info = adapter.write(@user, parent_node_id: nil, name: "back.stl", io: StringIO.new("restored"))
    adapter.delete(@user, node_id: info.node_id)
    adapter.undelete(@user, node_id: info.node_id)

    assert_not @user.nodes.find_by!(node_id: info.node_id).deleted
    assert_equal "restored", adapter.read(@user, node_id: info.node_id)
  end

  # Terminal-vs-retryable, the port's most consequential distinction, applies to writes too:
  # a transient backend failure must NEVER read as "the file is gone".
  def test_write_contract_transient_failure_on_write_raises_fetch_error
    with_transient_backend_failure do
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "flaky.stl", io: StringIO.new("b"))
      end
    end
  end
end
```

#### The two open questions on this task — both now RESOLVED against the real code

**1. `undelete` beyond the spec's port list — KEEP IT. The argument checks out.**

Spec §3.2 lists only `write`/`delete`/`move` and says *"undelete is a move back"*. That is not implementable here, and the reason is mechanical rather than stylistic: `move`'s first act is `live_node!`, and a trash tombstone is not live; even if it were let through, `move` resolves its source via `absolute_path(node)`, which reads `node.storage_path` — **NULL on a trash tombstone (Landmine 2)** — so it would resolve to the library root and rename the whole library. The bytes are not at `storage_path` anyway; they are at `.trash/<node_id>/<name>`, which only a trash-aware verb knows how to find.

**Verified, not reasoned:** `reconciler.rb:330`'s revive is by `storage_path`, which is what forces the NULL in the first place; a query for a NULL-path tombstone by path returns `nil`. So the NULL is load-bearing, and "undelete is a move back" is precluded *by the fix for Landmine 2*. A distinct verb is the honest shape. **This is a deliberate divergence from the spec's port list — record it in Task 9's docs, don't let it be discovered later.**

**2. `with_transient_backend_failure` does NOT fault the write path — ADD A SECOND HOOK.**

**Checked by execution, not by reading:** the existing hook (`share_test.rb:44`) faults `File.binread`. Under it, `Share#write` **succeeds and returns a `FileInfo`** — the write transport is `File.binwrite`, which the hook never touches. The contract's last test would fail against a correct implementation.

**Decision: a second hook, `with_transient_write_failure`, not a widened one.** Widening the existing hook to fault both would silently weaken the *read* contract it was written for: `test_contract_transient_backend_failure_raises_fetch_error_not_not_found` ends by re-reading the file to prove the fault was transient, and a hook that also broke writes would make that assertion's meaning ambiguous — it would no longer be isolating the read path. The read contract's own header is explicit that the hook must "fault the TRANSPORT... never the adapter's own error classification"; **read and write are different transports** (`File.binread` vs `File.binwrite`), so they get different hooks. That also keeps Phase 3's S3 adapter honest: its read fault (a GET 5xx) and its write fault (a PUT 5xx) are genuinely different things, and a single hook would force it to pretend otherwise.

Add to `share_test.rb`, next to the existing hook:

```ruby
    # Share's transient WRITE failure. A separate hook from with_transient_backend_failure on
    # purpose: read and write are different transports (binread vs binwrite), and the read
    # contract's test ends by re-reading the file to prove the fault was transient — a hook that
    # broke both would make that assertion stop isolating the read path. S3 will do the same
    # (a GET 5xx and a PUT 5xx are not the same fault).
    def with_transient_write_failure
      original = File.method(:binwrite)
      File.define_singleton_method(:binwrite) { |*| raise Errno::EACCES, "simulated" }
      yield
    ensure
      File.define_singleton_method(:binwrite, original)
    end
```

and the contract's last test becomes:

```ruby
  # Terminal-vs-retryable, the port's most consequential distinction, applies to writes too:
  # a transient backend failure must NEVER read as "the file is gone".
  def test_write_contract_transient_failure_on_write_raises_fetch_error
    with_transient_write_failure do
      assert_raises(FileLayer::FetchError) do
        adapter.write(@user, parent_node_id: nil, name: "flaky.stl", io: StringIO.new("b"))
      end
    end
    # ...and it left no half-state: a node whose bytes never landed is a browse entry that 404s
    # forever. Verified: the implementation creates the row only after the rename returns.
    assert_nil @user.nodes.find_by(storage_path: "flaky.stl")
  end
```

Update the contract module's header to document `with_transient_write_failure` alongside the hooks it inherits from the read contract. **Verified:** faulting `File.binwrite` against the Task 2 implementation raises `FileLayer::FetchError` and leaves no node.

- [ ] **Step 2: Include it in `share_test.rb`; run.** It must pass **without changing `Share`** — if it doesn't, either the contract over-specifies or Share has a real defect. Report which. (Prototyped: all five contract tests pass against Tasks 2–4's implementations unmodified.)

- [ ] **Step 3: Prove it constrains** — mutate `Share#move` to not preserve `node_id`; the contract test must fail. Report.

- [ ] **Step 4: Full suite + commit.**

---

### Task 6: `Library::TrashPurgeJob` + `LIBRARY_TRASH_DAYS`

**Files:**
- Create: `app/jobs/library/trash_purge_job.rb`
- Create: `test/jobs/library/trash_purge_job_test.rb`
- Modify: `config/recurring.yml`

**Read `app/jobs/library/scan_job.rb` first and match it.** Its lessons, learned the hard way in 2a:
- The backend gate belongs on the **schedule** entry point (`purge_all!`), not on `perform` — a caller who names a user and a root deserves the operation, not a silent no-op. A no-op `perform` made 2a's plan's own tests fail.
- Gate on `FileLayer.current.is_a?(FileLayer::Share)`, not a third `ENV` reader. It also hands back a root the boot guard has already validated.
- `queue_as :background` (the neighbours), `discard_on ActiveRecord::RecordNotFound`.
- `root:` is **required**; pass `root.to_s` — **`Pathname` is not ActiveJob-serializable** and raises `SerializationError` at enqueue.
- `recurring.yml` nests under `production:` — it never runs in dev. Do not restructure.

- [ ] **Step 1: Write the failing tests**

```ruby
require "test_helper"

module Library
  class TrashPurgeJobTest < ActiveSupport::TestCase
    setup do
      @root = Pathname.new(Dir.mktmpdir("purge-test"))
      @user = User.create!(email: "purge-#{SecureRandom.hex(4)}@example.com")
    end
    teardown { FileUtils.remove_entry(@root) if @root&.exist? }

    # Build a trash entry as Share#delete would, then age it by backdating the ENTRY DIR's
    # mtime — that is what the job reads, so no column is needed to know when it was trashed.
    #
    # `.to_time` is REQUIRED, not tidiness: Time.current returns an ActiveSupport::TimeWithZone,
    # and File.utime raises `TypeError: can't convert ActiveSupport::TimeWithZone into time` on
    # one. (This plan's first draft omitted it and every test in this file errored. Found by
    # running it.)
    def trash!(node_id, name, bytes, age_days:)
      dir = @root.join(".trash", node_id)
      FileUtils.mkdir_p(dir)
      File.binwrite(dir.join(name), bytes)
      at = (Time.current - age_days.days).to_time
      File.utime(at, at, dir)
      # The fixture must actually age: a backdate that silently no-ops would leave every test
      # below asserting nothing. (mtime granularity and tmpfs both bite here.)
      assert_in_delta at.to_i, File.mtime(dir).to_i, 2, "precondition: the entry must be aged"
      dir
    end

    test "purges entries older than LIBRARY_TRASH_DAYS and leaves fresh ones" do
      old   = trash!(SecureRandom.uuid, "old.stl",   "gone",  age_days: 45)
      fresh = trash!(SecureRandom.uuid, "fresh.stl", "still", age_days: 3)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      assert_not old.exist?,  "an entry past the window is purged"
      assert fresh.exist?,    "an entry inside the window survives"
      assert_equal "still", File.binread(fresh.join("fresh.stl"))
    end

    # 0 is the documented "keep forever" (spec §3.5). A 0 that purged everything immediately
    # would be a data-loss bug wearing a config knob — and `0.days.ago` is `now`, so the
    # obvious implementation does exactly that.
    test "LIBRARY_TRASH_DAYS=0 means never purge, not purge everything" do
      ancient = trash!(SecureRandom.uuid, "a.stl", "keep", age_days: 9999)
      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 0)
      assert ancient.exist?, "0 must mean NEVER purge"
    end

    test "purging the bytes leaves the node tombstoned, and undelete then fails cleanly" do
      id = SecureRandom.uuid
      @user.nodes.create!(node_id: id, name: "p.stl", kind: "file", deleted: true,
                          storage_path: nil, mtime: 1_700_000_000_000_000_000)
      trash!(id, "p.stl", "bytes", age_days: 45)

      Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30)

      node = @user.nodes.find_by!(node_id: id)
      assert node.deleted, "the row is the record that the file existed — never destroy it"
      # The bytes are gone; undelete must say so rather than 500.
      assert_raises(FileLayer::NotFound) do
        FileLayer::Share.new(root: @root.to_s).undelete(@user, node_id: id)
      end
    end

    test "a missing trash directory is a no-op, not an error" do
      assert_nothing_raised { Library::TrashPurgeJob.perform_now(root: @root.to_s, trash_days: 30) }
    end

    # The NEGATIVE half of the schedule's gate, matching ScanJobTest's pair exactly (read them:
    # test/jobs/library/scan_job_test.rb:113 and :123). On its own this passes for a
    # `def purge_all!; end`, which is why the positive half below is not optional.
    test "purge_all! no-ops when the deployment is not share-backed" do
      with_env("LIBRARY_BACKEND" => "chunk") do
        assert_no_enqueued_jobs { Library::TrashPurgeJob.purge_all! }
      end
    end

    # The POSITIVE half: proves the no-op above is the gate working, not the method doing nothing.
    # Also pins the root as the ADAPTER's (validated by LibraryBackendCheck) and as a String —
    # Pathname is not an ActiveJob-serializable argument and raises SerializationError at enqueue.
    #
    # Unlike ScanJob this does NOT fan out per user: .trash is one directory under one root, and
    # its entries are keyed by node_id, so one job purges the whole thing. (A share deployment is
    # single-user in practice anyway — but the reason this is one job and ScanJob is N is the
    # filesystem's shape, not the user count.)
    test "purge_all! enqueues one job with the adapter's root" do
      Dir.mktmpdir do |dir|
        with_env("LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => dir) do
          assert_enqueued_with(job: Library::TrashPurgeJob,
                               # expand_path, matching Share#root — NOT realpath, which would
                               # resolve macOS's /var -> /private/var symlink and diverge.
                               args: [ { root: File.expand_path(dir), trash_days: 30 } ]) do
            Library::TrashPurgeJob.purge_all!
          end
        end
      end
    end

    private

    # Mirrors ScanJobTest's helper. FileLayer is reset so the memoized adapter cannot leak the
    # previous test's backend into this one.
    def with_env(vars)
      prior = vars.keys.index_with { |k| ENV[k] }
      vars.each { |k, v| ENV[k] = v }
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end
  end
end
```

The test case needs `include ActiveJob::TestHelper` and `setup { FileLayer.reset! }` / `teardown { FileLayer.reset! }`, exactly as `ScanJobTest` does — `assert_no_enqueued_jobs`/`assert_enqueued_with` come from the former, and without the resets the memoized `FileLayer.current` leaks a backend between tests.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**Verified:** the age arithmetic, the `trash_days: 0` case, the mutation, and the missing-`.trash` case were all executed standalone. **`Dir.children` on a missing `.trash` raises `Errno::ENOENT`** — the no-op test pins that, so it must be guarded or rescued.

```ruby
module Library
  # Purge trash entries past the retention window. Share#delete renames a file to
  # .trash/<node_id>/<name> rather than unlinking it, so this is what actually reclaims the space
  # — without it a share library grows forever and the "delete" the user performed never lands.
  #
  # The ENTRY DIRECTORY's mtime is when it was trashed: mkdir_p stamps it at delete time, and
  # nothing touches it afterwards. That is why no `trashed_at` column exists — the filesystem
  # already records it, and a column would be a second copy to keep in sync (spec decision 3:
  # share libraries are current-state only; the disk is the truth).
  #
  # The node row is NEVER destroyed, only its bytes. The row is what makes a project say "file
  # missing" instead of an attachment silently vanishing, and it costs a few hundred bytes.
  class TrashPurgeJob < ApplicationJob
    queue_as :background
    discard_on ActiveRecord::RecordNotFound

    DEFAULT_TRASH_DAYS = 30

    # Same division as ScanJob's, for the same reason: purge_all! is a SCHEDULE (recurring.yml
    # fires it in chunk deployments too, where no-opping is the answer to a question nobody
    # asked); #perform is a COMMAND, and a caller who named a root deserves the operation.
    def perform(root:, trash_days: nil)
      days = trash_days || Integer(ENV.fetch("LIBRARY_TRASH_DAYS", DEFAULT_TRASH_DAYS.to_s))
      # 0 (or negative) is the documented "keep forever" (spec §3.5). This guard is the whole
      # test: `Time.now - 0*86400` is NOW, so the obvious implementation purges the ENTIRE trash
      # on a config value that means the opposite — a data-loss bug wearing a config knob.
      return if days <= 0

      trash = Pathname.new(root).join(Library::Scanner::TRASH_PREFIX)
      # No trash yet (nothing ever deleted) is the normal state of a fresh library, not an error.
      # Dir.children raises ENOENT on a missing directory, so this guard is load-bearing.
      return unless trash.directory?

      cutoff = Time.now - days * 86_400
      Dir.children(trash.to_s).each do |entry|
        dir = trash.join(entry)
        begin
          # `<` cutoff: OLDER than the window. Inverting this purges everything EXCEPT what should
          # go — the mutation Step 4 requires you to run.
          next unless dir.directory? && dir.mtime < cutoff
          FileUtils.remove_entry(dir)
        rescue SystemCallError => e
          # One unreadable entry must not abort the sweep, and must never be retried into a
          # failure: the next run picks it up. Same posture as the Scanner's per-entry rescues.
          Rails.logger.warn("Library::TrashPurgeJob: cannot purge #{entry.inspect}: " \
                            "#{e.class} (#{e.message})")
        end
      end
    end

    # PHASE 3 TRAP, the same one ScanJob.scan_all! carries (read the comment there): the moment
    # FileLayer::S3 exists this is_a? quietly answers false and the purge SILENTLY STOPS. S3's
    # trash is a key prefix, not a directory — it needs its own reaper. Decide here deliberately
    # rather than inherit this false.
    def self.purge_all!
      adapter = FileLayer.current
      return unless adapter.is_a?(FileLayer::Share)

      # .to_s: Pathname is not an ActiveJob-serializable argument.
      perform_later(root: adapter.root.to_s,
                    trash_days: Integer(ENV.fetch("LIBRARY_TRASH_DAYS", DEFAULT_TRASH_DAYS.to_s)))
    end
  end
end
```

`recurring.yml`, under `production:` (do not restructure it — it never runs in dev, and that is deliberate), placed next to `library_scan`. `command:` rather than `class:`, matching `library_scan`, because the gate lives in a class method rather than in `perform`:

```yaml
  # Reclaim space from FileLayer::Share#delete, which renames into .trash/<node_id>/<name> rather
  # than unlinking — so without this a share library grows forever and the user's delete never
  # actually lands. LIBRARY_TRASH_DAYS (default 30) is the undo window; 0 means keep forever.
  # No-ops unless LIBRARY_BACKEND=share, so it is inert in a chunk deployment. Daily and off-peak:
  # the window is measured in days, so nothing is gained by sweeping more often.
  library_trash_purge:
    command: "Library::TrashPurgeJob.purge_all!"
    schedule: every day at 3am
```

- [ ] **Step 4: Green, then mutate.** Flip the age comparison (`<` → `>`); the "purges entries older than LIBRARY_TRASH_DAYS and leaves fresh ones" test must die on **both** assertions (`old` survives, `fresh` is purged). Then delete the `days <= 0` guard; the "0 means never purge" test must die. Byte-exact abort-if-unchanged guard, `grep -c` with expected counts, revert by file backup + `cmp`. **Report both.**

- [ ] **Step 5: Commit.**

---

### Task 7: The boot guard's writability check

**Files:**
- Modify: `lib/library_backend_check.rb`
- Modify: `test/lib/library_backend_check_test.rb`

2a deliberately left this out (read-only phase) and left a TODO. **Read the file first** — its header explicitly documents *what it does not catch*, and that comment is load-bearing and must stay true.

- [ ] **Step 1: Write the failing tests**

```ruby
  test "share mode refuses to boot on a read-only root" do
    skip "root bypasses permission bits" if Process.uid.zero?
    Dir.mktmpdir do |d|
      File.chmod(0o500, d)
      begin
        err = assert_raises(LibraryBackendCheck::Error) do
          LibraryBackendCheck.check!(backend: "share", path: d)
        end
        assert_match(/writ/i, err.message)
      ensure
        File.chmod(0o755, d)
      end
    end
  end

  # The probe WRITES into a directory we do not own. It must leave nothing behind — a leaked
  # dotfile is not cosmetic here: Share#library_present? uses "the root is empty" as its
  # unmounted signal (and its header already names a stale .DS_Store as the known way that
  # fails), so a leaked probe file makes an unmounted share read as mounted and turns every
  # FetchError into a terminal NotFound. Verified: a stale dotfile does exactly that.
  test "the writability probe leaves nothing behind" do
    Dir.mktmpdir do |d|
      LibraryBackendCheck.check!(backend: "share", path: d)
      assert_equal [], Dir.children(d), "the probe must clean up after itself"
    end
  end

  # Chunk mode must not touch the filesystem at all — the guard returns before any probe.
  test "chunk mode writes no probe" do
    Dir.mktmpdir do |d|
      LibraryBackendCheck.check!(backend: "chunk", path: d)
      assert_equal [], Dir.children(d)
    end
  end
```

**Skip under root** (`Process.uid.zero?`) rather than ship a test that silently passes for the wrong reason — CI containers run as root. Precedent: `share_test.rb:143` (`skip "root bypasses permission bits" if Process.uid.zero?`). The two non-chmod tests above hold under root and carry what they can.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

**`File.writable?` is not sufficient and must not be the implementation** — it checks POSIX mode bits, not effective access, and is wrong under exactly the NFS/SMB ACLs this backend targets. A **real touch-probe** is the mechanism. **Verified:** on a `0500` directory the probe raises `EACCES` and reports unwritable; on a healthy one it leaves `Dir.children == []`.

Extend `check!` (after the existing `readable?` check) and add:

```ruby
    raise Error, "LIBRARY_PATH #{path.inspect} is not readable" unless File.readable?(path)
    writable!(path)
  end

  # A REAL write, not File.writable?. File.writable? tests POSIX mode bits against the process
  # uid/gid — it does not consult NFSv4/SMB ACLs, an SMB share's read-only export flag, or a
  # remount-ro, and every one of those is a live possibility for the mounted directory this
  # backend exists to serve. On those it cheerfully answers true for a root we cannot write, and
  # the operator learns the truth from a failed upload instead of a refused boot. The only honest
  # question is "can we create a file here?", so ask it.
  #
  # A DOTFILE with a random suffix: the Scanner walks this root every 15 minutes and only skips
  # `.trash` by name, so a probe that lingers could be indexed as a library file; the random
  # suffix means two boots (or a boot racing a purge) cannot collide on the name.
  def self.writable!(path)
    probe = File.join(path, ".maker-write-probe-#{Process.pid}-#{SecureRandom.hex(4)}")
    begin
      File.binwrite(probe, "")
    rescue SystemCallError => e
      raise Error, "LIBRARY_PATH #{path.inspect} is not writable (#{e.class}: #{e.message}) — " \
                   "phase 2b writes uploads and moves deletes into .trash/, so a read-only " \
                   "share cannot back a library. Check the mount options and the export's " \
                   "permissions for the user this process runs as."
    ensure
      # MUST NOT leak. Share#library_present? reads "the root is empty" as "unmounted", so a
      # stale probe dotfile would make an unmounted share look mounted and flip every transient
      # ENOENT to a terminal NotFound — burning every preview in the library. Its header already
      # names a stale .DS_Store as this exact failure; do not add a second source of it.
      begin
        File.unlink(probe)
      rescue SystemCallError
        nil
      end
    end
  end
```

`SecureRandom` is available here — this file is `require`d from an initializer that runs after Rails has loaded, and `FileLayer.build` calls `check!` at runtime. **Verified** (`defined?(SecureRandom) == "constant"` in the boot process).

**Known limitation — write it into the file's header comment, which already documents what this guard does not catch, and which §15 says must stay true.** The `ensure` covers every ordinary failure, but a `SIGKILL` between `binwrite` and `unlink` leaks a probe dotfile into the root, and `Share#library_present?` will then read an unmounted share as mounted until someone removes it. This is the same known hole the Share header already names for a stale `.DS_Store`, not a new class of one — and the alternative (probing nothing) trades a rare, self-inflicted false-mounted for a routine, silent read-only library. Stated so it is a documented trade rather than a discovery.

**The reach beyond this task's file list, which is deliberate and small:** `FileLayer.build` calls `check!` (`app/services/file_layer.rb`), so every `LIBRARY_BACKEND=share` adapter construction now touch-probes its root. That is correct — the factory's comment says it calls `check!` precisely so the operator gets the same explanation whether or not the boot guard ran — and it is why the CI leg (`LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`) exercises the probe for free. **If that leg goes red on a `Dir.children` assertion somewhere, this is why.**

- [ ] **Step 4: Green, then mutate.** Delete the `writable!(path)` call; the read-only test must die. Then replace the touch-probe body with `raise Error unless File.writable?(path)` — **it stays green**, which is the honest statement of what this test can and cannot pin: a unit test on a tmpdir cannot tell the two apart, because only an ACL-bearing filesystem can. Report both, and report that the second mutation survives — the reason for the touch-probe is the deployment target, not the test.
- [ ] **Step 5: Commit.**

---

### Task 8: The E2E — the write path, end to end

**Files:**
- Modify: `test/integration/library/share_library_test.rb`

- [ ] **Step 1: Write it**

Through the real stack — real tmpdir, real scan, real adapter:

```ruby
    test "upload, attach, delete to trash, undelete — the attachment survives all of it" do
      info = @adapter.write(@user, parent_node_id: nil, name: "bracket.stl",
                            io: StringIO.new("solid bracket"))
      project = @user.maker_projects.create!(name: "Printer mods")
      attachment = project.file_attachments.create!(user: @user, node_id: info.node_id, role: "model")

      # Deleted: the attachment still NAMES the node — a project shows "file missing" rather
      # than an attachment silently vanishing — but the bytes are no longer readable.
      @adapter.delete(@user, node_id: info.node_id)
      assert_equal info.node_id, attachment.reload.node_id
      assert @user.nodes.find_by!(node_id: info.node_id).deleted
      assert_raises(FileLayer::NotFound) { @adapter.read(@user, node_id: attachment.node_id) }

      # Undeleted: the same node_id resolves to the same bytes. The attachment was never touched.
      @adapter.undelete(@user, node_id: info.node_id)
      assert_equal info.node_id, attachment.reload.node_id
      assert_equal "solid bracket", @adapter.read(@user, node_id: attachment.node_id),
                   "the attachment must resolve to the bytes again after an undelete"
    end

    test "a trash-deleted file stays deleted across a scan, and the trash is never indexed" do
      info = @adapter.write(@user, parent_node_id: nil, name: "gone.stl", io: StringIO.new("bye"))
      @adapter.delete(@user, node_id: info.node_id)

      scan!
      scan! # twice: a resurrection bug often needs a second pass to show

      assert @user.nodes.find_by!(node_id: info.node_id).deleted,
             "the scan must not resurrect a trashed file (the pull_snapshot ghost class, spec §6)"
      assert_equal 0, @user.nodes.present.where(kind: "file").count
      assert_equal 0, @user.nodes.where("storage_path LIKE '.trash%'").count
    end

    test "deleting most of the library through the port does not refuse the next scan" do
      ids = 5.times.map do |i|
        @adapter.write(@user, parent_node_id: nil, name: "f#{i}.stl", io: StringIO.new("x#{i}")).node_id
      end
      ids.first(4).each { |id| @adapter.delete(@user, node_id: id) } # 80% >> the 20% threshold

      assert_nothing_raised { scan! }
      assert_equal 1, @user.nodes.present.where(kind: "file").count
    end
```

`@adapter` and `scan!` are already defined in this file's `setup` (2a) — `@adapter = FileLayer::Share.new(root: @root.to_s)` at `share_library_test.rb:20`, `def scan! = Library::Scanner.call(@user, root: @root.to_s)` at `:28`. **Do not pass `max_delete_pct:` to `scan!`** — this file deliberately runs against the deployment's real threshold, because "a UI delete is not a mass deletion" is the third test's whole point, and an override would disable the mechanism under test.

**The maker API is verified by execution, not by reading the association:** `User.reflect_on_association(:maker_projects).class_name == "Maker::Project"`; `Maker::Project.reflect_on_association(:file_attachments)` is a `has_many` of `Maker::FileAttachment` with `as: :attachable`; `Maker::FileAttachment` has columns `user_id`, `node_id`, `role`, `position`, `version_id`. `project.file_attachments.create!(user:, node_id:, role: "model")` was executed and succeeded. (A grep would have been the wrong tool here — the `as: :attachable` sits on a continuation line and a single-line grep misses it. That exact false negative already bit this plan's author once.)

- [ ] **Step 2: Green.**
- [ ] **Step 3: Prove it can fail** — disable the tombstone in `delete`; the E2E must die. Report. (Expected: the third test dies with `UnsafeScan`, `4/5 observable files (80.0% > 20%)` — the same mutation as Task 3's Landmine 1, now at the integration layer.)
- [ ] **Step 4: Both suites + commit** — `bin/rails test` AND `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`, both green, **identical counts**. Report both.

---

### Task 9: Docs

**Files:**
- Modify: `CLAUDE.md`, `docs/STATUS.md`

CLAUDE.md §15 requires it when the architecture moves. 2a's entries say the Share adapter is **read-only** and that 2b is next; both become false. **The specific now-false strings to grep for** (verified present at `63a330c`): in CLAUDE.md's §3 component table, `**`Share`** (a mounted SMB/NFS dir — read-only, **current-state only**...)`; and in §12 step 10, `Phase 2b = the write path + trash`. `docs/STATUS.md` carries the same 2a framing.

Record:
- the write path is **Share-only**, and why (chunk-mode writes are the sync engine's `Sync::Commit`; the port refuses them by name)
- the trash layout `.trash/<node_id>/<name>`, **keyed by node_id** — and that this is why two same-named deletes don't collide
- **the two tombstone kinds** (Landmine 2: scan tombstone keeps `storage_path` and is revivable by the scan; trash tombstone NULLs it and is revivable only by `undelete`). This is the thing a future reader will otherwise "simplify" away, and the simplification silently hands a new file an old file's attachments.
- **`undelete` is a fourth port verb, diverging from spec §3.2's three** — and why the spec's "undelete is a move back" is precluded by the Landmine 2 fix. Record it here or it gets rediscovered as an inconsistency.
- `LIBRARY_TRASH_DAYS` (default 30; **0 means keep forever**, not purge everything)
- the boot guard now **touch-probes** for writability, and why `File.writable?` is not the check

- [ ] **Step 1:** update both, grep for now-false claims, commit.

---

## Definition of done

- [ ] `bin/rails test` green; report the count and the delta from **636** (Task 1 has landed at `63a330c`: 635 + 1, verified)
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` green, **identical count** (note: this leg now exercises Task 7's touch-probe, via `FileLayer.build` → `check!`)
- [ ] `FileLayer::Share` passes **both** contracts — read and writable — unmodified
- [ ] `FileLayer::Chunk` refuses `write`/`delete`/`move`, naming `Sync::Commit`
- [ ] Point it at a real folder: write a file, delete it, confirm it is in `.trash/<node_id>/<name>`, undelete it, confirm the bytes come back
- [ ] Mutation results reported for: Landmine 1 (guard), Landmine 2 (revive), Task 2's **two** mtime mutations (wrong unit AND wrong source), the write contract, the purge age comparison + the `days <= 0` guard, and Task 7's **two** (the check removed; `File.writable?` substituted — the second is expected to SURVIVE, and reporting that is the point)
- [ ] `Dir.children(root)` is empty after a boot check — no leaked write probe
- [ ] No sync/changelog/conflict/lock/mount edits (spec §10); no controller wiring (Phase 4)

## Next

**Phase 3:** the S3 adapter — it includes the writable contract from Task 5; trash is copy+delete, and it must **tombstone only after the copy confirms** (spec §6). **Phase 4:** capability gating + 501s in the web UI, and `download`/`Delivery`.

**Carried from 2a, unresolved, and now more urgent** — the write path gives a share library a way to grow: `Library::Reconciler` loads every live node into memory (~1M AR objects on a large NAS), and `best_pairing` is O(n²) (~2s per 10k renames). Both are commented in-code. **Fix before pointing this at a real 2TB NAS.**
