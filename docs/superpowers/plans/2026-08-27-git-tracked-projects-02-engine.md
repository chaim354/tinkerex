# Phase 2 — The engine: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Read first:** [`00-overview.md`](2026-08-27-git-tracked-projects-00-overview.md), and the
> design's §3.1, §4, §4.1 and §9.1. **Phase 1 must be merged** — this phase consumes its verbs.

**Goal:** the app can build, extend, pack and persist a real git repository for a project, on all
three backends, verified by `git fsck`.

**Architecture:** `rugged` operates on an **ephemeral cache directory** hydrated from the library via
phase 1's verbs; on `share` the library is already a filesystem so hydration is a no-op. Loose
objects are consolidated into a pack by a hand-written writer, because **rugged has no packbuilder**
— confirmed by introspecting the gem, not by reading its README (§3.1).

**Tech stack:** `rugged` (libgit2, GPL-2.0 *with linking exception*), Rails 8, Minitest.

**Deliberately NOT in this phase:** any `ScanJob` wiring, any repo init for real projects, any UI.
Nothing here runs against production data. That is phase 3, and it is where all the risk lives.

---

## File structure

| file | responsibility |
|---|---|
| `Gemfile` (modify) | `gem "rugged"` |
| `Dockerfile` (modify) | `cmake` in the build stage — rugged compiles libgit2 |
| `app/services/maker/git/pack_writer.rb` (create) | objects → one undeltified pack + idx v2. Nothing else |
| `app/services/maker/git/repo.rb` (create) | the lifecycle: hydrate, commit, consolidate, persist |
| `app/services/maker/git/commit_info.rb` (create) | the value object the UI will read in phase 4 |
| `app/models/maker/git_repo.rb` (create) | bookkeeping row — an index, never a source of truth |
| `db/migrate/*_create_maker_git_repos.rb` (create) | the table |
| `test/services/maker/git/pack_writer_test.rb` (create) | verified against **real git** |
| `test/services/maker/git/repo_test.rb` (create) | the lifecycle, run on every backend |

---

### Task 1: rugged builds in the image

**Files:**
- Modify: `Gemfile`
- Modify: `Dockerfile`

- [ ] **Step 1: Add the gem**

```ruby
# Gemfile — beside the other service gems

# libgit2 bindings. LICENCE NOTE (§9): libgit2 is GPL-2.0 WITH A LINKING EXCEPTION, written to
# permit linking from a program under any licence — so this does NOT put GPL obligations on the
# app, unlike shipping the `git` CLI would. Recorded here because §9 says avoid GPL and a future
# reader will otherwise flag this as a violation.
gem "rugged"
```

- [ ] **Step 2: Add cmake to the build stage**

In `Dockerfile`, the build stage's `apt-get install` line (currently
`build-essential git libyaml-dev openssh-client pkg-config`) gains `cmake`:

```dockerfile
    apt-get install --no-install-recommends -y build-essential cmake git libyaml-dev openssh-client pkg-config && \
```

**Build stage only.** rugged compiles libgit2 into the gem at install time; the final image needs
neither cmake nor libgit2 separately, because `${BUNDLE_PATH}` is copied wholesale.

- [ ] **Step 3: Verify it installs**

Run: `bundle install`
Expected: `Fetching rugged` … `Building native extensions` … success. Locally this needs `cmake` on
`PATH` (`brew install cmake`).

- [ ] **Step 4: Verify the image still builds**

Run: `docker build -t tinkerex-rugged-check .`
Expected: success. If the build stage fails on cmake, the `apt-get` edit landed in the wrong stage.

- [ ] **Step 5: Commit**

```bash
git add Gemfile Gemfile.lock Dockerfile
git commit -m "Add rugged; cmake into the build stage only"
```

---

### Task 2: `Maker::Git::PackWriter`

This code is **already written and verified** — see
`docs/superpowers/specs/2026-08-27-git-tracked-projects-packwriter.rb`. Real git read its output at
254 and 11,214 objects with `fsck --full --strict` clean and `git clone` succeeding. Port it, keep
the header, and write the tests that prove it here too.

**Files:**
- Create: `app/services/maker/git/pack_writer.rb`
- Create: `test/services/maker/git/pack_writer_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/pack_writer_test.rb
require "test_helper"

class Maker::Git::PackWriterTest < ActiveSupport::TestCase
  # THE ONLY TEST THAT PROVES ANYTHING HERE IS ONE REAL GIT RUNS. A hand-rolled parser in the test
  # would share whatever misunderstanding the writer has and confirm it — the FakeS3 lesson in
  # §14e, where an exactly-inverse encode/decode pair kept 79 of 80 tests green over silent data
  # loss. Assert the WIRE, and let git be the reader.
  def setup
    skip "needs the git binary" unless system("git --version > /dev/null 2>&1")
    @dir = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir
  end

  test "git reads a pack this writes, with every loose object deleted" do
    build_repo_with_commits(3)
    objects = loose_objects

    Maker::Git::PackWriter.write(File.join(@dir, ".git/objects/pack"), objects)
    delete_loose_objects!

    assert_equal 0, loose_object_paths.size, "setup error: loose objects survived"
    assert git("fsck --full --strict"), "git fsck rejected the pack"
    assert_equal "3", git_out("rev-list --count HEAD")
  end

  test "the oid this writer names matches the oid git computed" do
    build_repo_with_commits(2)
    loose_objects.each do |oid, type, payload|
      recomputed = Digest::SHA1.hexdigest("#{type} #{payload.bytesize}\0".b + payload)
      assert_equal oid, recomputed, "oid naming rule disagrees with git for a #{type}"
    end
  end

  test "it refuses an offset past the idx v2 4-byte field rather than writing a corrupt idx" do
    # A >2 GiB pack needs the large-offset table, which this writer does not implement. Writing a
    # truncated offset instead would produce an idx that PARSES and resolves the wrong objects —
    # silent corruption of someone's history. Refuse loudly.
    huge = [ { oid: "a" * 40, offset: 0x80000000, crc: 0 } ]
    assert_raises(RuntimeError) { Maker::Git::PackWriter.build_idx(huge, "x" * 20) }
  end

  private

  def git(args) = system("git -C #{@dir} #{args} > /dev/null 2>&1")
  def git_out(args) = `git -C #{@dir} #{args}`.strip

  def build_repo_with_commits(n)
    system("git init -q #{@dir} && git -C #{@dir} config gc.auto 0 && " \
           "git -C #{@dir} config user.email b@t && git -C #{@dir} config user.name Bot")
    n.times do |i|
      File.write(File.join(@dir, "f.txt"), "line #{i}\n", mode: "a")
      system("git -C #{@dir} add -A && git -C #{@dir} commit -qm 'c#{i}' --no-gpg-sign")
    end
  end

  def loose_object_paths = Dir.glob(File.join(@dir, ".git/objects/??/*"))

  def loose_objects
    loose_object_paths.map do |p|
      oid = p.split("/")[-2] + File.basename(p)
      type, payload = Maker::Git::PackWriter.read_loose(p)
      [ oid, type, payload ]
    end
  end

  def delete_loose_objects! = loose_object_paths.each { |p| File.unlink(p) }
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/pack_writer_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Git::PackWriter`

- [ ] **Step 3: Implement**

Copy `docs/superpowers/specs/2026-08-27-git-tracked-projects-packwriter.rb` to
`app/services/maker/git/pack_writer.rb`, wrapping it as `module Maker; module Git; module PackWriter`
and keeping every comment. It is ~70 lines and reproduced in full in that file — do not retype it
from memory.

Then extend the header with what phase 2 adds:

```ruby
    # WHY THIS EXISTS AT ALL: rugged has no packbuilder. Confirmed by introspecting rugged 1.9.6 /
    # libgit2 1.9.6 — Rugged::Repository exposes 69 instance methods and NOT ONE matches
    # pack/repack/gc/prune, and Rugged::Packbuilder, Rugged::Indexer and Rugged::Odb are undefined.
    # That is a measurement, not a reading of its README.
    #
    # WHY UNDELTIFIED IS ACCEPTABLE: it costs 5x on bytes against `git gc` (3.9 MB vs 784 KB at
    # 1,500 commits, measured), and buys the entire 390x FILE-COUNT reduction, which is the term
    # that actually matters — an unpacked repo needs 11,287 GETs to hydrate on s3 against 3.
    # Five times SMALL is still small, and it is only small because §5 keeps binaries out as
    # pointers. If §5 is ever weakened, this trade goes with it.
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/pack_writer_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check the fanout**

The idx fanout is **cumulative**. A per-bucket fanout parses without error and resolves the wrong
objects — the worst kind of bug, because nothing raises. Temporarily change:

```ruby
counts.each { |c| total += c; idx << [ total ].pack("N") }
```
to
```ruby
counts.each { |c| idx << [ c ].pack("N") }
```

Run the test file.
Expected: `git fsck` goes **RED**. Restore, confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/pack_writer.rb test/services/maker/git/pack_writer_test.rb
git commit -m "Maker::Git::PackWriter: undeltified pack + idx v2, verified by real git"
```

---

### Task 3: The bookkeeping table

**Files:**
- Create: `db/migrate/<ts>_create_maker_git_repos.rb`
- Create: `app/models/maker/git_repo.rb`
- Create: `test/models/maker/git_repo_test.rb`

- [ ] **Step 1: Write the migration**

```ruby
class CreateMakerGitRepos < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_git_repos do |t|
      t.references :project, null: false, foreign_key: { to_table: :maker_projects }, index: { unique: true }
      t.string   :head_oid
      t.datetime :last_commit_at
      t.timestamps
    end
  end
end
```

**One row per project, enforced by a unique index** rather than by convention — two rows would let
two workers each believe they hold the head.

- [ ] **Step 2: Write the model and its test**

```ruby
# app/models/maker/git_repo.rb
module Maker
  # Bookkeeping for a project's repository. AN INDEX, NEVER A SOURCE OF TRUTH.
  #
  # The authoritative head is the repo's own `refs/heads/main`, and the authoritative answer to
  # "is this repo app-managed" is the git config key `tinkerex.managed` (§8.1) — both travel with
  # the repo, so a restore, a re-hydrate, or a maker copying their library to a new NAS keeps
  # them. This row exists so the UI and the intake sweep can ask "does this project have a repo,
  # and roughly where is it" WITHOUT hydrating, which on s3 is real requests.
  #
  # Consequence to respect: this row may be STALE or ABSENT and the repo still valid. Never treat
  # its absence as "no repo" for a destructive decision.
  class GitRepo < ApplicationRecord
    self.table_name = "maker_git_repos"
    belongs_to :project, class_name: "Maker::Project"
    validates :project_id, uniqueness: true
  end
end
```

```ruby
# test/models/maker/git_repo_test.rb
require "test_helper"

class Maker::GitRepoTest < ActiveSupport::TestCase
  test "one row per project" do
    project = users(:one).maker_projects.create!(title: "P")
    Maker::GitRepo.create!(project:)
    assert_raises(ActiveRecord::RecordInvalid) { Maker::GitRepo.create!(project:) }
  end
end
```

- [ ] **Step 3: Run**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/git_repo_test.rb`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add db/ app/models/maker/git_repo.rb test/models/maker/git_repo_test.rb
git commit -m "maker_git_repos: an index for project repos, one row per project"
```

---

### Task 4: `Maker::Git::Repo` — hydrate and commit

**Files:**
- Create: `app/services/maker/git/repo.rb`
- Create: `app/services/maker/git/commit_info.rb`
- Create: `test/services/maker/git/repo_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/repo_test.rb
require "test_helper"

# RUNS ON EVERY BACKEND. The three legs must report identical counts (§15), so nothing in here may
# branch on LIBRARY_BACKEND — the point is that the lifecycle is backend-agnostic above the port.
class Maker::Git::RepoTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @project = @user.maker_projects.create!(title: "Lamp")
    @project.ensure_library_folder!(@user)
    @repo = Maker::Git::Repo.for(@project)
  end

  test "a fresh repo has no head" do
    @repo.hydrate!
    assert_nil @repo.head_oid
  end

  test "commit! writes a commit and moves the head" do
    @repo.hydrate!
    oid = @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "first")

    assert_match(/\A[0-9a-f]{40}\z/, oid)
    assert_equal oid, @repo.head_oid
  end

  test "commit! returns nil when nothing changed" do
    @repo.hydrate!
    @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "first")

    assert_nil @repo.commit!(paths: { "docs/notes.md" => "hello\n" }, message: "second"),
               "an unchanged tree must not mint an empty commit every scan"
  end

  test "history survives a persist and a fresh hydrate" do
    # THE WHOLE PHASE IN ONE TEST. Everything the cache holds is thrown away, and the repo is
    # rebuilt from library bytes alone.
    @repo.hydrate!
    first = @repo.commit!(paths: { "docs/notes.md" => "one\n" }, message: "one")
    @repo.consolidate!
    @repo.persist!

    rebuilt = Maker::Git::Repo.for(@project.reload)
    rebuilt.discard_cache!
    rebuilt.hydrate!

    assert_equal first, rebuilt.head_oid
    assert_equal "one\n", rebuilt.blob_at(oid: first, path: "docs/notes.md")
  end

  test "consolidate! leaves no loose objects" do
    # Not cosmetic: §4.1 measures an unpacked repo at 11,287 GETs to hydrate on s3 against 3.
    @repo.hydrate!
    3.times { |i| @repo.commit!(paths: { "f#{i}.txt" => "#{i}\n" }, message: "c#{i}") }
    @repo.consolidate!

    assert_empty @repo.loose_object_rels,
                 "consolidate! must collapse every loose object; an unpacked repo is unhydratable off share"
  end

  test "log returns commits newest first" do
    @repo.hydrate!
    @repo.commit!(paths: { "a.txt" => "1\n" }, message: "older")
    @repo.commit!(paths: { "a.txt" => "2\n" }, message: "newer")

    assert_equal [ "newer", "older" ], @repo.log(limit: 10).map(&:message).map(&:strip)
  end

  test "the managed marker is written at init and readable after a rehydrate" do
    # §8.1 depends on this: a repo the maker made themselves must never be mistaken for ours.
    @repo.hydrate!
    @repo.commit!(paths: { "a.txt" => "1\n" }, message: "c")
    @repo.consolidate!
    @repo.persist!

    rebuilt = Maker::Git::Repo.for(@project.reload)
    rebuilt.discard_cache!
    rebuilt.hydrate!
    assert rebuilt.managed?, "the tinkerex.managed marker did not survive a persist/hydrate cycle"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/repo_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Git::Repo`

- [ ] **Step 3: Implement `CommitInfo`**

```ruby
# app/services/maker/git/commit_info.rb
module Maker
  module Git
    # What the UI reads. A VALUE OBJECT rather than a Rugged::Commit, because a Rugged object holds
    # a live handle into the cache directory — and the cache is thrown away between requests by
    # design. Handing one to a view is a use-after-free waiting for a slow render.
    CommitInfo = Data.define(:oid, :message, :author, :time, :parent_oids) do
      def short_oid = oid[0, 7]
      def root? = parent_oids.empty?
    end
  end
end
```

- [ ] **Step 4: Implement `Repo`**

```ruby
# app/services/maker/git/repo.rb
module Maker
  module Git
    # A project's git repository: hydrate from the library, commit, consolidate into a pack,
    # persist back.
    #
    # THE CACHE IS EPHEMERAL AND THAT IS LOAD-BEARING, NOT AN OPTIMISATION. Durable state on an app
    # volume was rejected outright (design §2.3); the library is the only durable store. Anything
    # this class leaves in the cache and does not persist IS LOST, and must be treated as lost.
    #
    # ON SHARE THE CACHE STEP IS SKIPPED. The library is already a real filesystem, so the repo is
    # operated on in place and #hydrate!/#persist! are no-ops. That is not a special case bolted
    # on: it is why the maker gets `git log` in Finder for free, which is the strongest single
    # argument for git over a bespoke version store.
    class Repo
      MANAGED_CONFIG_KEY = "tinkerex.managed".freeze
      BRANCH = "refs/heads/main".freeze

      def self.for(project) = new(project)

      def initialize(project)
        @project = project
        @user = project.user
        @adapter = FileLayer.current
      end

      # Bring the cache up to date with the library. No-op on share.
      def hydrate!
        return ensure_initialized! if in_place?

        FileUtils.mkdir_p(cache_dir)
        @adapter.list_repo_data(@user, project: @project).each do |rel|
          dest = File.join(cache_dir, rel)
          FileUtils.mkdir_p(File.dirname(dest))
          File.binwrite(dest, @adapter.read_repo_data(@user, project: @project, rel:))
        end
        ensure_initialized!
      end

      # paths: { "docs/notes.md" => "content" }. Returns the new commit oid, or NIL if the tree is
      # unchanged.
      #
      # NIL RATHER THAN AN EMPTY COMMIT IS REQUIRED, NOT TIDY. Phase 3 calls this from a sweep that
      # runs every 15 minutes forever; minting a commit per tick would fill the history with
      # nothing and make the version list useless within a week.
      def commit!(paths:, message:)
        index = ::Rugged::Index.new
        parent = head_oid
        rugged.lookup(parent).tree.walk(:preorder) { |root, e| index.add(path: root + e[:name], oid: e[:oid], mode: e[:filemode]) if e[:type] == :blob } if parent

        paths.each do |path, content|
          oid = rugged.write(content.to_s, :blob)
          index.add(path:, oid:, mode: 0o100644)
        end

        tree = index.write_tree(rugged)
        return nil if parent && rugged.lookup(parent).tree.oid == tree

        oid = ::Rugged::Commit.create(rugged,
                                      tree:, message:, parents: [ parent ].compact,
                                      author: signature, committer: signature,
                                      update_ref: BRANCH)
        Maker::GitRepo.find_or_initialize_by(project: @project)
                      .update!(head_oid: oid, last_commit_at: Time.current)
        oid
      end

      # Collapse every loose object into one pack. See PackWriter for why this is not rugged's job.
      def consolidate!
        rels = loose_object_rels
        return nil if rels.empty?

        objects = rels.map do |rel|
          path = File.join(git_dir, rel)
          oid = rel.split("/")[-2] + File.basename(rel)
          type, payload = PackWriter.read_loose(path)
          [ oid, type, payload ]
        end
        result = PackWriter.write(File.join(git_dir, "objects/pack"), objects)
        rels.each { |rel| File.unlink(File.join(git_dir, rel)) }
        result[:name]
      end

      # Push everything the library does not already have. No-op on share.
      #
      # PACKS AND REFS ONLY. Loose objects are never persisted — #consolidate! runs first, and
      # persisting loose would reintroduce the 11,287-request hydrate §4.1 measured.
      def persist!
        return if in_place?

        have = @adapter.list_repo_data(@user, project: @project).to_set
        local_rels.each do |rel|
          next if rel.start_with?("objects/") && have.include?(rel) # packs are immutable
          File.open(File.join(git_dir, rel), "rb") do |io|
            @adapter.write_repo_data(@user, project: @project, rel:, io:)
          end
        end
      end

      def head_oid = rugged.references[BRANCH]&.target_id
      def managed? = rugged.config[MANAGED_CONFIG_KEY].to_s == "true"
      def discard_cache! = FileUtils.remove_entry(cache_dir) if !in_place? && Dir.exist?(cache_dir)

      def log(limit:)
        return [] unless head_oid

        walker = ::Rugged::Walker.new(rugged)
        walker.sorting(::Rugged::SORT_TOPO)
        walker.push(head_oid)
        walker.first(limit).map do |c|
          CommitInfo.new(oid: c.oid, message: c.message, author: c.author[:name],
                         time: c.time, parent_oids: c.parent_oids)
        end
      end

      def blob_at(oid:, path:)
        entry = rugged.lookup(oid).tree.path(path)
        rugged.lookup(entry[:oid]).content
      rescue ::Rugged::TreeError
        raise FileLayer::NotFound, "#{path.inspect} is not in #{oid}"
      end

      def loose_object_rels
        Dir.glob("objects/??/*", base: git_dir)
      end

      private

      def in_place? = @adapter.is_a?(FileLayer::Share)

      def local_rels
        Dir.glob("**/*", base: git_dir).reject { |r| File.directory?(File.join(git_dir, r)) }
      end

      def git_dir
        @git_dir ||= in_place? ? File.join(@adapter.send(:project_folder_abs, @user, @project), ".git") : cache_dir
      end

      def cache_dir
        @cache_dir ||= Rails.root.join("tmp/git-cache", @user.id.to_s, @project.id.to_s).to_s
      end

      def ensure_initialized!
        FileUtils.mkdir_p(git_dir)
        unless File.exist?(File.join(git_dir, "HEAD"))
          ::Rugged::Repository.init_at(git_dir, :bare)
        end
        rugged.config[MANAGED_CONFIG_KEY] = "true"
      end

      def rugged = @rugged ||= ::Rugged::Repository.new(git_dir)

      # A BOT IDENTITY, NOT THE MAKER'S (§9.3). These commits record that the app OBSERVED a
      # change; on share the maker may have made that edit from a machine this app knows nothing
      # about, so attributing it to them is a small lie `git blame` would then repeat forever.
      def signature = { name: "Tinkerex", email: "bot@tinkerex.invalid", time: Time.current }
    end
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/repo_test.rb`
Expected: PASS.

- [ ] **Step 6: Run on the other two backends**

Run:
```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/services/maker/git/repo_test.rb
bin/ci test-s3
bin/ci test-chunk-remote
```
Expected: PASS on all three, identical counts.

- [ ] **Step 7: Mutation-check the unchanged-tree guard**

Change `return nil if parent && ...` to `return nil if false`.
Run the repo test.
Expected: `commit! returns nil when nothing changed` goes **RED**. Restore.

- [ ] **Step 8: Commit**

```bash
git add app/services/maker/git/ test/services/maker/git/repo_test.rb
git commit -m "Maker::Git::Repo: hydrate, commit, consolidate, persist"
```

---

### Task 5: Prove the output is a real repository

The lifecycle tests prove *our* code round-trips. They cannot prove git agrees, because they read
back through the same rugged that wrote it — the `FakeS3` failure mode (§14e), where exactly
inverse encode and decode kept 79 of 80 tests green over silent data loss.

**Files:**
- Modify: `test/services/maker/git/repo_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "the persisted repository passes git fsck and can be cloned" do
  skip "needs the git binary" unless system("git --version > /dev/null 2>&1")

  @repo.hydrate!
  @repo.commit!(paths: { "docs/notes.md" => "one\n" }, message: "one")
  @repo.commit!(paths: { "docs/notes.md" => "two\n" }, message: "two")
  @repo.consolidate!
  @repo.persist!

  rebuilt = Maker::Git::Repo.for(@project.reload)
  rebuilt.discard_cache!
  rebuilt.hydrate!
  dir = rebuilt.send(:git_dir)

  assert system("git -C #{dir} fsck --full --strict > /dev/null 2>&1"),
         "git rejected a repository this app built"
  assert_equal "2", `git -C #{dir} rev-list --count refs/heads/main`.strip

  Dir.mktmpdir do |dest|
    assert system("git clone -q #{dir} #{dest}/c > /dev/null 2>&1"), "git could not clone it"
    assert_equal "two\n", File.read("#{dest}/c/docs/notes.md")
  end
end
```

- [ ] **Step 2: Run**

Run: `bin/rails test test/services/maker/git/repo_test.rb`
Expected: PASS. If `fsck` fails, the fault is almost certainly in `consolidate!`'s oid derivation
(`objects/ab/cdef…` → `abcdef…`), not in `PackWriter`, which task 2 verified independently.

- [ ] **Step 3: Commit**

```bash
git add test/services/maker/git/repo_test.rb
git commit -m "Prove the built repository passes git fsck and clones"
```

---

### Task 6: Close the phase

- [ ] **Step 1:** Run `bin/ci`. All seven gates green.
- [ ] **Step 2:** Confirm the three backend legs report identical run counts.
- [ ] **Step 3:** Confirm **nothing** in `app/jobs/` or `config/recurring.yml` references
      `Maker::Git`. If it does, phase 3 started early and this phase is no longer risk-free.

```bash
grep -rn "Maker::Git" app/jobs/ config/recurring.yml app/controllers/ || echo "clean — no wiring yet"
```

- [ ] **Step 4:** Open the PR, then `bin/log arc --from-pr <n>` in the same breath (§15).

---

## Phase 2 is done when

- `Maker::Git::Repo` builds a repository **real git accepts** — `fsck --full --strict` clean and
  `git clone` succeeding — on all three backends.
- `consolidate!` leaves zero loose objects, mutation-checked.
- An unchanged tree mints **no** commit, mutation-checked.
- The `tinkerex.managed` marker survives a persist/hydrate cycle.
- **Nothing runs automatically.** No job, no schedule, no controller. Production is untouched.
