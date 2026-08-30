# History and Restore Implementation Plan

> **For agentic workers:** execution follows **`.claude/commands/execute-plan.md`** — batch by FILE,
> parallel where independent, one capped quality review per task. Steps use `- [ ]` checkboxes.

**Goal:** A maker can see what happened to a file in a repository they brought, view an old version,
diff it against what is on disk, and restore it as a pending edit that flows through the existing
commit box.

**Architecture:** One capped, asynchronously-loaded walk (`Maker::Git::History`) answers both the
file question and the repository question. Restore reuses the existing port write and `RepoEdit`
row — no second write mechanism.

**Spec:** `docs/superpowers/specs/2026-08-30-git-history-and-restore-design.md`. Bare `§` is
CLAUDE.md; the spec's sections are **part N**.

---

## Before you start

- [ ] Read the spec, especially **part 3** (the CIFS measurements and the two rules they force) and
      **part 6** (why restore writes a pending edit rather than a commit).
- [ ] Read `docs/invariants/git-editing.md` — this feature extends that area.
- [ ] **There is NO users fixture**; build users with `User.create!(email: "p-#{SecureRandom.hex(4)}@example.com")`.
- [ ] **`Library::ScanJob#perform` takes keyword args** — `perform(user_id:, root: nil)`.
- [ ] `test/support/git_repo_fixture.rb` exists: `make_repo!`, `seed_repo_file!`, `token_for`,
      `library_root`, `git_statuses`; it pins a share library via `use_fresh_share_library!`.
- [ ] Commit BEFORE mutating, and restore from a byte-exact snapshot rather than `git checkout --`,
      which restores to HEAD and discards uncommitted work in the same file.

Test commands (history tests need a real filesystem library):

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share DATABASE_URL=sqlite3:storage/test-h.sqlite3 bin/rails test <file>
```

---

## File structure

| Path | Responsibility |
|---|---|
| `app/services/maker/git/history.rb` | one capped walk; `for_repo`, `for_path`, `blob_at` |
| `app/controllers/repo_histories_controller.rb` | the repository-wide list |
| `app/views/repo_histories/show.html.erb` | that list |
| `app/javascript/controllers/history_controller.js` | async fetch + render of the file panel |
| `test/services/maker/git/history_test.rb` | |
| `test/integration/web/repo_history_flow_test.rb` | |
| `test/system/repo_history_test.rb` | |

Modified: `FilesController` (`#history`, `#history_blob`, `#restore`), `config/routes.rb`,
`app/views/files/show.html.erb`, `app/javascript/controllers/diffview_controller.js`,
`app/assets/stylesheets/application.css`, `test/support/git_repo_fixture.rb`,
`docs/invariants/git-editing.md`.

---

## Task 1: `Maker::Git::History`

**Files:** create `app/services/maker/git/history.rb`, `test/services/maker/git/history_test.rb`;
modify `test/support/git_repo_fixture.rb`.

- [ ] **Step 1: A fixture that can build more commits than the cap**

In `test/support/git_repo_fixture.rb`:

```ruby
  # A REPOSITORY WITH MORE COMMITS THAN THE CAP. Without this every cap assertion is vacuous --
  # a walk that never reaches its limit proves nothing about the limit, and that exact shape is
  # what kept tinkerex#185 invisible.
  #
  # `touch_every` makes path filtering sparse ON PURPOSE: with it at 4, only a quarter of commits
  # touch "tracked.txt", which is what makes "the walk stopped before finding anything" a state
  # the tests can actually reach (spec part 3).
  def make_repo_with_commits!(name: "many", count: 12, touch_every: 4)
    dir = File.join(library_root, name)
    FileUtils.mkdir_p(dir)
    repo = Rugged::Repository.init_at(dir)
    parents = []
    count.times do |i|
      rel = (i % touch_every).zero? ? "tracked.txt" : "other-#{i}.txt"
      File.write(File.join(dir, rel), "v#{i}\n")
      index = repo.index
      index.read_tree(repo.head.target.tree) unless repo.head_unborn?
      index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644)
      index.write
      oid = Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "c#{i}",
                                  parents:, update_ref: "HEAD",
                                  author: { name: "Seed", email: "s@example.com", time: Time.now.to_time },
                                  committer: { name: "Seed", email: "s@example.com", time: Time.now.to_time })
      parents = [ oid ]
    end
    Library::ScanJob.new.perform(user_id: @user.id)
    @user.nodes.present.find_by!(name:, kind: "dir")
  end
```

- [ ] **Step 2: Write the failing test**

`test/services/maker/git/history_test.rb`:

```ruby
require "test_helper"
require "support/git_repo_fixture"

class Maker::Git::HistoryTest < ActiveSupport::TestCase
  include GitRepoFixture

  setup { @user = User.create!(email: "h-#{SecureRandom.hex(4)}@example.com") }

  def history_for(root) = Maker::Git::History.new(Maker::Git::LocalRepo.open(@user, root))

  test "repository history is newest first" do
    root = make_repo_with_commits!(count: 5)
    r = history_for(root).for_repo

    assert_equal %w[c4 c3 c2 c1 c0], r.entries.map { |e| e.message.strip }
    assert_equal :exhausted, r.stopped
  end

  test "an entry carries the author and time git recorded" do
    root = make_repo_with_commits!(count: 2)
    e = history_for(root).for_repo.entries.first

    assert_equal "Seed", e.author_name
    assert_equal "s@example.com", e.author_email
    assert_kind_of Time, e.time
    assert_equal 40, e.oid.length
  end

  # THE CAP IS A CORRECTNESS RULE (spec part 3): an uncapped walk measured 4.9s on 333 commits
  # over CIFS. Assert what was WALKED, not just what was returned -- returning few is not the
  # same as looking at few, and only the second protects the page.
  test "the walk stops at walk_limit and says so" do
    root = make_repo_with_commits!(count: 20)
    r = history_for(root).for_repo(limit: 50, walk_limit: 5)

    assert_equal 5, r.walked
    assert_equal :walk_limit, r.stopped
  end

  test "the walk stops at limit and says so" do
    root = make_repo_with_commits!(count: 20)
    r = history_for(root).for_repo(limit: 3, walk_limit: 100)

    assert_equal 3, r.entries.size
    assert_equal :limit, r.stopped
  end

  test "path history lists only the commits that touched that path" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    r = history_for(root).for_path("tracked.txt")

    assert_equal %w[c8 c4 c0], r.entries.map { |e| e.message.strip }
  end

  # The state spec part 3 says must never be reported as "no history".
  test "a capped path walk can find nothing and reports walk_limit, not exhausted" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    r = history_for(root).for_path("other-1.txt", walk_limit: 2)

    assert_empty r.entries
    assert_equal :walk_limit, r.stopped
  end

  test "blob_at returns the content at that commit" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    h = history_for(root)
    oldest = h.for_path("tracked.txt").entries.last

    assert_equal "v0\n", h.blob_at(oldest.oid, "tracked.txt")
  end

  test "blob_at is nil when the path is absent at that commit" do
    root = make_repo_with_commits!(count: 4, touch_every: 4)
    h = history_for(root)

    assert_nil h.blob_at(h.for_repo.entries.first.oid, "nope.txt")
  end

  test "an oid from another repository is refused" do
    a = make_repo_with_commits!(name: "a", count: 2)
    make_repo_with_commits!(name: "b", count: 2)
    foreign = Rugged::Repository.new(File.join(library_root, "b")).head.target.oid

    assert_nil history_for(a).blob_at(foreign, "tracked.txt")
  end

  test "an unborn repository has no history and is exhausted" do
    root = make_repo!(files: { "a.txt" => "x\n" }, commit: false)
    r = history_for(root).for_repo

    assert_empty r.entries
    assert_equal :exhausted, r.stopped
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share DATABASE_URL=sqlite3:storage/test-h.sqlite3 bin/rails test test/services/maker/git/history_test.rb
```
Expected: `NameError: uninitialized constant Maker::Git::History`.

- [ ] **Step 4: Write the service**

`app/services/maker/git/history.rb`:

```ruby
require "rugged"

module Maker
  module Git
    # What happened in this repository, and to this path — as much of it as we can afford to look at.
    #
    # THE CAP IS NOT AN OPTIMISATION AND MUST NOT BE MADE OPTIONAL. Measured on the live share
    # deployment against a 333-commit repository over its real CIFS mount: a full walk is 4,917 ms,
    # a walk capped at 25 is 104 ms cold and 1 ms warm (spec part 3). ~15 ms per commit is a network
    # round trip per object. There is no "all history" call here and there must never be one.
    #
    # `stopped` IS LOAD-BEARING, NOT BOOKKEEPING. Path filtering is sparse — 1 of the last 50 commits
    # touched README.md in the measured repository, against 28 of all 333 — so an empty result
    # usually means "we stopped looking", not "nothing happened". Only `:exhausted` licenses a caller
    # to say there is no history. Delete this member and the UI starts lying quietly.
    #
    # BOTH QUESTIONS COME OFF ONE WALK on purpose. Building the file surface now and the repository
    # one later gives two walkers that drift on ordering, caps and what stopping early means.
    class History
      Entry  = Data.define(:oid, :message, :author_name, :author_email, :time) do
        def short_oid = oid[0, 8]
        def subject = message.to_s.lines.first.to_s.strip
      end

      Result = Data.define(:entries, :walked, :stopped) do
        # The ONE question the view may ask before saying "nothing here".
        def exhausted? = stopped == :exhausted
      end

      DEFAULT_LIMIT      = 25
      DEFAULT_WALK_LIMIT = 250
      MAX_WALK_LIMIT     = 2_000

      def initialize(local_repo)
        @local = local_repo
        @repo = local_repo.rugged
      end

      def for_repo(limit: DEFAULT_LIMIT, walk_limit: DEFAULT_WALK_LIMIT)
        walk(limit:, walk_limit:) { true }
      end

      # Compares the blob oid at each commit against its FIRST PARENT's. Absent in both is not a
      # change; a merge is therefore attributed once, to the merge, which is what `git log` does by
      # default. Comparing against every parent looks more thorough and lists the same change twice.
      def for_path(rel, limit: DEFAULT_LIMIT, walk_limit: DEFAULT_WALK_LIMIT)
        walk(limit:, walk_limit:) do |commit|
          parent = commit.parents.first
          blob_oid(commit, rel) != (parent && blob_oid(parent, rel))
        end
      end

      # The content of `rel` at `oid`, or nil — absent path, absent commit, or an oid belonging to
      # some other repository. NIL RATHER THAN RAISING: every caller here is answering a URL
      # parameter, and a 404 is the honest answer to all three.
      def blob_at(oid, rel)
        commit = @repo.lookup(oid)
        return nil unless commit.is_a?(Rugged::Commit)

        entry = commit.tree.path(rel)
        blob = @repo.lookup(entry[:oid])
        blob.is_a?(Rugged::Blob) ? blob.content : nil
      rescue Rugged::OdbError, Rugged::TreeError, Rugged::InvalidError, TypeError
        nil
      end

      private

      def walk(limit:, walk_limit:)
        return Result.new(entries: [], walked: 0, stopped: :exhausted) if @local.unborn?

        cap = [ walk_limit.to_i, MAX_WALK_LIMIT ].min
        entries = []
        walked = 0
        stopped = :exhausted

        walker = Rugged::Walker.new(@repo)
        # EXPLICIT ORDERING. libgit2 does not specify the walker's default, and a history list whose
        # order depends on an implementation detail will reorder itself one day for no visible reason.
        walker.sorting(Rugged::SORT_DATE)
        walker.push(@repo.head.target)

        walker.each do |commit|
          if walked >= cap
            stopped = :walk_limit
            break
          end
          walked += 1
          next unless yield(commit)

          entries << entry_for(commit)
          if entries.size >= limit
            stopped = :limit
            break
          end
        end

        Result.new(entries:, walked:, stopped:)
      end

      def entry_for(commit)
        Entry.new(oid: commit.oid, message: commit.message,
                  author_name: commit.author[:name], author_email: commit.author[:email],
                  time: commit.author[:time])
      end

      def blob_oid(commit, rel)
        commit.tree.path(rel)[:oid]
      rescue Rugged::TreeError
        nil
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests** — expected PASS, 10 runs.

- [ ] **Step 6: Mutation checks — paste ACTUAL output for each**

1. Remove the `walked >= cap` break → "the walk stops at walk_limit" goes RED.
2. Always set `stopped = :exhausted` → the capped-path test goes RED.
3. Compare against `commit.parents` (all) instead of `.first` → build a merge fixture and assert
   the merged change is listed once; it must go RED. *If your fixture has no merge, add one — a
   mutation nothing can catch is not a checked mutation.*
4. Drop the `is_a?(Rugged::Commit)` guard in `blob_at` → the foreign-oid test goes RED.

Restore from a byte-exact snapshot after each; confirm `git status --porcelain`.

- [ ] **Step 7: Commit** with a message naming the measurement the cap comes from.

---

## Task 2: the server surfaces

**Files:** modify `app/controllers/files_controller.rb`, `config/routes.rb`,
`app/views/files/show.html.erb`; create `app/controllers/repo_histories_controller.rb`,
`app/views/repo_histories/show.html.erb`, `test/integration/web/repo_history_flow_test.rb`.

- [ ] **Step 1: Routes**

```ruby
  # History is FETCHED, not rendered inline: a cold capped walk is ~100ms and a deep one is
  # seconds, and the file page must not wait on either (spec part 3 rule 2).
  resources :files, only: %i[index create show update destroy] do
    member do
      get "blob"
      get "geometry"
      get "history"                     # JSON, for history_controller.js
      get "history/:oid", to: "files#history_blob", as: :history_blob, constraints: { oid: /[0-9a-f]{7,40}/ }
      post "restore/:oid", to: "files#restore", as: :restore, constraints: { oid: /[0-9a-f]{7,40}/ }
    end
  end

  # The repository-wide list. Reached from the .repo-banner the file page already renders — a new
  # page with no door is the defect PR #282 fixed, and it is too recent to repeat.
  get "repos/:root_id/history", to: "repo_histories#show", as: :repo_history
```

- [ ] **Step 2: Write the failing tests**

`test/integration/web/repo_history_flow_test.rb` — cases:

```ruby
  test "the file page mounts the history panel for a file in a working tree" do
    node = seed_repo_file!("notes.md", "old\n")
    get file_path(node.node_id)
    assert_select "[data-controller='history']", 1
  end

  test "history JSON lists the commits that touched this path" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")

    get history_file_path(node.node_id), as: :json

    body = JSON.parse(response.body)
    assert_equal %w[c4 c0], body["entries"].map { |e| e["subject"] }
    assert_equal "exhausted", body["stopped"]
  end

  # The honest-emptiness rule (spec part 3). A capped walk that found nothing must NOT be
  # reported in a way a view could render as "no history".
  test "a capped walk that finds nothing reports walk_limit, not exhausted" do
    root = make_repo_with_commits!(count: 12, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "other-1.txt")

    get history_file_path(node.node_id, walk_limit: 2), as: :json

    body = JSON.parse(response.body)
    assert_empty body["entries"]
    assert_equal "walk_limit", body["stopped"]
  end

  test "the blob at a commit is served as text" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oid = JSON.parse(get_history(node)).dig("entries", 1, "oid")

    get history_blob_file_path(node.node_id, oid: oid)

    assert_equal "v0\n", response.body
  end

  test "restoring writes the old content and creates a pending edit" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oid = JSON.parse(get_history(node)).dig("entries", 1, "oid")

    post restore_file_path(node.node_id, oid: oid)

    assert_equal "v0\n", FileLayer.current.read(@user, node_id: node.node_id)
    assert_equal 1, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
  end

  test "restoring the content already on disk is refused" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    head_oid = JSON.parse(get_history(node)).dig("entries", 0, "oid")

    post restore_file_path(node.node_id, oid: head_oid)

    assert_response :unprocessable_entity
    assert_equal 0, Maker::RepoEdit.where(user: @user, node_id: node.node_id).count
  end

  test "an oid this repository does not contain is 404" do
    node = seed_repo_file!("notes.md", "old\n")
    get history_blob_file_path(node.node_id, oid: "0" * 40)
    assert_response :not_found
  end

  test "the repository page lists commits and is reachable from the banner" do
    root = make_repo_with_commits!(count: 5)
    node = @user.nodes.present.find_by!(name: "tracked.txt")

    get file_path(node.node_id)
    assert_select "a[href=?]", repo_history_path(root.node_id)

    get repo_history_path(root.node_id)
    assert_response :success
    assert_select "[data-oid]", 5
  end
```

Add `def get_history(node) = (get(history_file_path(node.node_id), as: :json); response.body)`.

- [ ] **Step 3: `FilesController` actions**

```ruby
  # GET /files/:id/history — JSON, fetched by history_controller.js after the page renders.
  def history
    node, root = repo_context!
    return render json: { entries: [], stopped: "no_repo" } if root.nil?

    result = Maker::Git::History.new(Maker::Git::LocalRepo.open(current_user, root))
                                .for_path(repo_relative_path(node, root),
                                          walk_limit: history_walk_limit)
    render json: {
      stopped: result.stopped.to_s,
      walked: result.walked,
      restorable: FileLayer.current.capabilities.local_worktree?,
      entries: result.entries.map { |e|
        { oid: e.oid, short_oid: e.short_oid, subject: e.subject,
          author: e.author_name, time: e.time.iso8601 }
      }
    }
  end

  # GET /files/:id/history/:oid — the file's content at that commit, as text, for the diff view.
  def history_blob
    node, root = repo_context!
    content = root && Maker::Git::History.new(Maker::Git::LocalRepo.open(current_user, root))
                                         .blob_at(params[:oid], repo_relative_path(node, root))
    return head :not_found if content.nil?

    render plain: content, content_type: "text/plain"
  end

  # POST /files/:id/restore/:oid — put an old version back as a PENDING EDIT. It does not commit;
  # the maker reviews it in the commit box like any other change (spec part 6).
  def restore
    node, root = repo_context!
    return render_save_error(:unprocessable_entity, "Only files inside a git repository can be restored.") if root.nil?
    unless FileLayer.current.capabilities.local_worktree?
      return render_save_error(:unprocessable_entity, "Restoring needs a library on a local filesystem.")
    end

    rel = repo_relative_path(node, root)
    content = Maker::Git::History.new(Maker::Git::LocalRepo.open(current_user, root)).blob_at(params[:oid], rel)
    return head :not_found if content.nil?
    if content.bytesize > EDITABLE_MAX_BYTES
      return render_save_error(:unprocessable_entity, "That version is too large to restore here.")
    end
    # A NO-OP RESTORE IS REFUSED rather than performed. Writing identical bytes creates a pending
    # edit the commit box immediately drops as :unchanged -- a button that appears to do nothing.
    if content == FileLayer.current.read(current_user, node_id: node.node_id)
      return render_save_error(:unprocessable_entity, "That version is already what is on disk.")
    end

    Maker::Addons::LibraryOutput.write_bytes!(current_user, parent_node_id: node.parent_node_id,
                                              name: node.name, bytes: content, replace: true)
    Maker::RepoEdit.record!(user: current_user, repo_root_node_id: root.node_id, node_id: node.node_id)
    redirect_to file_path(node.node_id), notice: "Restored. Review it in the commit box."
  rescue FileLayer::FetchError => e
    render_save_error(:service_unavailable, e.message)
  end
```

with private helpers:

```ruby
  def repo_context!
    node = current_user.nodes.present.find_by!(node_id: params[:id])
    [ node, Library::WorkingTree.new(current_user).root_for(node) ]
  end

  # The path git knows this file by. Derived from the catalog, never rebuilt from names: the same
  # source the commit box reconciles against, so the two cannot disagree about what a file is called.
  def repo_relative_path(node, root)
    tree = Maker::LibraryTree.new(current_user)
    full = "#{tree.path_for(node.parent_node_id)}/#{node.name}"
    root_path = tree.path_for(root.node_id)
    full.delete_prefix("#{root_path}/")
  end

  # Bounded by the service's own ceiling, so a caller cannot ask for an unbounded walk however
  # they spell the parameter. A missing, zero or negative value is the default, not an error: this
  # is a query string, and the honest response to junk is the ordinary page.
  def history_walk_limit
    requested = params[:walk_limit].to_i
    return Maker::Git::History::DEFAULT_WALK_LIMIT if requested <= 0

    requested.clamp(1, Maker::Git::History::MAX_WALK_LIMIT)
  end
```

- [ ] **Step 4: `RepoHistoriesController` + view** — the same service with `for_repo`, rendering
      rows with `data-oid`, each linking to the files it changed. Mirror `RepoCommitsController`'s
      `load_repo` refusal handling exactly; do not invent a second style.

- [ ] **Step 5: The panel mount and the banner link** in `app/views/files/show.html.erb` —
      `data-controller="history"` with the three URLs as values. **A literal identifier, never an
      ERB ternary**: `stimulus_hygiene_test.rb` scans the literal attribute (§14d).

- [ ] **Step 6: Run all three legs**; run counts must be identical.

- [ ] **Step 7: Mutation checks with pasted output** — remove the no-op-restore refusal; remove the
      `local_worktree?` gate on restore; return `stopped` as always `"exhausted"`.

- [ ] **Step 8: Commit.**

---

## Task 3: the browser

**Files:** create `app/javascript/controllers/history_controller.js`,
`test/system/repo_history_test.rb`; modify
`app/javascript/controllers/diffview_controller.js`, `app/assets/stylesheets/application.css`.

- [ ] **Step 1: Generalise `diffview_controller`** so the "original" side is any URL, not only
      `repo_head_blob_path`. It currently hardcodes HEAD; the history panel needs it to diff a
      commit's blob against the working tree. Keep `mergeControls: false` and the
      "Revert hunk, never Reject" note — `tinkerex#184` is still open and this must not quietly
      re-enable a control that does not post.

- [ ] **Step 2: `history_controller.js`** — fetch the JSON after connect, render rows, and wire
      View / Diff / Restore. It must:
  - render the honest empty state: `stopped !== "exhausted"` → *"No changes to this file in the
    last N commits"* plus a **Look further** control that re-fetches with a doubled `walk_limit`;
    only `"exhausted"` may say the file has no earlier history;
  - hide Restore when `restorable` is false;
  - degrade to a plain message if the fetch fails, never an empty panel that looks like "no history".

- [ ] **Step 3: A system test that drives it in a browser.** The panel is populated by fetch, so a
      request test cannot see it at all, and a `data-controller` that resolves to nothing is a
      silent no-op (§14d). Assert: rows appear; View renders content; Diff renders
      `.cm-deletedChunk`; Restore produces a pending edit that the commit box then offers.

- [ ] **Step 4: Mutation check** — make the empty state say "no history" unconditionally; the
      honest-emptiness assertion must go RED. Paste the output.

- [ ] **Step 5: Commit.**

---

## Task 4: invariants and docs

**Files:** modify `docs/invariants/git-editing.md`.

- [ ] Add the spec's part 10 rules (six), each with its consequence named. The cap and the
      `stopped` member both need the measurement beside them — a rule whose number is missing is
      the first one someone "simplifies".
- [ ] `bin/rails test test/docs_hygiene_test.rb` must pass. **CLAUDE.md needs no new stub**: §14l
      already points at `docs/invariants/git-editing.md`, and the ceiling is at 1,355 with no
      headroom, so do not add lines there.
- [ ] Commit.

---

## Before the PR

- [ ] Bare `bin/ci`; read the three legs' run counts and confirm they are identical (§15).
- [ ] `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync` from this worktree.
- [ ] Open the PR. **Do not merge and do not deploy** — both need the user's explicit go-ahead.
- [ ] `bin/log arc --from-pr <n>` as the PR opens.
- [ ] State in the PR that the real-library gate (part 8) has **not** been run, since it needs a
      deploy.
