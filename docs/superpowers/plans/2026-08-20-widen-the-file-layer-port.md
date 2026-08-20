# Widen the FileLayer Port (Stage 2) Implementation Plan

> ## ✅ DONE — merged to `main` as `8cbe21d` (PR #200), 2026-08-20.
> **Do not execute this plan.** Every task below is complete and every box is ticked. It is kept as
> the record of what was intended versus what was actually built, because the two diverged in ways
> worth reading before planning Stage 1, 3 or 4:
>
> - Task 2 was written as "create a mutation contract"; the four tests already existed inside
>   `FileLayerWritableContract`, so it became an **extraction**. The plan's module names were
>   invented and wrong.
> - Task 8's `Sync::Commit.begin` signature was **guessed and wrong**. The real one is in
>   `chunk_test.rb`'s `create_file!`.
> - The broadcast assertions in Tasks 4–6 were **vacuous as first written** — `head_seq` advances
>   whether or not anything broadcasts. Caught only by the mandated mutation check.
> - The plan cited **CLAUDE.md §12 item 11** for chunk's duplicate-sibling gap. The right citation
>   is **§14c**. The error propagated into three code comments before it was caught.
>
> The lesson those four share is the one CLAUDE.md §14e already states: **a plan written from
> reading is a hypothesis.** Every task here that survived contact unchanged was one where the
> implementer was told to read the real call sites first.
>
> **What comes next is NOT in this file.** The four-stage design is
> `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md`; Stages 1, 3 and 4 have **no
> implementation plan yet**, and Stage 3 needs its own design pass first — the close-out review
> found `share_links` straddles the split in a way that design's own table gets wrong.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the six maker→sync call sites go through `FileLayer` instead of reaching around it into `Sync::*`, so the chunk backend can later be moved behind an HTTP boundary without touching a single maker-layer caller.

**Architecture:** Bytes and metadata are different problems. The four **metadata** verbs (`delete`, `move`, `mkdir`, `undelete`) stop raising on `FileLayer::Chunk` and start delegating to the sync engine — no bytes, so CLAUDE.md §15 does not bind. The **byte** path does not grow a byte-taking `write` on chunk; it grows the presigned two-phase pair `begin_upload`/`finalize_upload`, so bytes still never flow through Rails. Four of §14d's five `port_writable?` branch copies collapse as a direct consequence.

**Tech Stack:** Rails 8, Minitest, SQLite (test), `bin/ci` (8 gates).

**Spec:** `docs/superpowers/specs/2026-08-20-chunk-repo-separation-design.md` §4.

---

## Context an implementer needs before Task 1

**Read these first.** They are short and every one of them will stop you making a mistake this plan cannot spell out:

- `app/services/file_layer/capabilities.rb` — the whole file is an argument about what each capability means. `port_writable?` is **not** "accepts uploads".
- `app/services/file_layer/chunk.rb:9-29` — the four refusal constants you are deleting, and why they were four and not one.
- CLAUDE.md §14a — the FileLayer port invariants. This plan deliberately reopens part of it; §4.4 of the spec says exactly which part is **not** being reopened.

**The sync-engine call signatures you will delegate to** (do not guess these):

```ruby
Sync::Mutation.apply(user:, node:, op: "move") { |n| n.parent_node_id = x; n.name = y }  # => seq
Sync::Mutation.apply(user:, node:, op: "mkdir")                                          # => seq (node is NEW, unsaved)
Sync::SubtreeDelete.call(user:, node:)                                                   # => seq
Sync::Trash.restore(user:, node_id:, to_root: false)                                     # => [node, seq]
Sync::Commit.begin(...)                                                                  # => result
Sync::Commit.finalize(user:, commit_id:, verify:)                                        # => [version, seq]
```

**Every mutation must broadcast.** `LibraryChannel.broadcast_change(user, seq)` after each one, or a device following the changelog diverges from the server's tree. Every existing chunk call site does this; the port must keep doing it.

**`Sync::SubtreeDelete`, never `Sync::Mutation.apply(op: "delete")`.** The latter tombstones only the node it is handed and orphans every descendant. This is the single sharpest trap in §14a and it survives this plan unchanged.

---

## File Structure

| File | Change | Responsibility after |
|---|---|---|
| `app/services/file_layer/capabilities.rb` | Modify | gains `dir_deletable` (6th capability) |
| `app/services/file_layer/chunk.rb` | Modify | four metadata verbs delegate; `write` still refuses |
| `app/services/file_layer/share.rb` | Modify | declares `dir_deletable: false` |
| `app/services/file_layer/s3.rb` | Modify | declares `dir_deletable: false` |
| `app/services/maker/library_folder.rb` | Modify | branch removed — port only |
| `app/services/maker/move_node.rb` | Modify | branch removed — port only |
| `app/controllers/files_controller.rb` | Modify | `#destroy` branch removed |
| `app/controllers/trash_controller.rb` | Modify | `#restore` branch removed |
| `test/services/file_layer/adapter_mutation_contract.rb` | **Create** | the metadata verbs, asserted against all three adapters |
| `test/services/file_layer/adapter_write_contract.rb` | Modify | header narrowed to the BYTE write path only |
| `test/services/file_layer/chunk_test.rb` | Modify | refusal test → behaviour tests |
| `test/architecture_invariants_test.rb` | Modify | gains the maker→sync seam guard |

Tasks 1–7 are ordered so each leaves `bin/ci` green. Task 8 is the byte path and is the largest; tasks 1–7 deliver goal 4 without it.

---

### Task 1: Add the `dir_deletable` capability

Chunk's `delete` can cascade a directory safely (`Sync::SubtreeDelete`). Share's cannot — §14a: children are stranded at paths that no longer exist while their bytes sit in `.trash`, where the scan refuses to look. On S3 there is no directory and no rename at all. Today `FilesController#destroy` hides that behind its `port_writable?` branch; once the branch is gone it is one call with two answers, which §14a forbids. A capability is the honest expression, exactly as `scannable` was added when a coincidence between two questions became wrong.

**Files:**
- Modify: `app/services/file_layer/capabilities.rb`
- Modify: `app/services/file_layer/chunk.rb` (the `capabilities` method, ~line 41)
- Modify: `app/services/file_layer/share.rb` (~line 27)
- Modify: `app/services/file_layer/s3.rb` (~line 84)
- Test: `test/services/file_layer/value_objects_test.rb`

- [x] **Step 1: Write the failing test**

Append inside the existing `Capabilities` test class in `test/services/file_layer/value_objects_test.rb`:

```ruby
    # dir_deletable asks ONE question: can this backend's `delete` be handed a DIRECTORY?
    #
    # It exists because FilesController#destroy stopped branching on port_writable?. Chunk
    # answers true (Sync::SubtreeDelete cascades the tombstone to the whole subtree); share
    # answers false (children would be stranded at paths that no longer exist while their bytes
    # sit in .trash, which the scan refuses to look at); S3 answers false (there is no directory
    # and no rename -- a dir node's key does not exist).
    #
    # IT IS NOT `syncable`, and the fact that it currently equals it is a coincidence of having
    # exactly three backends -- the same trap `scannable` was introduced to escape. A backend
    # that owns its own tree without a changelog (a database-backed store, a versioned object
    # store with real directories) answers dir_deletable true and syncable false.
    test "dir_deletable is part of the capability set and reads as a predicate" do
      caps = FileLayer::Capabilities.new(versioned: true, syncable: true, presignable: true,
                                         scannable: false, port_writable: false,
                                         dir_deletable: true)
      assert_predicate caps, :dir_deletable?
    end

    # Asserted as a RELATIONSHIP against the real adapters rather than three literals, so a
    # backend added later cannot quietly skip declaring it.
    test "every adapter declares dir_deletable, and only chunk allows it" do
      expected = { FileLayer::Chunk => true, FileLayer::Share => false, FileLayer::S3 => false }
      expected.each do |klass, want|
        got = klass.allocate.capabilities.dir_deletable?
        assert_equal want, got, "#{klass} must declare dir_deletable: #{want}"
      end
    end
```

- [x] **Step 2: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/value_objects_test.rb
```

Expected: FAIL with `ArgumentError: unknown keyword: :dir_deletable` (first test) and `NoMethodError: undefined method 'dir_deletable?'` (second).

- [x] **Step 3: Add the field to `Capabilities`**

In `app/services/file_layer/capabilities.rb`, extend the `Data.define` and add the predicate. Add this paragraph to the file's header comment, above the `Capabilities =` line:

```ruby
  # DIR_DELETABLE answers ONE question, for ONE caller -- FilesController#destroy:
  #
  #     may this backend's `delete` be handed a DIRECTORY?
  #
  # true  -> chunk. Sync::SubtreeDelete cascades the tombstone to the whole subtree.
  # false -> share, S3. On share a dir delete strands children at paths that no longer exist
  #          while their bytes sit in .trash, where the scan refuses to look. On S3 there is
  #          no directory and no rename at all: a dir node's key does not exist.
  #
  # It was added when #destroy stopped branching on port_writable? and became ONE call with TWO
  # answers -- which §14a forbids. IT IS NOT `syncable`, though the two agree on all three
  # backends today; that is three samples, not an identity, and encoding such a coincidence once
  # already (`is_a?(Share)`) is the whole reason `scannable` exists.
```

Then:

```ruby
  Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable, :port_writable,
                             :dir_deletable) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
    def scannable? = scannable
    def port_writable? = port_writable
    def dir_deletable? = dir_deletable
  end
```

- [x] **Step 4: Declare it in all three adapters**

`app/services/file_layer/chunk.rb`, in `#capabilities`:

```ruby
      Capabilities.new(versioned: true, syncable: true, presignable: true, scannable: false,
                       port_writable: false, dir_deletable: true)
```

`app/services/file_layer/share.rb`, in `#capabilities` — keep the existing keyword arguments on that line and append `dir_deletable: false`.

`app/services/file_layer/s3.rb`, in `#capabilities` — same, append `dir_deletable: false`.

- [x] **Step 5: Run the tests to verify they pass**

```bash
bin/rails test test/services/file_layer/
```

Expected: PASS, 0 failures 0 errors.

- [x] **Step 6: Mutation-check the guard (§15 — required, not optional)**

Change chunk's declaration to `dir_deletable: false`, run `bin/rails test test/services/file_layer/value_objects_test.rb`, and **confirm it goes RED**. Then restore `true` and confirm green. A guard that has never failed has not been shown to work.

- [x] **Step 7: Commit**

```bash
git add app/services/file_layer/ test/services/file_layer/value_objects_test.rb
git commit -m "feat(file-layer): add the dir_deletable capability

FilesController#destroy is about to stop branching on port_writable?, which
makes it one call with two answers -- forbidden by CLAUDE.md 14a. A capability
is the honest expression, the same move that added scannable.

Chunk true (SubtreeDelete cascades); share and s3 false.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Extract the shared mutation contract

**CORRECTED after reading the real files.** The plan originally said "create" and named the modules
`AdapterContract`/`AdapterMutationContract`. Both were wrong:

- The real module names are **`FileLayerAdapterContract`** (read) and **`FileLayerWritableContract`**
  (write), in `adapter_contract.rb` and `adapter_write_contract.rb`.
- `FileLayerWritableContract` **already contains** the four metadata tests
  (`mkdir_creates_a_dir_node_and_is_idempotent`, `move_keeps_the_node_id`,
  `delete_tombstones_rather_than_destroying`, `undelete_restores_the_same_node_and_bytes`).

So this is an **extraction**, not new authorship. Writing parallel tests would duplicate coverage
and let the two copies drift — the exact failure this repo records over and over. The four tests
move; their assertions and their comments come with them unchanged.

The one thing that must change is how each test gets its fixture: all four currently call
`adapter.write(...)`, which chunk does not have and must never grow. That becomes a **hook**.

**Files:**
- Create: `test/services/file_layer/adapter_mutation_contract.rb`
- Modify: `test/services/file_layer/adapter_write_contract.rb` (remove the four moved tests; narrow the header)
- Modify: `test/services/file_layer/share_test.rb` (include the new module + define the hooks)
- Modify: `test/services/file_layer/s3_test.rb` (same)

`chunk_test.rb` is **not** touched in this task — chunk has no `move`/`delete`/`undelete` until
Tasks 4–6, so including the contract there now would fail. Task 7 wires it in.

- [x] **Step 1: Create `adapter_mutation_contract.rb`**

Header:

```ruby
# The contract EVERY adapter's METADATA verbs must satisfy -- mkdir, move, delete, undelete.
#
# EXTRACTED FROM FileLayerWritableContract, not written beside it. Those four tests lived there
# because, when it was written, the only adapters answering them were the two port_writable ones;
# Stage 2 gave chunk all four, so the grouping had become "the verbs share and s3 happen to share"
# rather than a real boundary. A second copy for chunk would have been two sets of assertions
# about one contract, free to drift -- this repo's most-recorded failure shape.
#
# THE REAL BOUNDARY IS BYTES. What stayed behind in FileLayerWritableContract is `write`, which
# takes an IO. Chunk does not have it and must never grow it: chunk uploads are Sync::Commit's
# two-phase presigned flow precisely so bytes never travel through Rails (CLAUDE.md 15). These
# four verbs move NO bytes, so 15 does not bind and all three adapters answer them.
#
# Include alongside FileLayerAdapterContract; its hooks (`adapter`, `@user`) are assumed.
#
# TWO HOOKS the including test case must define:
#
#   make_file(name:, bytes:) -> create one live FILE node carrying those bytes, through whatever
#                       door this backend really uses, and return its node_id. A HOOK rather than
#                       a shared helper because the doors genuinely differ -- share and s3 write
#                       through the port, chunk commits through the sync engine -- and a contract
#                       that reached for one of them would test that backend twice and the other
#                       not at all. It must produce REAL READABLE BYTES: three of these tests
#                       assert on adapter.read, which is what proves a move or an undelete kept
#                       the node_id resolving to the same content rather than merely to a row.
#
#   make_dir(name:)  -> the same, for a DIRECTORY node. Returns its node_id.
#
# WHAT THIS DELIBERATELY DOES NOT PIN:
#
#   - DIRECTORY DELETION. That is `dir_deletable`, and both answers are correct: chunk cascades
#     via Sync::SubtreeDelete, share strands children at paths that no longer exist while their
#     bytes sit in .trash, s3 has no directory at all. Asserted below as a capability-conditional,
#     never as one fixed expectation.
#   - WHERE THE BYTES GO. Share's `.trash/<node_id>/<name>` layout is share's own test; s3 trashes
#     by key prefix; chunk moves no bytes. Encoding one backend's storage layout in a shared
#     contract is the leak the port exists to prevent.
#   - `undelete`'s DESTINATION FOR AN ORPHAN. Share restores under the (tombstoned) parent's path,
#     which still exists on a filesystem; chunk restores to the ROOT, because a tombstoned parent
#     has no path to restore under. Both are right for their backend.
#   - A MOVE ONTO A TAKEN NAME. Share and s3 refuse it (UnsupportedOperation -- a clobber); chunk
#     does NOT, because Sync::Mutation performs no name check at all and Sync::Commit validates a
#     manifest exhaustively and the name not at all (CLAUDE.md 14c). Two live siblings sharing one
#     (parent, name) really are reachable on chunk. The WEB path is still protected --
#     Maker::MoveNode.collision! runs before it calls the port -- so this is not a regression
#     Stage 2 introduces, and closing it is a separate decision (CLAUDE.md 14c's recorded gap --
#     NOT 12 item 11, which is a different gap one layer up), not
#     something a refactor does silently. It stays asserted in share's and s3's OWN tests.
#   - A MOVE OF A DIRECTORY. Share allows it; s3 refuses (`movable_file!`). Every test here moves
#     a FILE for that reason.
module FileLayerMutationContract
```

- [x] **Step 2: Move the four tests into it, verbatim except for the fixture line**

Cut these four methods out of `FileLayerWritableContract` and paste them into the new module,
**keeping every existing comment above each one**. Rename the `test_write_contract_` prefix to
`test_mutation_contract_`. In each, replace the `adapter.write(...)` fixture call with the hook:

```ruby
# BEFORE (in FileLayerWritableContract)
info = adapter.write(@user, parent_node_id: nil, name: "before.stl", io: StringIO.new("same"))
adapter.move(@user, node_id: info.node_id, ...)

# AFTER (in FileLayerMutationContract)
node_id = make_file(name: "before.stl", bytes: "same")
adapter.move(@user, node_id:, ...)
```

`test_write_contract_mkdir_creates_a_dir_node_and_is_idempotent` needs no fixture change at all —
it only calls `adapter.mkdir`. Update its comment, which currently says *"Chunk does NOT include
this contract — its mkdir goes through the sync engine — so this pins only that Share and S3 do
not diverge"*: that sentence becomes false the moment Task 7 includes chunk. Replace it with a
note that all three now answer mkdir, chunk's through the sync engine.

- [x] **Step 3: Add the `dir_deletable` conditional test**

New — this one has no ancestor in the write contract, because until Task 1 there was no capability
to branch on:

```ruby
  # The capability from Task 1, asserted as a CONDITIONAL rather than a fixed expectation, because
  # both answers are correct and which one is right is a property of the backend.
  def test_mutation_contract_delete_refuses_a_directory_unless_dir_deletable
    dir_id = make_dir(name: "adir")
    if adapter.capabilities.dir_deletable?
      adapter.delete(@user, node_id: dir_id)
      assert @user.nodes.find_by!(node_id: dir_id).deleted, "a dir_deletable backend tombstones it"
    else
      assert_raises(FileLayer::UnsupportedOperation) { adapter.delete(@user, node_id: dir_id) }
      assert_not @user.nodes.find_by!(node_id: dir_id).deleted, "a refused delete must not half-apply"
    end
  end
```

- [x] **Step 4: Narrow the write contract's header**

In `adapter_write_contract.rb`, replace the opening paragraph (through `...spec §10).`) with:

```ruby
# The contract every adapter implementing the port's BYTE write path must satisfy -- `write`,
# which takes an IO. Separate from adapter_contract.rb (the read contract, which runs against
# every adapter) and from adapter_mutation_contract.rb (mkdir/move/delete/undelete, which ALSO
# runs against every adapter, chunk included, since Stage 2).
#
# Chunk does not implement THIS one and must never be made to: chunk-mode uploads are
# Sync::Commit's two-phase presigned flow, and a server-side byte write here would push bytes
# through Rails, which CLAUDE.md 15 forbids. That is a NARROWER claim than this header used to
# make -- it said chunk could not satisfy the write path at all, which stopped being true for the
# four metadata verbs when they moved to adapter_mutation_contract.rb.
```

- [x] **Step 5: Wire it into share and s3 and prove the extraction lost nothing**

In `test/services/file_layer/share_test.rb`, beside `include FileLayerWritableContract`:

```ruby
    include FileLayerMutationContract

    # The hooks FileLayerMutationContract requires. Share's real door for creating a file is the
    # port's own write, which is exactly what the four extracted tests used inline before they
    # became backend-agnostic.
    def make_file(name:, bytes:)
      adapter.write(@user, parent_node_id: nil, name:, io: StringIO.new(bytes)).node_id
    end

    def make_dir(name:) = adapter.mkdir(@user, parent_node_id: nil, name:).node_id
```

Add the identical pair to `test/services/file_layer/s3_test.rb`. **Repeat them rather than
extracting a shared helper**: the whole point of a hook is that each backend answers through its
own door, and a shared helper would let one backend's door stand in for the other's.

Add `require_relative "adapter_mutation_contract"` beside the existing `require_relative` in each.

- [x] **Step 6: Run and compare counts**

```bash
bin/rails test test/services/file_layer/
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/file_layer/
```

Expected: PASS. **The total run count must be exactly 2 higher than before this task** — the four
moved tests are the same four tests (no gain), plus the new `dir_deletable` conditional running on
share and s3 (two more, one per adapter). If it moved by any other amount, a test was lost or
duplicated: find out which before continuing.

Record the before/after counts in your report.

- [x] **Step 7: Commit**

```bash
git add test/services/file_layer/
git commit -m "test(file-layer): extract the metadata verbs into their own adapter contract

mkdir/move/delete/undelete lived in FileLayerWritableContract because the only
adapters answering them were the two port_writable ones. Stage 2 gives chunk all
four, so that grouping was about which backends happened to agree rather than
about a real boundary. The real boundary is BYTES: what stays behind is write,
which takes an IO and which chunk must never grow (CLAUDE.md 15).

Extracted, not copied -- the four tests move with their assertions and comments
intact, with their adapter.write fixture replaced by a make_file hook. Wired into
share and s3 now; chunk joins in Task 7 once it has the verbs.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `Chunk#mkdir`, and collapse `Maker::LibraryFolder`

Smallest verb, smallest caller — do it first to establish the delegation shape the next three tasks copy.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/services/maker/library_folder.rb:39-63`
- Test: `test/services/file_layer/chunk_test.rb`

- [x] **Step 1: Write the failing test**

Append to the `FileLayer::ChunkTest` class in `test/services/file_layer/chunk_test.rb`:

```ruby
    # The port is now the door for chunk-mode mkdir, not a refusal that names another door.
    # Maker::LibraryFolder used to branch around it into Sync::Mutation; it no longer can,
    # because in remote mode there is no Sync::Mutation in the process to branch into.
    test "mkdir creates a dir node through the sync engine and returns its FileInfo" do
      info = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_equal "dir",  info.kind
      assert_equal "cad",  info.name
      node = @user.nodes.present.find_by(node_id: info.node_id)
      assert_equal "dir", node.kind
    end

    # A mutation that does not broadcast leaves every device's tree diverged from the server's,
    # silently -- pull is incremental, so nothing anywhere reports it. Asserted on the CHANGELOG
    # rather than by stubbing the broadcast: the changelog entry is what a device actually reads,
    # and a test that stubs LibraryChannel proves only that we called our own method.
    test "mkdir appends a changelog entry so devices converge" do
      before = @user.reload.head_seq
      adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_operator @user.reload.head_seq, :>, before, "mkdir must advance head_seq"
    end

    test "mkdir is idempotent -- LibraryFolder walks each path segment on every call" do
      first  = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      second = adapter.mkdir(@user, parent_node_id: nil, name: "cad")
      assert_equal first.node_id, second.node_id
    end
```

- [x] **Step 2: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: FAIL with `NotImplementedError` carrying `MKDIR_MSG`.

- [x] **Step 3: Implement `Chunk#mkdir`**

In `app/services/file_layer/chunk.rb`, delete the `mkdir` refusal stub and the `MKDIR_MSG` constant, and add:

```ruby
    # THE PORT IS THE DOOR, and it was a refusal until Stage 2. It changed because
    # Maker::LibraryFolder used to branch around the port into Sync::Mutation directly -- which
    # works only while the sync engine is in this process. It will not be.
    #
    # IDEMPOTENT, matching Share#mkdir: Maker::LibraryFolder walks a path segment by segment and
    # calls this for each one, so a second walk of an existing path must return the SAME node.
    # Returning a fresh one would mint a duplicate directory on every ensure_path! of a path that
    # already exists -- which is the common case, not the edge case.
    def mkdir(user, parent_node_id: nil, name: nil)
      existing = user.nodes.present.find_by(parent_node_id:, name:, kind: "dir")
      return file_info(existing, nil) if existing

      node = user.nodes.new(
        node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "dir",
        deleted: false, mode: 0o755, mtime: (Time.current.to_f * 1e9).to_i
      )
      seq = Sync::Mutation.apply(user:, node:, op: "mkdir")
      LibraryChannel.broadcast_change(user, seq)
      file_info(node, nil)
    end
```

- [x] **Step 4: Run test to verify it passes**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 5: Collapse the branch in `Maker::LibraryFolder`**

In `app/services/maker/library_folder.rb`, replace `ensure_segment`, `port_mkdir` and `chunk_mkdir` (lines 39–63) with:

```ruby
    # ONE DOOR. This used to branch on port_writable? -- one of the five copies CLAUDE.md 14d
    # counts -- because the port refused mkdir in chunk mode. It no longer does, so the branch
    # has nothing left to decide.
    def ensure_segment(parent_node_id, name)
      info = FileLayer.current.mkdir(@user, parent_node_id:, name:)
      @user.nodes.find_by!(node_id: info.node_id)
    end
```

Then delete the now-unused `@port_writable` assignment in this class if nothing else reads it — grep first:

```bash
grep -n "port_writable" app/services/maker/library_folder.rb
```

If the only remaining hit is the assignment in `initialize`, remove that line too.

- [x] **Step 6: Run the full suite**

```bash
bin/rails test
```

Expected: PASS, 0 failures 0 errors.

- [x] **Step 7: Run the other two backend legs**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

Expected: PASS, and the **same test count** as the previous command (§15).

- [x] **Step 8: Mutation-check the broadcast guard**

Delete the `LibraryChannel.broadcast_change(user, seq)` line from `Chunk#mkdir`, run `bin/rails test test/services/file_layer/chunk_test.rb`, and **confirm the changelog test goes RED**. Restore it. If it stays green the assertion is not carrying weight — fix the test, not the code.

- [x] **Step 9: Commit**

```bash
git add app/services/file_layer/chunk.rb app/services/maker/library_folder.rb test/services/file_layer/chunk_test.rb
git commit -m "feat(file-layer): Chunk#mkdir goes through the port

First of the four metadata verbs. Maker::LibraryFolder branched around the port
into Sync::Mutation, which works only while the sync engine shares this process.
Idempotent, matching Share#mkdir, because LibraryFolder walks every path segment
on every call.

Removes one of CLAUDE.md 14d's five port_writable? branch copies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `Chunk#move`, and collapse `Maker::MoveNode`

> **Task 3 established two things every remaining verb inherits.** (a) The broadcast is asserted
> with `assert_broadcast_on`, never by watching `head_seq` — `Sync::Mutation` advances head_seq on
> its own, so the head_seq spelling stays GREEN when the broadcast is deleted. `chunk_test.rb`
> already has `include ActionCable::TestHelper` from Task 3. (b) Collapsing a caller's branch can
> break a TEST FAKE that stood in for `FileLayer.current` and got away with not implementing the
> verb, because the caller's own short-circuit used to run first. Task 3 hit this in
> `test/services/maker/project_intake_test.rb`. Expect it; fix the fake, do not weaken the caller.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/services/maker/move_node.rb:209-233`
- Test: `test/services/file_layer/chunk_test.rb`

- [x] **Step 1: Write the failing test**

Append to `FileLayer::ChunkTest`:

```ruby
    test "move renames a node through the sync engine and returns its post-move FileInfo" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "before.stl", kind: "file",
                                 deleted: false, mtime: 0)
      info = adapter.move(@user, node_id: node.node_id, new_parent_node_id: nil,
                          new_name: "after.stl")
      assert_equal "after.stl",  info.name
      assert_equal node.node_id, info.node_id, "a move must preserve node_id"
      assert_equal "after.stl",  node.reload.name
    end

    # ASSERTED ON THE BROADCAST ITSELF, not on head_seq. Task 3 proved the head_seq spelling
    # cannot fail for the reason it exists: Sync::Mutation advances head_seq whether or not
    # anything broadcasts, so deleting the broadcast left that test GREEN. `assert_broadcast_on`
    # with the EXACT payload also catches a broadcast carrying a stale seq, which a count would
    # not. Requires `include ActionCable::TestHelper` on the test case.
    test "move broadcasts the new head_seq so devices converge" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "before.stl", kind: "file",
                                 deleted: false, mtime: 0)
      expected = @user.reload.head_seq + 1
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: expected) do
        adapter.move(@user, node_id: node.node_id, new_parent_node_id: nil, new_name: "after.stl")
      end
    end
```

- [x] **Step 2: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: FAIL with `NotImplementedError` carrying `MOVE_MSG`.

- [x] **Step 3: Implement `Chunk#move`**

In `app/services/file_layer/chunk.rb`, delete the `move` refusal stub and the `MOVE_MSG` constant, and add:

```ruby
    # RETURNS THE POST-MOVE FileInfo, which is the port's contract and was the one real behavioural
    # difference between the two doors Maker::MoveNode used to pick between: the port resolved the
    # node_id into its OWN instance, so the caller's object still held the pre-move name, while the
    # chunk door assigned the caller's object in place. A caller rendering `node.name` after a
    # rename printed the OLD name on share/s3 only. One door, one answer.
    def move(user, node_id: nil, new_parent_node_id: nil, new_name: nil)
      node = live_node!(user, node_id)
      seq = Sync::Mutation.apply(user:, node:, op: "move") do |n|
        n.parent_node_id = new_parent_node_id
        n.name = new_name
      end
      LibraryChannel.broadcast_change(user, seq)
      file_info(node, node.current_version&.size)
    end
```

- [x] **Step 4: Run test to verify it passes**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 5: Collapse the branch in `Maker::MoveNode`**

In `app/services/maker/move_node.rb`, replace `port_move` and `chunk_move` (lines 209–233) with a single method, and update its caller to use the new name. First find the caller:

```bash
grep -n "port_move\|chunk_move" app/services/maker/move_node.rb
```

Replace both methods with:

```ruby
    # ONE DOOR. This used to branch on port_writable? -- another of CLAUDE.md 14d's five copies --
    # because the port refused move in chunk mode.
    #
    # THE RELOAD IS THE RETURN VALUE, not tidiness. The port resolves the node_id into its own
    # instance, so without this the caller's object still holds the pre-move name, parent and
    # storage_path, and a flash or turbo frame rendering `node.name` prints the OLD name.
    def apply_move(node, new_parent_node_id, name)
      FileLayer.current.move(@user, node_id: node.node_id,
                             new_parent_node_id:, new_name: name)
      node.reload
    end
```

Update the branch site that called `port_move`/`chunk_move` to call `apply_move` unconditionally, and remove the `@port_writable` read there.

- [x] **Step 6: Run the full suite plus the share leg**

```bash
bin/rails test && LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

Expected: PASS both, identical counts.

- [x] **Step 7: Mutation-check**

Change `Chunk#move` to return `file_info(node, nil)` **without** reloading — i.e. drop the `n.name = new_name` assignment inside the block. Confirm the move test goes RED. Restore.

- [x] **Step 8: Commit**

```bash
git add app/services/file_layer/chunk.rb app/services/maker/move_node.rb test/services/file_layer/chunk_test.rb
git commit -m "feat(file-layer): Chunk#move goes through the port

Second metadata verb. Collapses Maker::MoveNode's two doors into one, which
also settles their one real behavioural difference: the port's return value is
post-move state, so a caller rendering node.name after a rename no longer
prints the old name on share/s3 only.

Removes a second of CLAUDE.md 14d's five port_writable? branch copies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `Chunk#delete`, and collapse `FilesController#destroy`

> **CARRIED FORWARD FROM TASK 4'S REVIEW — do this as part of Task 5.**
> `test/services/file_layer/adapter_contract.rb` has
> `test_contract_port_writable_agrees_with_what_delete_actually_does`. Task 4 narrowed it from
> covering delete AND move once chunk's move stopped being gated by `port_writable?`. **Task 5
> must DELETE it outright, not narrow it again.** Once `Chunk#delete` goes through the port,
> `port_writable?` predicts nothing about delete either, and the assertion becomes exactly as
> vacuous as it was for move — it encodes the "port_writable means can-mutate" misreading §14a
> explicitly forbids. Its cross-backend content already lives in
> `adapter_mutation_contract.rb`'s `test_mutation_contract_delete_tombstones_rather_than_destroying`.
> `test_contract_port_writable_agrees_with_what_write_actually_does` is the sole survivor of the
> pattern and stays — `write` is the one verb `port_writable?` is genuinely about.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/controllers/files_controller.rb:615-624`
- Test: `test/services/file_layer/chunk_test.rb`

- [x] **Step 1: Write the failing test**

Append to `FileLayer::ChunkTest`:

```ruby
    test "delete tombstones the node through the sync engine" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "gone.stl", kind: "file",
                                 deleted: false, mtime: 0)
      adapter.delete(@user, node_id: node.node_id)
      assert_predicate node.reload, :deleted?
    end

    # SubtreeDelete, NEVER Sync::Mutation.apply(op: "delete"). The latter tombstones only the node
    # it is handed, so on a directory it orphans every descendant: /v1/tree serves children
    # pointing at a deleted parent while changelog-following devices drop the whole subtree. This
    # is the sharpest trap in CLAUDE.md 14a and the reason chunk answers dir_deletable true at all.
    test "delete CASCADES to the subtree -- the reason chunk is dir_deletable" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "adir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      adapter.delete(@user, node_id: dir.node_id)
      assert_predicate dir.reload,   :deleted?
      assert_predicate child.reload, :deleted?, "a dir delete must cascade, never orphan children"
    end

    # On the BROADCAST, not head_seq -- see the note in Task 4. NOTE the expected seq: a subtree
    # delete of a childless file is ONE mutation, so head_seq + 1. If you write this test against
    # a node WITH children, SubtreeDelete tombstones each one and the final seq is higher; assert
    # what the cascade actually produces rather than assuming one.
    test "delete broadcasts the new head_seq so devices converge" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "gone.stl", kind: "file",
                                 deleted: false, mtime: 0)
      expected = @user.reload.head_seq + 1
      assert_broadcast_on(LibraryChannel.broadcasting_for(@user), head_seq: expected) do
        adapter.delete(@user, node_id: node.node_id)
      end
    end
```

- [x] **Step 2: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: FAIL with `NotImplementedError` carrying `DELETE_MSG`.

- [x] **Step 3: Implement `Chunk#delete`**

In `app/services/file_layer/chunk.rb`, delete the `delete` refusal stub and the `DELETE_MSG` constant, and add:

```ruby
    # Sync::SubtreeDelete, NOT Sync::Mutation.apply(op: "delete"): the latter tombstones only the
    # node it is given, so on a directory it orphans the descendants -- /v1/tree would serve
    # children pointing at a deleted parent while changelog-following devices dropped the whole
    # subtree. SubtreeDelete is the safe superset: on a childless file it collects exactly one node
    # and does the identical single tombstone, which is why it is the right answer to give a caller
    # who has not told us which kind they hold.
    #
    # THIS IS WHY CHUNK ANSWERS dir_deletable TRUE while share and s3 answer false. Do not "fix"
    # that asymmetry in either direction: the cascade is real here and impossible there.
    def delete(user, node_id: nil)
      node = live_node!(user, node_id)
      seq = Sync::SubtreeDelete.call(user:, node:)
      LibraryChannel.broadcast_change(user, seq)
      nil
    end
```

- [x] **Step 4: Run test to verify it passes**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 5: Collapse `FilesController#destroy`**

In `app/controllers/files_controller.rb`, replace lines 615–624 with:

```ruby
  # ONE DOOR since Stage 2. This branched on port_writable? -- a third of CLAUDE.md 14d's five
  # copies -- because the port refused delete in chunk mode.
  #
  # A DIRECTORY is refused on share/s3 and cascades on chunk. That is `dir_deletable`, and the
  # refusal arrives as UnsupportedOperation, which this controller already maps to 422.
  def destroy
    node = current_user.nodes.find_by!(node_id: params[:id])
    FileLayer.current.delete(current_user, node_id: node.node_id)
    redirect_to files_path, notice: "Deleted #{node.name}."
  end
```

Note `node.name` is read **before** the delete in both the old and new code — keep it that way; reading it after a tombstone still works but the ordering is what the flash has always used.

- [x] **Step 6: Run the full suite plus both other legs**

```bash
bin/rails test && LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

Expected: PASS both, identical counts.

- [x] **Step 7: Mutation-check the cascade guard**

Change `Chunk#delete` to use `Sync::Mutation.apply(user:, node:, op: "delete")` instead of `Sync::SubtreeDelete.call`. Confirm the cascade test goes **RED** on the child assertion. Restore. This is the mutation that matters most in the whole plan.

- [x] **Step 8: Commit**

```bash
git add app/services/file_layer/chunk.rb app/controllers/files_controller.rb test/services/file_layer/chunk_test.rb
git commit -m "feat(file-layer): Chunk#delete goes through the port

Third metadata verb, delegating to Sync::SubtreeDelete (never
Mutation.apply(op: delete), which orphans descendants). Collapses
FilesController#destroy's branch; a directory now refuses on share/s3 via
dir_deletable and cascades on chunk.

Removes a third of CLAUDE.md 14d's five port_writable? branch copies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `Chunk#undelete`, and collapse `TrashController#restore`

> **FOUR THINGS TASK 5'S REVIEW ESTABLISHED FOR THIS TASK.**
>
> 1. **`undelete` RETURNS A `FileInfo`, NOT nil.** `Share#undelete` ends `stat(...)` and
>    `TrashController#restore`'s live share/s3 branch already reads `info.name` off it. This is the
>    one metadata verb where `delete`'s `nil` is the wrong precedent — delete changes no field
>    `FileInfo` exposes, undelete can silently reparent to the root.
> 2. **RESTORE ORDER IS NOT COMMUTATIVE, AND TASK 5 MADE THAT MAINLINE RATHER THAN RARE.**
>    `Sync::Trash.restore(to_root: true)` nulls `parent_node_id` when the parent is tombstoned.
>    Restoring a CHILD first permanently rewrites that pointer — restoring the parent afterwards
>    does **not** reunite them. Before `delete` cascaded, an orphan needed two deliberate deletes;
>    now one click on a folder tombstones its whole subtree, so every file under it is an orphan
>    and bottom-up restore scatters the folder's contents to the root, irreversibly. **Say this
>    plainly in `Chunk#undelete`'s comment.** Do not try to fix it — top-down restore already
>    preserves structure, and `V1::TrashController` deliberately exposes `to_root` as a caller
>    choice defaulting to a 409 instead.
> 3. **The collision hole stays open and gets documented, not closed** — see the note further down.
>    `Sync::Trash.restore` has no `destination_vacant!`-style check anywhere in it. If the message
>    wants Share's wording ("occupied — undelete must not clobber"), inline it rather than bending
>    `Chunk#destination_vacant!`'s — its own comment says so.
> 4. **FOUR ENUMERATION SITES SAY "mkdir, move and delete" AND ALL FOUR NEED "undelete" IN THIS
>    SAME COMMIT**: `chunk.rb:27`, `chunk.rb:185`, `chunk_test.rb:106`, `chunk_test.rb:109`. They
>    are accurate today and become wrong the moment this task lands.

> **KNOWN DIVERGENCE, found while reviewing Task 3 — do NOT try to close it here.**
> `Sync::Trash.restore` (`app/services/sync/trash.rb:30-42`) has **no collision check at all**, so
> on chunk a restore can produce two live nodes sharing one `(parent_node_id, name)`. Share and s3
> cannot: `db/schema.rb:435` carries `index_nodes_on_user_id_and_storage_path unique, where
> "deleted = false"`, and their port-level `undelete` refuses a clobber with `UnsupportedOperation`.
> Reproduced: mkdir "cad" → tombstone it → mkdir "cad" again (mints a NEW node_id, since the
> idempotence lookup is `.present`) → restore the tombstone → two live "cad" dirs.
> It is **pre-existing and not a regression** — the same hole existed when `TrashController` called
> `Sync::Trash.restore` directly — and it is the same family as CLAUDE.md §14c's "two live siblings
> sharing one (parent, name) are reachable on chunk". `FileLayerMutationContract` deliberately does
> **not** pin undelete-clobber for exactly this reason. Adding a check inside a refactor task would
> be a silent behaviour change to the sync engine; it needs its own decision. **Document it in the
> `Chunk#undelete` comment, do not fix it.**

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/controllers/trash_controller.rb:71-81`
- Test: `test/services/file_layer/chunk_test.rb`

- [x] **Step 1: Write the failing test**

Append to `FileLayer::ChunkTest`:

```ruby
    test "undelete revives a tombstoned node, keeping its node_id" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "back.stl", kind: "file",
                                 deleted: false, mtime: 0)
      adapter.delete(@user, node_id: node.node_id)
      info = adapter.undelete(@user, node_id: node.node_id)
      refute_predicate node.reload, :deleted?
      assert_equal node.node_id, info.node_id,
                   "undelete must keep node_id -- attachments, BOM links and tags key on it"
    end

    # to_root: true, matching what TrashController#restore has always passed. An orphan -- a node
    # whose parent is itself tombstoned -- has no path to restore under, so it comes back at the
    # root rather than raising ParentDeleted at a user who only clicked Restore.
    test "undelete restores an orphan to the root rather than raising" do
      dir   = @user.nodes.create!(node_id: SecureRandom.uuid, name: "adir", kind: "dir",
                                  deleted: false, mtime: 0)
      child = @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id: dir.node_id,
                                  name: "kid.stl", kind: "file", deleted: false, mtime: 0)
      adapter.delete(@user, node_id: dir.node_id)
      info = adapter.undelete(@user, node_id: child.node_id)
      assert_nil child.reload.parent_node_id, "an orphan must come back at the root"
      assert_equal child.node_id, info.node_id
    end
```

- [x] **Step 2: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'undelete'` — chunk has no `undelete` stub at all today.

- [x] **Step 3: Implement `Chunk#undelete`**

In `app/services/file_layer/chunk.rb`, add beside the other metadata verbs:

```ruby
    # `to_root: true`, which is what TrashController#restore has always passed and is now the
    # port's single answer for chunk. An ORPHAN -- a node whose parent is itself tombstoned -- has
    # no path to restore under, so Sync::Trash puts it at the root instead of raising
    # ParentDeleted at a user who only clicked Restore.
    #
    # V1::TrashController keeps its own direct Sync::Trash.restore call with a caller-supplied
    # to_root:. That is deliberate: it is sync-engine code that moves to the sync repo in Stage 3,
    # and the API genuinely offers the choice the web UI does not.
    #
    # Share restores under the (tombstoned) parent's own path instead, because on a filesystem
    # that path still exists. Both are right for their backend and the shared contract does not
    # pin it.
    def undelete(user, node_id: nil)
      node, seq = Sync::Trash.restore(user:, node_id:, to_root: true)
      LibraryChannel.broadcast_change(user, seq) if seq
      file_info(node, node.current_version&.size)
    end
```

- [x] **Step 4: Run test to verify it passes**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 5: Collapse `TrashController#restore`**

In `app/controllers/trash_controller.rb`, replace lines 71–81 with:

```ruby
  # ONE DOOR since Stage 2 -- the fourth of CLAUDE.md 14d's five port_writable? copies to go.
  # The port's undelete answers a FileInfo on every backend, so the flash reads one field.
  def restore
    info = FileLayer.current.undelete(current_user, node_id: params[:id])
    redirect_to files_path, notice: "Restored #{info.name}."
  end
```

Check the class's existing `rescue_from`/rescue block still covers `FileLayer::UnsupportedOperation` — §14a records that `TrashController` once rescued `NotFound` but not `UnsupportedOperation`, producing an uncaught 500 *while its own rescue comment already named that case*:

```bash
grep -n "rescue" app/controllers/trash_controller.rb
```

If `UnsupportedOperation` is not handled, add it to the same rescue that handles `NotFound`.

- [x] **Step 6: Run the full suite plus the share leg**

```bash
bin/rails test && LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
```

Expected: PASS both, identical counts.

- [x] **Step 7: Mutation-check**

Change `to_root: true` to `to_root: false` in `Chunk#undelete`. Confirm the orphan test goes **RED** with `Sync::Trash::ParentDeleted`. Restore.

- [x] **Step 8: Commit**

```bash
git add app/services/file_layer/chunk.rb app/controllers/trash_controller.rb test/services/file_layer/chunk_test.rb
git commit -m "feat(file-layer): Chunk#undelete goes through the port

Fourth and last metadata verb. Collapses TrashController#restore's branch --
the fourth of CLAUDE.md 14d's five port_writable? copies.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Retire the refusal test and wire in the mutation contract

The old test asserted the *messages* of four refusals that no longer exist. It must become a test of behaviour, and the shared contract from Task 2 must actually run.

**Files:**
- Modify: `test/services/file_layer/chunk_test.rb`
- Modify: `test/services/file_layer/share_test.rb`
- Modify: `test/services/file_layer/s3_test.rb`

- [x] **Step 1: Replace the refusal test**

In `test/services/file_layer/chunk_test.rb`, delete the whole `test "the write path is not chunk mode's — each op refuses, naming its OWN real path"` block **and its preceding comment** (roughly lines 99–135), and put in its place:

```ruby
    # THE BYTE WRITE PATH IS STILL NOT CHUNK MODE'S, and this is the one refusal Stage 2 kept.
    # The four metadata verbs above now go through the port; `write` must never join them,
    # because it takes an IO and would push bytes through Rails, which CLAUDE.md 15 forbids.
    # Chunk uploads are Sync::Commit's two-phase presigned flow -- begin_upload/finalize_upload.
    #
    # NotImplementedError is a ScriptError, NOT a StandardError, so `rescue => e` and ActiveJob's
    # retry_on do not catch it. That is deliberate and load-bearing: the answer must stay loud.
    test "the BYTE write path refuses, naming the two-phase flow" do
      err = assert_raises(NotImplementedError) do
        adapter.write(@user, parent_node_id: nil, name: "x.stl", io: StringIO.new("b"))
      end
      assert_match(/Sync::Commit/, err.message)
      refute_kind_of StandardError, err,
                     "NotImplementedError must stay a ScriptError -- a rescue-based gate would " \
                     "silently not catch it"
    end
```

- [x] **Step 2: Run it**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 3: Include the mutation contract in all three adapter tests**

In `test/services/file_layer/chunk_test.rb`, `share_test.rb` and `s3_test.rb`, add near the top of each test class (beside the existing `include AdapterContract`):

```ruby
    include AdapterMutationContract
```

Each file also needs the two hooks. For **chunk** (`chunk_test.rb`):

```ruby
    # The hooks AdapterMutationContract requires. Chunk's real door for creating a node is the
    # sync engine, so these build nodes the way Sync::Mutation would rather than through a port
    # `write` this adapter does not have.
    def make_file(name:, parent_node_id: nil)
      @user.nodes.create!(node_id: SecureRandom.uuid, parent_node_id:, name:, kind: "file",
                          deleted: false, mtime: 0)
    end

    def make_dir(name:, parent_node_id: nil)
      @user.nodes.find_by(node_id: adapter.mkdir(@user, parent_node_id:, name:).node_id)
    end
```

For **share** (`share_test.rb`) — write through the port, which is share's real door:

```ruby
    def make_file(name:, parent_node_id: nil)
      info = adapter.write(@user, parent_node_id:, name:, io: StringIO.new("bytes"))
      @user.nodes.find_by!(node_id: info.node_id)
    end

    def make_dir(name:, parent_node_id: nil)
      @user.nodes.find_by!(node_id: adapter.mkdir(@user, parent_node_id:, name:).node_id)
    end
```

For **s3** (`s3_test.rb`) — identical bodies to share; both are `port_writable`. Repeat them rather than extracting a shared helper: the whole point of a hook is that each backend answers through its own door, and a shared helper would make one backend's door stand in for the other's.

- [x] **Step 4: Run all three legs**

```bash
bin/rails test test/services/file_layer/
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/file_layer/
```

Expected: PASS. If a contract test fails on one backend only, **do not weaken the contract** — that is a real divergence and the answer is either a capability (as `dir_deletable` was) or a fix in the adapter. Report it rather than editing the assertion.

- [x] **Step 5: Add the seam guard to `architecture_invariants_test.rb`**

This is goal 4's actual enforcement — without it, "the seam is closed" is a claim nothing checks.

```ruby
  # THE MAKER->SYNC SEAM. After Stage 2 the maker layer reaches the sync engine through exactly
  # one door: FileLayer::Chunk. Everything else that mentions Sync:: is either inside the sync
  # engine, inside the v1 sync API, or a reaper job -- all three of which move to the sync repo
  # in Stage 3 and so are not maker-layer code.
  #
  # DERIVED FROM THE TREE, never a hard-coded file list, so a new app/**/maker directory or a new
  # controller is covered the day it is created. The grep -v is load-bearing and not noise: without
  # it the check reports COMMENTS that merely describe the removed coupling, and a proof that
  # cries wolf gets ignored.
  #
  # ASSERTS THE FILE, not just the count. A mutation that keeps the count at 1 while MOVING the
  # reference somewhere else is caught only by the second assertion.
  test "the maker layer reaches the sync engine through FileLayer::Chunk alone" do
    allowed = %r{\Aapp/(services/sync|controllers/v1|jobs/[a-z_]*reaper_job\.rb|services/file_layer/chunk\.rb|services/sync\.rb|channels/)}
    hits = `grep -rln "Sync::[A-Z]" app --include='*.rb'`.split("\n").reject(&:empty?)
    offenders = hits.reject { |f| f.match?(allowed) }.select do |f|
      # A file counts only if it CALLS into Sync:: outside a comment.
      `grep -n "Sync::[A-Z]" #{f}`.lines.any? { |l| !l.match?(/:\s*\d+:\s*#/) }
    end
    assert_empty offenders,
                 "these maker-layer files reach around the FileLayer port into Sync:: -- in " \
                 "remote chunk mode there is no Sync:: in the process to reach: #{offenders}"
  end
```

- [x] **Step 6: Run it and fix any offender it names**

```bash
bin/rails test test/architecture_invariants_test.rb
```

Expected: PASS. If it names a file, that file is a real seam violation this plan missed — fix it the same way (port verb + collapse), or, if it is genuinely sync-repo code, widen `allowed` **with a comment saying why**, never silently.

- [x] **Step 7: Mutation-check the seam guard**

Add `Sync::Commit` to a maker-layer file (e.g. a throwaway line in `app/services/maker/dead_nodes.rb`), confirm the test goes **RED and names that file**, then remove it.

- [x] **Step 8: Commit**

```bash
git add test/
git commit -m "test(file-layer): behaviour over refusal messages, and guard the maker/sync seam

The refusal test asserted the wording of four errors that no longer exist. It
becomes one test of the byte path -- the only refusal Stage 2 keeps -- plus the
shared mutation contract, now running against all three adapters.

architecture_invariants_test gains the seam guard: the maker layer reaches the
sync engine through FileLayer::Chunk alone. Derived from the tree, asserting the
file and not merely a count.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: The byte path

> **THREE THINGS TASK 7'S REVIEW ESTABLISHED, MEASURED AGAINST THE REAL TREE.**
>
> 1. **`files_controller.rb` has FOUR seam hits, not two.** Besides `Sync::Commit.begin`/`.finalize`
>    it carries `rescue Sync::Commit::InvalidManifest` and `rescue Sync::Commit::ChunksMissing`.
>    Moving only the CALLS behind the port leaves the guard **red** on the rescues. The fix is the
>    one `ea9bb50` already set a precedent for with `undelete`'s `ActiveRecord::RecordNotFound`
>    leak: `Chunk#begin_upload`/`#finalize_upload` catch these internally and re-raise through the
>    port's own closed vocabulary, so the controller only ever rescues `FileLayer::*`.
> 2. **The two guards share `library_output.rb`, so they are not as independent as they look.**
>    That file also holds the ONE sanctioned `Storage::ChunkStore.current.put` call, which
>    `architecture_invariants_test.rb`'s chunk-internals test pins with `assert_equal 1, hits.size`.
>    If Task 8 folds the put-missing-chunks step into the new port method, that count drops to
>    **0** and must be updated in the SAME commit. If the put stays the caller's job, it does not.
>    Decide explicitly; do not discover it from a red suite.
> 3. **Emptying `SYNC_SEAM_EXCEPTIONS` is not enough — the guard's own `assert_not_empty` then
>    fires**, telling you to delete the constant and its comment block too. That is deliberate.
>
> Beyond the guard: `begin_upload`/`finalize_upload` are `syncable`-gated and chunk-only, so unlike
> the four metadata verbs they are **not** a verb every adapter answers — share/s3 have no
> two-phase concept at all. Decide and document whether they get refusing stubs or the port stays
> asymmetric. Their return shapes (`{commit_id, node_id, put_urls, missing}` and
> `{version_id, seq}`) do not map onto `FileInfo`, so Task 8 needs its own argued answer on return
> types, the way Task 6 needed one for `delete` vs the rest. And the bytes move browser→storage via
> presigned PUT **between** the two calls, entirely outside any port call — a structural difference
> from all four metadata verbs, which complete atomically in one.
 — `begin_upload` / `finalize_upload` as port verbs

The last two call sites. This does **not** give chunk a byte-taking `write`; it lifts the presigned two-phase pair onto the port so the caller never names `Sync::Commit`.

**Files:**
- Modify: `app/services/file_layer/chunk.rb`
- Modify: `app/services/file_layer/share.rb`
- Modify: `app/services/file_layer/s3.rb`
- Modify: `app/controllers/files_controller.rb` (`#begin_upload`, `#finalize_upload`)
- Modify: `app/services/maker/addons/library_output.rb`
- Test: `test/services/file_layer/chunk_test.rb`

- [x] **Step 1: Read the two existing call sites before writing anything**

```bash
grep -n "Sync::Commit" -B 5 -A 25 app/controllers/files_controller.rb
grep -n "Sync::Commit" -B 5 -A 25 app/services/maker/addons/library_output.rb
```

The port verbs must pass through **exactly** the arguments and return values these two already use — including `verify:` on finalize, which `config/initializers/finalize_verification.rb` controls and which the sync-engine test suites set to 0. Do not change that behaviour here.

- [x] **Step 2: Write the failing test**

Append to `FileLayer::ChunkTest`:

```ruby
    # THE TWO-PHASE FLOW IS A PORT VERB, NOT A BYTE WRITE. The port never sees the bytes: begin
    # returns presigned PUT URLs for the chunks the store is missing, the client PUTs straight to
    # object storage, and finalize records the version. That is what keeps CLAUDE.md 15 true, and
    # it is why `write` still refuses one method above.
    test "begin_upload answers the two-phase flow without taking any bytes" do
      result = adapter.begin_upload(@user, parent_node_id: nil, name: "part.stl",
                                    manifest: [ { hash: "a" * 64, size: 5 } ])
      assert_respond_to result, :[], "begin_upload returns Sync::Commit's own result shape"
      refute_nil result[:commit_id], "a caller needs the commit_id to finalize"
    end
```

- [x] **Step 3: Run test to verify it fails**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: FAIL with `NoMethodError: undefined method 'begin_upload'`.

- [x] **Step 4: Add the verbs to `Chunk`**

In `app/services/file_layer/chunk.rb`, using the exact argument names the two call sites read in Step 1:

```ruby
    # THE TWO-PHASE PRESIGNED FLOW, lifted onto the port so no maker-layer caller names
    # Sync::Commit. It is NOT a byte-taking `write` and must never become one: begin returns
    # presigned PUT URLs, the client PUTs to object storage directly, finalize records the
    # version. Bytes touch neither this process nor -- in remote mode -- the sync server's.
    # That is CLAUDE.md 15, and it is the whole reason `write` above still refuses.
    # The keyword list is Sync::Commit.begin's OWN, verbatim -- an earlier draft of this plan
    # guessed a shorter one (user/parent_node_id/name/manifest) and was wrong. Read the two real
    # call sites before writing this signature; they are the source of truth, not this plan.
    def begin_upload(user, device:, commit_id:, node_id:, parent_node_id:, name:,
                     base_version_id:, size:, mtime:, manifest:)
      Sync::Commit.begin(user:, device:, commit_id:, node_id:, parent_node_id:, name:,
                         base_version_id:, size:, mtime:, manifest:)
    end

    # `verify:` is passed through rather than defaulted here. It is a DEPLOYMENT setting
    # (config/initializers/finalize_verification.rb) that the sync-engine suites turn off because
    # they move bytes through SharedDirIO, which the server's store cannot see. Defaulting it in
    # the port would silently override that.
    def finalize_upload(user, commit_id:, verify: true)
      version, seq = Sync::Commit.finalize(user:, commit_id:, verify:)
      LibraryChannel.broadcast_change(user, seq)
      [ version, seq ]
    end
```

If Step 1 showed `Sync::Commit.begin` taking different or additional keywords, use those — the call sites are the source of truth, not this plan.

- [x] **Step 5: Refuse the verbs on share and s3**

Both are `port_writable` and use `write`; the two-phase flow is meaningless for them. Add to each of `share.rb` and `s3.rb`:

```ruby
    # This backend is port_writable: its uploads POST the bytes to #write. The two-phase presigned
    # flow exists only where the sync engine owns the write path. Refusing keeps the 501 a
    # capability gate BEFORE the call (`syncable`) rather than a rescue -- NotImplementedError is
    # a ScriptError and `rescue => e` does not catch it.
    def begin_upload(_user, parent_node_id: nil, name: nil, manifest: nil)
      raise NotImplementedError, "#{self.class.name} is port_writable -- uploads go through #write"
    end

    def finalize_upload(_user, commit_id: nil, verify: true)
      raise NotImplementedError, "#{self.class.name} is port_writable -- uploads go through #write"
    end
```

- [x] **Step 6: Run test to verify it passes**

```bash
bin/rails test test/services/file_layer/chunk_test.rb
```

Expected: PASS.

- [x] **Step 7: Point both call sites at the port**

In `app/controllers/files_controller.rb`, replace the `Sync::Commit.begin(...)` and `Sync::Commit.finalize(...)` calls with `FileLayer.current.begin_upload(...)` and `FileLayer.current.finalize_upload(...)`, keeping every argument identical.

**Keep the `rescue Sync::Commit::ChunksMissing` and `rescue Sync::Commit::InvalidManifest` arms as they are for now.** Error classes are a separate concern from the call path, and moving them is Stage 3's job — the seam guard in Task 7 matches `Sync::[A-Z]` and will flag these, so add them to that test's `allowed` list with a comment saying they are error-class references awaiting Stage 3, and confirm the guard still passes.

Do the same in `app/services/maker/addons/library_output.rb`. Note §14c: `LibraryOutput` is the **one** legitimate direct `Storage::ChunkStore` call in the maker layer, and that stays — only the `Sync::Commit` calls move to the port.

- [x] **Step 8: Run everything**

```bash
bin/ci
```

Expected: all 8 gates PASS. The three test legs must report **identical counts** (§15).

- [x] **Step 9: Mutation-check**

Change `finalize_upload` to drop its `LibraryChannel.broadcast_change` call. Confirm an upload test goes RED. Restore. If nothing goes red, add an assertion on `head_seq` to the relevant upload test — a broadcast nobody asserts is a broadcast that can be deleted silently.

- [x] **Step 10: Commit**

```bash
git add app/ test/
git commit -m "feat(file-layer): the two-phase upload flow becomes a port verb

begin_upload/finalize_upload lift Sync::Commit's presigned flow onto the port so
no maker-layer caller names it. NOT a byte-taking write and must never become
one: begin returns presigned PUT URLs, the client PUTs to object storage, and
bytes touch neither process. That is CLAUDE.md 15, and the reason Chunk#write
still refuses.

Closes the last two of the six maker->sync call sites.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Documentation

Per CLAUDE.md §15, `docs/STATUS.md` is part of the work, in the same branch and the same PR — never a tidy-up afterwards.

**Files:**
- Modify: `CLAUDE.md` (§14a, §14d, §4, §8)
- Modify: `docs/STATUS.md`

- [x] **Step 1: Update CLAUDE.md §14a**

Replace the bullet beginning **"`Chunk` refuses writes PER-OP, naming the real door each time"** with:

```
- **`Chunk` ANSWERS the four metadata verbs and refuses only the BYTE write.** Until Stage 2 it
  refused `write`/`delete`/`move`/`mkdir` per-op, each naming its real door, because the maker
  layer branched around the port. It no longer can: in remote chunk mode there is no `Sync::*` in
  the process to branch into. So `delete` → `Sync::SubtreeDelete.call` (**never**
  `Sync::Mutation.apply(op: "delete")`, which tombstones only the node it is handed and
  **orphans descendants**), `move`/`mkdir` → `Sync::Mutation.apply`, `undelete` →
  `Sync::Trash.restore(to_root: true)`. **`write` still refuses**, and must: it takes an IO, and a
  server-side byte write would push bytes through Rails (§15). Chunk uploads are the port's
  `begin_upload`/`finalize_upload` — the two-phase presigned flow, where the port never sees a byte.
```

- [x] **Step 2: Add the `dir_deletable` bullet to §14a**

Immediately after the bullet above:

```
- **`dir_deletable` IS NOT `syncable`, and it exists because `FilesController#destroy` stopped
  branching.** Chunk true (SubtreeDelete cascades); share false (children stranded at paths that
  no longer exist while their bytes sit in `.trash`, which the scan refuses to look at); s3 false
  (no directory, no rename — a dir node's key does not exist). The two agree with `syncable` on
  all three backends today; that is three samples, not an identity, and encoding such a
  coincidence once already (`is_a?(Share)`) is the entire reason `scannable` exists.
```

- [x] **Step 3: Update §14d's count**

Replace **"The `port_writable?` two-door branch is written out FIVE times, not three"** with:

```
- **The `port_writable?` two-door branch is now written out ONCE, and the four that went are the
  precedent for refusing a fifth.** It was five (`Maker::LibraryFolder#mkdir`,
  `FilesController#destroy`, `TrashController#restore`, `Maker::Addons::LibraryOutput.write`,
  `Maker::MoveNode`) until Stage 2 gave `FileLayer::Chunk` the four metadata verbs; the four
  callers that were only branching because the port refused now just call the port.
  **`Maker::Addons::LibraryOutput` keeps its branch** and has the argument the others lacked: the
  two-phase presigned upload genuinely IS a different flow from POSTing bytes, not the same verb
  behind two doors. A NEW copy needs that same argument.
```

- [x] **Step 4: Land the two corrections the design found**

In §4's Mount row, delete the parenthetical **"(no `client/fs-fskit` crate on `main`)"** — the crate exists (`f40c101`). Keep the rest of the sentence, which is still true: FSKit is not a shipping mount path and needs a paid Apple Developer membership.

In §8, replace the pairing-code sentence with a description of `POST /v1/devices/login` (email + password → device token), noting that pairing codes were the earlier mechanism. The endpoint's own comment in `config/routes.rb` says it *"Replaces the pairing-code flow."*

- [x] **Step 4b: Sweep the comments that name the deleted branch methods**

Collapsing the four callers deletes `Maker::LibraryFolder#chunk_mkdir`/`#port_mkdir`,
`Maker::MoveNode#chunk_move`/`#port_move` and the inline branches in `FilesController#destroy` and
`TrashController#restore`. Comments in OTHER files still name them. Task 3 found these five and
more will have accumulated by Task 8:

```bash
grep -rn "chunk_mkdir\|port_mkdir\|chunk_move\|port_move" app/ test/ docs/ CLAUDE.md
```

Known at the time of writing: `app/controllers/library_browse_controller.rb:39`,
`app/services/library/reserved_names.rb:9`, `test/integration/web/library_browse_test.rb:128,149`,
`test/jobs/library/scan_job_test.rb:286`. Nothing executable depends on these names — they are
prose — which is exactly why nothing goes red and why they must be swept deliberately. Update each
to describe what the code does NOW; do not simply delete the sentence if it was making a point
worth keeping.

- [x] **Step 5: Write the STATUS.md entry**

Add ONE entry for this arc (amend it in later stages, never append a second — §15). Include: the six call sites closed, the four `port_writable?` copies collapsed, `dir_deletable`'s justification, the mutation-checks performed and what each one proved, and a pointer to the design doc for Stages 1, 3 and 4.

- [x] **Step 6: Verify the docs are honest**

```bash
grep -rn "port_writable" CLAUDE.md | head -20
grep -c "FIVE times" CLAUDE.md
```

Expected: the second command prints `0`. Then confirm the real count in the code matches what §14d now claims:

```bash
grep -rn "port_writable" app/ --include='*.rb' --include='*.erb' | grep -v "capabilities.rb" | grep -v ":[0-9]*: *#"
```

The only remaining branch should be `Maker::Addons::LibraryOutput` (plus `require_capability!` gates and views picking an upload form, which §14d already excludes on purpose).

- [x] **Step 7: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs: record Stage 2 -- the port widened, four branches collapsed

CLAUDE.md 14a: Chunk answers the four metadata verbs and refuses only the byte
write; adds dir_deletable and why it is not syncable.
CLAUDE.md 14d: the port_writable? branch count goes five -> one, with the
argument a new copy would have to make.

Also lands two corrections the design measurement found: fs-fskit does exist on
main, and devices/login has replaced the pairing-code flow.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Done when — all five verified at close-out, not assumed

*(criterion 2's grep and criterion 3's suite were re-run against `main` after the merge; criteria
1, 4 and 5 are evidenced by the CI run on PR #200 and by the mutation-check output recorded in each
task's commit message.)*

- [x] `bin/ci` is green — all 8 gates, three test legs reporting identical counts.
- [x] `grep -rn "Sync::[A-Z]" app/services/maker app/controllers/files_controller.rb app/controllers/trash_controller.rb` returns only comments and the error-class rescues noted in Task 8 Step 7.
- [x] `architecture_invariants_test.rb`'s seam guard passes **and has been mutation-checked**.
- [x] Every guard written in this plan has been broken once and seen to go red.
- [x] CLAUDE.md §14a/§14d/§4/§8 and `docs/STATUS.md` updated in this same branch.
