# Edit and commit files in a git repository — Implementation Plan

> **For agentic workers:** this repo overrides the generic subagent loop. Use
> **`.claude/commands/execute-plan.md`** (`/execute-plan`) — batch by FILE, run independent tasks in
> PARALLEL, no spec-compliance stage, and cap each quality review to named claims. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A maker can open a text file inside a git repository they brought, edit it, save it, review
an inline diff, and commit selected paths — without leaving tinkerex.

**Architecture:** Two write doors. **Save** goes through the `FileLayer` port
(`write(replace: true)`, node reused) and works on all three backends. **Commit** bypasses the port
and drives rugged directly against `<repo>/.git`, gated on a new `local_worktree` capability that is
true on `share` alone. Eligibility is "any file inside a working tree", answered by one shared
ancestor walk.

**Tech Stack:** Rails 8, rugged (libgit2), CodeMirror 6 + `@codemirror/merge` (vendored bundle),
Hotwire/Stimulus, SQLite in dev/test and Postgres in production.

**Spec:** `docs/superpowers/specs/2026-08-28-edit-and-commit-in-a-repo-design.md`.
Bare `§` below means **CLAUDE.md**; the spec's own sections are cited as **spec part N**.

---

## Before you start

> **There is NO users fixture in this repo, and `users(:one)` appears nowhere in the suite.**
> Unit tests build a user with `User.create!(email: "prefix-#{SecureRandom.hex(4)}@example.com")`
> (see `test/services/file_layer/s3_test.rb`); web integration tests add a password and define
> their own `sign_in_as`. Do not reach for a fixture.

- [ ] Read the spec end to end. Parts 3 (two write doors), 6 (the flow) and 8 (network filesystem)
      are the ones that will bite if skipped.
- [ ] Read `docs/invariants/project-intake.md` — Task 3 moves a method `Maker::ProjectIntake` depends on.
- [ ] Confirm `../tinkerex-sync` is cloned, or export `TINKEREX_SYNC_DIR`; the `test-chunk-remote` leg
      needs it (§13).
- [ ] **Write `test/support/git_repo_fixture.rb` first** — its code is Task 7 Step 1, but Tasks 5,
      7, 9, 10 and 13 all include it. Doing it up front avoids writing tests against a helper that
      does not exist yet.

**Test commands used throughout:**

```bash
bin/rails test test/path/to/file_test.rb -n test_name
```

The three backend legs, which must report identical run counts (§15):

```bash
bin/ci test && bin/ci test-s3 && bin/ci test-chunk-remote
```

---

## File structure

**New**

| Path | Responsibility |
|---|---|
| `app/services/library/working_tree.rb` | Walk ancestors to the nearest `.git` marker; return the repo ROOT node |
| `app/services/maker/git/local_repo.rb` | Open a repository in place; state and lock refusals; status for given paths |
| `app/services/maker/git/commit_paths.rb` | HEAD's tree with selected paths replaced; ref compare-and-swap; index update |
| `app/models/maker/repo_edit.rb` | One row per pending edit |
| `db/migrate/20260828160000_create_maker_repo_edits.rb` | That table |
| `app/controllers/repo_commits_controller.rb` | Review + commit |
| `app/views/repo_commits/show.html.erb` | The commit box |
| `app/javascript/controllers/editor_controller.js` | Editable CodeMirror mount, dirty tracking, save |
| `test/services/library/working_tree_test.rb` | |
| `test/services/maker/git/local_repo_test.rb` | |
| `test/services/maker/git/commit_paths_test.rb` | |
| `test/integration/web/repo_edit_flow_test.rb` | Save + commit through the real doors |
| `test/integration/web/repo_commit_wedge_test.rb` | The scanner assertion (Task 13) |
| `test/support/git_repo_fixture.rb` | Build real repositories with rugged |

**Modified**

| Path | Change |
|---|---|
| `Gemfile`, `Dockerfile` | rugged back (Task 1) |
| `app/services/file_layer/capabilities.rb` | 7th member |
| `app/services/file_layer/{share,s3,chunk_remote}.rb` | answer it |
| `app/services/maker/attach_to_project.rb` | ask `Library::WorkingTree` instead of owning the walk |
| `app/controllers/files_controller.rb` | `#update` |
| `app/views/files/show.html.erb` | editable branch |
| `app/javascript/controllers/codeview_controller.js` | read-only stays default |
| `config/routes.rb` | `PATCH /files/:id`, repo commit routes |
| `vendor/javascript/codemirror-entry.js`, `bin/build-codemirror` | `@codemirror/merge` |
| `test/architecture_invariants_test.rb` | no adapter class-checks under `maker/git/` |
| `test/services/file_layer/adapter_contract.rb` | assert the new capability is answered |

---

# Phase 0 — the seam

No user-visible change. Everything here is machinery the two later phases stand on.

---

## Task 1: rugged back in the Gemfile and the image

The revert removed rugged **and** `diff-lcs`. Only rugged comes back: `@codemirror/merge` diffs in
the browser, so there is no server-side text diff to write (spec part 13).

**Files:**
- Modify: `Gemfile`
- Modify: `Dockerfile`

- [ ] **Step 1: Recover the exact notes the revert removed**

They record two image-build failures that no local `bundle install` reproduces. Do not paraphrase them.

```bash
git show c3b2430 -- Gemfile Dockerfile | grep -E '^-' | sed 's/^-//' | less
```

- [ ] **Step 2: Add the gem**

In `Gemfile`, beside the other runtime gems:

```ruby
# libgit2 bindings, for editing and committing in a repository the maker brought
# (Maker::Git::LocalRepo).
#
# LICENCE NOTE, because §9 says avoid GPL and a future reader will otherwise flag this as a
# violation: libgit2 is GPL-2.0 WITH A LINKING EXCEPTION, written expressly to permit linking from
# a program under any licence. That is what makes it usable here where the `git` CLI is not --
# shipping the binary would put a GPL executable in our image, which is why this repo's answer to
# GPL everywhere else is an HTTP sidecar (§14c).
#
# IT DOES NOT COVER PACKING. Rugged::Repository exposes 69 instance methods and not one matches
# pack/repack/gc/prune; Packbuilder, Indexer and Odb are undefined. Measured against the built gem,
# not read off its README. Nothing here packs -- see docs/roads-not-taken.md §9 for why that
# matters only if git on s3 is ever revived.
gem "rugged"
```

**Do NOT add `diff-lcs`.** If you find yourself wanting it, you are about to rebuild
`Maker::Git::TextDiff`, which this design deletes.

- [ ] **Step 3: Restore the image's build dependency**

In `Dockerfile`, restore `cmake` to the build-stage `apt-get install` line and the flags above it:

```dockerfile
# `cmake` IS HERE FOR rugged, which compiles libgit2 from source at gem-install time.
#
# AND libgit2 IS BUILT WITHOUT HTTPS OR SSH, WHICH IS THE CORRECT MINIMAL BUILD RATHER THAN A
# WORKAROUND -- nothing in this app talks to a git REMOTE. Maker::Git::LocalRepo does local object,
# tree and ref work against a directory. Turning both off drops the OpenSSL dependency entirely.
#
# IT IS ALSO WHAT MAKES THE BUILD WORK AT ALL, and finding that out needed a real image build --
# no local `bundle install` reproduces it, because the Mac has OpenSSL and this slim Debian stage
# does not. Two failures in sequence, both only visible here: first libgit2's cmake aborts with
# "Unable to autodetect a usable HTTPS backend"; add libssl-dev and it configures, then mkmf fails
# at `checking for -lgit2` because the static libgit2 now needs OpenSSL symbols that its test link
# does not pull in. Removing the dependency fixes both at the root.
ENV CMAKE_FLAGS="-DUSE_HTTPS=OFF -DUSE_SSH=OFF"
```

- [ ] **Step 4: Install and verify the capabilities the spec assumes**

```bash
bundle install
bin/rails runner 'require "rugged"; puts Rugged::VERSION; puts Rugged::Repository.instance_methods.grep(/ignored|diff_workdir/).sort.inspect'
```

Expected: a version, and `[:diff_workdir, :path_ignored?]`. If `bundle install` fails on the Mac,
install cmake (`brew install cmake`) — that is the same dependency Step 3 adds to the image.

- [ ] **Step 5: Commit**

```bash
git add Gemfile Gemfile.lock Dockerfile
git commit -m "$(cat <<'EOF'
Bring rugged back, without diff-lcs (tinkerex#178)

The revert removed both. Only rugged returns: @codemirror/merge diffs in the browser, so
there is no server-side text diff to rebuild.

The Gemfile and Dockerfile notes are restored verbatim rather than paraphrased -- they
record two libgit2 build failures that only a real image build reproduces, because the Mac
has OpenSSL and the slim Debian stage does not.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: the `local_worktree` capability

**Files:**
- Modify: `app/services/file_layer/capabilities.rb`
- Modify: `app/services/file_layer/share.rb:16-29`
- Modify: `app/services/file_layer/s3.rb:74-86`
- Modify: `app/services/file_layer/chunk_remote.rb:51-54`
- Modify: `test/services/file_layer/adapter_contract.rb`

- [ ] **Step 1: Write the failing contract assertion**

Add to `test/services/file_layer/adapter_contract.rb`, inside `module FileLayerAdapterContract`:

```ruby
  # EVERY adapter answers this, and only Share answers true. Asserted in the shared contract
  # rather than per-adapter so a fourth backend cannot quietly omit it -- the omission would
  # read as "commits are unavailable here", which is indistinguishable from a correct false.
  def test_local_worktree_is_answered_and_only_share_says_yes
    caps = adapter.capabilities

    assert_includes [ true, false ], caps.local_worktree,
                    "local_worktree must be a real boolean, not nil"
    assert_equal adapter.is_a?(FileLayer::Share), caps.local_worktree?,
                 "only a real local filesystem can be handed to git in place"
  end
```

> The `is_a?` here is deliberate and is the **one** place it is allowed: a test asserting which
> adapter answers true is the opposite of production code branching on the class. Task 12's guard
> scopes itself to `app/` for exactly this reason.

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/file_layer/share_test.rb -n test_local_worktree_is_answered_and_only_share_says_yes
```

Expected: FAIL — `NoMethodError: undefined method 'local_worktree'`.

- [ ] **Step 3: Add the member**

In `app/services/file_layer/capabilities.rb`, extend the `Data.define` and add the predicate. Put
this comment above `Capabilities` alongside the existing ones:

```ruby
  # LOCAL_WORKTREE answers ONE question, for ONE caller — the git editing surface:
  #
  #   Is the library a real filesystem this process can hand to git IN PLACE?
  #
  # share true; s3 false (a flat keyspace has no directory to open); chunk_remote false (the
  # `nodes` table is a mirror and the bytes are remote).
  #
  # IT IS NOT `scannable`, WHICH IS TRUE FOR S3. It is not `port_writable` either, which is also
  # true for s3. It agrees with NO existing capability, so unlike scannable/port_writable/
  # dir_deletable there is not even a coincidence here to mistake for an identity.
  #
  # NEVER SPELL THIS `is_a?(FileLayer::Share)`. That class check is what §14b records as having
  # made Library::ScanJob answer false for S3 and silently never index the library. Widening
  # commits to another backend must be a new ANSWER here, never a rewrite of the callers.
  # Note the mutation this cannot catch, and what does catch it: spec part 12.
  Capabilities = Data.define(:versioned, :syncable, :presignable, :scannable, :port_writable,
                             :dir_deletable, :local_worktree) do
    def versioned? = versioned
    def syncable? = syncable
    def presignable? = presignable
    def scannable? = scannable
    def port_writable? = port_writable
    def dir_deletable? = dir_deletable
    def local_worktree? = local_worktree
  end
```

- [ ] **Step 4: Answer it in all three adapters**

`share.rb` — add to the existing `Capabilities.new(...)` call and extend its comment:

```ruby
      # local_worktree: true — the library IS a mounted filesystem, so a repository inside it can
      # be opened by rugged in place, with no hydration. This is the ONLY backend that can say so,
      # and it is why committing is share-only (spec part 3c). It is a NETWORK filesystem though,
      # which is a live hazard rather than a footnote — spec part 8.
      Capabilities.new(versioned: false, syncable: false, presignable: false, scannable: true,
                       port_writable: true, dir_deletable: false, local_worktree: true)
```

`s3.rb`:

```ruby
      # local_worktree: false — a flat keyspace has no directory to hand to git. Making this true
      # would mean materialising the repository first; measured at 11,287 GETs on a cold container
      # for an unpacked repo (docs/roads-not-taken.md §9).
      Capabilities.new(versioned: false, syncable: false, presignable: true, scannable: true,
                       port_writable: true, dir_deletable: false, local_worktree: false)
```

`chunk_remote.rb`:

```ruby
    # local_worktree: false — the `nodes` table is a MIRROR and the bytes are remote. The reason
    # not to commit here is not cost, though: the maker's own machine has this repository checked
    # out with real git, so a server-side commit would move refs under a live working copy.
    CAPABILITIES = Capabilities.new(
      versioned: true, syncable: true, presignable: false,
      scannable: false, port_writable: false, dir_deletable: true, local_worktree: false
    ).freeze
```

- [ ] **Step 5: All three legs green**

```bash
bin/ci test && bin/ci test-s3 && bin/ci test-chunk-remote
```

Expected: PASS on all three, with identical run counts (§15; a ±2 assertion flap is `tinkerex#131`).

- [ ] **Step 6: Mutation-check**

Flip `local_worktree: true` to `false` in `share.rb`. Re-run the share leg — the contract test must
go **RED**. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/services/file_layer/ test/services/file_layer/adapter_contract.rb
git commit -m "$(cat <<'EOF'
Add the local_worktree capability (tinkerex#178)

"Is the library a real filesystem this process can hand to git in place?" -- share true,
s3 and chunk_remote false. Named for the question rather than for who says yes today.

It agrees with NO existing capability: scannable and port_writable are both TRUE for s3.
So unlike scannable/port_writable/dir_deletable there is not even a coincidence here to
mistake for an identity.

Asserted in the SHARED contract, so a fourth backend cannot quietly omit it -- an omission
would read as "commits are unavailable here", indistinguishable from a correct false.
Mutation-checked: flipping share to false turns the contract red.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `Library::WorkingTree` — one ancestor walk, moved not copied

`Maker::AttachToProject#in_working_tree?` answers a boolean. The git surface needs the **root node**.
Two walks would be two definitions; §14d says a verb more than one caller performs gets a named
service.

**Files:**
- Create: `app/services/library/working_tree.rb`
- Create: `test/services/library/working_tree_test.rb`
- Modify: `app/services/maker/attach_to_project.rb:219-254`

- [ ] **Step 1: Write the failing test**

`test/services/library/working_tree_test.rb`:

```ruby
require "test_helper"

class Library::WorkingTreeTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com")
    @tree = Library::WorkingTree.new(@user)
  end

  def dir!(name, parent: nil)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir",
                        parent_node_id: parent&.node_id)
  end

  def file!(name, parent:)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                        parent_node_id: parent.node_id)
  end

  test "returns the repository root for a file inside a working tree" do
    repo = dir!("TheFlightWall_OSS")
    dir!(".git", parent: repo)
    src  = dir!("src", parent: repo)
    file = file!("main.cpp", parent: src)

    assert_equal repo.node_id, @tree.root_for(file)&.node_id
  end

  test "returns nil outside a working tree" do
    plain = dir!("Models")
    assert_nil @tree.root_for(file!("bracket.stl", parent: plain))
  end

  # The marker node is the repository root's CHILD, so the root is its parent -- not the marker.
  test "the marker itself resolves to its parent, not to itself" do
    repo   = dir!("catan")
    marker = dir!(".git", parent: repo)

    assert_equal repo.node_id, @tree.root_for(marker)&.node_id
  end

  # A tombstoned .git is not a working tree. Without this, deleting a repository would freeze its
  # former folder against the intake sweep forever with nothing visible saying why.
  test "a tombstoned marker is not a working tree" do
    repo = dir!("catan")
    dir!(".git", parent: repo).update!(deleted: true)

    assert_nil @tree.root_for(file!("board.stl", parent: repo))
  end

  # RepoMetadata's rule is "a DIRECTORY named .git". A .git FILE is a submodule or linked-worktree
  # pointer and nothing here reads the pointer, so treating it as a marker would be right by
  # accident and wrong by construction.
  test "a .git FILE is not a marker" do
    repo = dir!("submodule")
    file!(".git", parent: repo)

    assert_nil @tree.root_for(file!("thing.txt", parent: repo))
  end

  test "the nearest marker wins for a nested repository" do
    outer = dir!("outer");  dir!(".git", parent: outer)
    inner = dir!("inner", parent: outer); dir!(".git", parent: inner)

    assert_equal inner.node_id, @tree.root_for(file!("a.txt", parent: inner))&.node_id
  end

  test "the ancestor walk is memoised per parent" do
    repo = dir!("r"); dir!(".git", parent: repo)
    deep = dir!("a", parent: repo)
    files = 5.times.map { |i| file!("f#{i}.txt", parent: deep) }

    @tree.root_for(files.first)
    after = count_queries { files.each { |f| @tree.root_for(f) } }

    assert_equal 0, after, "a second lookup under a known parent must not query"
  end

  def count_queries
    n = 0
    sub = ->(*, payload) { n += 1 unless payload[:name].in?(%w[CACHE SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(sub, "sql.active_record") { yield }
    n
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/services/library/working_tree_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Library::WorkingTree`.

- [ ] **Step 3: Write the service**

`app/services/library/working_tree.rb`:

```ruby
module Library
  # Is this node inside a git working tree, and if so where does that tree START?
  #
  # MOVED OUT OF Maker::AttachToProject, NOT COPIED. That class asked a boolean
  # (`in_working_tree?`) and the git editing surface needs the ROOT NODE, so keeping both would be
  # one question with two implementations -- the drift §14d names a service to end. AttachToProject
  # now asks this and compares against nil; its rules came with the walk and are restated below
  # because they are load-bearing, not decoration.
  #
  # THE ROOT IS THE MARKER'S PARENT. `Library::RepoMetadata` keeps the `.git` directory node
  # indexed precisely so this question is answerable, on all three backends -- on chunk_remote the
  # mirror carries whatever the desktop client synced, and app/services/library/repo_metadata_purge.rb
  # records as a decision that those rows are HIDDEN rather than removed.
  #
  # `present` AND `kind: "dir"` ARE BOTH LOAD-BEARING. A tombstoned `.git` is not a working tree --
  # without the scope, deleting a repository would freeze its former folder against
  # Maker::ProjectIntake's sweep forever with nothing visible saying why. And a `.git` FILE is a
  # submodule's or a linked worktree's `gitdir:` pointer; nothing here reads the pointer, so
  # treating it as a marker would be right by accident and wrong by construction.
  #
  # MEMOISED ON THE PARENT, NOT ON THE NODE. Maker::ProjectIntake sweeps every file at one project
  # folder's root through this, so without the memo the walk runs once per FILE at two queries per
  # level. The memo lives on the instance and the instance lives for one sweep or one request, so
  # there is no staleness window worth naming.
  class WorkingTree
    # A cap on the ancestor walk. Not defensive dressing: `parent_node_id` is a plain string column
    # with no foreign key, so a cycle is representable and an uncapped `while` here is an infinite
    # loop in a request.
    MAX_ANCESTOR_WALK = 64

    def initialize(user)
      @user = user
      @roots = {}
    end

    # The repository ROOT node for `node`, or nil. A node that IS the marker resolves to its
    # parent, which is what makes `root_for` total over every node in a repository.
    def root_for(node)
      parent_id = node.parent_node_id
      return nil if parent_id.nil?
      return @roots[parent_id] if @roots.key?(parent_id)

      @roots[parent_id] = walk_for_root(parent_id)
    end

    def in_working_tree?(node) = !root_for(node).nil?

    private

    def walk_for_root(parent_id)
      id = parent_id
      MAX_ANCESTOR_WALK.times do
        break if id.nil?

        if @user.nodes.present.exists?(parent_node_id: id, kind: "dir",
                                       name: Library::RepoMetadata::DIR_NAME)
          return @user.nodes.present.find_by(node_id: id)
        end

        id = @user.nodes.where(node_id: id).pick(:parent_node_id)
      end
      nil
    end
  end
end
```

- [ ] **Step 4: Run the test**

```bash
bin/rails test test/services/library/working_tree_test.rb
```

Expected: PASS, 7 runs.

- [ ] **Step 5: Point `AttachToProject` at it**

In `app/services/maker/attach_to_project.rb`, delete `MAX_ANCESTOR_WALK`, `#in_working_tree?` and
`#walk_for_marker`, and replace the call site in `#refusal_for`:

```ruby
      return :in_working_tree if working_tree.in_working_tree?(node)
```

Add, beside the other memoised collaborators:

```ruby
    # ONE DEFINITION OF THE WALK, shared with the git editing surface (Library::WorkingTree's own
    # header says why it moved). Memoised here because the memo INSIDE it is per-instance, and
    # Maker::ProjectIntake sweeps every file at a project root through #refusal_for -- a fresh
    # instance per call would throw the memo away once per file.
    def working_tree = @working_tree ||= Library::WorkingTree.new(@user)
```

- [ ] **Step 6: The existing suites must still pass unchanged**

```bash
bin/rails test test/services/maker/attach_to_project_test.rb test/services/maker/project_intake_test.rb
```

Expected: PASS, no test edits needed. If a test had to change, the move was not behaviour-preserving —
stop and find out why.

- [ ] **Step 7: Mutation-check both directions**

§14j warns that one assertion catches "relaxation removed" and misses "protection removed".

1. Make `root_for` ignore `kind: "dir"` → the `.git` FILE test goes RED.
2. Make it ignore `.present` → the tombstoned-marker test goes RED.
3. Return the marker instead of its parent → the root tests go RED.

Restore after each.

- [ ] **Step 8: Commit**

```bash
git add app/services/library/working_tree.rb test/services/library/working_tree_test.rb app/services/maker/attach_to_project.rb
git commit -m "$(cat <<'EOF'
Move the .git ancestor walk into Library::WorkingTree (tinkerex#178)

AttachToProject asked a boolean; the git editing surface needs the repository ROOT node.
Keeping both would be one question with two implementations -- the drift §14d names a
service to end -- so this MOVES the walk rather than copying it, and AttachToProject now
asks it and compares against nil. Its existing suites pass unchanged.

The two load-bearing scopes came with it and are mutation-checked in both directions:
`present` (a tombstoned .git is not a working tree, or deleting a repository would freeze
its former folder against the intake sweep forever) and `kind: "dir"` (a .git FILE is a
submodule pointer nothing here reads).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

# Phase 1 — Save

After this phase a maker can edit and save a text file in a repository on **all three** backends.
No committing yet.

---

## Task 4: `maker_repo_edits`

**Files:**
- Create: `db/migrate/20260828160000_create_maker_repo_edits.rb`
- Create: `app/models/maker/repo_edit.rb`
- Create: `test/models/maker/repo_edit_test.rb`

- [ ] **Step 1: Write the failing test**

`test/models/maker/repo_edit_test.rb`:

```ruby
require "test_helper"

class Maker::RepoEditTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  test "one row per (user, node)" do
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r1", node_id: "n1")

    assert_raises(ActiveRecord::RecordNotUnique) do
      Maker::RepoEdit.insert!({ user_id: @user.id, repo_root_node_id: "r1", node_id: "n1",
                                created_at: Time.current, updated_at: Time.current })
    end
  end

  test "record! is idempotent and re-stamps rather than duplicating" do
    Maker::RepoEdit.record!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    travel 1.hour do
      Maker::RepoEdit.record!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    end

    assert_equal 1, Maker::RepoEdit.where(user: @user).count
  end

  test "pending_for is scoped to one repository and one user" do
    other = User.create!(email: "rt2-#{SecureRandom.hex(4)}@example.com")
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r1", node_id: "n1")
    Maker::RepoEdit.create!(user: @user, repo_root_node_id: "r2", node_id: "n2")
    Maker::RepoEdit.create!(user: other, repo_root_node_id: "r1", node_id: "n3")

    assert_equal [ "n1" ], Maker::RepoEdit.pending_for(@user, "r1").pluck(:node_id)
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/models/maker/repo_edit_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::RepoEdit`.

- [ ] **Step 3: Write the migration**

`db/migrate/20260828160000_create_maker_repo_edits.rb`:

```ruby
class CreateMakerRepoEdits < ActiveRecord::Migration[8.1]
  # One row per file edited through tinkerex and not yet committed.
  #
  # NO PATH COLUMN, DELIBERATELY. The catalog is the one source and the path is recomputed on read
  # via Maker::LibraryTree#path_for. A stored path would let this table disagree with the library
  # the moment a node moved, with no way to tell which was right.
  #
  # `node_id` AND `repo_root_node_id` ARE BARE STRINGS WITH NO FOREIGN KEY, the same shape and the
  # same population as maker_file_attachments. Reconciliation when the commit box opens is the
  # correctness mechanism (spec part 6 step 5); Maker::AttachmentReaper's precedent covers rows
  # whose node is gone for good.
  def change
    create_table :maker_repo_edits do |t|
      t.references :user, null: false, foreign_key: true
      t.string :repo_root_node_id, null: false
      t.string :node_id, null: false
      t.timestamps
    end

    add_index :maker_repo_edits, %i[user_id node_id], unique: true
    add_index :maker_repo_edits, %i[user_id repo_root_node_id]
  end
end
```

- [ ] **Step 4: Write the model**

`app/models/maker/repo_edit.rb`:

```ruby
module Maker
  # A file this app wrote into a git working tree, still waiting to be committed.
  #
  # THIS TABLE IS A HINT, NEVER AN AUTHORITY. It answers "which files did tinkerex touch", and
  # nothing else -- whether a path actually differs from HEAD is asked of git every time the commit
  # box opens (spec part 6 step 5). Treating a row as proof of a pending change is how the box
  # starts lying about the repository.
  class RepoEdit < ApplicationRecord
    self.table_name = "maker_repo_edits"

    belongs_to :user

    scope :pending_for, ->(user, repo_root_node_id) {
      where(user:, repo_root_node_id:).order(:updated_at)
    }

    # Idempotent by construction. A maker saves the same file repeatedly; that is one pending
    # edit, re-stamped, not N rows.
    def self.record!(user:, repo_root_node_id:, node_id:)
      row = find_or_initialize_by(user:, node_id:)
      row.repo_root_node_id = repo_root_node_id
      row.touch if row.persisted?
      row.save!
      row
    end
  end
end
```

- [ ] **Step 5: Migrate and run**

```bash
bin/rails db:migrate && bin/rails test test/models/maker/repo_edit_test.rb
```

Expected: PASS, 3 runs.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260828160000_create_maker_repo_edits.rb db/schema.rb app/models/maker/repo_edit.rb test/models/maker/repo_edit_test.rb
git commit -m "$(cat <<'EOF'
Add maker_repo_edits — one row per pending edit (tinkerex#178)

NO PATH COLUMN, deliberately: the catalog is the one source and the path is recomputed via
LibraryTree#path_for, so the table cannot disagree with the library after a node moves.

The row is a HINT, never an authority. Whether a path actually differs from HEAD is asked
of git every time the commit box opens; treating a row as proof is how the box starts lying
about the repository.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: the Save door

**Files:**
- Modify: `config/routes.rb:67-86`
- Modify: `app/controllers/files_controller.rb`
- Create: `test/integration/web/repo_edit_flow_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/integration/web/repo_edit_flow_test.rb`:

```ruby
require "test_helper"

require "support/git_repo_fixture"

class RepoEditFlowTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  # `sign_in_as` DOES NOT EXIST IN test_helper.rb. The only method by that name is a Capybara
  # helper in test/system/support/web_helpers.rb, which takes an EMAIL and drives the real form.
  # Every web integration test here defines its own; shelves_test.rb records a previous plan
  # having assumed otherwise, so do not assume it again.
  PASSWORD = "password123".freeze

  setup do
    @library = use_fresh_share_library!
    @user = User.create!(email: "re-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    sign_in_as(@user)
  end

  def sign_in_as(user)
    post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
  end

  # Drives the REAL door. §14e: the suite being green is not evidence a guard works if the
  # guard's precondition is never established in test.
  test "saving a text file in a working tree rewrites it and keeps the node" do
    node = seed_repo_file!("notes.md", "old\n")
    before = node.node_id

    patch file_path(node.node_id), params: { content: "new\n", base_token: token_for(node) }

    assert_response :success
    assert_equal "new\n", read_back(node)
    assert_equal before, @user.nodes.present.find_by!(name: "notes.md").node_id,
                 "a replace must REUSE the node (§14a) or every attachment is orphaned"
  end

  test "saving records exactly one pending edit, however many saves" do
    node = seed_repo_file!("notes.md", "a\n")

    patch file_path(node.node_id), params: { content: "b\n", base_token: token_for(node) }
    patch file_path(node.node_id), params: { content: "c\n", base_token: token_for(node.reload) }

    assert_equal 1, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
  end

  test "a stale base_token is refused and nothing is written" do
    node = seed_repo_file!("notes.md", "original\n")

    patch file_path(node.node_id), params: { content: "clobber\n", base_token: "sha256:stale" }

    assert_response :conflict
    assert_equal "original\n", read_back(node),
                 "last-write-wins would destroy the other edit silently, and on share for good"
  end

  test "a file outside a working tree is not saveable" do
    node = seed_plain_file!("loose.md", "x\n")

    patch file_path(node.node_id), params: { content: "y\n", base_token: token_for(node) }

    assert_response :unprocessable_entity
  end
end

# SAVE ON WHATEVER BACKEND IS LIVE. The cases above pin a share library so they run identically on
# all three legs, which is what keeps run counts equal — but that means none of them exercises s3's
# `write` or chunk_remote's two-phase upload, and "Save works everywhere" is half this design.
#
# NO REAL GIT IS NEEDED, and that is the point: the Save door asks Library::WorkingTree, which
# reads NODES. A `.git` dir node is all it takes, and every backend has one — on chunk_remote the
# mirror carries whatever the client synced, and repo_metadata_purge.rb records those rows as
# HIDDEN rather than removed.
class RepoEditAmbientBackendTest < ActionDispatch::IntegrationTest
  PASSWORD = "password123".freeze

  setup do
    @user = User.create!(email: "ab-#{SecureRandom.hex(4)}@example.com",
                         password: PASSWORD, confirmed_at: Time.current)
    post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
  end

  test "saving works on the ambient backend, whichever it is" do
    repo = @user.nodes.create!(node_id: SecureRandom.uuid, name: "r", kind: "dir")
    @user.nodes.create!(node_id: SecureRandom.uuid, name: ".git", kind: "dir",
                        parent_node_id: repo.node_id)
    node = write_through_port!(parent: repo, name: "a.md", bytes: "old\n")

    patch file_path(node.node_id),
          params: { content: "new\n",
                    base_token: FileLayer.current.stat(@user, node_id: node.node_id)&.content_token }

    assert_response :success
    assert_equal "new\n", FileLayer.current.read(@user, node_id: node.node_id)
  end

  # Uses the SAME door the editor does, so this test cannot pass by a route the product lacks.
  def write_through_port!(parent:, name:, bytes:)
    id = Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: parent.node_id, name:, bytes:)
    @user.nodes.present.find_by!(node_id: id)
  end
end
```

> `seed_repo_file!`, `seed_plain_file!`, `token_for` and `read_back` come from
> `test/support/git_repo_fixture.rb`, written in Task 7 Step 1. Write that helper first if you are
> executing tasks out of order.

- [ ] **Step 2: Run and watch it fail**

```bash
bin/rails test test/integration/web/repo_edit_flow_test.rb
```

Expected: FAIL — no route matches `PATCH /files/:id`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, extend the existing `resources :files` line:

```ruby
  # `update` is the editor's Save. PATCH rather than POST because it replaces the content of a
  # file that already exists — and `replace: true` REUSES the node, which is what keeps every
  # attachment, BOM link and tag pointing at it (§14a).
  resources :files, only: %i[index create show update destroy] do
```

- [ ] **Step 4: Implement `#update`**

In `app/controllers/files_controller.rb`, after `#show`:

```ruby
  # PATCH /files/:id — the editor's Save.
  #
  # WORKING TREE ONLY, ON EVERY BACKEND. Share and s3 are current-state only (§14a), so outside a
  # repository a save destroys the previous bytes with nothing to recover from — while on
  # chunk_remote it would be an ordinary new version. One condition with two answers across
  # backends is the shape §14a forbids, so the answer is the same everywhere: git is the undo, and
  # no repository means no editing. Spec part 2 records what reverses this.
  #
  # THE TOKEN CHECK IS NOT OPTIMISTIC POLITENESS. `base_token` is the content_token the editor
  # loaded with; if the file has moved on, the maker edited it in vim meanwhile and a
  # last-write-wins save destroys that edit silently. 409, and nothing written.
  def update
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    root = Library::WorkingTree.new(current_user).root_for(node)
    return render_save_error(:unprocessable_entity, "Only files inside a git repository can be edited.") if root.nil?
    return render_save_error(:unprocessable_entity, "This file is too large to edit here.") unless editable?(node)

    info = FileLayer.current.stat(current_user, node_id: node.node_id)
    if info&.content_token.to_s != params[:base_token].to_s
      return render_save_error(:conflict, "This file changed since you opened it. Reload to see the current version.")
    end

    Maker::Addons::LibraryOutput.replace_text!(current_user, node:, text: params[:content].to_s)
    Maker::RepoEdit.record!(user: current_user, repo_root_node_id: root.node_id, node_id: node.node_id) if
      FileLayer.current.capabilities.local_worktree?

    render json: { ok: true, content_token: FileLayer.current.stat(current_user, node_id: node.node_id)&.content_token }
  rescue FileLayer::FetchError => e
    render_save_error(:service_unavailable, e.message)
  end
```

and, among the private methods:

```ruby
  # A TRUNCATED BUFFER IS NEVER EDITABLE, and this is the reason the cap is duplicated on the
  # server rather than trusted from the client. codeview_controller fetches at most MAX_BYTES and
  # appends "… (truncated)"; saving that buffer would TRUNCATE THE FILE. The browser already
  # refuses to mount an editor over the cap, but a refusal that only lives in JavaScript is a
  # refusal an unmodified `curl` walks straight past.
  EDITABLE_MAX_BYTES = 200_000

  def editable?(node)
    return false unless Maker::FileAttachment.text?(node.name)

    size = FileLayer.current.stat(current_user, node_id: node.node_id)&.size
    size.present? && size <= EDITABLE_MAX_BYTES
  end

  def render_save_error(status, message)
    render json: { ok: false, error: message }, status:
  end
```

- [ ] **Step 5: Expose the ONE port_writable? branch, in place**

`Maker::Addons::LibraryOutput#write` currently couples the byte-write branch to addon bookkeeping:

```ruby
          node_id = caps.port_writable? ? write_port(user, dest, f, replace) : write_chunk(user, dest, f, replace)
          enqueue_preview(user, node_id, f[:name])
          upsert_file!(state, node_id:, role: f[:role], content_type: f[:content_type], position: i)
```

The editor needs the first line and none of the rest — it has no addon state. **Extract that line
into a public method on the same class; do not move the class.** `docs/invariants/addons.md` says
in as many words that `Maker::Addons::LibraryOutput` is the ONE output path, and §14d counts this
branch at exactly one — relocating it would put both claims in question to save an awkward
namespace.

```ruby
      # THE ONE port_writable? BRANCH, callable by a non-addon door. §14d counts these; this
      # extraction keeps the count at ONE rather than adding a sixth copy. An addon save and an
      # editor save are the same operation seen twice — server-side bytes into a library file,
      # replacing what is there, REUSING THE NODE — and the only difference is that an addon save
      # additionally records a maker_addon_files row.
      #
      # NAMED `write_bytes!` RATHER THAN `write` because the sibling `write` above takes a whole
      # addon save and returns rows. Two methods called `write` on one class, with different
      # arities and different return types, is the drift this repo names services to end.
      def write_bytes!(user, parent_node_id:, name:, bytes:, replace: false)
        f = { name:, bytes: }
        caps = FileLayer.current.capabilities
        caps.port_writable? ? write_port(user, parent_node_id, f, replace) : write_chunk(user, parent_node_id, f, replace)
      end
```

and rewrite the branch inside `#write` to call it, so there is genuinely one copy:

```ruby
          node_id = write_bytes!(user, parent_node_id: dest, name: f[:name], bytes: f[:bytes], replace:)
```

The controller then calls:

```ruby
    Maker::Addons::LibraryOutput.write_bytes!(current_user, parent_node_id: node.parent_node_id,
                                              name: node.name, bytes: params[:content].to_s.b,
                                              replace: true)
```

- [ ] **Step 5a: Record the second caller**

`docs/invariants/addons.md` line ~129 states that class is the ONE output path. It still is — but it
now has a caller outside the addon system, and an invariant that silently acquires an exception is
worse than one that names it. Add a sentence there saying the editor's Save shares this branch
deliberately, and why a second copy was refused.

```bash
bin/rails test test/docs_hygiene_test.rb test/controllers/tools/addons_controller_test.rb
```

Expected: PASS — the addon save path must be behaviourally unchanged by the extraction.

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/integration/web/repo_edit_flow_test.rb
```

Expected: PASS, 4 runs.

- [ ] **Step 7: Mutation-check**

1. Delete the token comparison → the stale-token test goes RED.
2. Delete the `editable?` size check and save a 300 KB file → assert it is refused; must go RED.
3. Change `replace: true` to a delete-then-create → the node-identity assertion goes RED.

- [ ] **Step 8: All three legs**

```bash
bin/ci test && bin/ci test-s3 && bin/ci test-chunk-remote
```

Expected: PASS on all three, identical run counts. Save works everywhere; only the `RepoEdit` row
is conditional.

- [ ] **Step 9: Commit**

```bash
git add config/routes.rb app/controllers/files_controller.rb app/services/maker/addons/library_output.rb test/integration/web/repo_edit_flow_test.rb
git commit -m "$(cat <<'EOF'
Add the editor's Save door (tinkerex#178)

PATCH /files/:id, working-tree only, on every backend. Outside a repository share and s3
would destroy the previous bytes with nothing to recover from while chunk_remote would
make an ordinary new version -- one condition with two answers, which §14a forbids. Git is
the undo, so no repository means no editing.

The base_token check is the load-bearing part: without it a save silently destroys an edit
the maker made in vim, unrecoverably on share. 409, nothing written.

Reuses Maker::Addons::LibraryOutput's ONE port_writable? branch instead of adding a sixth
copy (§14d) -- an addon save and an editor save are the same operation seen twice.

The server re-checks the size cap rather than trusting the client: a refusal that lives
only in JavaScript is one curl walks past, and saving a truncated buffer truncates the file.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: the editor in the browser

**Files:**
- Create: `app/javascript/controllers/editor_controller.js`
- Modify: `app/views/files/show.html.erb:118-131`
- Modify: `app/controllers/files_controller.rb` (`#show` sets `@repo_root`)

- [ ] **Step 1: Expose eligibility to the view**

In `FilesController#show`, after `@kind` is set:

```ruby
    # Editing appears exactly where committing could — one walk, one answer, nothing to keep in
    # sync between the two surfaces.
    @repo_root = Library::WorkingTree.new(current_user).root_for(@node)
    @editable  = @kind == :text && @repo_root.present? && editable?(@node)
```

- [ ] **Step 2: Switch the view's text branch**

In `app/views/files/show.html.erb`, replace the `data-controller="codeview"` div's attributes.
Never write a percent-greater-than sequence inside an ERB comment — an ERB comment ends at the
first one and the rest prints into the page (§14d).

```erb
    <div class="preview-code"
         data-controller="<%= @editable ? "editor" : "codeview" %>"
         data-<%= @editable ? "editor" : "codeview" %>-url-value="<%= blob_file_path(@node.node_id) %>"
         data-<%= @editable ? "editor" : "codeview" %>-ext-value="<%= File.extname(@node.name).downcase.delete(".") %>"
         <% if @editable %>
           data-editor-save-url-value="<%= file_path(@node.node_id) %>"
           data-editor-base-token-value="<%= @info.content_token %>"
         <% end %>>
      <pre class="preview-text" data-<%= @editable ? "editor" : "codeview" %>-target="fallback">Loading…</pre>
    </div>
```

- [ ] **Step 3: Write the controller**

`app/javascript/controllers/editor_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Editable source view. The read-only sibling is codeview_controller, which stays the default —
// this one mounts only where FilesController#show says the file is inside a working tree.
//
// THE FETCH RUNS FIRST AND THE BUNDLE LOADS SECOND, exactly as codeview does: the bytes are what
// the user came for, and a failed bundle load leaves the <pre> holding the file's text.
//
// A TRUNCATED BUFFER IS NEVER EDITABLE. Saving one would truncate the file. The server refuses it
// too (FilesController::EDITABLE_MAX_BYTES) — this is the courteous half of that rule, not the
// enforcing half.
const MAX_BYTES = 200_000

export default class extends Controller {
  static targets = ["fallback"]
  static values = { url: String, ext: String, saveUrl: String, baseToken: String }

  async connect() {
    this.disconnected = false
    this.abort = new AbortController()

    let res
    try {
      res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
    } catch (e) {
      if (this.disconnected) return
      this.fallbackTarget.textContent = `Could not load file: ${e.message}`
      return
    }
    const text = await res.text()
    if (this.disconnected) return
    this.fallbackTarget.textContent = text

    if (text.length > MAX_BYTES) return // stays a read-only <pre>; the server refuses the save too

    let cm, languages
    try {
      ;[cm, languages] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages")
      ])
    } catch (e) {
      console.warn("[editor] keeping the plain preview:", e)
      return
    }
    if (this.disconnected) return

    this.mount(cm, languages, text)
  }

  mount(cm, languages, text) {
    const language = languages.languageFor(this.extValue, cm)
    // NO EditorState.readOnly AND NO EditorView.editable HERE — codeview sets both, and this
    // controller exists precisely because unsetting them on that one is not a flag flip: a page
    // that is sometimes editable needs a different mount, not a mutated one.
    const extensions = [cm.basicSetup]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: text, extensions }),
      parent: this.element
    })
    this.fallbackTarget.remove()
    this.addSaveBar()
  }

  addSaveBar() {
    this.bar = document.createElement("div")
    this.bar.className = "editor-bar"
    this.button = document.createElement("button")
    this.button.type = "button"
    this.button.textContent = "Save"
    this.button.addEventListener("click", () => this.save())
    this.status = document.createElement("span")
    this.status.className = "editor-status"
    this.bar.append(this.button, this.status)
    this.element.append(this.bar)
  }

  async save() {
    this.button.disabled = true
    this.status.textContent = "Saving…"
    try {
      const res = await fetch(this.saveUrlValue, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        body: JSON.stringify({
          content: this.view.state.doc.toString(),
          base_token: this.baseTokenValue
        })
      })
      const body = await res.json()
      if (!res.ok) { this.status.textContent = body.error ?? `Save failed (${res.status})`; return }

      // THE TOKEN ROLLS FORWARD ON SUCCESS. Without this a second save sends the ORIGINAL token,
      // which the server correctly refuses as stale — so the editor would work exactly once.
      this.baseTokenValue = body.content_token ?? this.baseTokenValue
      this.status.textContent = "Saved"
    } finally {
      this.button.disabled = false
    }
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
```

- [ ] **Step 4: Verify the identifier resolves**

A `data-controller` name that resolves to nothing is a **silent no-op** — no error, no console
warning (§14d; nine days, once).

```bash
bin/rails test test/stimulus_hygiene_test.rb
```

Expected: PASS. That guard derives identifiers from filenames, so `editor_controller.js` needs no
test edit — but it only proves the name resolves, never that the editor works. Step 5 does that.

- [ ] **Step 5: Drive it in a real browser**

Add to `test/system/` a test that opens a repository file, types, clicks Save, reloads, and asserts
the new text is there. Only a browser proves the editor mounted editable.

```bash
bin/ci system
```

- [ ] **Step 6: Mutation-check**

Delete `this.baseTokenValue = body.content_token ?? this.baseTokenValue` and save twice in the
system test — the second save must fail with the conflict message. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/javascript/controllers/editor_controller.js app/views/files/show.html.erb app/controllers/files_controller.rb test/system
git commit -m "$(cat <<'EOF'
Add the editable source view (tinkerex#178)

A SEPARATE controller rather than a flag on codeview. That one sets BOTH
EditorState.readOnly and EditorView.editable, with a comment explaining why a merely
disabled contenteditable still takes focus and IME -- a page that is sometimes editable
needs a different mount, not a mutated one.

Driven in a real browser, not only by a request test: a data-controller name that resolves
to nothing is a silent no-op with no console warning, and a request test proves the
endpoint works while saying nothing about whether anything calls it.

The token rolls forward on a successful save. Without that the second save sends the
original token, the server correctly calls it stale, and the editor works exactly once --
mutation-checked.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

# Phase 2 — Commit

---

## Task 7: `Maker::Git::LocalRepo` — open, and refuse

**Files:**
- Create: `app/services/maker/git/local_repo.rb`
- Create: `test/support/git_repo_fixture.rb`
- Create: `test/services/maker/git/local_repo_test.rb`

> **Do not restore `tinkerex#161`'s `app/services/maker/git/repo.rb`.** It is still reachable on
> `claude/git-phase5-refinement`, it is 583 lines, and it was built for a model that no longer
> exists. The different filename is what stops one `git checkout <branch> -- <path>` overwriting
> this class (spec part 10).

- [ ] **Step 1: Write the fixture helper**

`test/support/git_repo_fixture.rb` — real repositories, built with rugged. Provides
`seed_repo_file!`, `seed_plain_file!`, `token_for` and `read_back` used from Task 5 onward.

```ruby
require "rugged"

# REAL REPOSITORIES, NOT FIXTURES. tinkerex#178's evidence came from real ones, and the two cases
# that matter most — a .gitignore excluding almost everything, and a repository with no commits at
# all — are exactly the ones a hand-rolled fixture quietly omits.
module GitRepoFixture
  # Creates <library>/<name>/ as a git repository with `files`, all committed, and indexes the
  # catalog nodes for it. Returns the repository's root Node.
  def make_repo!(name: "demo", files: { "notes.md" => "old\n" }, gitignore: nil, commit: true)
    dir = File.join(library_root, name)
    FileUtils.mkdir_p(dir)
    repo = Rugged::Repository.init_at(dir)

    files.each do |rel, body|
      FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
      File.write(File.join(dir, rel), body)
    end
    File.write(File.join(dir, ".gitignore"), gitignore) if gitignore

    if commit
      index = repo.index
      (files.keys + (gitignore ? [ ".gitignore" ] : [])).each { |rel| index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644) }
      index.write
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "seed", parents: [],
                            update_ref: "HEAD",
                            author:    { name: "Seed", email: "seed@example.com", time: Time.now },
                            committer: { name: "Seed", email: "seed@example.com", time: Time.now })
    end

    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "dir")
  end

  def seed_repo_file!(rel, body)
    make_repo!(files: { rel => body })
    @user.nodes.present.find_by!(name: File.basename(rel), kind: "file")
  end

  def seed_plain_file!(name, body)
    FileUtils.mkdir_p(File.join(library_root, "Loose"))
    File.write(File.join(library_root, "Loose", name), body)
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "file")
  end

  def token_for(node) = FileLayer.current.stat(@user, node_id: node.node_id)&.content_token
  def read_back(node) = FileLayer.current.read(@user, node_id: node.node_id)

  # PINS A REAL SHARE LIBRARY, so a case that needs a working tree runs IDENTICALLY on all three
  # legs instead of varying with the ambient LIBRARY_BACKEND -- which is what keeps the run counts
  # equal (§15). The cases that must vary by backend are the ones asserting the AFFORDANCE'S
  # ABSENCE, and those deliberately do not call this (Task 10 Step 6).
  def library_root = (@library ||= use_fresh_share_library!).to_s
end
```

> On `s3` and `chunk_remote` this helper cannot build a working tree — that is the point. Include it
> only in cases that either gate on `local_worktree?` or assert the absence of the affordance
> (Task 10 Step 6).

- [ ] **Step 2: Write the failing tests**

`test/services/maker/git/local_repo_test.rb`:

```ruby
require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::LocalRepoTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  test "opens a repository the maker brought" do
    root = make_repo!
    assert Maker::Git::LocalRepo.open(@user, root).committable?
  end

  # An ordinary first commit, not an edge case to refuse.
  test "an unborn HEAD is committable" do
    root = make_repo!(commit: false)
    assert Maker::Git::LocalRepo.open(@user, root).committable?
  end

  test "a detached HEAD refuses, naming the reason" do
    root = make_repo!
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    repo.checkout(repo.head.target_id, strategy: :force)

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/detached/i, local.refusal)
  end

  test "an operation in progress refuses" do
    root = make_repo!
    File.write(File.join(library_root, "demo", ".git", "MERGE_HEAD"), "deadbeef\n")

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/merge/i, local.refusal)
  end

  # §8 rule 2: another git may hold this repository, or a crashed one left the lock. Deleting
  # another process's lock is how repositories get corrupted.
  test "a lock file refuses and is NOT deleted" do
    root = make_repo!
    lock = File.join(library_root, "demo", ".git", "index.lock")
    File.write(lock, "")

    local = Maker::Git::LocalRepo.open(@user, root)
    refute local.committable?
    assert_match(/index\.lock/, local.refusal)
    assert File.exist?(lock), "a lock must be refused, never deleted"
  end
end
```

- [ ] **Step 3: Run and watch it fail**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/local_repo_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::Git::LocalRepo`.

- [ ] **Step 4: Write the class**

`app/services/maker/git/local_repo.rb`:

```ruby
require "rugged"

module Maker
  module Git
    # A git repository the maker brought, opened IN PLACE.
    #
    # NOT tinkerex#161's Maker::Git::Repo. That class hydrated an ephemeral cache, wrote packs and
    # persisted them back, because it had to make git work where there is no filesystem. This one
    # answers `local_worktree` instead: there is a filesystem, or there is no commit button. The
    # filename differs from `repo.rb` deliberately — spec part 10.
    #
    # NOTHING HERE WRITES. Opening, inspecting and refusing live here; the write is
    # Maker::Git::CommitPaths, so every refusal in this class is decided before any object exists.
    #
    # THE PATH COMES FROM THE PORT, NEVER FROM A REBUILT STRING. FileLayer::Share#absolute_path
    # resolves inside the library root and raises on a NULL storage_path — §14b records that
    # resolving one to the library ROOT once handed a whole directory to send_file.
    class LocalRepo
      # Operations that leave a marker in .git and mean "a human is halfway through something".
      # Half-finished operations belong to real git, not a web form.
      IN_PROGRESS_MARKERS = {
        "MERGE_HEAD"        => "a merge",
        "REBASE_HEAD"       => "a rebase",
        "CHERRY_PICK_HEAD"  => "a cherry-pick",
        "REVERT_HEAD"       => "a revert",
        "BISECT_LOG"        => "a bisect"
      }.freeze

      # §8 rule 2. `index.lock` is the common one; a ref lock is the one that bites during a
      # concurrent commit.
      LOCK_FILES = %w[index.lock HEAD.lock].freeze

      def self.open(user, root_node, adapter: FileLayer.current)
        new(user, root_node, adapter:)
      end

      attr_reader :root_node

      def initialize(user, root_node, adapter: FileLayer.current)
        @user = user
        @root_node = root_node
        @adapter = adapter
      end

      def workdir = @workdir ||= @adapter.absolute_path(@root_node).to_s

      def rugged = @rugged ||= Rugged::Repository.new(workdir)

      # nil when this repository can be committed to; otherwise a sentence the UI shows verbatim.
      # ONE METHOD, so `committable?` and the message can never disagree about why.
      def refusal
        return @refusal if defined?(@refusal)

        @refusal = compute_refusal
      end

      def committable? = refusal.nil?

      # True when HEAD points at a branch that has no commits yet. Allowed: the commit simply has
      # no parents.
      def unborn? = rugged.head_unborn?

      private

      def compute_refusal
        unless @adapter.capabilities.local_worktree?
          return "Committing needs a library on a local filesystem."
        end

        if (lock = LOCK_FILES.find { |f| File.exist?(File.join(workdir, ".git", f)) })
          return "Another git process may be using this repository (.git/#{lock} exists). " \
                 "Close it, or remove that file yourself if you are sure nothing is running."
        end

        if (marker = IN_PROGRESS_MARKERS.keys.find { |f| File.exist?(File.join(workdir, ".git", f)) })
          return "This repository has #{IN_PROGRESS_MARKERS[marker]} in progress. Finish it in git first."
        end

        return "HEAD is detached, so a commit here would not be on any branch." if !unborn? && rugged.head_detached?

        nil
      rescue Rugged::RepositoryError, Rugged::OSError => e
        "This folder could not be opened as a git repository (#{e.class})."
      rescue FileLayer::FetchError
        raise # an unmounted share is 503, not a refusal sentence (§14a)
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/local_repo_test.rb
```

Expected: PASS, 5 runs.

- [ ] **Step 6: Mutation-check the lock rule**

Change the lock branch to `File.delete(...)` and continue. The "is NOT deleted" assertion must go
**RED**. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/git/local_repo.rb test/support/git_repo_fixture.rb test/services/maker/git/local_repo_test.rb
git commit -m "$(cat <<'EOF'
Add Maker::Git::LocalRepo — open in place, and refuse (tinkerex#178)

Not tinkerex#161's Maker::Git::Repo, and deliberately not at that filename: that one is
583 lines, still on claude/git-phase5-refinement, and built for a model that no longer
exists. Reusing repo.rb would let one `git checkout <branch> -- <path>` overwrite this.

Nothing here writes. Opening, inspecting and refusing live here so every refusal is decided
before any git object exists.

A lock file is REFUSED, NEVER DELETED (spec part 8 rule 2, from Cursor's git-at-scale post):
another git may hold the repository, or a crashed one left it, and deleting another
process's lock is how repositories get corrupted. Mutation-checked by making it delete.

An unborn HEAD is ALLOWED -- an ordinary first commit with no parents, not an edge case.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: `LocalRepo#status_for` — reconcile against git

**Files:**
- Modify: `app/services/maker/git/local_repo.rb`
- Modify: `test/services/maker/git/local_repo_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/services/maker/git/local_repo_test.rb`:

```ruby
  test "a path whose content matches HEAD is reported unchanged" do
    root = make_repo!(files: { "a.txt" => "same\n" })
    rows = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ])

    assert_equal :unchanged, rows.fetch("a.txt").state
  end

  test "a modified path reports its line counts" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one\ntwo\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "a.txt" ]).fetch("a.txt")

    assert_equal :modified, row.state
    assert_equal 1, row.additions
  end

  test "an ignored path is listed and NOT committable" do
    root = make_repo!(files: { "a.txt" => "x\n" }, gitignore: "secret.txt\n")
    File.write(File.join(library_root, "demo", "secret.txt"), "shh\n")

    row = Maker::Git::LocalRepo.open(@user, root).status_for([ "secret.txt" ]).fetch("secret.txt")

    assert_equal :ignored, row.state
    refute row.committable?
  end

  # Counted, never listed. The box must not misrepresent the repository, and must not become a
  # staging panel either.
  test "other dirty paths are counted, not returned" do
    root = make_repo!(files: { "a.txt" => "x\n", "b.txt" => "y\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "also changed\n")

    local = Maker::Git::LocalRepo.open(@user, root)
    rows  = local.status_for([ "a.txt" ])

    assert_equal [ "a.txt" ], rows.keys
    assert_equal 1, local.other_dirty_count([ "a.txt" ])
  end
```

- [ ] **Step 2: Run and watch it fail**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/local_repo_test.rb -n /status_for|dirty|ignored/
```

Expected: FAIL — `NoMethodError: undefined method 'status_for'`.

- [ ] **Step 3: Implement**

Add to `Maker::Git::LocalRepo`:

```ruby
      # What the commit box shows for one path. `state` is :modified, :added, :unchanged, :ignored
      # or :missing; only :modified and :added can be committed.
      Row = Data.define(:path, :state, :additions, :deletions) do
        def committable? = state == :modified || state == :added
      end

      # CONTENT AGAINST HEAD'S BLOB, NEVER A STAT COMPARISON — §8 rule 1, and the reason is the
      # backend rather than fussiness: `share` is a NAS over SMB/NFS, where attribute caching can
      # make a stat-based "unchanged" answer wrong. git's own stat cache is an optimisation it can
      # afford because it is talking to a local disk. We are not.
      def status_for(paths)
        paths.index_with { |rel| row_for(rel) }
      end

      # How many OTHER paths git sees as dirty. Counted, never listed: listing them is the staging
      # panel, and hiding them entirely would let the box misrepresent the repository.
      def other_dirty_count(known_paths)
        known = known_paths.to_set
        return 0 if unborn?

        rugged.status.count { |rel, flags| !known.include?(rel) && flags.any? { |f| f != :ignored } }
      end

      private

      def row_for(rel)
        abs = File.join(workdir, rel)
        return Row.new(path: rel, state: :missing, additions: 0, deletions: 0) unless File.file?(abs)
        return Row.new(path: rel, state: :ignored, additions: 0, deletions: 0) if rugged.path_ignored?(rel)

        head_blob = unborn? ? nil : head_blob_for(rel)
        current   = File.binread(abs)
        return Row.new(path: rel, state: :added, additions: current.lines.size, deletions: 0) if head_blob.nil?
        return Row.new(path: rel, state: :unchanged, additions: 0, deletions: 0) if head_blob == current

        added, removed = line_delta(head_blob, current)
        Row.new(path: rel, state: :modified, additions: added, deletions: removed)
      end

      def head_blob_for(rel)
        entry = rugged.head.target.tree.path(rel)
        rugged.lookup(entry[:oid]).content
      rescue Rugged::TreeError
        nil # not in HEAD: an untracked file, which is :added
      end

      # A COUNT, NOT A DIFF. The real diff is rendered by @codemirror/merge in the browser from the
      # two blobs; this is only the "+3 −1" on the row. Computing a proper diff here would rebuild
      # the server-side text diff this design deletes (spec part 13).
      def line_delta(before, after)
        b = before.lines
        a = after.lines
        common = (b & a).size
        [ a.size - common, b.size - common ]
      end
```

- [ ] **Step 4: Run**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/local_repo_test.rb
```

Expected: PASS, 9 runs.

- [ ] **Step 5: Mutation-check §8 rule 1**

Replace the content comparison with an mtime comparison against the index. The "matches HEAD is
unchanged" test must go **RED** when you `touch` the file without changing it — add that assertion
if it does not already fail. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/local_repo.rb test/services/maker/git/local_repo_test.rb
git commit -m "$(cat <<'EOF'
Reconcile pending edits against git, by content (tinkerex#178)

CONTENT AGAINST HEAD'S BLOB, NEVER A STAT COMPARISON -- spec part 8 rule 1. share is a NAS
over SMB/NFS, where attribute caching can make a stat-based "unchanged" answer wrong. git's
own stat cache is an optimisation it can afford talking to a local disk; we cannot.

A row is dropped when it now matches HEAD (they committed it elsewhere) and listed but NOT
committable when .gitignore covers it -- silently omitting a file the maker can see is the
gap, and git itself needs -f.

Other dirty paths are COUNTED, NEVER LISTED: listing them is the staging panel this design
scopes out, and hiding them lets the box misrepresent the repository.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `Maker::Git::CommitPaths`

The class whose name carries the rule: it commits **paths**, never the working tree.

**Files:**
- Create: `app/services/maker/git/commit_paths.rb`
- Create: `test/services/maker/git/commit_paths_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/services/maker/git/commit_paths_test.rb`:

```ruby
require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::CommitPathsTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com") }

  def local(root) = Maker::Git::LocalRepo.open(@user, root)
  def rugged_at   = Rugged::Repository.new(File.join(library_root, "demo"))

  # THE ONE THAT MATTERS MOST. index.clear + add_all passes every bytes-oriented test while
  # committing whatever is lying around the maker's working tree.
  test "an unselected dirty file is NOT swept into the commit" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "just a")

    tree = rugged_at.head.target.tree
    assert_equal "one changed\n", rugged_at.lookup(tree.path("a.txt")[:oid]).content
    assert_equal "two\n", rugged_at.lookup(tree.path("b.txt")[:oid]).content,
                 "b.txt was never selected and must be exactly as HEAD had it"
  end

  test "the commit's parent is the old HEAD and the branch moves" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    before = rugged_at.head.target_id
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_equal [ before ], rugged_at.head.target.parent_ids
    # THE BRANCH HEAD MOVED, and the commit is ON it -- not left dangling. libgit2's `init_at`
    # writes refs/heads/master while git's own default is main, so assert against whatever HEAD
    # actually points at rather than hard-coding either name.
    assert_equal rugged_at.head.target_id, rugged_at.references[rugged_at.head.name].target_id
  end

  test "a first commit on an unborn HEAD has no parents" do
    root = make_repo!(files: { "a.txt" => "one\n" }, commit: false)

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "first")

    assert_empty rugged_at.head.target.parent_ids
  end

  # Leaving the index alone leaves the committed path reporting as modified in the maker's own
  # `git status`, which reads as "the app half-did something".
  test "the committed path reports clean afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_empty rugged_at.status.select { |rel, _| rel == "a.txt" }.to_a
  end

  test "an unselected dirty path is still dirty afterwards" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    refute_empty rugged_at.status.select { |rel, _| rel == "b.txt" }.to_a
  end

  test "the author falls back to the account email with its local-part as the name" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    author = rugged_at.head.target.author
    assert_equal @user.email, author[:email]
    assert_equal @user.email.split("@").first, author[:name]
  end

  test "repo-local identity wins when it is set" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    r = rugged_at
    r.config["user.name"]  = "Real Maker"
    r.config["user.email"] = "maker@example.com"
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "m")

    assert_equal "Real Maker", rugged_at.head.target.author[:name]
  end

  test "a ref that moved under us is refused" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    l = local(root)
    expected = l.rugged.head.target_id
    File.write(File.join(library_root, "demo", "a.txt"), "two\n")

    # someone else commits first
    Maker::Git::CommitPaths.new(local(root)).call(paths: [ "a.txt" ], message: "theirs")

    assert_raises(Maker::Git::CommitPaths::RefMoved) do
      Maker::Git::CommitPaths.new(l).call(paths: [ "a.txt" ], message: "mine", expected_head: expected)
    end
  end
end
```

- [ ] **Step 2: Run and watch it fail**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/commit_paths_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Maker::Git::CommitPaths`.

- [ ] **Step 3: Implement**

`app/services/maker/git/commit_paths.rb`:

```ruby
require "rugged"

module Maker
  module Git
    # HEAD's tree with the SELECTED PATHS replaced. The class is named for the rule.
    #
    # NEVER `index.clear` FOLLOWED BY add_all. That is what tinkerex#161's reverted code did, and
    # it turns "commit these two files" into "commit whatever is lying around the maker's working
    # tree". It passes every bytes-oriented test, because the bytes of the selected files are
    # right; what is wrong is everything else that came along.
    #
    # AND NEVER LEAVE THE INDEX UNTOUCHED EITHER, which is the symmetric mistake. After the commit
    # the index still holds the OLD blob for a committed path, so the maker's own `git status`
    # reports it as staged-and-different — reading as "the app half-did something". Read the index,
    # update the committed entries, write it back.
    #
    # THE WRITE WINDOW IS TWO OPERATIONS WIDE (§8 rule 3). Objects are content-addressed and safe
    # to write early, so blobs and trees go in first; only the ref update and the index write need
    # a lock, and share is a NETWORK filesystem where a lock is the risky part.
    class CommitPaths
      class RefMoved < StandardError; end
      class NothingToCommit < StandardError; end

      def initialize(local_repo)
        @local = local_repo
        @repo = local_repo.rugged
      end

      # `expected_head` is the compare-and-swap. A caller that read the head, rendered a page and
      # came back passes what it saw; a mismatch means another commit landed meanwhile and this
      # one must be re-shown rather than silently layered on top.
      def call(paths:, message:, expected_head: nil)
        raise NothingToCommit if paths.empty?

        parents = @local.unborn? ? [] : [ @repo.head.target ]
        if expected_head && (parents.first&.oid != expected_head)
          raise RefMoved, "another commit landed while you were reviewing"
        end

        builder = tree_builder(parents.first)
        paths.each { |rel| stage(builder, rel) }

        oid = Rugged::Commit.create(@repo,
                                    tree: builder.write, message: message.to_s,
                                    parents: parents.map(&:oid),
                                    update_ref: ref_name,
                                    author: identity, committer: identity)
        refresh_index(paths)
        oid
      end

      private

      # HEAD's tree is the STARTING POINT, which is the whole design. `Rugged::Tree::Builder.new`
      # with a source tree copies it; without one, the commit would contain only the selected
      # paths and delete the entire rest of the repository.
      def tree_builder(head_commit)
        head_commit ? Rugged::Tree::Builder.new(@repo, head_commit.tree) : Rugged::Tree::Builder.new(@repo)
      end

      # Nested paths need each intermediate tree rebuilt, so this recurses rather than assuming a
      # flat repository. A repository with everything at the root is the easy case, not the case.
      def stage(builder, rel)
        oid = Rugged::Blob.from_workdir(@repo, rel)
        segments = rel.split("/")
        if segments.size == 1
          builder.insert(name: segments.first, oid:, filemode: filemode_for(rel))
          return
        end

        head = segments.first
        sub_oid = builder[head]&.fetch(:oid, nil)
        sub = sub_oid ? Rugged::Tree::Builder.new(@repo, @repo.lookup(sub_oid)) : Rugged::Tree::Builder.new(@repo)
        stage(sub, segments.drop(1).join("/"))
        builder.insert(name: head, oid: sub.write, filemode: 0o040000)
      end

      # Preserve the executable bit a file already has. Dropping it silently un-chmods scripts.
      def filemode_for(rel)
        File.executable?(File.join(@local.workdir, rel)) ? 0o100755 : 0o100644
      end

      def ref_name
        return "HEAD" if @local.unborn?

        @repo.head.name
      end

      # ONLY THE COMMITTED PATHS. Anything wider is index.clear with extra steps.
      def refresh_index(paths)
        index = @repo.index
        paths.each do |rel|
          index.add(path: rel, oid: Rugged::Blob.from_workdir(@repo, rel), mode: filemode_for(rel))
        end
        index.write
      end

      # Repo-local config if BOTH halves are set. `Rugged::Config.global` reads the CONTAINER's
      # config and is meaningless here, so there is no second git source to fall back to; the
      # fallback is the tinkerex account. `users` has no name column (checked against
      # db/schema.rb), so the address's local-part is the name — if that column is ever added, it
      # becomes the name and this comment is the reason to change it.
      def identity
        name  = @repo.config["user.name"]
        email = @repo.config["user.email"]
        if name.present? && email.present?
          { name:, email:, time: Time.current }
        else
          account = @local.user_email
          { name: account.split("@").first, email: account, time: Time.current }
        end
      end
    end
  end
end
```

Add to `Maker::Git::LocalRepo`, public:

```ruby
      # The account's address, for the commit-identity fallback. Exposed rather than reaching for
      # `@user.email` from CommitPaths so that class needs no User at all.
      def user_email = @user.email
```

- [ ] **Step 4: Run**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/commit_paths_test.rb
```

Expected: PASS, 8 runs.

- [ ] **Step 5: Mutation-check — the important one**

Replace `tree_builder` and `stage` with:

```ruby
        index = @repo.index
        index.clear
        index.add_all
```

Run the suite. **"an unselected dirty file is NOT swept into the commit" must go RED.** If it
passes, the test is not testing what it claims and must be fixed before you restore the code.

Then a second mutation: delete `refresh_index`. "the committed path reports clean afterwards" must
go RED.

Then a third: delete the `expected_head` comparison. "a ref that moved under us is refused" must go
RED — without it, two commits racing one ref silently layer one on top of the other. Restore all
three.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/commit_paths.rb app/services/maker/git/local_repo.rb test/services/maker/git/commit_paths_test.rb
git commit -m "$(cat <<'EOF'
Add Maker::Git::CommitPaths (tinkerex#178)

HEAD's tree with the SELECTED PATHS replaced. The class is named for the rule so the rule
cannot be lost the way a comment can.

NEVER index.clear + add_all -- tinkerex#161's reverted code did exactly that, turning
"commit these two files" into "commit whatever is lying around the maker's working tree".
It passes every bytes-oriented test, because the selected files' bytes are right; what is
wrong is everything else that came along. Mutation-checked: restoring index.clear turns the
unselected-dirty-file test red.

AND NEVER leave the index untouched either, the symmetric mistake: the index would still
hold the old blob, so the maker's own git status reports the committed path as staged and
different. Only the committed paths are refreshed -- anything wider is index.clear with
extra steps.

Ref update is compare-and-swap. Unborn HEAD commits with no parents. Author is repo-local
config if both halves are set, else users.email with its local-part as the name --
Rugged::Config.global reads the CONTAINER's config and is meaningless here.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: the review-and-commit surface

**Files:**
- Create: `app/controllers/repo_commits_controller.rb`
- Create: `app/views/repo_commits/show.html.erb`
- Modify: `config/routes.rb`
- Modify: `test/integration/web/repo_edit_flow_test.rb`

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/web/repo_edit_flow_test.rb`:

```ruby
  test "the review page lists pending edits and counts the rest" do
    root = make_repo!(files: { "a.txt" => "one\n", "b.txt" => "two\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }
    File.write(File.join(library_root, "demo", "b.txt"), "two changed\n")

    get repo_commit_path(root.node_id)

    assert_response :success
    assert_select "[data-path='a.txt']", 1
    assert_select "[data-path='b.txt']", 0
    assert_match(/1 other change/, response.body)
  end

  test "committing writes the commit and clears the rows" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }

    post repo_commit_path(root.node_id), params: { paths: [ "a.txt" ], message: "from tinkerex" }

    assert_redirected_to repo_commit_path(root.node_id)
    repo = Rugged::Repository.new(File.join(library_root, "demo"))
    assert_equal "from tinkerex", repo.head.target.message
    assert_equal 0, Maker::RepoEdit.where(user: @user).count
  end

  test "a row that now matches HEAD is dropped rather than offered" do
    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "one changed\n", base_token: token_for(a) }
    # the maker commits it themselves, at the terminal
    File.write(File.join(library_root, "demo", "a.txt"), "one changed\n")
    system("git -C #{File.join(library_root, 'demo')} commit -am theirs", out: File::NULL, err: File::NULL)

    get repo_commit_path(root.node_id)

    assert_select "[data-path='a.txt']", 0
    assert_equal 0, Maker::RepoEdit.where(user: @user).count
  end
```

- [ ] **Step 2: Run and watch it fail**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/repo_edit_flow_test.rb
```

Expected: FAIL — `NameError: undefined local variable or method 'repo_commit_path'`.

- [ ] **Step 3: Routes**

```ruby
  # --- Review and commit, for a repository the maker brought (session-authed; never the v1 API,
  # which is device-token only — §14d). Keyed by the repository ROOT node id, because eligibility
  # is "inside a working tree" and has nothing to do with projects.
  get  "repos/:root_id/commit", to: "repo_commits#show",   as: :repo_commit
  post "repos/:root_id/commit", to: "repo_commits#create"
```

- [ ] **Step 4: The controller**

`app/controllers/repo_commits_controller.rb`:

```ruby
# Review pending edits in one repository, then commit the selected paths.
#
# SESSION-AUTHED, NEVER THE v1 API. §14d: /v1/* is device-token; the web app is cookies, and a
# web controller is not limited to what the JSON API exposes.
#
# THE TABLE IS A HINT, NOT AN AUTHORITY. Every pending row is re-asked of git here: the path is
# recomputed from the catalog, the row is dropped if the node is gone or has moved out of this
# repository or now matches HEAD, and it is listed-but-not-committable when .gitignore covers it.
class RepoCommitsController < ApplicationController
  before_action :load_repo

  def show
    @rows, @dropped = reconcile
    Maker::RepoEdit.where(user: current_user, node_id: @dropped).delete_all if @dropped.any?
    @other_dirty = @local.other_dirty_count(@rows.keys)
    @head = @local.unborn? ? nil : @local.rugged.head.target_id
  end

  def create
    rows, = reconcile
    paths = Array(params[:paths]) & rows.select { |_, r| r.committable? }.keys

    Maker::Git::CommitPaths.new(@local).call(paths:, message: params[:message].to_s,
                                             expected_head: params[:expected_head].presence)
    Maker::RepoEdit.where(user: current_user, node_id: node_ids_for(paths, rows)).delete_all
    redirect_to repo_commit_path(@root.node_id), notice: "Committed #{paths.size} file(s)."
  rescue Maker::Git::CommitPaths::RefMoved
    redirect_to repo_commit_path(@root.node_id),
                alert: "Another commit landed while you were reviewing. Here is the current state."
  rescue Maker::Git::CommitPaths::NothingToCommit
    redirect_to repo_commit_path(@root.node_id), alert: "Nothing selected."
  end

  private

  def load_repo
    @root = current_user.nodes.present.find_by!(node_id: params[:root_id], kind: "dir")
    @local = Maker::Git::LocalRepo.open(current_user, @root)
    return if @local.committable?

    redirect_to files_path, alert: @local.refusal
  end

  # Returns [rows_by_path, node_ids_to_drop]. The path comes from the catalog every time — the
  # table stores none, so it cannot disagree with the library after a node moves.
  def reconcile
    tree = Maker::LibraryTree.new(current_user)
    root_path = tree.path_for(@root.node_id)
    pending = Maker::RepoEdit.pending_for(current_user, @root.node_id).to_a

    by_path, dropped = {}, []
    pending.each do |row|
      full = tree.path_for(row.node_id)
      rel  = full && root_path && full.start_with?("#{root_path}/") ? full.delete_prefix("#{root_path}/") : nil
      next dropped << row.node_id if rel.nil?

      by_path[rel] = row.node_id
    end

    status = @local.status_for(by_path.keys)
    keep = {}
    status.each do |rel, r|
      if r.state == :unchanged || r.state == :missing
        dropped << by_path[rel]
      else
        keep[rel] = r
      end
    end
    @node_id_by_path = by_path
    [ keep, dropped ]
  end

  def node_ids_for(paths, _rows) = paths.filter_map { |p| @node_id_by_path[p] }
end
```

- [ ] **Step 5: The view**

`app/views/repo_commits/show.html.erb`:

```erb
<h1>Commit — <%= @root.name %></h1>

<% if @rows.empty? %>
  <p class="muted">Nothing edited here yet.</p>
<% else %>
  <%= form_with url: repo_commit_path(@root.node_id), method: :post, scope: nil do |f| %>
    <%# `scope: nil` and no `model:` means a blank object_name, so f.text_field emits a FLAT
        name. Do not add fields_for here — on a blank object_name it emits "[thing][x]", which
        Rack parses to the literal key "[thing]" and the controller's require rejects (§14d). %>
    <%= hidden_field_tag :expected_head, @head %>
    <ul class="commit-rows">
      <% @rows.each do |path, row| %>
        <li data-path="<%= path %>">
          <% if row.committable? %>
            <%= check_box_tag "paths[]", path, true, id: "path_#{path.parameterize}" %>
          <% else %>
            <span class="muted">ignored by .gitignore</span>
          <% end %>
          <code><%= path %></code>
          <span class="plus">+<%= row.additions %></span>
          <span class="minus">−<%= row.deletions %></span>
        </li>
      <% end %>
    </ul>
    <%= text_area_tag :message, nil, rows: 3, placeholder: "What changed?" %>
    <% if @other_dirty.positive? %>
      <p class="muted"><%= pluralize(@other_dirty, "other change") %> in this repository — not included.</p>
    <% end %>
    <%= submit_tag "Commit" %>
  <% end %>
<% end %>
```

- [ ] **Step 6: Absence on the other two backends**

Add to `test/integration/web/repo_edit_flow_test.rb`, running on every leg:

```ruby
  # RUNS ON ALL THREE LEGS and asserts the ABSENCE of the affordance rather than skipping — §14e,
  # a guard that skips on the thing it asserts is vacuous, and that exact mistake once made a boot
  # test report success over a loaded engine.
  test "the commit surface exists only where local_worktree is true" do
    if FileLayer.current.capabilities.local_worktree?
      root = make_repo!
      get repo_commit_path(root.node_id)
      assert_response :success
    else
      dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "x", kind: "dir")
      get repo_commit_path(dir.node_id)
      assert_redirected_to files_path
      assert_match(/local filesystem/i, flash[:alert])
    end
  end
```

- [ ] **Step 7: All three legs**

```bash
bin/ci test && bin/ci test-s3 && bin/ci test-chunk-remote
```

Expected: PASS, identical run counts.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/repo_commits_controller.rb app/views/repo_commits config/routes.rb test/integration/web/repo_edit_flow_test.rb
git commit -m "$(cat <<'EOF'
Add the review-and-commit surface (tinkerex#178)

Keyed by the repository ROOT node, not by a project: eligibility is "inside a working tree",
and keying on projects would exclude a repo that is not directly under Projects/.

Every pending row is re-asked of git rather than trusted -- the path is recomputed from the
catalog, and the row is dropped when the node is gone, has moved out of the repository, or
now matches HEAD because the maker committed it at the terminal. Ignored paths are listed
and not committable.

The absence test runs on ALL THREE legs and asserts the affordance is missing rather than
skipping: §14e, a guard that skips on the thing it asserts is vacuous.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: `@codemirror/merge` and the inline diff

**Files:**
- Modify: `vendor/javascript/codemirror-entry.js`
- Modify: `bin/build-codemirror`
- Modify: `app/views/repo_commits/show.html.erb`
- Create: `app/javascript/controllers/diffview_controller.js`

- [ ] **Step 1: Add the export**

In `vendor/javascript/codemirror-entry.js`:

```javascript
export { unifiedMergeView, getChunks, rejectChunk } from "@codemirror/merge"
```

- [ ] **Step 2: Re-derive the pin list**

Add `"@codemirror/merge": "6.12.2"` to the DIRECT block in `bin/build-codemirror`, then re-derive
the transitive block by that file's own recipe. **Rebuilding twice and comparing digests does not
prove reproducibility** — the registry does not move in two minutes.

```bash
mkdir -p /tmp/cm-pins && cd /tmp/cm-pins
# copy the DIRECT dependency block from bin/build-codemirror into package.json, then:
npm install --no-audit --no-fund
node -e 'const l=require("./package-lock.json"); for (const [p,v] of Object.entries(l.packages)) if (p.startsWith("node_modules/")) console.log(`    "${p.slice(13)}": "${v.version}",`)'
```

Drop the `@esbuild/*` platform binaries and paste the rest into the TRANSITIVE block.

- [ ] **Step 3: Rebuild and check the duplicate guard**

```bash
bin/build-codemirror
```

Expected: no "REFUSING TO BUILD" line, and a size near **962,174 bytes (334,181 gzipped)** — the
measured figures from spec part 13. A refusal means a package resolved to two copies; reconcile the
pins rather than proceeding. Two copies of `@codemirror/state` make CM6 ignore extensions
**silently**.

- [ ] **Step 4: Confirm no per-package pin crept in**

```bash
bin/rails test test/ci_hygiene_test.rb
```

Expected: PASS. It fails the build if a `pin "@codemirror/..."` line appears.

- [ ] **Step 5: The diff controller**

`app/javascript/controllers/diffview_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Inline diff for one pending path, in the commit box.
//
// THE VOCABULARY IS INVERTED HERE AND IT IS EASY TO SHIP BACKWARDS. CM6's merge extension is
// worded for merging a change IN: `original` is what you had, the document is what is proposed.
// Here `original` is HEAD's blob and the document is the maker's working tree, so REJECTING a
// chunk means REVERTING it. The button says "Revert hunk" for that reason — never "Reject".
export default class extends Controller {
  static values = { headUrl: String, workUrl: String, ext: String }

  async connect() {
    const [head, work] = await Promise.all([
      fetch(this.headUrlValue, { credentials: "same-origin" }).then(r => r.text()),
      fetch(this.workUrlValue, { credentials: "same-origin" }).then(r => r.text())
    ])
    const [cm, languages] = await Promise.all([
      import("codemirror"),
      import("lib/codemirror_languages")
    ])
    const language = languages.languageFor(this.extValue, cm)
    const extensions = [
      cm.basicSetup,
      cm.unifiedMergeView({ original: head, mergeControls: true }),
      cm.EditorState.readOnly.of(true)
    ]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: work, extensions }),
      parent: this.element
    })
  }

  disconnect() { this.view?.destroy(); this.view = null }
}
```

- [ ] **Step 6: Serve HEAD's blob**

Add to `RepoCommitsController`:

```ruby
  # HEAD's version of one path, as text, for the browser to diff against the working tree. The
  # server ships two blobs and diffs neither — that is what deletes the server-side text diff
  # tinkerex#161 built (spec part 13).
  def head_blob
    render plain: @local.head_text_for(params[:path].to_s), content_type: "text/plain"
  end
```

with the route `get "repos/:root_id/head_blob", to: "repo_commits#head_blob", as: :repo_head_blob`,
and in `LocalRepo`:

```ruby
      def head_text_for(rel)
        return "" if unborn?

        head_blob_for(rel).to_s
      end
```

(make `head_blob_for` public).

- [ ] **Step 7: Wire it into the view**

Inside the `<li>` in `app/views/repo_commits/show.html.erb`:

```erb
          <div class="commit-diff"
               data-controller="diffview"
               data-diffview-head-url-value="<%= repo_head_blob_path(@root.node_id, path: path) %>"
               data-diffview-work-url-value="<%= blob_file_path(@node_id_by_path[path]) %>"
               data-diffview-ext-value="<%= File.extname(path).downcase.delete(".") %>"></div>
```

- [ ] **Step 8: Prove it in a browser**

Extend the Task 6 system test: save a change, open the commit page, and assert the diff rendered.
A merge extension silently ignored by a duplicate `@codemirror/state` is invisible to every
request test.

```bash
bin/ci system
```

- [ ] **Step 9: Commit**

```bash
git add vendor/javascript bin/build-codemirror app/javascript/controllers/diffview_controller.js app/views/repo_commits app/controllers/repo_commits_controller.rb app/services/maker/git/local_repo.rb config/routes.rb test/system
git commit -m "$(cat <<'EOF'
Add the inline diff with @codemirror/merge (tinkerex#178)

6.12.2, MIT, into the VENDORED BUNDLE -- never a per-package importmap pin, which
ci_hygiene_test.rb fails the build over. Measured: +28,406 bytes (+9,597 gzipped, +3.0%),
no duplicate @codemirror/state, and the transitive pin block re-derived by
bin/build-codemirror's own recipe rather than by rebuilding twice, which proves nothing
because the registry does not move in two minutes.

The server ships two blobs and diffs neither -- that is what deletes the 207-line
server-side text diff tinkerex#161 built.

THE VOCABULARY IS INVERTED and the button says so: CM6's merge extension is worded for
merging a change IN, but here `original` is HEAD and the document is the working tree, so
rejecting a chunk means REVERTING it. "Revert hunk", never "Reject".

Driven in a browser, because a merge extension silently ignored by a duplicate
@codemirror/state is invisible to every request test.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

# Phase 3 — the guards that stop this rotting

---

## Task 12: the structural guard

Spec part 12: swapping `local_worktree?` for `is_a?(FileLayer::Share)` gives the same answer on all
three backends today, so **every behavioural test stays green**. Only a structural guard catches it.

**Files:**
- Modify: `test/architecture_invariants_test.rb`

- [ ] **Step 1: Write the guard**

```ruby
  # NO ADAPTER CLASS-CHECKS IN THE GIT SURFACE. `is_a?(FileLayer::Share)` and `local_worktree?`
  # give the SAME answer on all three backends today, so no behavioural test can tell them apart —
  # this is the only instrument that can. Same shape as the Sync:: seam guard below.
  #
  # SCOPED TO app/. The shared adapter contract asserts WHICH adapter answers true and needs the
  # class name to do it; a test saying so is the opposite of production code branching on it.
  def test_the_git_surface_never_branches_on_an_adapter_class
    files = Dir[Rails.root.join("app/{services/maker/git,controllers}/**/*.rb")] +
            Dir[Rails.root.join("app/services/library/working_tree.rb")]
    refute_empty files, "this scan matched nothing — it is vacuous (§14e)"

    offenders = files.select { |f| File.read(f).match?(/is_a\?\(\s*FileLayer::/) }

    assert_empty offenders.map { |f| Pathname(f).relative_path_from(Rails.root).to_s },
                 "ask a capability, never an adapter class (§14b: the ScanJob class check " \
                 "answered false for S3 and silently never indexed the library)"
  end
```

- [ ] **Step 2: Run**

```bash
bin/rails test test/architecture_invariants_test.rb -n test_the_git_surface_never_branches_on_an_adapter_class
```

Expected: PASS.

- [ ] **Step 3: Mutation-check, both assertions**

1. In `RepoCommitsController#load_repo`, replace the capability check with
   `FileLayer.current.is_a?(FileLayer::Share)` → the guard goes **RED**.
2. Change the glob to a path that matches nothing → the `refute_empty` goes **RED**. §14e: a guard
   that scans a directory dies silently when the directory leaves.

Restore both.

- [ ] **Step 4: Commit**

```bash
git add test/architecture_invariants_test.rb
git commit -m "$(cat <<'EOF'
Guard: the git surface never branches on an adapter class (tinkerex#178)

is_a?(FileLayer::Share) and local_worktree? give the SAME answer on all three backends
today, so no behavioural test can tell them apart. Stated in the spec as the one mutation
that cannot be caught behaviourally; this is the instrument that catches it.

Scoped to app/ -- the shared adapter contract asserts WHICH adapter answers true and needs
the class name to do it. A test saying so is the opposite of production code branching on it.

Mutation-checked both ways: swapping in the class check turns it red, and pointing the glob
at nothing turns the refute_empty red (§14e -- a guard that scans a directory dies silently
when the directory leaves).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: the wedge check

The highest-consequence silent failure in this repo. §14b records four skip-list wedges, each found
only after the previous explanation said it could not happen, and a wedge refuses that scan **and
every scan after it, permanently**.

**Files:**
- Create: `test/integration/web/repo_commit_wedge_test.rb`

- [ ] **Step 1: Write it**

```ruby
require "test_helper"
require "support/git_repo_fixture"

class RepoCommitWedgeTest < ActionDispatch::IntegrationTest
  include GitRepoFixture

  setup do
    @user = User.create!(email: "rt-#{SecureRandom.hex(4)}@example.com")
    sign_in_as @user
  end

  # THE MOST IMPORTANT ASSERTION IS THE ABSENCE OF A ROW. rugged writes blobs, trees, a commit and
  # a ref into .git; if any of that were ever to reach the catalog, the next scan would find a live
  # node at a path no observation can pair, tombstone it, and trip the mass-deletion guard —
  # refusing that scan and every scan after it, permanently, with nothing saying why.
  test "a commit leaves no catalog node under .git and the next scan is clean" do
    skip "share only" unless FileLayer.current.capabilities.local_worktree?

    root = make_repo!(files: { "a.txt" => "one\n" })
    a = @user.nodes.present.find_by!(name: "a.txt")
    patch file_path(a.node_id), params: { content: "two\n", base_token: token_for(a) }
    post repo_commit_path(root.node_id), params: { paths: [ "a.txt" ], message: "m" }

    Library::ScanJob.new.perform(user_id: @user.id) # must not raise Library::Scanner::UnsafeScan

    under_git = @user.nodes.where("storage_path LIKE ?", "%/.git/%").count
    assert_equal 0, under_git, "a cataloged write under .git is a permanent scan wedge (§14b)"

    marker = @user.nodes.present.find_by(name: ".git", kind: "dir")
    assert marker, "the marker itself must stay indexed — it is the evidence this is a repository"
  end
end
```

> The `skip` here is the one place it is right: the precondition is *a working tree existing at
> all*, which is not what the test asserts. Task 10 Step 6 is where the absence of the affordance
> is asserted on the other legs.

- [ ] **Step 2: Run**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/repo_commit_wedge_test.rb
```

Expected: PASS.

- [ ] **Step 3: Mutation-check**

Make the commit path write one object through the port instead of directly:

```ruby
FileLayer.current.write(@user, parent_node_id: @root_node.node_id, name: ".git", io: StringIO.new("x"))
```

It must raise from `observable!` — proving the bypass in spec part 3b is structural rather than a
convention. Restore.

- [ ] **Step 4: Commit**

```bash
git add test/integration/web/repo_commit_wedge_test.rb
git commit -m "$(cat <<'EOF'
Guard: a commit creates no catalog node under .git (tinkerex#178)

The highest-consequence silent failure available here. §14b records four skip-list wedges,
each found only after the previous explanation said it could not happen; a wedge refuses
that scan and every scan after it, permanently, with nothing saying why.

The most important assertion is the ABSENCE of a row. The marker itself must stay indexed --
it is the evidence the folder is a repository, and Library::WorkingTree reads exactly it.

Mutation-checked by routing one git object through the port: observable! refuses it, which
is what makes the bypass structural rather than a convention someone can forget.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: query budget, and the docs

**Files:**
- Modify: `test/integration/web/page_query_budget_test.rb`
- Create: `docs/invariants/git-editing.md`
- Modify: `CLAUDE.md` (a §14 stub)

- [ ] **Step 1: Query budget**

Add a case asserting the file page's query count is **constant in the repository's size** — never a
literal, because the counts differ per backend:

```ruby
  test "the file page's query count does not grow with the repository" do
    small = seed_repo_file!("a.txt", "x\n")
    3.times { |i| File.write(File.join(library_root, "demo", "sib#{i}.txt"), "y\n") }
    Library::ScanJob.new.perform(user_id: @user.id)
    get file_path(small.node_id) # warm anything memoised per process
    few = count_queries { get file_path(small.node_id) }

    30.times { |i| File.write(File.join(library_root, "demo", "more#{i}.txt"), "z\n") }
    Library::ScanJob.new.perform(user_id: @user.id)
    many = count_queries { get file_path(small.node_id) }

    # CONSTANCY IN N, NEVER A LITERAL -- the counts differ per backend, so a literal pins one leg
    # and fails the other two.
    assert_equal few, many,
                 "Library::WorkingTree walks ANCESTORS; if this grows it is walking siblings"
  end
```

- [ ] **Step 2: Write the invariants file**

`docs/invariants/git-editing.md`. Write these eight, each with its consequence named — not a
pointer to the spec, because §14's rule is that the RULE lives in the invariant and the STORY lives
elsewhere:

1. Bytes the catalog tracks go through the port; bytes git owns never do. Routing the git write
   through the port fails at `observable!`; routing a file write around it orphans every
   attachment, BOM link and tag on that node.
2. Ask `local_worktree?`, never `is_a?(FileLayer::Share)`. Same answer today, so no behavioural
   test can tell them apart — `architecture_invariants_test.rb` is the only guard.
3. `index.clear` is never written. It turns "commit these two files" into "commit whatever is lying
   around". And the index is never left untouched either — the committed paths would report as
   modified in the maker's own `git status`.
4. Compare content against HEAD's blob, never a stat. `share` is a NAS over SMB/NFS, where
   attribute caching can make a stat-based "unchanged" answer wrong.
5. A `.lock` file is refused, never deleted. Deleting another process's lock corrupts repositories.
6. A truncated buffer is never editable, and the server enforces it — a JavaScript-only refusal is
   one `curl` walks past, and saving a truncated buffer truncates the file.
7. `Library::WorkingTree` is the one definition of the ancestor walk. A second copy is the drift
   §14d names a service to end.
8. No file under `app/services/maker/git/` reuses a name `tinkerex#161` used. Those files are still
   on `claude/git-phase5-refinement`, and one `git checkout <branch> -- <path>` would overwrite the
   new class with a 583-line one built for a model that no longer exists.

- [ ] **Step 3: Add the CLAUDE.md stub**

Under a new `### 14l. Editing and committing in a repository` anchor, pointing at that file and
naming the paths that trigger it: `app/services/maker/git/`, `app/services/library/working_tree.rb`,
`app/controllers/repo_commits_controller.rb`, `FilesController#update`, `editor_controller.js`,
`diffview_controller.js`.

- [ ] **Step 4: Docs hygiene**

```bash
bin/rails test test/docs_hygiene_test.rb
```

Expected: PASS. It fails if a stub loses its file, a file loses its stub, or CLAUDE.md passes its
line ceiling.

- [ ] **Step 5: Commit**

```bash
git add test/integration/web/page_query_budget_test.rb docs/invariants/git-editing.md CLAUDE.md
git commit -m "$(cat <<'EOF'
Record the git-editing invariants and budget the page (tinkerex#178)

docs/invariants/git-editing.md with a §14l stub, per §14's rule that an invariant binding
one area is loaded when it applies rather than skimmed every session. The stub names the
paths that should send a reader there.

The query budget asserts CONSTANCY IN N, never a literal -- the counts differ per backend,
so a literal pins one leg and fails the other two.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
EOF
)"
```

---

# Before the PR — the gate `bin/ci` cannot provide

`tinkerex#161` was green through **eight merged PRs** while being wrong about the real library. Do
not skip this.

- [ ] **All gates green**

```bash
bin/ci
```

The three backend legs must print identical run counts (§15). A ±2 assertion / ±1 skip difference is
the known flap (`tinkerex#131`); a structural difference means a test depends on the ambient
`LIBRARY_BACKEND` and is a real bug.

- [ ] **Drive it on the share deployment, against the two repositories the maker actually brought** —
      `TheFlightWall_OSS` and `ESPHome-Projection-Clock`:
  1. edit a file, save, review, commit;
  2. in a terminal on the box: `git log`, `git status`, `git fsck --full --strict`;
  3. **the §8 rule 4 locking probe** — whether `O_CREAT|O_EXCL` is atomic on that mount. Take a
     lock by hand and confirm the app refuses rather than deleting it; commit from two sessions at
     once and confirm one is refused rather than lost. If this comes back bad, the fallback is
     **not** hydration — it is committing only when no lock is present and the mount passes a
     write-then-read-back check, the same touch-probe shape §14a uses at boot;
  4. a `Library::ScanJob` tick afterwards: no `UnsafeScan`, no nodes under `.git`.

- [ ] **Confirm the four app-created repositories still behave as ordinary repositories** —
      `catan`, `jewelry-box`, `test2`, `laser-mount`. Nothing should read `tinkerex.managed`, and
      nothing should treat them differently.

- [ ] **Open the PR, then file the arc as it opens** — never afterwards (§15):

```bash
gh pr create --fill
bin/log arc --from-pr <n>
```

State plainly in the PR what was verified and what was not. `bin/log close <n>` at merge — an arc
never closes itself.
