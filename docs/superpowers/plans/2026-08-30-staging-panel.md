# Staging Panel Implementation Plan

> **For agentic workers:** execution follows **`.claude/commands/execute-plan.md`** — batch by FILE,
> parallel where independent, one capped quality review per task.

**Goal:** The commit box gains a second, unchecked group listing everything else git sees, so a maker
can commit work they did outside tinkerex — including deletions.

**Spec:** `docs/superpowers/specs/2026-08-30-staging-panel-design.md`. Bare `§` is CLAUDE.md; the
spec's sections are **part N**.

---

## Before you start

- [ ] Read the spec, especially **part 1** (the safety property this knowingly gives up) and
      **part 4** (why the deletion risk is the `index.clear` shape).
- [ ] Read `docs/invariants/git-editing.md` — 18 rules, all binding here.
- [ ] **No users fixture**: `User.create!(email: "p-#{SecureRandom.hex(4)}@example.com")`.
- [ ] **`Library::ScanJob#perform` takes keyword args**: `perform(user_id:, root: nil)`.
- [ ] **Rugged rejects `ActiveSupport::TimeWithZone`**; `Repository#status` requires a block;
      `SORT_DATE` does not order within one second (the fixture already handles this).
- [ ] Commit BEFORE mutating; restore from a byte-exact `cp` snapshot, never `git checkout --`.

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share DATABASE_URL=sqlite3:storage/test-s.sqlite3 bin/rails test <file>
```

---

## Tasks 1 and 2 are independent — run them in parallel

They touch disjoint files. Task 3 needs both.

---

## Task 1: `#full_status`, and splitting `:deleted` from `:missing`

**Files:** modify `app/services/maker/git/local_repo.rb`, `test/services/maker/git/local_repo_test.rb`,
`test/support/git_repo_fixture.rb`.

- [ ] **Step 1: A fixture carrying all five states at once**

One repository, five states — added, modified, deleted, clutter, ignored — so the grouping is
provable in a single pass rather than in five fixtures that drift apart.

```ruby
  # ALL FIVE STATES IN ONE REPOSITORY. Five separate fixtures would let the groups drift: a change
  # that quietly reclassifies clutter as an ordinary add passes four of them.
  def make_repo_with_every_state!(name: "mixed")
    root = make_repo!(name:, files: { "kept.txt" => "same\n", "edited.txt" => "before\n",
                                      "doomed.txt" => "bye\n" },
                      gitignore: "secret.log\n")
    dir = File.join(library_root, name)
    File.write(File.join(dir, "edited.txt"), "after\n")   # modified
    File.write(File.join(dir, "fresh.txt"), "new\n")      # added
    File.delete(File.join(dir, "doomed.txt"))             # deleted
    File.write(File.join(dir, ".DS_Store"), "\x00clutter") # OS clutter
    File.write(File.join(dir, "secret.log"), "hidden\n")  # ignored
    Library::ScanJob.new.perform(user_id: @user.id)
    root
  end
```

- [ ] **Step 2: Write the failing tests**

```ruby
  test "full_status reports every non-ignored path with its state" do
    root = make_repo_with_every_state!
    rows = Maker::Git::LocalRepo.open(@user, root).full_status.rows.to_h { |r| [ r.path, r.state ] }

    assert_equal :modified, rows["edited.txt"]
    assert_equal :added,    rows["fresh.txt"]
    assert_equal :deleted,  rows["doomed.txt"]
    assert_equal :added,    rows[".DS_Store"]      # clutter is a state-less fact; grouping is the VIEW's job
    assert_nil              rows["secret.log"]      # .gitignore'd paths never appear
    assert_nil              rows["kept.txt"]        # unchanged paths are not "changes"
  end

  # THE SPLIT. Conflated, either every stale RepoEdit row becomes a committable deletion or every
  # real deletion is silently dropped — and both are silent.
  test "a path in HEAD and gone from the worktree is deleted, and committable" do
    root = make_repo_with_every_state!
    row = Maker::Git::LocalRepo.open(@user, root).full_status.rows.find { |r| r.path == "doomed.txt" }

    assert_equal :deleted, row.state
    assert row.committable?
  end

  test "a path in neither HEAD nor the worktree is missing, and NOT committable" do
    root = make_repo_with_every_state!
    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "never-existed.txt" ]).fetch("never-existed.txt")

    assert_equal :missing, row.state
    refute row.committable?
  end

  test "full_status is capped and says how many it did not list" do
    root = make_repo!(files: { "a.txt" => "x\n" })
    12.times { |i| File.write(File.join(library_root, "demo", "f#{i}.txt"), "y\n") }
    Library::ScanJob.new.perform(user_id: @user.id)

    s = Maker::Git::LocalRepo.open(@user, root).full_status(limit: 5)

    assert_equal 5, s.rows.size
    assert_operator s.truncated_count, :>=, 1
  end
```

- [ ] **Step 3: Run and watch fail.** Expected: `NoMethodError: undefined method 'full_status'`.

- [ ] **Step 4: Implement**

```ruby
      FullStatus = Data.define(:rows, :truncated_count)

      DEFAULT_STATUS_LIMIT = 500

      # Everything git sees as changed, capped. The counterpart to #status_for, which answers about
      # paths a caller names; this one ENUMERATES.
      #
      # CAPPED FOR THE SAME REASON THE HISTORY WALK IS, and the number is not decoration: every row
      # costs a content comparison against HEAD's blob, and over CIFS that is ~15 ms per object
      # (the history spec's measurement). `truncated_count` reaches the view — a truncated list that
      # does not say so is the same lie as a capped walk reporting "no history".
      #
      # `.gitignore`d PATHS ARE DROPPED HERE, NOT IN THE VIEW. git will not commit them without
      # `-f`, so offering them is offering something that cannot happen.
      def full_status(limit: DEFAULT_STATUS_LIMIT)
        return FullStatus.new(rows: [], truncated_count: 0) unless committable?

        paths = []
        rugged.status { |path, flags| paths << path unless flags == [ :ignored ] || flags.include?(:ignored) }
        paths.sort!

        rows = paths.first(limit).map { |rel| row_for(rel) }.reject { |r| r.state == :unchanged }
        FullStatus.new(rows:, truncated_count: [ paths.size - limit, 0 ].max)
      end
```

and in `#row_for`, replace the single `:missing` return:

```ruby
        # TWO SITUATIONS, NOT ONE, AND CONFLATING THEM IS SILENT EITHER WAY. In HEAD and gone from
        # the worktree is a real DELETION the maker may want to commit; in neither is a stale
        # maker_repo_edits row the commit box already drops. One `:missing` for both means either
        # every stale row becomes a committable deletion, or every real deletion vanishes.
        unless File.file?(abs)
          in_head = !unborn? && !head_blob_for(rel).nil?
          return Row.new(path: rel, state: in_head ? :deleted : :missing, additions: 0, deletions: 0)
        end
```

and extend `Row#committable?` to include `:deleted`.

- [ ] **Step 5: Run** — expected PASS.

- [ ] **Step 6: Mutation checks, ACTUAL OUTPUT pasted**
  1. Collapse `:deleted` back into `:missing` → the deletion test goes RED.
  2. Stop filtering `:ignored` → `secret.log` appears; RED.
  3. Drop `truncated_count` (return 0 always) → the cap test goes RED.

- [ ] **Step 7: Commit.**

---

## Task 2: deletions in `CommitPaths`

**Files:** modify `app/services/maker/git/commit_paths.rb`,
`test/services/maker/git/commit_paths_test.rb`.

- [ ] **Step 1: Write the failing tests — the second one is the whole point**

```ruby
  test "a selected deleted path is removed from the new tree" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "drop a")

    tree = rugged_at.head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("a.txt") }
    assert_equal "two\n", rugged_at.lookup(tree.path("b.txt")[:oid]).content
  end

  # THE ONE THAT MATTERS. The danger is not dropping the entry you selected — it is dropping one
  # you did not. Same shape as index.clear: right about the files it was asked about, wrong about
  # everything else, and green on every bytes-oriented assertion.
  test "an UNSELECTED deleted path survives in the new tree with HEAD's bytes" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "b.txt" ], message: "only b")

    tree = rugged_at.head.target.tree
    assert_equal "one\n", rugged_at.lookup(tree.path("a.txt")[:oid]).content,
                 "a.txt was deleted on disk but NOT selected; the commit must keep HEAD's copy"
  end

  test "a nested deletion prunes only its own entry" do
    root = make_repo!(files: { "src/a.txt" => "one\n", "src/b.txt" => "two\n" })
    File.delete(File.join(library_root, "demo", "src", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "src/a.txt" ], message: "drop nested")

    tree = rugged_at.head.target.tree
    assert_raises(Rugged::TreeError) { tree.path("src/a.txt") }
    assert_equal "two\n", rugged_at.lookup(tree.path("src/b.txt")[:oid]).content
  end

  test "the committed deletion reports clean to git afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.delete(File.join(library_root, "demo", "a.txt"))

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "drop a")

    assert_empty git_statuses(rugged_at).select { |rel, _| rel == "a.txt" }
  end
```

- [ ] **Step 2: Run and watch fail** — the deletion path currently raises from
      `Rugged::Blob.from_workdir` on a file that is not there.

- [ ] **Step 3: Implement.** In `#stage`, before reading bytes:

```ruby
        # A SELECTED PATH THAT IS GONE FROM THE WORKING TREE IS A DELETION, not an error. The rule
        # is unchanged -- HEAD's tree with the selected paths REPLACED -- and "replaced with
        # nothing" is what a maker who deleted the file is asking for.
        #
        # ONLY THE SELECTED PATH. Everything else in HEAD's tree is carried through untouched,
        # which is the invariant this method has always had and the one a deletion is most likely
        # to break: see the unselected-deletion test, which is index.clear's shape one level down.
        return remove(builder, rel, segments) unless File.exist?(File.join(@local.workdir, rel))
```

with a `#remove` that recurses like `#stage`, deleting the leaf and pruning a parent tree that
becomes empty. `#refresh_index` takes `index.remove(rel)` for those paths instead of `index.add`.

- [ ] **Step 4: Run** — expected PASS.

- [ ] **Step 5: Mutation checks, ACTUAL OUTPUT pasted**
  1. Build the tree from the working directory instead of HEAD (`index.clear` + `add_all`) →
     the unselected-deletion test AND the existing unselected-modification test both go RED.
  2. Remove **every** absent path rather than only selected ones → the unselected-deletion test
     goes RED. *This is the mutation the task exists for; if it passes, the test is wrong.*
  3. Skip the index update for deletions → "reports clean to git afterwards" goes RED.

- [ ] **Step 6: Commit.**

---

## Task 3: the box, in three groups

**Files:** modify `app/controllers/repo_commits_controller.rb`,
`app/views/repo_commits/show.html.erb`, `test/integration/web/repo_edit_flow_test.rb`.

Needs Tasks 1 and 2.

- [ ] **Step 1:** `#show` gains the wider list. Reconcile as today for the pre-checked group; then
      `full_status` for the rest, partitioned into **other** and **clutter** by
      `Library::OsClutter.ignore?(path)` — **reuse that predicate, never a second list of names**
      (§14b: it is composed once and copied nowhere).

- [ ] **Step 2:** The view renders three `<section>`s: *Edited in tinkerex* (checked), *Other
      changes* (unchecked, inside a `<details>`), *OS clutter* (unchecked, labelled "tinkerex never
      creates these"). Show `truncated_count` when non-zero. Binary rows say "binary — no diff" and
      offer no diff mount. Add the rename note where any `:deleted` and `:added` coexist.

- [ ] **Step 3:** `#create` needs no change — it already intersects submitted paths with
      committable rows. **Verify that by test rather than assuming**, including that a submitted
      path which is *not* in any group is ignored rather than committed.

- [ ] **Step 4: Tests** — the three groups appear with the right membership; only the first is
      checked; `.gitignore`d never appears; clutter appears unchecked; committing one path from
      *Other changes* leaves the rest untouched; a submitted path outside the groups is ignored.

- [ ] **Step 5: Mutation checks, ACTUAL OUTPUT pasted**
  1. Pre-check the "Other changes" group → the only-first-group-checked test goes RED.
     **This guards the property part 1 knowingly reduced.**
  2. Filter clutter out entirely instead of labelling it → the clutter test goes RED.
  3. Use a literal `%w[.DS_Store]` instead of `Library::OsClutter` → assert the predicate is the
     one used (add a name `OsClutter` covers that the literal misses, e.g. `Thumbs.db`).

- [ ] **Step 6:** All three legs, identical run counts. **Commit.**

---

## Task 4: the browser

**Files:** modify `app/javascript/controllers/` (the commit box's controller, if any) and
`app/assets/stylesheets/application.css`; create `test/system/repo_staging_test.rb`.

- [ ] Expand/collapse for *Other changes*; a **Select all in this group** control that is
      per-group and never global — a global one is how you commit clutter by accident.
- [ ] A system test: expand the group, check one path, commit, and assert with rugged that the
      others are untouched in the resulting tree. The box is a form over a working tree the maker
      is also using, so this must exercise the real page.
- [ ] Mutation: make "Select all" global → a test asserting clutter stays unchecked goes RED.
- [ ] **Commit.**

---

## Task 5: invariants

**Files:** modify `docs/invariants/git-editing.md`. Parallel with Task 4.

- [ ] Add the spec's part 7 rules (five), each with what breaks if undone. The first —
      *only the tinkerex-edited group is checked on load* — needs the reasoning from part 1 beside
      it: this is a safety property deliberately reduced, and a change that pre-checks the wider
      group removes the reduction while leaving every other test green.
- [ ] **Do not touch CLAUDE.md.** §14l already points here; the ceiling is at 1,355 with no headroom.
- [ ] `bin/rails test test/docs_hygiene_test.rb` must pass. **Commit.**

---

## Before the PR

- [ ] Bare `bin/ci`; read the three legs' counts and confirm they are identical (§15).
- [ ] `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`.
- [ ] Open the PR; `bin/log arc --from-pr <n>`. **Do not merge, do not deploy.**
- [ ] Note in the PR that the real-library gate (spec part 6) needs a deploy and has not run.
