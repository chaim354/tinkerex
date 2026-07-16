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

**Non-negotiable:** every commit leaves `bin/rails test` green. Baseline **635 runs, 1814 assertions, 0 failures, 0 errors, 5 skips**, and `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` must stay **identical** — the suite is backend-independent and must remain so.

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

### Why this plan gives you tests but not implementations

A deliberate departure from 2a's format, and from the plan-writing default of "show the code in every step." The evidence: **2a's plan supplied a full implementation for every task, and every one of them was wrong** — a dead `- unmatched_obs.map { nil }.compact`, a `FileLayer.current.root` that simply crashes (`Chunk` has no `root`), an errno whitelist that failed open, a guard whose design refused the phase's own headline test, and two that would have shipped silent data loss. The implementers' best work came from treating those snippets as suspect and deriving against the real code; their worst came from transcribing faithfully.

Meanwhile 2a's plan-supplied **tests** were mostly right, and where one was wrong (an EDIT fixture that contradicted the incremental-skip requirement) the contradiction was *findable* precisely because it was written down.

So: the tests here are complete and are the specification — read them as the definition of done. The implementations are given as **constraints and seams**, and you derive the code against the files as they actually are. If a constraint here turns out to be wrong, **that is the expected outcome — report it.**

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

    # A leaf name is a leaf. A separator in it is either a caller bug or a traversal attempt,
    # and the escape guard below only catches the latter.
    test "write rejects a separator in the leaf name" do
      assert_raises(FileLayer::NotFound) do
        adapter.write(@user, parent_node_id: nil, name: "cad/gear.stl", io: StringIO.new("g"))
      end
    end

    test "write refuses a name that escapes the root" do
      [ "../outside.stl", "/etc/passwd", "a/../../outside.stl" ].each do |bad|
        assert_raises(FileLayer::NotFound) do
          adapter.write(@user, parent_node_id: nil, name: bad, io: StringIO.new("x"))
        end
        assert_not File.exist?("/etc/passwd.tmp"), "nothing may be written outside the root"
      end
    end

    test "write refuses bytes over MAX_BYTES rather than filling the NAS" do
      skip "MAX_BYTES is 256MB; allocating it is wasteful" # see Step 3's note
    end
```

Delete the `MAX_BYTES` skip if you can pin it cheaply (a stubbed `MAX_BYTES`, not a 256MB allocation); otherwise drop the test rather than ship a permanent skip that reads as coverage.

- [ ] **Step 2: Run to see them fail** — `NoMethodError: undefined method 'write'`.

- [ ] **Step 3: Implement**

In `share.rb`. Key constraints, each of which a test above pins:
- Resolve the destination through the **same escape guard** `read` uses (`absolute_path`-shaped). The audit that preceded this work found exactly this bug class.
- Write to a temp file in the destination directory and `File.rename` into place, so a reader never sees a half-written file (the scan may run concurrently).
- Index the node **in the same transaction**, with the real post-write `stat` — hash, size, and **nanosecond** mtime. Do not compute mtime as `Time.now`: the contract pins the unit, and the file's own stat is the truth the next scan will compare against.
- Return `FileInfo`.

- [ ] **Step 4: Green, then prove the scan-agreement test can fail**

Mutate: make `write` record `mtime: Time.now.to_i` (seconds, the bug that shipped twice in the mount adapters). The nanos assertion must fail. Byte-exact abort-if-unchanged guard; `grep -c` with an expected count. Revert via file backup + `cmp`. **Report the result.**

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

Constraints each test above pins:
- `.trash/<node_id>/<name>`, `mkdir_p` the node_id dir.
- `File.rename` — atomic within a filesystem. **`Errno::EXDEV` → `FetchError`** (transient-shaped: the operator can fix the mount), and **must not tombstone**. Order matters: **move first, tombstone only if the move succeeded.** A tombstone with the bytes still in place is a file the user can't see but the scan will resurrect; a move with no tombstone is Landmine 1.
- The tombstone sets `deleted: true` **and `storage_path: nil`** (Landmine 2), in one transaction.
- Note the Reconciler deliberately runs **without** a transaction (a multi-hour hash of a 2TB tree must not pin one). `delete` is a single small operation — a transaction here is correct and does not contradict that.

- [ ] **Step 4: Prove Landmines 1 and 2 can fail (mutation)**

- Landmine 1: make `delete` skip the tombstone → the guard test must fail with `UnsafeScan`.
- Landmine 2: make the tombstone retain `storage_path` → the new-file test must fail by inheriting the node_id.

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

    test "move refuses a destination that escapes the root" do
      id = index!("a.stl", bytes: "aaa")
      assert_raises(FileLayer::NotFound) do
        adapter.move(@user, node_id: id, new_parent_node_id: nil, new_name: "../escaped.stl")
      end
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
```

- [ ] **Step 2: Run to see them fail.**
- [ ] **Step 3: Implement.** `undelete` restores to `node.name` at the node's original parent; it must refuse rather than clobber (the last test). Reviving sets `deleted: false` and restores `storage_path`.
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

**`undelete` is an addition beyond the spec's port list** (§3.2 lists `write`/`delete`/`move` and says only *"undelete is a move back"*). A trash tombstone has a NULL `storage_path` (Landmine 2), so `move` cannot address it — a distinct verb is the honest shape. Flagged so it is a decision, not a smuggled API. If you disagree, argue it before implementing.

**`with_transient_backend_failure`** already exists in `share_test.rb` (it faults `File.binread`). The last test above needs it to fault the **write** transport too — check whether it does, and if not, decide: widen that hook, or add a second one. Report which and why.

- [ ] **Step 2: Include it in `share_test.rb`; run.** It must pass **without changing `Share`** — if it doesn't, either the contract over-specifies or Share has a real defect. Report which.

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
    def trash!(node_id, name, bytes, age_days:)
      dir = @root.join(".trash", node_id)
      FileUtils.mkdir_p(dir)
      File.binwrite(dir.join(name), bytes)
      at = Time.current - age_days.days
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

    test "purge_all! no-ops unless the backend is share" do
      # Same shape as ScanJob's gate test — read it and match. The gate asks FileLayer.current,
      # not a third ENV reader.
    end
  end
end
```

The last test is a stub on purpose: **read `test/jobs/library/scan_job_test.rb`'s equivalent and match its idiom** rather than inventing a second one. Write it out fully before implementing.

- [ ] **Step 2-4:** run → implement → green. Mutate the age comparison (`>` → `<`) and confirm a test dies. Report.
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
```

**`File.writable?` is not sufficient and must not be the implementation** — it checks POSIX mode bits, not effective access, and is wrong under NFS/SMB ACLs, which is exactly the deployment this phase targets. Do a **real** write: create and remove a temp entry in the root, and map the failure. Note the boot guard runs at boot in a directory we do not own — the probe must clean up after itself, and must not disturb a library.

**Skip under root** (`Process.uid.zero?`) rather than ship a test that silently passes for the wrong reason — CI containers run as root. 2a's precedent: `share_test.rb`'s chmod tests skip honestly, and the non-chmod cases carry the rule when they do.

- [ ] **Step 2-4:** run → implement → green. Mutate the check away; the test must die. Report.
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

`@adapter` and `scan!` are already defined in this file's `setup` (2a). The maker API is verified: `@user.maker_projects`, and `Project` declares `has_many :file_attachments, -> { order(:position) }, as: :attachable`, so `create!(user:, node_id:, role: "model")` is valid.

- [ ] **Step 2: Green.**
- [ ] **Step 3: Prove it can fail** — disable the tombstone in `delete`; the E2E must die. Report.
- [ ] **Step 4: Both suites + commit** — `bin/rails test` AND `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test`, both green, **identical counts**. Report both.

---

### Task 9: Docs

**Files:**
- Modify: `CLAUDE.md`, `docs/STATUS.md`

CLAUDE.md §15 requires it when the architecture moves. 2a's entries say the Share adapter is **read-only** and that 2b is next; both become false. Record: the write path is Share-only and why (chunk writes are the sync engine's); the trash layout and that it is keyed by `node_id`; the two tombstone kinds (Landmine 2) — that distinction is the thing a future reader will otherwise "simplify" away; `LIBRARY_TRASH_DAYS`.

- [ ] **Step 1:** update both, grep for now-false claims, commit.

---

## Definition of done

- [ ] `bin/rails test` green; report the count and the delta from 635
- [ ] `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test` green, **identical count**
- [ ] `FileLayer::Share` passes **both** contracts — read and writable — unmodified
- [ ] `FileLayer::Chunk` refuses `write`/`delete`/`move`, naming `Sync::Commit`
- [ ] Point it at a real folder: write a file, delete it, confirm it is in `.trash/<node_id>/<name>`, undelete it, confirm the bytes come back
- [ ] Mutation results reported for: Landmine 1 (guard), Landmine 2 (revive), the write contract, and the purge age comparison
- [ ] No sync/changelog/conflict/lock/mount edits (spec §10); no controller wiring (Phase 4)

## Next

**Phase 3:** the S3 adapter — it includes the writable contract from Task 5; trash is copy+delete, and it must **tombstone only after the copy confirms** (spec §6). **Phase 4:** capability gating + 501s in the web UI, and `download`/`Delivery`.

**Carried from 2a, unresolved, and now more urgent** — the write path gives a share library a way to grow: `Library::Reconciler` loads every live node into memory (~1M AR objects on a large NAS), and `best_pairing` is O(n²) (~2s per 10k renames). Both are commented in-code. **Fix before pointing this at a real 2TB NAS.**
