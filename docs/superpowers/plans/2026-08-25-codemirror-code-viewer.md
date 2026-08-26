# CodeMirror Source Viewer + Git-Safe Library — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the library safe for a git repo, put source code in the file-type vocabulary, and replace the plain-`<pre>` text preview with a read-only CodeMirror 6 viewer.

**Architecture:** Four pieces, viewer last. A new `Library::RepoMetadata` predicate names `.git` once and is consulted from five places. The `.git` **directory node stays indexed as a marker** while its **contents** are skipped — that marker is what lets `Maker::AttachToProject#refusal_for` answer "is this file inside a working tree", identically on all three backends. Editing/save-back is deliberately out of scope.

**Tech Stack:** Rails 8, Hotwire/Stimulus, importmap + hand-vendored ESM, CodeMirror 6 (MIT) bundled once with esbuild, minitest.

**Spec:** `docs/superpowers/specs/2026-08-25-codemirror-code-viewer-design.md`

**PROGRESS (2026-08-25):** **Task 2 is LANDED** (`2217257`), and with it the part of Task 1 it
needed — `Library::RepoMetadata` exists holding **only `DIR_NAME`**. Its `marker?` / `internal?` /
`marker_prefix` predicates were deliberately NOT written, because Task 2's rule queries the database
by name and has no path to test; shipping them early would be uncalled code. **Task 3 adds `marker?`
and `marker_prefix`, Task 4 adds `internal?`, each TDD in the task that first calls it** — write
Task 1's test cases for a predicate at the point you add it. Task 1's own step list is otherwise
complete; skip it and start at Task 3.

**Read before starting:** `CLAUDE.md` §14a (the FileLayer port), §14b (the library scan — especially THE SKIP-LIST BLIND SPOT), §14d (the maker web layer), §14f (project-folder intake), §15 (working agreements — every guard gets mutation-checked).

---

## File structure

| file | responsibility | task |
|---|---|---|
| `app/services/library/repo_metadata.rb` | **create** — the one definition of `.git`: is this the marker, is this path inside it, what prefix is the marker for a key | 1 |
| `test/services/library/repo_metadata_test.rb` | **create** — pins the predicate itself | 1 |
| `app/services/maker/attach_to_project.rb` | **modify** — a fourth refusal, `:in_working_tree`, plus a per-instance ancestor cache | 2 |
| `test/services/maker/attach_to_project_test.rb` | **modify** — the refusal, unscoped, and its cache | 2 |
| `test/services/maker/project_intake_test.rb` | **modify** — the sweep leaves a repo alone (the shredder fix, end to end) | 2 |
| `app/services/library/scanner.rb` | **modify** — index the `.git` dir node, do not push it on the walk stack | 3 |
| `app/services/library/s3_observer.rb` | **modify** — emit the `.git` prefix as a dir observation, drop keys beneath it | 3 |
| `app/services/file_layer/share.rb`, `app/services/file_layer/s3.rb` | **modify** — `observable!` refuses a destination inside `.git` | 4 |
| `app/services/library/reserved_names.rb` | **modify** — a door may not MINT `.git` | 4 |
| `lib/tasks/library.rake` | **modify/create** — the one-time migration that removes nodes beneath `.git` | 5 |
| `app/models/maker/file_attachment.rb` | **modify** — the `code` role and its extensions | 6 |
| `app/services/maker/project_folders.rb` | **modify** — `code` → `code` folder | 6 |
| `app/controllers/files_controller.rb` | **modify** — derive the `:text` set from the one table instead of a second inline list | 6 |
| `vendor/javascript/codemirror.js` | **create** — the single pre-built bundle | 7 |
| `bin/build-codemirror` | **create** — reproduces the bundle byte-for-byte | 7 |
| `test/ci_hygiene_test.rb` | **modify** — forbid per-package `@codemirror/*` pins | 7 |
| `app/javascript/controllers/codeview_controller.js` | **create** — replaces `textpreview` | 8 |
| `app/javascript/lib/codemirror_languages.js` | **create** — ext→language table + the `gcode`/`scad` stream modes | 8 |
| `app/javascript/controllers/textpreview_controller.js` | **delete** — superseded | 8 |
| `app/views/files/show.html.erb` | **modify** — the `:text` branch | 8 |

---

## Task 1: `Library::RepoMetadata` — one definition of `.git`

**Why first:** every later task consults it. Defining `.git` in five places is the exact drift `Library::OsClutter`'s header exists to prevent.

**Files:**
- Create: `app/services/library/repo_metadata.rb`
- Test: `test/services/library/repo_metadata_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/library/repo_metadata_test.rb`:

```ruby
require "test_helper"

module Library
  # The one definition of `.git`, and the ONE ASYMMETRY that makes this design work: the marker
  # directory is observable and indexed, everything BENEATH it is neither observed nor writable.
  # Collapse the two and either the working-tree marker disappears (so
  # Maker::AttachToProject's :in_working_tree has nothing to detect) or the repo's objects come
  # back into the catalog. Both halves are pinned here.
  class RepoMetadataTest < ActiveSupport::TestCase
    test "the marker is the directory named .git, as a LEAF name" do
      assert RepoMetadata.marker?(".git")
      assert_not RepoMetadata.marker?(".gitignore")
      assert_not RepoMetadata.marker?("git")
      assert_not RepoMetadata.marker?("a/.git"), "marker? takes a leaf, never a path"
    end

    test "internal? is STRICTLY BENEATH .git — the marker itself is not internal" do
      assert_not RepoMetadata.internal?(".git"), "the marker is observed, so it is not internal"
      assert_not RepoMetadata.internal?("firmware/.git")

      assert RepoMetadata.internal?(".git/config")
      assert RepoMetadata.internal?("firmware/.git/objects/ab/cdef")
      assert RepoMetadata.internal?("a/b/.git/HEAD")
    end

    test "a file merely NAMED like git metadata is not internal" do
      assert_not RepoMetadata.internal?(".gitignore")
      assert_not RepoMetadata.internal?("firmware/.gitmodules")
      assert_not RepoMetadata.internal?("notes/git/todo.txt")
    end

    test "marker_prefix returns the path up to and including .git, or nil" do
      assert_nil RepoMetadata.marker_prefix("firmware/main.cpp")
      assert_equal ".git", RepoMetadata.marker_prefix(".git")
      assert_equal ".git", RepoMetadata.marker_prefix(".git/config")
      assert_equal "firmware/.git", RepoMetadata.marker_prefix("firmware/.git/objects/ab/cdef")
    end

    test "the OUTERMOST .git wins, so a repo inside a repo cannot hide one" do
      assert_equal "a/.git", RepoMetadata.marker_prefix("a/.git/modules/b/.git/HEAD")
    end

    test "non-strings answer false rather than raising" do
      assert_not RepoMetadata.marker?(nil)
      assert_not RepoMetadata.internal?(nil)
      assert_nil RepoMetadata.marker_prefix(nil)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/library/repo_metadata_test.rb
```

Expected: every test errors with `NameError: uninitialized constant Library::RepoMetadata`.

- [ ] **Step 3: Write the implementation**

Create `app/services/library/repo_metadata.rb`:

```ruby
module Library
  # Where a git repository keeps its own state, and the ONE place `.git` is spelled.
  #
  # THE ASYMMETRY IS THE DESIGN, and it is the opposite of every other skip in this codebase.
  # Scanner::TRASH_PREFIX and Library::OsClutter skip the ENTRY — the observers never look at it,
  # so no node exists for it at all. This one skips the CONTENTS and KEEPS THE ENTRY:
  #
  #   .git            observed, indexed, one dir node   <- the marker
  #   .git/**         never observed, never writable    <- the contents
  #
  # Two things depend on keeping the marker, and both break silently without it:
  #
  #   1. Maker::AttachToProject's :in_working_tree refusal asks "does an ancestor of this file
  #      have a live child named .git". Skip the marker and there is nothing to ask, and the
  #      intake sweep goes back to filing a repo's root files away by category — README.md into
  #      docs/, main.py into other/ — which git sees as a delete plus an untracked add.
  #   2. On chunk_remote the `nodes` table MIRRORS the sync server's tree, and the desktop client
  #      syncs .git whether this app likes it or not (CLAUDE.md §14j — what that server indexes is
  #      another repo's decision). A marker present on all three backends makes the working-tree
  #      question answerable uniformly instead of one condition having two answers (§14a).
  #
  # THE CONTENTS HALF OBEYS OsClutter'S LAW: a name the observers skip must ALSO be refused as a
  # write destination, or a write lands a live node at a path no observation can ever pair,
  # whose tombstone trips the mass-deletion guard and refuses that scan and every scan after it,
  # permanently. That is `internal?`, consulted by both FileLayer::Share#observable! and
  # FileLayer::S3#observable!. Adding a skip here without adding the refusal is shipping the
  # fifth wedge.
  #
  # SCOPE: git only. `.svn`, `.hg` and friends are deliberately absent — adding one is a real
  # indexing change and a new write refusal, the same explicit decision OsClutter's header
  # demands, not a net to widen on a hunch.
  module RepoMetadata
    DIR_NAME = ".git".freeze

    # Is this LEAF name the marker directory itself? Takes a leaf, never a path — callers that
    # hold a path use #internal? or #marker_prefix. Non-strings answer false rather than raising:
    # a door's input is JSON a browser bundle sent, and a nil must reach that door's own routine
    # refusal instead of a NoMethodError 500 (the rule Library::ReservedNames states).
    def self.marker?(name)
      name.is_a?(String) && name == DIR_NAME
    end

    # Is `rel` STRICTLY BENEATH a `.git` segment? False for the marker itself — that node is
    # observed, and answering true here would make the observers skip the very marker the
    # refusal needs. `.gitignore` is an ordinary file: this matches whole segments, never
    # prefixes.
    def self.internal?(rel)
      idx = segment_index(rel)
      !idx.nil? && idx < rel.split("/").length - 1
    end

    # The path up to and INCLUDING the first `.git` segment, or nil when there is none. The S3
    # observer uses it to emit one dir observation for a repo whose keys it is dropping — S3 has
    # no directories, so the marker has to be synthesized from the keys beneath it or it would
    # not exist there at all.
    #
    # OUTERMOST WINS (`index`, not `rindex`): a submodule's `a/.git/modules/b/.git` must resolve
    # to `a/.git`, so the whole outer subtree is dropped rather than only the inner one.
    def self.marker_prefix(rel)
      idx = segment_index(rel)
      idx && rel.split("/")[0..idx].join("/")
    end

    def self.segment_index(rel)
      return nil unless rel.is_a?(String)

      rel.split("/").index(DIR_NAME)
    end
    private_class_method :segment_index
  end
end
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
bin/rails test test/services/library/repo_metadata_test.rb
```

Expected: PASS, 6 runs, 0 failures.

- [ ] **Step 5: Mutation-check the predicate (§15 — a guard that has never failed has not been shown to work)**

Change `internal?` to use `<=` instead of `<` (which would make the marker itself "internal", the bug that deletes the marker). Re-run the test.

Expected: FAIL on `internal? is STRICTLY BENEATH .git`. **Restore the `<`** and confirm green again.

- [ ] **Step 6: Commit**

```bash
git add app/services/library/repo_metadata.rb test/services/library/repo_metadata_test.rb
git commit -m "Library::RepoMetadata: one definition of .git, marker kept, contents skipped"
```

---

## Task 2: `:in_working_tree` — stop the intake sweep shredding repos

**Why now:** this is a live bug, independent of the viewer. `Maker::AttachToProject#refusal_for` has three rules and none knows what a working tree is, so a repo cloned at `Projects/<slug>/` has its root files filed away by category on every sweep.

**Files:**
- Modify: `app/services/maker/attach_to_project.rb` (the header rule list, `#refusal_for`, two new private methods)
- Test: `test/services/maker/attach_to_project_test.rb`, `test/services/maker/project_intake_test.rb`

- [ ] **Step 1: Write the failing test for the refusal itself**

Append inside `class AttachToProjectTest` in `test/services/maker/attach_to_project_test.rb`:

```ruby
    # --- :in_working_tree ---------------------------------------------------------
    #
    # UNSCOPED, unlike :attached_elsewhere, and the asymmetry is deliberate. A refusal does not
    # mean "refuse the attachment" — #call returns `relocation: (move(node) if refusal.nil?)`, so
    # it means ATTACH THE ROW AND LEAVE THE BYTES WHERE THEY ARE, which is the right answer for a
    # file inside a repo at every one of refusal_for's four callers. :attached_elsewhere needed
    # `within_own_folder:` because its stated reason is positional and stopped applying to one
    # caller; "do not move a file out from under git" has no such exception.
    test "a file inside a working tree is refused, at any depth" do
      repo = dir("firmware")
      dir(".git", parent: repo.node_id)
      src = file("main.cpp", parent: repo.node_id)

      nested = dir("src", parent: repo.node_id)
      deep = file("util.cpp", parent: nested.node_id)

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      assert_equal :in_working_tree, policy.refusal_for(src)
      assert_equal :in_working_tree, policy.refusal_for(deep)
    end

    test "the refusal is NOT scoped by within_own_folder: — it holds for the sweep too" do
      repo = dir("firmware")
      dir(".git", parent: repo.node_id)
      src = file("main.cpp", parent: repo.node_id)

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      assert_equal :in_working_tree, policy.refusal_for(src, within_own_folder: true),
                   "ProjectIntake#place passes within_own_folder: true; the repo rule must survive it"
    end

    test "a sibling folder that merely CONTAINS a repo is not itself a working tree" do
      dir("firmware").then { |repo| dir(".git", parent: repo.node_id) }
      loose = file("notes.txt")

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      assert_nil policy.refusal_for(loose),
                 "the repo is one folder over; this file is not inside it"
    end

    test "a TOMBSTONED .git does not make a folder a working tree" do
      repo = dir("firmware")
      marker = dir(".git", parent: repo.node_id)
      marker.update!(deleted: true)
      src = file("main.cpp", parent: repo.node_id)

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      assert_nil policy.refusal_for(src)
    end

    test "the ancestor walk is asked ONCE per parent, not once per file" do
      repo = dir("firmware")
      dir(".git", parent: repo.node_id)
      files = 5.times.map { |i| file("f#{i}.cpp", parent: repo.node_id) }

      policy = Maker::AttachToProject.new(user: @user, project: @project)
      policy.refusal_for(files.first) # warm the cache

      queries = count_queries { files.each { |f| policy.refusal_for(f) } }
      assert_equal 0, queries,
                   "a sweep files N nodes under one parent; the ancestor walk must not run N times"
    end
```

If `count_queries` is not already defined in this file, copy it verbatim from
`test/services/maker/project_intake_test.rb` (it is defined there, and duplicating a
test-only helper across two suites is cheaper than a shared harness for one method).

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/maker/attach_to_project_test.rb -n "/working_tree|working tree/"
```

Expected: FAIL — `refusal_for` returns `nil` where `:in_working_tree` is expected.

- [ ] **Step 3: Implement the refusal**

In `app/services/maker/attach_to_project.rb`, add to the header's `THE RULES` block, directly after the `:attached_elsewhere` entry:

```ruby
  #   :in_working_tree    — the file lives inside a git working tree, so moving it is a delete
  #                         plus an untracked add as far as git is concerned. UNCONDITIONAL, and
  #                         deliberately NOT scoped by `within_own_folder:`: a refusal here means
  #                         "attach the row, leave the bytes", which is the right answer at all
  #                         four callers. Detected by the `.git` marker node Library::RepoMetadata
  #                         keeps indexed — see that file for why the marker survives the skip.
```

Replace `#refusal_for` with:

```ruby
    def refusal_for(node, within_own_folder: false)
      return :not_a_file unless node.file?
      return :model_bundle if model_owning(node)
      return :attached_elsewhere if !within_own_folder && attached_elsewhere?(node)
      return :in_working_tree if in_working_tree?(node)

      nil
    end
```

Add these private methods beside `#model_owning`:

```ruby
    # A cap on the ancestor walk. Not defensive dressing: `parent_node_id` is a plain string
    # column with no FK, so a cycle is representable, and an uncapped `while` here is an infinite
    # loop inside a 15-minute unattended sweep. 64 is far past any real library depth.
    MAX_ANCESTOR_WALK = 64

    # Is this node inside a git working tree — i.e. does any ancestor directory have a live child
    # named `.git`?
    #
    # MEMOIZED ON THE PARENT, not on the node. ProjectIntake sweeps every file at one project
    # folder's root, so without the cache the walk runs once per FILE and each run is two queries
    # per level. With it, a sweep of N files pays for one walk. The cache lives on the instance
    # and the instance lives for one sweep or one request, so there is no staleness window worth
    # naming — and ProjectIntake already memoizes this object (`attach_policy`).
    def in_working_tree?(node)
      parent_id = node.parent_node_id
      return false if parent_id.nil?

      @working_tree ||= {}
      return @working_tree[parent_id] if @working_tree.key?(parent_id)

      @working_tree[parent_id] = walk_for_marker(parent_id)
    end

    # `present` scope, so a TOMBSTONED `.git` does not keep a folder frozen forever: a deleted
    # repo is not a working tree, and the marker is revivable by node_id if it comes back.
    def walk_for_marker(parent_id)
      id = parent_id
      MAX_ANCESTOR_WALK.times do
        break if id.nil?
        return true if @user.nodes.present.exists?(parent_node_id: id, kind: "dir",
                                                   name: Library::RepoMetadata::DIR_NAME)

        id = @user.nodes.where(node_id: id).pick(:parent_node_id)
      end
      false
    end
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
bin/rails test test/services/maker/attach_to_project_test.rb
```

Expected: PASS, all pre-existing tests still green.

- [ ] **Step 5: Write the end-to-end test — the sweep leaves a repo alone**

Append inside `class ProjectIntakeTest` in `test/services/maker/project_intake_test.rb`:

```ruby
    # --- the repo shredder -------------------------------------------------------
    #
    # THE BUG THIS FIXES SHIPPED AND RAN UNATTENDED. §14f's root-is-inbox rule means a repo
    # cloned at `Projects/<slug>/` has its ROOT-LEVEL files filed away by category on every
    # sweep: README.md -> docs/, main.py -> other/, platformio.ini -> other/. Git sees a delete
    # plus an untracked add for each one. Nested files were always safe (already in a subfolder,
    # never revisited); the root files are most of what identifies a repo.
    test "a repo cloned at the project folder root is left entirely alone" do
      dir(".git")
      readme = file("README.md")
      main   = file("main.py")
      ini    = file("platformio.ini")

      result = intake.call

      assert_empty result.moves, "the sweep must move nothing inside a working tree"
      [ readme, main, ini ].each do |node|
        assert_equal @folder.node_id, node.reload.parent_node_id,
                     "#{node.name} was moved out from under git"
      end
    end

    test "with NO .git, the same files sort normally — so the test above is not vacuous" do
      readme = file("README.md")
      main   = file("main.py")

      intake.call

      assert_not_equal @folder.node_id, readme.reload.parent_node_id
      assert_not_equal @folder.node_id, main.reload.parent_node_id
    end
```

- [ ] **Step 6: Run them**

```bash
bin/rails test test/services/maker/project_intake_test.rb -n "/repo|\.git|sort normally/"
```

Expected: PASS both.

- [ ] **Step 7: Mutation-check the refusal (§15)**

Delete the `return :in_working_tree if in_working_tree?(node)` line and re-run:

```bash
bin/rails test test/services/maker/project_intake_test.rb test/services/maker/attach_to_project_test.rb
```

Expected: **RED** — "a repo cloned at the project folder root is left entirely alone" fails, showing the shred reappearing. **Restore the line** and confirm green.

- [ ] **Step 8: Commit**

```bash
git add app/services/maker/attach_to_project.rb test/services/maker/attach_to_project_test.rb test/services/maker/project_intake_test.rb
git commit -m "Refuse to move a file out from under git: :in_working_tree"
```

---

## Task 3: The observers skip `.git`'s contents and keep the marker

**Files:**
- Modify: `app/services/library/scanner.rb` (the `#observe` stack push)
- Modify: `app/services/library/s3_observer.rb` (`#observe`'s `each_object` block)
- Test: `test/services/library/scanner_test.rb`, `test/services/library/s3_observer_test.rb`

- [ ] **Step 1: Write the failing Scanner test**

Append inside the scanner test class in `test/services/library/scanner_test.rb`:

```ruby
    test ".git is indexed as ONE dir node and never descended into" do
      (@root/"firmware"/".git"/"objects"/"ab").mkpath
      (@root/"firmware"/".git"/"objects"/"ab"/"cdef").write("x")
      (@root/"firmware"/".git"/"config").write("[core]")
      (@root/"firmware"/"main.cpp").write("int main(){}")

      rels = Library::Scanner.new(@user, root: @root).observe.map(&:rel_path)

      assert_includes rels, "firmware/.git", "the MARKER must be observed — it is what makes " \
                                             "a working tree detectable"
      assert_includes rels, "firmware/main.cpp"
      assert_empty rels.select { |r| r.start_with?("firmware/.git/") },
                   "nothing beneath .git may be observed"
    end

    test "a file merely named .gitignore is indexed normally" do
      (@root/".gitignore").write("tmp/")

      rels = Library::Scanner.new(@user, root: @root).observe.map(&:rel_path)

      assert_includes rels, ".gitignore"
    end
```

Adapt `@root`/`@user` to whatever this suite's `setup` already provides — read the top of the
file first and match it rather than introducing a second fixture idiom.

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/library/scanner_test.rb -n "/\.git/"
```

Expected: FAIL — `firmware/.git/config` and the objects are all present in `rels`.

- [ ] **Step 3: Implement the Scanner change**

In `app/services/library/scanner.rb`, inside `#observe`, replace the directory arm:

```ruby
          if stat.directory?
            out << Observation.new(rel_path: rel, size: nil, mtime: nanos(stat), dir: true)
            # SKIP THE CONTENTS, KEEP THE MARKER. The dir node IS observed — that is what makes a
            # working tree detectable by Maker::AttachToProject's :in_working_tree, and what stops
            # this from being a fifth skip-list wedge (an observed node pairs normally; a skipped
            # entry with a live node does not). What we decline is the DESCENT, which is the one
            # explicit decision this worklist exists to make in one place. Library::RepoMetadata
            # carries the full argument.
            stack << [ path, rel ] unless Library::RepoMetadata.marker?(name)
          elsif stat.file?
```

- [ ] **Step 4: Run the Scanner test**

```bash
bin/rails test test/services/library/scanner_test.rb
```

Expected: PASS, and every pre-existing scanner test still green.

- [ ] **Step 5: Write the failing S3Observer test**

Append inside the S3 observer test class in `test/services/library/s3_observer_test.rb`, matching
that file's existing fixture idiom for seeding keys:

```ruby
    test ".git becomes ONE synthesized dir observation and its keys are dropped" do
      put_object("firmware/.git/config", "[core]")
      put_object("firmware/.git/objects/ab/cdef", "x")
      put_object("firmware/main.cpp", "int main(){}")

      obs = observer.observe
      rels = obs.map(&:rel_path)

      assert_includes rels, "firmware/.git"
      assert(obs.find { |o| o.rel_path == "firmware/.git" }.dir,
             "S3 has no directories, so the marker must be synthesized as a DIR observation")
      assert_includes rels, "firmware/main.cpp"
      assert_empty rels.select { |r| r.start_with?("firmware/.git/") }
    end
```

- [ ] **Step 6: Run it and watch it fail**

```bash
bin/rails test test/services/library/s3_observer_test.rb -n "/\.git/"
```

Expected: FAIL — the `.git` keys are indexed as files.

- [ ] **Step 7: Implement the S3Observer change**

In `app/services/library/s3_observer.rb`, inside `#observe`'s `each_object` block, add this as the
**first** branch, before the `if marker` check:

```ruby
        # A repo's metadata is ONE dir node and no files. S3 has no directories, so unlike the
        # Scanner — which observes a real `.git` dir and simply declines to descend — the marker
        # here has to be SYNTHESIZED from the keys being dropped, or it would not exist on this
        # backend at all and the working-tree question would have two answers across backends
        # (§14a). Note this is deliberately NOT in #indexable?: that predicate's answers are
        # dropped outright, and we need the key to reach here so the prefix can be recorded.
        if (repo_root = Library::RepoMetadata.marker_prefix(rel))
          dirs.merge(dir_chain(repo_root))
          next
        end
```

- [ ] **Step 8: Run the S3 test**

```bash
bin/rails test test/services/library/s3_observer_test.rb
```

Expected: PASS, all pre-existing tests green.

- [ ] **Step 9: Mutation-check both observers (§15)**

Remove the `unless Library::RepoMetadata.marker?(name)` guard in `scanner.rb`. Run
`bin/rails test test/services/library/scanner_test.rb` — expected **RED**. Restore it.

Change the S3 branch to `next` without `dirs.merge(...)` (dropping the marker). Run
`bin/rails test test/services/library/s3_observer_test.rb` — expected **RED** on the marker
assertion. Restore it.

- [ ] **Step 10: Commit**

```bash
git add app/services/library/scanner.rb app/services/library/s3_observer.rb test/services/library/scanner_test.rb test/services/library/s3_observer_test.rb
git commit -m "Observers: index the .git marker, skip its contents"
```

**CAUTION — this is the commit that arms the wedge.** From here until Task 6 lands, scanning a
DEVELOPMENT library that already has a `.git` indexed will trip the mass-deletion guard and refuse
that scan and every scan after it. Nothing is deleted (the guard raises before tombstoning), but
you will see `Library::Scanner::UnsafeScan` until you run `Library::RepoMetadataPurge.call`. If you
hit it before Task 6 exists, delete the offending nodes by hand rather than raising
`LIBRARY_SCAN_MAX_DELETE_PCT` — the override is how a real mass deletion gets waved through.

---

## Task 4: The write guards and the doors refuse `.git`

**Why this task cannot be skipped or deferred:** `Library::OsClutter`'s header states the law — a name the observers skip must ALSO be refused as a write destination. A write that lands a live node beneath `.git` creates a ghost the Reconciler can never pair (pairing needs an observation, and a skipped path produces none); the resulting tombstone trips the mass-deletion guard and refuses that scan and every scan after it, permanently. This shape has wedged this library four times.

**Files:**
- Modify: `app/services/file_layer/share.rb`, `app/services/file_layer/s3.rb` (`#observable!`)
- Modify: `app/services/library/reserved_names.rb`
- Test: `test/services/library/reserved_names_test.rb`, plus the shared adapter write contract

- [ ] **Step 1: Write the failing ReservedNames test**

Append inside `class ReservedNamesTest` in `test/services/library/reserved_names_test.rb`:

```ruby
    test "a door may not MINT .git" do
      assert ReservedNames.reserved?(".git")
    end

    test "but ordinary git-adjacent filenames stay mintable" do
      assert_not ReservedNames.reserved?(".gitignore")
      assert_not ReservedNames.reserved?(".gitmodules")
      assert_not ReservedNames.reserved?("git")
    end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/library/reserved_names_test.rb
```

Expected: FAIL on `a door may not MINT .git`.

- [ ] **Step 3: Implement the door refusal**

In `app/services/library/reserved_names.rb`, extend `#reserved?`:

```ruby
      name == Library::Scanner::TRASH_PREFIX ||
        name.start_with?(Library::Scanner::TEMP_PREFIX) ||
        Library::OsClutter.clutter_segment?(name) ||
        Library::RepoMetadata.marker?(name)
```

and add to the module's header comment, after the OsClutter paragraph:

```ruby
  # RepoMetadata.marker? joins the union for a different reason than the others, and the
  # difference is worth stating: `.git` is not clutter and IS observed when it already exists on
  # disk — a real repo's marker is a legitimate node. What has no legitimate use is MINTING one
  # through a web door: you cannot create a repository by creating the folder, and a folder named
  # `.git` made by hand silently turns off intake for everything under it
  # (Maker::AttachToProject's :in_working_tree reads exactly this marker). Observed-but-not-
  # mintable is the same shape `.DS_Store` already has here, arrived at from the opposite side.
```

- [ ] **Step 4: Run it and watch it pass**

```bash
bin/rails test test/services/library/reserved_names_test.rb
```

Expected: PASS.

- [ ] **Step 5: Write the failing write-guard test**

Find the shared adapter write contract (`test/support/adapter_write_contract.rb` — locate it with
`grep -rl "adapter_write_contract\|clobber" test/`) and append a case beside the existing clobber
test, so it runs on **both** writable adapters:

```ruby
    test "#{backend}: a destination inside .git is refused" do
      assert_raises(FileLayer::UnsupportedOperation) do
        adapter.write(user, rel_path: "firmware/.git/hooks/pre-commit", io: StringIO.new("x"))
      end
    end

    test "#{backend}: a destination merely NAMED .gitignore is accepted" do
      adapter.write(user, rel_path: ".gitignore", io: StringIO.new("tmp/"))
      assert adapter.stat(user, rel_path: ".gitignore")
    end
```

Match the contract file's existing signature style exactly — read one neighbouring test first; the
argument names above are illustrative of intent, not of this file's API.

- [ ] **Step 6: Run it and watch it fail**

```bash
bin/rails test test/services/file_layer/ 2>&1 | tail -20
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/file_layer/ 2>&1 | tail -20
```

Expected: FAIL — the write into `.git` succeeds.

- [ ] **Step 7: Implement the guard in both adapters**

In `app/services/file_layer/share.rb` and `app/services/file_layer/s3.rb`, inside each
`#observable!`, add beside the existing `OsClutter` refusal:

```ruby
      # BENEATH `.git` only — the marker directory itself is observed and indexed
      # (Library::RepoMetadata explains the asymmetry). This is OsClutter's law applied to the
      # one skip that keeps its entry: the CONTENTS are unobservable, so they must be unwritable,
      # or a write manufactures a node no scan can ever pair.
      raise UnsupportedOperation, "#{rel} is inside a git repository's metadata" if
        Library::RepoMetadata.internal?(rel)
```

- [ ] **Step 8: Run all three backend legs**

```bash
bin/ci test
```
```bash
bin/ci test-s3
```

Expected: PASS on both.

- [ ] **Step 9: Mutation-check (§15)**

Remove the `RepoMetadata.internal?` raise from `share.rb` only. Run `bin/ci test`. Expected:
**RED** on the share leg while `test-s3` stays green — which is the cross-backend divergence §14a
forbids, demonstrated. Restore it.

- [ ] **Step 10: Commit**

```bash
git add app/services/file_layer/share.rb app/services/file_layer/s3.rb app/services/library/reserved_names.rb test/
git commit -m "Refuse writes inside .git, and refuse minting .git at the doors"
```

---

## Task 5: Hide the `.git` marker in the Files UI

**Why:** indexed is not the same as displayed. The marker exists so `:in_working_tree` can find it; nobody browsing a project wants a `.git` tile.

**Files:**
- Modify: `app/models/node.rb` (one scope)
- Modify: `app/controllers/files_controller.rb:184,192` (both listing scopes)
- Test: `test/integration/web/files_index_test.rb` (or the closest existing home — find it with `grep -rl "FLAT_LIMIT\|folder_page_order" test/`)

- [ ] **Step 1: Write the failing test**

```ruby
  test "the .git marker is indexed but never listed" do
    repo = node(name: "firmware", kind: "dir")
    marker = node(name: ".git", kind: "dir", parent_node_id: repo.node_id)

    get files_path(folder: repo.node_id)

    assert_response :success
    assert_select "[data-node-id=?]", marker.node_id, count: 0
    assert Node.exists?(marker.id), "hidden from the UI, still in the catalog"
  end

  test "a file merely named .gitignore is still listed" do
    keep = node(name: ".gitignore", kind: "file")

    get files_path

    assert_select "[data-node-id=?]", keep.node_id, count: 1
  end
```

Match the suite's existing node-fixture helper and its row selector — read one neighbouring test
first; `node(...)` and `[data-node-id=?]` above are intent, not necessarily this file's API.

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/integration/web/files_index_test.rb -n "/\.git/"
```

Expected: FAIL — the marker is listed.

- [ ] **Step 3: Add the scope**

In `app/models/node.rb`, beside `scope :present`:

```ruby
  # The `.git` marker is INDEXED ON PURPOSE (Library::RepoMetadata explains why) and displayed
  # never. Excluded by NAME, which is exact and costs no extra query — the contents beneath it are
  # not indexed at all on share/s3, so on those backends the name is the whole of it.
  scope :outside_repo_metadata, -> { where.not(name: Library::RepoMetadata::DIR_NAME) }
```

- [ ] **Step 4: Use it in both listing scopes**

In `app/controllers/files_controller.rb`, add `.outside_repo_metadata` to the flat scope (~line 184)
and the folder scope (line 192). Both, because they are two independent scopes over the same
catalog and fixing one is the divergence §14a forbids.

- [ ] **Step 5: Run it and watch it pass**

```bash
bin/rails test test/integration/web/
```

Expected: PASS.

- [ ] **Step 6: Mutation-check (§15)**

Remove `.outside_repo_metadata` from the FLAT scope only, leaving the folder scope. Re-run.
Expected: **RED** if the test covers the flat view — if it stays green, the test only covers one
scope and is not yet the guard it claims to be. Add the flat-view case, then restore.

- [ ] **Step 7: Commit**

```bash
git add app/models/node.rb app/controllers/files_controller.rb test/
git commit -m "Hide the .git marker from the Files listing"
```

**KNOWN LIMITATION, recorded rather than left to be discovered.** On `chunk_remote` the `nodes`
table mirrors the sync server's tree, so the files INSIDE `.git` exist as rows there (share and s3
never index them at all). This scope hides the marker on every backend but does **not** hide those
descendants from the FLAT view, where they can still be listed. Closing that needs a recursive CTE
on a page in the hot path — a real per-request cost, on the product's main deployment, to tidy a
view — and §14j says the tree in question is the sync server's to decide about. If it becomes a
real complaint, the fix belongs there or in a materialized ancestor column, not in a CTE bolted
onto `FilesController#index`.

---

## Task 6: Purge already-indexed `.git` nodes — as a MIGRATION, not a rake task

**Why this is the dangerous step:** the mass-deletion guard is a percentage of the observable library with **no floor** (`app/services/library/reconciler.rb:206`). Any library that already has a `.git` indexed sees every one of those nodes vanish on the first scan after Task 3 — 5,000 objects in a 6,000-file library is 83% doomed, `Library::Scanner::UnsafeScan`, and **the library stops scanning** until an operator overrides `LIBRARY_SCAN_MAX_DELETE_PCT`.

**Why a migration and not the rake task the spec first proposed:** a rake task is an operator step that has to be remembered *between* the deploy and the first `Library::ScanJob` tick. Kamal runs migrations before it boots the new containers, so a migration closes that window instead of documenting it. (The guard refuses the scan rather than tombstoning, so the failure mode is an outage, not data loss — but an outage nobody has to have is still worth not having.)

**Files:**
- Create: `app/services/library/repo_metadata_purge.rb` (the logic — testable, and re-runnable by an operator)
- Create: `db/migrate/<timestamp>_purge_repo_metadata_nodes.rb` (calls it once, at deploy)
- Test: `test/services/library/repo_metadata_purge_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/library/repo_metadata_purge_test.rb`:

```ruby
require "test_helper"

module Library
  # THE ONE-TIME PURGE, and its reason is arithmetic rather than tidiness: once the observers stop
  # descending into `.git`, every node already indexed beneath one VANISHES in a single pass. The
  # mass-deletion guard is a percentage with no floor, so a repo-heavy library trips it and the
  # scan is refused — that scan and every scan after it — until someone overrides the threshold.
  class RepoMetadataPurgeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "purge-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def node(storage_path, kind: "file")
      @user.nodes.create!(node_id: SecureRandom.uuid, name: File.basename(storage_path),
                          kind:, storage_path:, size: (kind == "file" ? 1 : nil))
    end

    test "nodes beneath .git are destroyed and the MARKER itself survives" do
      marker = node("firmware/.git", kind: "dir")
      config = node("firmware/.git/config")
      object = node("firmware/.git/objects/ab/cdef")
      source = node("firmware/main.cpp")

      result = RepoMetadataPurge.call

      assert Node.exists?(marker.id), "the marker is what detects a working tree — it must survive"
      assert Node.exists?(source.id)
      assert_not Node.exists?(config.id)
      assert_not Node.exists?(object.id)
      assert_equal 2, result.destroyed
    end

    test "a node carrying an attachment is REPORTED, never destroyed" do
      hook = node("firmware/.git/hooks/pre-commit")
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: hook.node_id, role: "other")

      result = RepoMetadataPurge.call

      assert Node.exists?(hook.id),
             "destroying an attached node silently orphans a project reference"
      assert_equal [ hook.node_id ], result.skipped.map(&:node_id)
      assert_equal 0, result.destroyed
    end

    test "a file merely NAMED .gitignore is untouched" do
      keep = node(".gitignore")
      RepoMetadataPurge.call
      assert Node.exists?(keep.id)
    end

    test "it is idempotent — a second run destroys nothing" do
      node("firmware/.git", kind: "dir")
      node("firmware/.git/config")

      assert_equal 1, RepoMetadataPurge.call.destroyed
      assert_equal 0, RepoMetadataPurge.call.destroyed
    end

    test "a chunk_remote-shaped node (NULL storage_path) is resolved by its parent chain" do
      # On chunk_remote there is no storage_path at all (§14a), so a purge that only reads that
      # column would silently do nothing on the product's main deployment — green suite, zero
      # effect. The path is rebuilt from parent_node_id instead.
      repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "firmware", kind: "dir")
      marker = @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                                   parent_node_id: repo.node_id)
      inner = @user.nodes.create!(node_id: SecureRandom.uuid, name: "config", kind: "file",
                                  parent_node_id: marker.node_id, size: 1)

      RepoMetadataPurge.call

      assert Node.exists?(marker.id)
      assert_not Node.exists?(inner.id)
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/library/repo_metadata_purge_test.rb
```

Expected: every test errors with `NameError: uninitialized constant Library::RepoMetadataPurge`.

- [ ] **Step 3: Write the service**

Create `app/services/library/repo_metadata_purge.rb`:

```ruby
module Library
  # Remove nodes already indexed BENEATH a `.git` directory, keeping the marker itself.
  #
  # RUN ONCE, AT DEPLOY, BY A MIGRATION — see db/migrate/*_purge_repo_metadata_nodes.rb. Idempotent,
  # so a re-run costs a scan of the table and destroys nothing.
  #
  # DESTROY, NOT TOMBSTONE. These paths will never be observed again, so a tombstone would sit
  # there forever as a revivable row for a file that cannot come back — and §14a's two-tombstone-
  # kinds rule makes a lingering trash-kind row actively worse than no row: Reconciler
  # #create_or_revive! could hand a new, unrelated file that node_id along with every attachment,
  # BOM link and tag pointing at it.
  #
  # RESOLVED BY THE PARENT CHAIN, NOT BY storage_path. On chunk_remote storage_path is NULL for
  # every node (§14a), so a purge reading only that column would do nothing at all on the product's
  # main deployment while every test built on share fixtures stayed green — this repo's signature
  # failure shape. The chain is walked once into a memo, so the whole pass is O(nodes).
  module RepoMetadataPurge
    Result = Data.define(:destroyed, :skipped)

    def self.call
      destroyed = 0
      skipped = []

      Node.find_each do |node|
        next unless beneath_marker?(node)

        if Maker::FileAttachment.exists?(user_id: node.user_id, node_id: node.node_id)
          skipped << node
          next
        end

        node.destroy!
        destroyed += 1
      end

      Result.new(destroyed:, skipped:)
    end

    # Is this node strictly BELOW a `.git` directory? Walks parents rather than reading a path, so
    # it answers identically on all three backends. Capped for the same reason
    # Maker::AttachToProject::MAX_ANCESTOR_WALK is: parent_node_id has no FK, so a cycle is
    # representable and an uncapped walk is an infinite loop inside a deploy.
    def self.beneath_marker?(node)
      id = node.parent_node_id
      64.times do
        break if id.nil?

        parent = lookup(node.user_id, id)
        return false if parent.nil?
        return true if parent.name == RepoMetadata::DIR_NAME && parent.kind == "dir"

        id = parent.parent_node_id
      end
      false
    end

    def self.lookup(user_id, node_id)
      @cache ||= {}
      key = [ user_id, node_id ]
      return @cache[key] if @cache.key?(key)

      @cache[key] = Node.select(:node_id, :name, :kind, :parent_node_id, :user_id)
                        .find_by(user_id:, node_id:)
    end
    private_class_method :lookup
  end
end
```

**Note the memo is module-level and therefore process-lived.** That is fine for a one-shot deploy
migration and wrong for anything long-running; if this is ever called from a job, reset `@cache`
per call. Say so in the file rather than leaving it to be discovered.

- [ ] **Step 4: Run the test and watch it pass**

```bash
bin/rails test test/services/library/repo_metadata_purge_test.rb
```

Expected: PASS, 5 runs.

- [ ] **Step 5: Generate and write the migration**

```bash
bin/rails generate migration PurgeRepoMetadataNodes
```

Fill it in:

```ruby
class PurgeRepoMetadataNodes < ActiveRecord::Migration[8.1]
  # DATA MIGRATION, one-time. Runs at deploy, BEFORE the new containers boot — which is the whole
  # point: the observers in this same deploy stop descending into `.git`, and the first
  # Library::ScanJob tick afterwards would otherwise see every node beneath one vanish at once and
  # trip the mass-deletion guard (a percentage with no floor). The guard refuses rather than
  # tombstoning, so the cost is a stalled library rather than lost data — an outage nobody needs
  # to have.
  #
  # RESCUES NameError ON PURPOSE. A migration is replayed on a fresh database for as long as this
  # repo exists, and Library::RepoMetadataPurge is a one-time service that a future cleanup may
  # legitimately delete. On a fresh database there is nothing to purge, so a missing constant must
  # be a no-op rather than a broken `db:setup` years from now.
  def up
    Library::RepoMetadataPurge.call
  rescue NameError
    say "Library::RepoMetadataPurge is gone; nothing to purge on a fresh database"
  end

  # IRREVERSIBLE BY NATURE, not by neglect: the rows are gone and the paths they named are no
  # longer observable, so there is nothing to restore them from. A down that did nothing would be
  # a lie about that.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

- [ ] **Step 6: Run it against a database with a repo in it**

```bash
bin/rails db:migrate
```

Expected: succeeds. Then confirm replay from scratch is clean:

```bash
bin/rails db:drop db:create db:schema:load db:migrate
```

- [ ] **Step 7: Prove the guard-trip it prevents is real (§15 — probe over argument)**

Add to `test/services/library/repo_metadata_purge_test.rb`:

```ruby
    test "after the purge, a scan over a repo library does not trip the mass-deletion guard" do
      root = use_fresh_share_library!
      (root/"firmware"/".git"/"objects").mkpath
      20.times { |i| (root/"firmware"/".git"/"objects"/"o#{i}").write("x") }
      (root/"firmware"/"main.cpp").write("int main(){}")

      Library::Scanner.call(@user, root: root)   # index everything — the OLD behaviour
      assert_operator @user.nodes.present.count, :>, 20

      RepoMetadataPurge.call

      assert_nothing_raised { Library::Scanner.call(@user, root: root) }
    ensure
      FileLayer.reset!
      FileUtils.remove_entry(root) if root&.exist?
    end
```

Run it:

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/library/repo_metadata_purge_test.rb
```

Expected: PASS. Then **mutation-check it**: comment out the `RepoMetadataPurge.call` line and
re-run. Expected: **RED** with `Library::Scanner::UnsafeScan`. Read that message — it is the wedge
this whole task exists to prevent — then restore the line.

- [ ] **Step 8: Commit**

```bash
git add app/services/library/repo_metadata_purge.rb db/migrate/ db/schema.rb test/services/library/repo_metadata_purge_test.rb
git commit -m "Purge nodes indexed beneath .git, at deploy, before the skip bites"
```

- [ ] **Step 9: Record it in the deploy doc anyway**

The migration makes it automatic; the operator still needs to know it happened and what to do if a
library was scanned before it ran. Add to `docs/DEPLOY.md`:

```markdown
### The `.git` purge (2026-08-25) — automatic, but know it exists

`PurgeRepoMetadataNodes` removes library nodes already indexed beneath a `.git` directory, keeping
the `.git` marker itself. It runs as part of `db:migrate`, before the new containers boot.

If a library was scanned by the new code before the migration ran, the scan will REFUSE with
`Library::Scanner::UnsafeScan` (a mass-deletion guard trip — nothing was deleted). Fix:

    kamal app exec --reuse "bin/rails runner 'Library::RepoMetadataPurge.call'"

then let the next scheduled scan run. Do NOT reach for `LIBRARY_SCAN_MAX_DELETE_PCT`.
```

```bash
git add docs/DEPLOY.md && git commit -m "DEPLOY: what the .git purge migration does, and its one failure mode"
```

---

## Task 7: Source code joins the one vocabulary

**Files:**
- Modify: `app/models/maker/file_attachment.rb` (`ROLE_LABELS`, `ROLE_BY_EXT`, a new `TEXT_ROLES`)
- Modify: `app/services/maker/project_folders.rb` (`ROLE_FOLDERS`)
- Modify: `app/controllers/files_controller.rb:1130` (derive, don't duplicate)
- Test: `test/models/maker/file_attachment_test.rb`, `test/services/maker/project_folders_test.rb`, `test/helpers/files_helper_test.rb`

**Read first:** §14d's ONE file-type vocabulary rule. `FilesHelper::EXT_FAMILIES` already derives from `ROLE_LABELS` + `ROLE_BY_EXT` (`app/helpers/files_helper.rb:101`); `preview_kind`'s inline list is the one place that still duplicates.

- [ ] **Step 1: Write the failing tests**

In `test/models/maker/file_attachment_test.rb`:

```ruby
  test "source files resolve to the code role" do
    %w[main.cpp sketch.ino app.py lib.rs main.go build.sh config.toml].each do |name|
      assert_equal "code", Maker::FileAttachment.role_for(name), name
    end
  end

  test "adding code did not disturb the roles that carry BEHAVIOUR" do
    assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf"),
                 "Models::AttachmentsController dispatches ExtractPdfMetadataJob on this exact value"
    assert_equal "document", Maker::FileAttachment.role_for("notes.md")
    assert_equal "gcode", Maker::FileAttachment.role_for("part.nc")
  end

  test "every extension satisfies EXT_RE, or its filter chip links and does nothing" do
    Maker::FileAttachment::ROLE_BY_EXT.each_key do |ext|
      assert_match FilesController::EXT_RE, ext, ext
    end
  end

  test "TEXT_ROLES names only roles that exist" do
    assert_empty Maker::FileAttachment::TEXT_ROLES - Maker::FileAttachment::ROLES
  end
```

In `test/services/maker/project_folders_test.rb` the existing totality test will fail on its own
once `code` is a role — that is the guard doing its job, not a test to add.

In `test/controllers/files_controller_test.rb` (or the closest existing home for `preview_kind`):

```ruby
  test "preview_kind's text set is DERIVED from the one vocabulary, not a second list" do
    controller = FilesController.new
    %w[main.cpp app.py notes.md data.json part.gcode].each do |name|
      assert_equal :text, controller.send(:preview_kind, name), name
    end
    assert_equal :pdf, controller.send(:preview_kind, "manual.pdf"),
                 "instructions is not a text role — pdf embeds the browser's viewer"
    assert_equal :image, controller.send(:preview_kind, "cover.png")
  end
```

- [ ] **Step 2: Run them and watch them fail**

```bash
bin/rails test test/models/maker/file_attachment_test.rb test/services/maker/project_folders_test.rb
```

Expected: FAIL — `role_for("main.cpp")` is `"other"`, and `TEXT_ROLES` is undefined.

- [ ] **Step 3: Add the role and its extensions**

In `app/models/maker/file_attachment.rb`, add to `ROLE_LABELS` between `cad_source` and `gcode`:

```ruby
      "code"           => "Code",
```

Add to `ROLE_BY_EXT`, after the text-formats block:

```ruby
      # Source code, config and build files — the "hardware + firmware + software" half of a
      # project (§1). `ino` is Arduino; `h`/`hpp` sit with c/cpp because a firmware tree is
      # headers and sources together and splitting them would put one project's files in two
      # folders. Config formats (`toml ini cfg conf yml yaml`) are here rather than under
      # `document` because they belong beside the code they configure, and ProjectFolders is what
      # that choice actually decides.
      "c" => "code", "h" => "code", "cpp" => "code", "cc" => "code", "hpp" => "code",
      "ino" => "code", "py" => "code", "rb" => "code", "js" => "code", "ts" => "code",
      "rs" => "code", "go" => "code", "sh" => "code", "lua" => "code", "sql" => "code",
      "html" => "code", "css" => "code", "xml" => "code", "log" => "code",
      "toml" => "code", "ini" => "code", "cfg" => "code", "conf" => "code",
      "yml" => "code", "yaml" => "code", "cmake" => "code",
```

Add below `ROLE_BY_EXT`:

```ruby
    # Roles whose files are TEXT a browser can display as source. Consulted by
    # FilesController#preview_kind, which used to carry its own inline extension list — a second
    # vocabulary beside this one, which is exactly the drift FilesHelper::EXT_FAMILIES was
    # rewritten to end in 2026-07-29 after two lists disagreed about `.svg` for months (§14d).
    #
    # `instructions` is deliberately absent: pdf is text-ish only in the sense that it is not an
    # image, and the detail view embeds the browser's own PDF viewer for it.
    TEXT_ROLES = %w[document code gcode].freeze
```

- [ ] **Step 4: Add the folder**

In `app/services/maker/project_folders.rb`, add to `ROLE_FOLDERS`:

```ruby
      "code"           => "code",
```

- [ ] **Step 5: Derive the text set**

In `app/controllers/files_controller.rb`, replace the `:text` line at ~1130:

```ruby
    # DERIVED FROM THE ONE VOCABULARY (§14d). This was an inline list of 25 extensions sitting
    # beside Maker::FileAttachment::ROLE_BY_EXT — a second table that had already drifted from the
    # first, and would have drifted further the moment `code` added fifteen more. Adding an
    # extension is still a one-line edit to ROLE_BY_EXT and nothing here has to hear about it.
    return :text if Maker::FileAttachment::TEXT_ROLES.include?(Maker::FileAttachment.role_for(name))
```

Note this reads `name`, not `ext` — check the surrounding method's local variable names and use
whichever is in scope, calling `role_for` with the full filename (it takes a filename and does its
own `File.extname`).

- [ ] **Step 6: Run the full suite**

```bash
bin/ci test
```

Expected: PASS. If `files_helper_test.rb` fails on a chip-count or family assertion, that is the
new `Code` family appearing — update the expectation, do not special-case the helper.

- [ ] **Step 7: Mutation-check the derivation (§15)**

Change `TEXT_ROLES` to `%w[document]`. Run
`bin/rails test test/controllers/files_controller_test.rb`. Expected: **RED** on `main.cpp` and
`part.gcode`. Restore.

- [ ] **Step 8: Commit**

```bash
git add app/models/maker/file_attachment.rb app/services/maker/project_folders.rb app/controllers/files_controller.rb test/
git commit -m "A code role, and one text vocabulary instead of two"
```

**Out of scope, stated so it is not read as an oversight:** `Maker::Previews::Registry` is NOT
extended to render grid thumbnails for `code` extensions. Those files render as `:text` on the
detail page (which is the point of this arc) and have no grid thumbnail, exactly as they did
before. Adding `TextThumb` for them is a separate, arguable change.

---

## Task 8: The CodeMirror bundle

**Files:**
- Create: `bin/build-codemirror`, `vendor/javascript/codemirror-entry.js`, `vendor/javascript/codemirror.js`
- Modify: `config/importmap.rb`
- Test: `test/ci_hygiene_test.rb`

- [ ] **Step 1: Write the entry file**

Create `vendor/javascript/codemirror-entry.js` (the SOURCE the bundle is built from — committed so
the bundle is reproducible, never served):

```javascript
// The source of vendor/javascript/codemirror.js. NOT served — bin/build-codemirror bundles this
// into the single file the importmap pins. See that script for why one bundle rather than pins.
//
// FOUR EXPORTS ARE UNUSED TODAY — keymap, lineNumbers, highlightActiveLine, Compartment — and they
// are kept deliberately: basicSetup already pulls the whole of @codemirror/view and
// @codemirror/state, so naming them costs nothing measurable, and they are the primitives the
// deferred editing arc needs (Compartment is how a read-only view is later made editable without
// rebuilding the state). Removing them would shrink the bundle by approximately zero and
// invalidate the size figure bin/build-codemirror prints.
export { EditorView, keymap, lineNumbers, highlightActiveLine } from "@codemirror/view"
export { EditorState, Compartment } from "@codemirror/state"
export { basicSetup } from "codemirror"
export { StreamLanguage } from "@codemirror/language"
export { cpp } from "@codemirror/lang-cpp"
export { python } from "@codemirror/lang-python"
export { javascript } from "@codemirror/lang-javascript"
export { json } from "@codemirror/lang-json"
export { markdown } from "@codemirror/lang-markdown"
export { yaml } from "@codemirror/lang-yaml"
export { xml } from "@codemirror/lang-xml"
export { html } from "@codemirror/lang-html"
export { css } from "@codemirror/lang-css"
export { rust } from "@codemirror/lang-rust"
export { go } from "@codemirror/lang-go"
export { sql } from "@codemirror/lang-sql"
export { shell } from "@codemirror/legacy-modes/mode/shell"
export { toml } from "@codemirror/legacy-modes/mode/toml"
export { simpleMode } from "@codemirror/legacy-modes/mode/simple-mode"
```

- [ ] **Step 2: Write the build script**

Create `bin/build-codemirror` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# Rebuild vendor/javascript/codemirror.js from vendor/javascript/codemirror-entry.js.
#
# ONE BUNDLE, NEVER PER-PACKAGE IMPORTMAP PINS. Two reasons, and the second is the one that bites:
#
#   1. `bin/importmap pin @codemirror/view` resolves through jspm, which splits packages into
#      internal `../_/<hash>.js` chunks that `pin` does not vendor and Propshaft's flat /assets
#      serving could not satisfy anyway. config/importmap.rb documents that failure twice already
#      (JSZip, Three.js).
#   2. TWO COPIES OF @codemirror/state BREAK CODEMIRROR SILENTLY. Facets and StateFields have
#      OBJECT identity, so an extension built against copy A is simply ignored by a view built on
#      copy B — no error, no console warning, the editor just renders without the feature. That is
#      this repo's dominant failure shape (a green everything over something that never worked),
#      which is why test/ci_hygiene_test.rb forbids the pins rather than a comment asking nicely.
#
# This differs from every other file in vendor/javascript/, which are unmodified upstream bytes
# fetched from a CDN. That is what this script buys back: the artifact is reproducible from
# pinned versions by anyone, rather than being bytes of unknown provenance.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/package.json" <<'JSON'
{
  "name": "tinkerex-codemirror-bundle",
  "private": true,
  "dependencies": {
    "@codemirror/lang-cpp": "6.0.3",
    "@codemirror/lang-css": "6.3.1",
    "@codemirror/lang-go": "6.0.1",
    "@codemirror/lang-html": "6.4.12",
    "@codemirror/lang-javascript": "6.2.5",
    "@codemirror/lang-json": "6.0.2",
    "@codemirror/lang-markdown": "6.5.2",
    "@codemirror/lang-python": "6.2.1",
    "@codemirror/lang-rust": "6.0.2",
    "@codemirror/lang-sql": "6.10.0",
    "@codemirror/lang-xml": "6.1.0",
    "@codemirror/lang-yaml": "6.1.3",
    "@codemirror/legacy-modes": "6.5.3",
    "codemirror": "6.0.2",
    "esbuild": "0.28.2"
  }
}
JSON

cp "$ROOT/vendor/javascript/codemirror-entry.js" "$WORK/entry.js"

echo "installing pinned CodeMirror packages…"
(cd "$WORK" && npm install --silent --no-audit --no-fund)

echo "bundling…"
(cd "$WORK" && npx esbuild entry.js \
  --bundle --format=esm --minify --target=es2020 \
  --legal-comments=none \
  --outfile=codemirror.js)

cp "$WORK/codemirror.js" "$ROOT/vendor/javascript/codemirror.js"

SIZE=$(wc -c < "$ROOT/vendor/javascript/codemirror.js")
GZIP=$(gzip -9 -c "$ROOT/vendor/javascript/codemirror.js" | wc -c)
printf 'wrote vendor/javascript/codemirror.js — %d bytes (%d gzipped)\n' "$SIZE" "$GZIP"
```

- [ ] **Step 3: Run it**

```bash
bin/build-codemirror
```

Expected: `wrote vendor/javascript/codemirror.js — ~933000 bytes (~325000 gzipped)`. The measured
figures at design time were 911.9 KB minified / 317.0 KB gzipped; a few KB either way is version
drift, a large difference means the entry file changed.

- [ ] **Step 4: Pin it — exactly one pin**

In `config/importmap.rb`, add beside the other vendored libraries:

```ruby
# CodeMirror 6 (MIT) — the read-only source viewer (codeview_controller.js), DYNAMIC-imported so
# the payload ships only on a page showing a text file. ONE PIN FOR ONE BUNDLE, built by
# bin/build-codemirror from vendor/javascript/codemirror-entry.js.
#
# NEVER add `pin "@codemirror/..."` lines beside this. Two copies of @codemirror/state make
# facets and StateFields fail to match by object identity, and CM6 responds by silently ignoring
# the extension — no error, no warning. test/ci_hygiene_test.rb fails the build if a per-package
# pin appears.
pin "codemirror", to: "codemirror.js" # bundle: see bin/build-codemirror for pinned versions
```

- [ ] **Step 5: Write the failing guard**

Append to `test/ci_hygiene_test.rb`:

```ruby
  test "the CodeMirror bundle is pinned once, and never per package" do
    importmap = Rails.root.join("config/importmap.rb").read
    pins = importmap.scan(/^\s*pin\s+"([^"]+)"/).flatten

    # NON-VACUOUS FIRST (§14e): a guard that scans a file dies silently when the file moves or the
    # syntax changes, and `assert_empty offenders` over an empty parse passes perfectly forever.
    assert_operator pins.size, :>, 5, "parsed #{pins.size} pins — the importmap parse is broken, " \
                                      "so everything below this line is vacuous"

    assert_includes pins, "codemirror", "the bundle pin is missing"

    offenders = pins.grep(%r{\A@codemirror/})
    assert_empty offenders,
                 "per-package CodeMirror pins (#{offenders.join(', ')}) load a second copy of " \
                 "@codemirror/state, which makes CM6 ignore extensions SILENTLY — no error, no " \
                 "console warning. Add languages to vendor/javascript/codemirror-entry.js and " \
                 "re-run bin/build-codemirror instead."
  end

  test "the pinned CodeMirror bundle file actually exists" do
    assert Rails.root.join("vendor/javascript/codemirror.js").exist?,
           "run bin/build-codemirror"
  end
```

- [ ] **Step 6: Run it**

```bash
bin/rails test test/ci_hygiene_test.rb
```

Expected: PASS.

- [ ] **Step 7: Mutation-check the guard (§15)**

Add `pin "@codemirror/state"` to `config/importmap.rb` and re-run. Expected: **RED** naming the
offender. Remove it. Then change the scan regex to something that matches nothing and re-run:
expected **RED** on the non-vacuous assertion, not a false green. Restore.

- [ ] **Step 8: Commit**

```bash
git add bin/build-codemirror vendor/javascript/codemirror-entry.js vendor/javascript/codemirror.js config/importmap.rb test/ci_hygiene_test.rb
git commit -m "Vendor CodeMirror 6 as one bundle, and forbid per-package pins"
```

---

## Task 9: The `codeview` controller

**Files:**
- Create: `app/javascript/lib/codemirror_languages.js`
- Create: `app/javascript/controllers/codeview_controller.js`
- Delete: `app/javascript/controllers/textpreview_controller.js`
- Modify: `app/views/files/show.html.erb:119-123`, `config/importmap.rb`
- Test: `test/integration/web/files_show_test.rb` (or the closest existing home)

- [ ] **Step 1: Write the language table**

Create `app/javascript/lib/codemirror_languages.js`:

```javascript
// ext -> CodeMirror LanguageSupport. A HOST module, imported only by codeview_controller.
//
// THE DEFAULT IS NO LANGUAGE, NOT A GUESS. An unknown extension renders as plain text with line
// numbers, which is honest; highlighting a file as the wrong language is worse than not
// highlighting it, because it renders confidently wrong.
//
// gcode and scad are OURS. Neither exists in @codemirror/legacy-modes (checked, 6.5.3) and both
// are cheap: a simpleMode is a regex tokenizer, measured at +0.1 KB against the bundle. Do not
// reach for a full lezer grammar for either.
export function languageFor(ext, cm) {
  switch (ext) {
    case "c": case "h": case "cpp": case "cc": case "hpp": case "ino": return cm.cpp()
    case "py": return cm.python()
    case "js": case "ts": return cm.javascript({ typescript: ext === "ts" })
    case "json": return cm.json()
    case "md": case "markdown": return cm.markdown()
    case "yml": case "yaml": return cm.yaml()
    case "xml": case "lbrn2": case "lbrn": return cm.xml()
    case "html": return cm.html()
    case "css": return cm.css()
    case "rs": return cm.rust()
    case "go": return cm.go()
    case "sql": return cm.sql()
    case "sh": return cm.StreamLanguage.define(cm.shell)
    case "toml": case "ini": case "cfg": case "conf": return cm.StreamLanguage.define(cm.toml)
    case "gcode": case "gco": case "nc": case "tap": case "ngc":
      return cm.StreamLanguage.define(cm.simpleMode(GCODE))
    case "scad": return cm.StreamLanguage.define(cm.simpleMode(OPENSCAD))
    default: return null
  }
}

// G-code. Comments are BOTH `( … )` and `; …` — the two dialects in this app's own vocabulary
// (LinuxCNC/GRBL `;`, Fanuc-style parentheses) — and a mode handling only one renders half a
// file as code.
const GCODE = {
  start: [
    { regex: /\(.*?\)/, token: "comment" },
    { regex: /;.*/, token: "comment" },
    { regex: /^%/, token: "meta" },
    { regex: /[GgMm]\d+(?:\.\d+)?/, token: "keyword" },
    { regex: /[NnTtSsFf]\d+/, token: "atom" },
    { regex: /[A-Za-z](?=[-+]?[\d.])/, token: "variableName" },
    { regex: /[-+]?(?:\d*\.\d+|\d+\.?)/, token: "number" }
  ]
}

// OpenSCAD. C-like, so the token set is small; `include`/`use` take `<angle>` paths rather than
// quoted strings, which is why they get their own rule before the string rule.
const OPENSCAD = {
  start: [
    { regex: /\/\/.*/, token: "comment" },
    { regex: /\/\*/, token: "comment", next: "comment" },
    { regex: /(?:include|use)\s*<[^>]*>/, token: "meta" },
    { regex: /"(?:[^\\"]|\\.)*"/, token: "string" },
    { regex: /\b(?:module|function|if|else|for|intersection_for|let|each|true|false|undef)\b/,
      token: "keyword" },
    { regex: /\b(?:cube|sphere|cylinder|polyhedron|square|circle|polygon|text|linear_extrude|rotate_extrude|translate|rotate|scale|mirror|multmatrix|color|offset|hull|minkowski|union|difference|intersection|render|surface|projection|import|children)\b/,
      token: "builtin" },
    { regex: /\$[A-Za-z_]\w*/, token: "variableName.special" },
    { regex: /[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/, token: "number" }
  ],
  comment: [
    { regex: /.*?\*\//, token: "comment", next: "start" },
    { regex: /.*/, token: "comment" }
  ],
  languageData: { commentTokens: { line: "//", block: { open: "/*", close: "*/" } } }
}
```

Add the pin in `config/importmap.rb` beside the other `lib/` host pins:

```ruby
# The codeview controller's ext -> language table. A host module; no addon bundle may import it.
pin "lib/codemirror_languages", to: "lib/codemirror_languages.js"
```

- [ ] **Step 2: Write the controller**

Create `app/javascript/controllers/codeview_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Read-only source viewer. Replaces textpreview_controller, which rendered a bare <pre>.
//
// THE FETCH RUNS FIRST AND THE BUNDLE LOADS SECOND, deliberately. The bytes are the thing the
// user came for; if the 912 KB bundle fails to load — offline, a CSP change, a bad deploy — the
// <pre> fallback already holds the file's text and the page degrades to exactly what it used to
// be. Loading the bundle first would trade a working page for a spinner.
//
// DYNAMIC import(), like modelviewer_controller does for Three.js: a page with no text file never
// downloads the bundle at all.
const MAX_CHARS = 200_000

export default class extends Controller {
  static targets = ["fallback"]
  static values = { url: String, ext: String }

  async connect() {
    let text
    try {
      const res = await fetch(this.urlValue)
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
      text = await res.text()
      if (text.length > MAX_CHARS) text = text.slice(0, MAX_CHARS) + "\n… (truncated)"
    } catch (e) {
      this.fallbackTarget.textContent = `Could not load preview: ${e.message}`
      return
    }

    this.fallbackTarget.textContent = text

    let cm, languages
    try {
      ;[cm, languages] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages")
      ])
    } catch (e) {
      return // the <pre> above is already showing the file; that is the degraded state
    }
    if (this.disconnected) return

    const language = languages.languageFor(this.extValue, cm)
    const extensions = [
      cm.basicSetup,
      // BOTH, and neither is redundant. readOnly refuses document changes; editable removes the
      // caret and IME. A contenteditable that merely looks disabled still takes focus and still
      // accepts an IME composition.
      cm.EditorState.readOnly.of(true),
      cm.EditorView.editable.of(false)
    ]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: text, extensions }),
      parent: this.element
    })
    this.fallbackTarget.remove()
  }

  disconnect() {
    this.disconnected = true
    this.view?.destroy()
    this.view = null
  }
}
```

- [ ] **Step 3: Swap the view**

In `app/views/files/show.html.erb`, replace the `:text` branch (lines ~119-123):

```erb
  <% elsif @kind == :text %>
    <%# Source viewer — CodeMirror 6, loaded dynamically by codeview_controller. The inner <pre>
        is the fallback AND the resting state: the controller fills it with the fetched text
        first and only removes it once the editor is mounted, so a failed bundle load degrades to
        the plain preview this branch used to be. %>
    <div class="preview-code"
         data-controller="codeview"
         data-codeview-url-value="<%= blob_file_path(@node.node_id) %>"
         data-codeview-ext-value="<%= File.extname(@node.name).downcase.delete('.') %>">
      <pre class="preview-text" data-codeview-target="fallback">Loading…</pre>
    </div>
```

- [ ] **Step 4: Delete the superseded controller**

```bash
git rm app/javascript/controllers/textpreview_controller.js
grep -rn "textpreview" app/ config/ test/
```

Expected from the grep: no results. If any remain, they are dead references — fix them now.

- [ ] **Step 5: Write the rendered-output test**

Add to the files-show integration test:

```ruby
  test "a source file renders the codeview controller with its extension" do
    # ASSERT THE RENDERED ATTRIBUTES, not the Ruby that produces them (§14d): a data-controller
    # naming nothing is a silent no-op, and a values mismatch is equally silent.
    get file_path(@node_for("main.cpp"))

    assert_select "[data-controller=codeview]", 1
    assert_select "[data-codeview-ext-value=cpp]", 1
    assert_select "[data-codeview-target=fallback]", 1
  end
```

Match this suite's existing fixture idiom for creating a node and resolving its path; read a
neighbouring test first rather than inventing `@node_for`.

- [ ] **Step 6: Run the suite**

```bash
bin/rails test test/integration/web/ test/stimulus_hygiene_test.rb
```

Expected: PASS. `stimulus_hygiene_test.rb` derives registered identifiers from filenames, so it
covers `codeview` resolving with no test edit — and would have caught the deleted `textpreview`
if a view still named it.

- [ ] **Step 7: Look at the page (§14d — a green suite cannot see an ERB comment printing itself)**

```bash
bin/rails server
```

Open a `.cpp`, a `.gcode` and a `.scad` file in the library. Confirm: line numbers, highlighting,
no caret when clicking in the text, and no SEVERE console errors. Then open a `.txt` and confirm
it renders plainly rather than erroring.

- [ ] **Step 8: Verify the s3 fetch path (recorded in the spec as unverified)**

```bash
bin/ci test-s3
```

Then, against a real s3 deployment, open a text file and check the browser console for a CORS
error on the presigned redirect. **If it fails, it fails today too** — `textpreview` has the same
exposure — so record it as a pre-existing bug and fix it in its own change rather than widening
this one.

- [ ] **Step 9: Commit**

```bash
git add app/javascript/ app/views/files/show.html.erb config/importmap.rb test/
git commit -m "codeview: a read-only CodeMirror source viewer, replacing the bare <pre>"
```

---

## Close-out

- [ ] **Verify the bundle is reproducible**

```bash
shasum -a 256 vendor/javascript/codemirror.js && bin/build-codemirror && shasum -a 256 vendor/javascript/codemirror.js
```

Expected: identical digests. If they differ, the versions in `bin/build-codemirror` are not fully
pinned (a transitive dependency floated) and the artifact's provenance claim is false — pin the
offender before shipping.

- [ ] **Verify the truncation cap against a real machine file**

Put a g-code file of 20 MB or more in the library (a sliced print is the easy source) and open it.
Expected: the page renders the first 200,000 characters with the `… (truncated)` marker and stays
responsive. The spec records this as unverified; if CodeMirror struggles well below the cap, lower
`MAX_CHARS` in `codeview_controller.js` and say so in the STATUS entry rather than leaving the
number as measured-by-nobody.

- [ ] **Check whether the bundle is served compressed**

```bash
curl -sI -H 'Accept-Encoding: gzip' https://<deployed-host>/assets/codemirror-<digest>.js | grep -i content-encoding
```

912 KB versus 317 KB is the entire difference between a fine first load and a bad one, and nothing
in this repo currently asserts which one users get. Record the answer in the STATUS entry either
way — an unmeasured claim about it is worse than none (§15).

- [ ] **Run every gate**

```bash
bin/ci
```

The three backend legs (`test`, `test-s3`, `test-chunk-remote`) must report **identical run
counts**; `test-chunk-remote` needs `../tinkerex-sync` checked out (§13). A ±2 assertion
difference is the known flap recorded in `docs/STATUS.md`; a structural difference means a test
depends on the ambient `LIBRARY_BACKEND` and is a real bug.

- [ ] **Update `CLAUDE.md` §14b** with two one-line invariants (the rule, not the story):
  - `.git`'s CONTENTS are skipped while the DIR NODE is kept — the marker is what makes a working
    tree detectable, and `Library::RepoMetadata` owns the one definition.
  - `Maker::AttachToProject`'s `:in_working_tree` is UNSCOPED, unlike `:attached_elsewhere`.

- [ ] **Update `CLAUDE.md` §14d** with one line: the CodeMirror bundle is ONE pin; per-package
  `@codemirror/*` pins duplicate `@codemirror/state` and make CM6 ignore extensions silently.

- [ ] **Write the `docs/STATUS.md` entry in THIS branch** — §15 is explicit that a deferred STATUS
  entry does not happen. One entry for the whole arc, carrying the measured bundle figures
  (912 KB / 317 KB, the per-language table) and what was left out (editing, grid thumbnails for
  code, the tree UI).

- [ ] **Open the PR** via `/finish-branch`. State plainly what was verified on hardware and what
  was not — specifically the s3 CORS question from Task 9 Step 8.
