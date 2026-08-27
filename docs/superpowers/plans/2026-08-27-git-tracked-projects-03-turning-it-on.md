# Phase 3 — Turning it on: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Read first:** [`00-overview.md`](2026-08-27-git-tracked-projects-00-overview.md) and the design's
> §5, §7 and §8.1. **Phases 1 and 2 must be merged.**

**Goal:** every project actually accumulates history, safely, without breaking project intake.

**Architecture:** `Library::ScanJob` gains a commit step after project intake. Only **settled** files
are eligible. Text is committed as content; binaries as LFS-style pointers. `:in_working_tree` is
narrowly relaxed for repos this app manages, and only for those.

**Tech stack:** Rails 8, Solid Queue, the phase 1 and 2 components.

---

## ⚠ This is the dangerous phase — read before starting

Phases 1 and 2 changed nothing about existing data. **This one does**, in three ways that are each
capable of silent damage:

1. **Project intake stops working the moment a project folder becomes a working tree.**
   `Maker::AttachToProject#refusal_for` returns `:in_working_tree` unconditionally, and
   `Maker::ProjectIntake` asks it for every loose file at a project's root. Turn on commits without
   the relaxation and §14f's entire feature goes dark, for every project, with **nothing going
   red** — no test today asserts that a project folder is not a repo. **Task 5 is not optional and
   cannot be deferred to a follow-up.**
2. **Committing everything eats the NAS.** Git stores each version of a binary whole; twenty saves
   of a 50 MB STEP file is ~1 GB permanently, and git cannot prune reachable history. Task 1 must
   land before task 4.
3. **A scan can catch a half-written file.** A slicer writing a 200 MB 3MF takes tens of seconds. A
   commit made mid-write records a **truncated file as a legitimate version**. Task 2.

---

## File structure

| file | responsibility |
|---|---|
| `app/services/maker/git/tracking.rb` (create) | content vs pointer, derived from `ROLE_BY_EXT` |
| `app/services/maker/git/project_commit.rb` (create) | one project's commit pass: gather, decide, commit, pack, persist |
| `app/jobs/maker/git/commit_job.rb` (create) | the job wrapper, one project per job |
| `app/jobs/library/scan_job.rb` (modify) | call the commit step **after** project intake |
| `app/services/maker/attach_to_project.rb` (modify) | the §8.1 relaxation |
| `config/recurring.yml` (modify) | the chunk_remote schedule, mirroring the intake entries |

---

### Task 1: `Maker::Git::Tracking` — what goes in as content

**Files:**
- Create: `app/services/maker/git/tracking.rb`
- Create: `test/services/maker/git/tracking_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/tracking_test.rb
require "test_helper"

class Maker::Git::TrackingTest < ActiveSupport::TestCase
  test "text roles are tracked as content" do
    %w[main.c notes.md config.yml part.scad job.gcode script.rb].each do |name|
      assert_equal :content, Maker::Git::Tracking.mode_for(name), "#{name} should be content"
    end
  end

  test "model and cad roles are tracked as pointers" do
    %w[bracket.stl body.step case.3mf art.lbrn2 photo.jpg bundle.zip].each do |name|
      assert_equal :pointer, Maker::Git::Tracking.mode_for(name), "#{name} should be a pointer"
    end
  end

  # §14d: extensionless text is a SEPARATE AXIS. File.extname("LICENSE") is "", so no entry in an
  # extension table can ever reach these — and a repo's root is full of them.
  test "extensionless text files are content" do
    %w[LICENSE Makefile README makefile].each do |name|
      assert_equal :content, Maker::Git::Tracking.mode_for(name), "#{name} should be content"
    end
  end

  # THE DERIVATION IS THE POINT. A hand-written second extension list is exactly the drift
  # FilesHelper::EXT_FAMILIES was rewritten to end (§14d).
  test "every extension in ROLE_BY_EXT gets an answer, so a new one cannot fall through" do
    Maker::FileAttachment::ROLE_BY_EXT.each_key do |ext|
      mode = Maker::Git::Tracking.mode_for("file.#{ext}")
      assert_includes [ :content, :pointer ], mode, "#{ext} has no tracking mode"
    end
  end

  test "a pointer body names the content hash and size" do
    node = users(:one).nodes.create!(node_id: "n1", name: "b.stl", kind: "file",
                                     content_hash: "sha256:" + "a" * 64, size: 4_000_000)
    body = Maker::Git::Tracking.pointer_for(node)

    assert_match(/\Aversion tinkerex\/v1\n/, body)
    assert_match(/^oid sha256:a{64}$/, body)
    assert_match(/^size 4000000$/, body)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/tracking_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Git::Tracking`

- [ ] **Step 3: Implement**

```ruby
# app/services/maker/git/tracking.rb
module Maker
  module Git
    # Does this file go into the repository as CONTENT, or as a POINTER to content that lives in
    # the library?
    #
    # THE PATTERN IS LFS, AND IT IS NOT AN INVENTION. Every git host — Forgejo, Gitea, GitHub,
    # GitLab — keeps large binaries out of the repo and stores a pointer instead. Design §2.2
    # records that the same hosts refuse to put repositories in object storage at all, while
    # routing LFS objects there happily. We take the pattern, not the protocol: a pointer is three
    # lines of text and there is no LFS server anywhere in this.
    #
    # WHY IT MATTERS HERE MORE THAN ANYWHERE: git stores each version of a binary WHOLE, and binary
    # deltas on meshes are near-worthless. Twenty saves of a 50 MB STEP file is ~1 GB in `.git`,
    # permanently, and git cannot prune reachable history without rewriting it. This module is what
    # stops that.
    #
    # AND IT IS WHY §9.1's UNDELTIFIED PACK WRITER IS AFFORDABLE. That writer costs 5x on bytes
    # against `git gc`. Five times SMALL is still small — but only because everything large is a
    # pointer. These two decisions hold each other up; weakening either breaks the other.
    #
    # DERIVED FROM ROLE_BY_EXT, NEVER A SECOND EXTENSION TABLE. §14d records that a parallel
    # hand-written list is the exact drift FilesHelper::EXT_FAMILIES was rewritten to end — two
    # lists that disagreed about `.svg` for months. Adding an extension stays a one-line edit to
    # ROLE_BY_EXT and nothing here has to hear about it.
    module Tracking
      # Roles whose files are text a human reads and git can diff.
      CONTENT_ROLES = %w[code document instructions].freeze

      POINTER_VERSION = "tinkerex/v1".freeze

      module_function

      def mode_for(name)
        # Extensionless text first: File.extname("LICENSE") is "", so no extension lookup can
        # reach it, and a repo root is full of exactly these (§14d).
        return :content if Maker::FileAttachment.text_basename?(name)

        CONTENT_ROLES.include?(Maker::FileAttachment.role_for(name)) ? :content : :pointer
      end

      # THE POINTER RESOLVES AGAINST CONTENT THE LIBRARY ALREADY HAS, because Library::Reconciler
      # computes a content_hash for every file today. So a pointer to the CURRENT version costs
      # nothing extra.
      #
      # A pointer to a SUPERSEDED version resolves only where the store kept those bytes — the
      # sync server on chunk_remote, bucket versioning on s3, and NOWHERE on share, where the
      # Finder overwrite destroyed them before any scan ran. Phase 4's UI says "not kept" rather
      # than pretending the version never existed.
      def pointer_for(node)
        "version #{POINTER_VERSION}\noid #{node.content_hash}\nsize #{node.size}\n"
      end
    end
  end
end
```

If `Maker::FileAttachment` has no `text_basename?` predicate, add one there — beside
`TEXT_BASENAMES`, which already exists — rather than reaching into the constant from here.

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/tracking_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check the totality test**

Add a throwaway role to `ROLE_BY_EXT` (`"xyz" => "sculpture"`), run the test file, confirm the
totality test still passes (it should — `:pointer` is the default). Then change `mode_for` to
`return nil unless ...` and confirm it goes **RED**. Restore both.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/tracking.rb test/services/maker/git/tracking_test.rb app/models/maker/file_attachment.rb
git commit -m "Maker::Git::Tracking: text as content, binaries as pointers, derived from ROLE_BY_EXT"
```

---

### Task 2: Settle detection

**Files:**
- Create: `app/services/maker/git/project_commit.rb` (first slice — eligibility only)
- Create: `test/services/maker/git/project_commit_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/project_commit_test.rb
require "test_helper"

class Maker::Git::ProjectCommitTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @project = @user.maker_projects.create!(title: "Lamp")
    @project.ensure_library_folder!(@user)
  end

  # THE HAZARD THIS EXISTS FOR: a slicer writing a 200 MB 3MF takes tens of seconds. A commit made
  # mid-write records a TRUNCATED FILE as a legitimate version — and it looks entirely normal
  # afterwards, which is what makes it dangerous.
  test "a node changed during this scan is not eligible" do
    node = file_node("notes.md")
    scan_started = Time.current
    node.update!(updated_at: scan_started + 1.second)

    assert_empty Maker::Git::ProjectCommit.new(project: @project, scan_started_at: scan_started).eligible_nodes
  end

  test "a node unchanged since before this scan is eligible" do
    node = file_node("notes.md")
    node.update!(updated_at: 1.hour.ago)

    eligible = Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current).eligible_nodes
    assert_equal [ node.node_id ], eligible.map(&:node_id)
  end

  # travel_to separates the two events by three orders of magnitude, because a timestamp compared
  # at second resolution is a guard that usually cannot fail (§15) — the row under test would
  # otherwise be written in the same second as the thing we fear overwrote it.
  test "a file still being written stays ineligible across consecutive scans" do
    node = travel_to(3.days.ago) { file_node("big.3mf", size: 1000) }

    first = Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current)
    assert_equal [ node.node_id ], first.eligible_nodes.map(&:node_id)

    node.update!(size: 2000) # the write is still going
    second = Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current - 1.second)
    assert_empty second.eligible_nodes, "a node touched after the scan started must wait a tick"
  end

  private

  def file_node(name, size: 10)
    folder = @user.nodes.find_by!(node_id: @project.folder_node_id)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                        parent_node_id: folder.node_id, size:,
                        content_hash: "sha256:#{SecureRandom.hex(32)}",
                        storage_path: "#{folder.storage_path}/#{name}")
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/project_commit_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Git::ProjectCommit`

- [ ] **Step 3: Implement the eligibility slice**

```ruby
# app/services/maker/git/project_commit.rb
module Maker
  module Git
    # One project's commit pass: gather what is settled, decide content vs pointer, commit, pack,
    # persist.
    class ProjectCommit
      def initialize(project:, scan_started_at:)
        @project = project
        @user = project.user
        @scan_started_at = scan_started_at
      end

      # SETTLE DETECTION. A node is eligible only if it has NOT been touched since this scan
      # started — meaning it survived a full quiet interval.
      #
      # WHY updated_at RATHER THAN A NEW COLUMN: Library::Reconciler already writes the node on
      # every in-place content change (reconciler.rb:329). A file still being written therefore
      # gets a fresh updated_at on each scan that observes a different size, and never settles
      # until the writer stops. That is the property we want and the schema already carries it.
      #
      # THE COST IS ONE TICK OF LATENCY, deliberately. A file saved at T is committed after the
      # scan following the one that first observed it — up to 30 minutes rather than 15. That is
      # the price of never committing a truncated 3MF, and it is worth paying: a late commit is
      # invisible, a corrupt one is permanent.
      def eligible_nodes
        folder = @user.nodes.present.find_by(node_id: @project.folder_node_id)
        return Node.none unless folder

        descendants_of(folder).where(kind: "file").where(updated_at: ...@scan_started_at)
      end

      private

      # The project folder's subtree. Capped at the same depth Maker::AttachToProject caps its
      # ancestor walk, and for the same reason: parent_node_id is a plain string column with no
      # foreign key, so a cycle is representable and an uncapped descent is an infinite loop
      # inside an unattended sweep.
      MAX_DEPTH = 64

      def descendants_of(folder)
        ids = [ folder.node_id ]
        seen = []
        MAX_DEPTH.times do
          break if ids.empty?
          seen.concat(ids)
          ids = @user.nodes.present.where(parent_node_id: ids).pluck(:node_id) - seen
        end
        @user.nodes.present.where(parent_node_id: seen)
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/project_commit_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check the settle guard**

Remove `.where(updated_at: ...@scan_started_at)`.
Run the test file.
Expected: two tests go **RED**. Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/git/project_commit.rb test/services/maker/git/project_commit_test.rb
git commit -m "Settle detection: a node touched during this scan waits a tick"
```

---

### Task 3: The commit pass

**Files:**
- Modify: `app/services/maker/git/project_commit.rb`
- Modify: `test/services/maker/git/project_commit_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "call! commits text as content and binaries as pointers" do
  travel_to(3.days.ago) do
    file_node("notes.md")
    file_node("body.step")
  end

  Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current).call!

  repo = Maker::Git::Repo.for(@project.reload)
  repo.hydrate!
  head = repo.head_oid
  assert head, "expected a commit"

  assert_equal "sha256", repo.blob_at(oid: head, path: "body.step.ptr")[/oid (\w+):/, 1]
  assert repo.blob_at(oid: head, path: "notes.md"), "text should be committed as content"
end

test "call! is a no-op when nothing settled" do
  file_node("notes.md").update!(updated_at: Time.current + 1.second)

  Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current).call!

  assert_nil Maker::GitRepo.find_by(project: @project)&.head_oid
end

test "call! leaves the repository packed" do
  travel_to(3.days.ago) { file_node("notes.md") }
  Maker::Git::ProjectCommit.new(project: @project, scan_started_at: Time.current).call!

  repo = Maker::Git::Repo.for(@project.reload)
  repo.hydrate!
  assert_empty repo.loose_object_rels,
               "an unpacked repo needs thousands of requests to hydrate off share (§4.1)"
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/project_commit_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'call!'`

- [ ] **Step 3: Implement**

```ruby
# app/services/maker/git/project_commit.rb — add as a public method

      # THE ORDER IS LOAD-BEARING: commit, then consolidate, then persist. Persisting before
      # consolidating would push loose objects into the library — the 11,287-request hydrate §4.1
      # measured — and they would have to be deleted again afterwards.
      def call!
        nodes = eligible_nodes.to_a
        return if nodes.empty?

        repo = Repo.for(@project)
        repo.hydrate!
        oid = repo.commit!(paths: paths_for(nodes), message: commit_message(nodes))
        return unless oid

        repo.consolidate!
        repo.persist!
        oid
      end

      private

      def paths_for(nodes)
        folder = @user.nodes.find_by(node_id: @project.folder_node_id)
        base = folder&.storage_path.to_s

        nodes.each_with_object({}) do |node, out|
          rel = node.storage_path.to_s.delete_prefix("#{base}/")
          next if rel.blank? || rel == node.storage_path.to_s && base.present?

          case Tracking.mode_for(node.name)
          when :content
            begin
              out[rel] = FileLayer.current.read(@user, node_id: node.node_id)
            rescue FileLayer::NotFound, FileLayer::FetchError
              # A file that vanished or is unreachable mid-sweep is skipped, not fatal. The next
              # tick picks it up; failing the whole pass would stall every other project's history
              # behind one bad file.
              next
            end
          when :pointer
            out["#{rel}.ptr"] = Tracking.pointer_for(node)
          end
        end
      end

      def commit_message(nodes)
        "Observed #{nodes.size} file#{'s' unless nodes.size == 1} at #{Time.current.utc.iso8601}"
      end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/project_commit_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/git/project_commit.rb test/services/maker/git/project_commit_test.rb
git commit -m "ProjectCommit#call!: commit settled files, pack, persist"
```

---

### Task 4: The §8.1 relaxation — **before** any wiring

Do this **before** task 5 wires the sweep. The instant commits run, every project folder is a
working tree; if the relaxation is not already in, intake is dead for every project and nothing
goes red.

**Files:**
- Modify: `app/services/maker/attach_to_project.rb`
- Modify: `test/services/maker/attach_to_project_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
test "a file in a repo THIS APP manages may still be filed" do
  project = @user.maker_projects.create!(title: "Lamp")
  project.ensure_library_folder!(@user)
  folder = @user.nodes.find_by!(node_id: project.folder_node_id)
  @user.nodes.create!(node_id: "marker", name: ".git", kind: "dir", parent_node_id: folder.node_id)
  Maker::GitRepo.create!(project:, head_oid: "a" * 40, last_commit_at: Time.current)

  node = @user.nodes.create!(node_id: "f1", name: "notes.md", kind: "file",
                             parent_node_id: folder.node_id,
                             storage_path: "#{folder.storage_path}/notes.md")

  assert_nil Maker::AttachToProject.new(user: @user, project:).refusal_for(node),
             "a managed repo must not freeze its own project against the intake sweep"
end

# THE PROTECTION THAT MUST SURVIVE. A maker who drops their OWN repo into the library still gets
# the refusal — moving a tracked file there really is a delete plus an untracked add, because
# nothing commits it afterwards.
test "a file in a repo the app does NOT manage is still refused" do
  project = @user.maker_projects.create!(title: "Lamp")
  project.ensure_library_folder!(@user)
  folder = @user.nodes.find_by!(node_id: project.folder_node_id)
  @user.nodes.create!(node_id: "marker", name: ".git", kind: "dir", parent_node_id: folder.node_id)
  # deliberately NO Maker::GitRepo row

  node = @user.nodes.create!(node_id: "f1", name: "notes.md", kind: "file",
                             parent_node_id: folder.node_id,
                             storage_path: "#{folder.storage_path}/notes.md")

  assert_equal :in_working_tree, Maker::AttachToProject.new(user: @user, project:).refusal_for(node)
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/attach_to_project_test.rb`
Expected: FAIL — the first test gets `:in_working_tree`.

- [ ] **Step 3: Implement**

```ruby
# app/services/maker/attach_to_project.rb — replace the :in_working_tree line in #refusal_for

      return :in_working_tree if in_working_tree?(node) && !app_managed_repo?
```

```ruby
# app/services/maker/attach_to_project.rb — add to the private section

    # THE §8.1 RELAXATION, AND ITS SHAPE IS WHAT MAKES IT SAFE.
    #
    # The refusal exists because moving a tracked file is a delete plus an untracked add — WHEN
    # NOTHING COMMITS IT AFTERWARDS. Once this app performs the move AND the commit, git records a
    # rename and the objection evaporates. So the rule is not "working trees are fine now"; it is
    # "working trees WE MAINTAIN are fine, because we finish the job."
    #
    # THE INDEX CAN ONLY EVER GRANT PERMISSION, NEVER WITHHOLD IT, and that asymmetry is the whole
    # safety argument. Maker::GitRepo is explicitly an index and may be stale or absent while the
    # repo is fine — so a miss falls back to the EXISTING refusal, which is today's behaviour and
    # was safe yesterday. There is no state where staleness here does damage; the worst case is a
    # project that keeps not being filed, which is visible and recoverable.
    #
    # Memoized per instance because Maker::ProjectIntake sweeps every file at a project's root
    # through #refusal_for, and this is one query for the whole sweep rather than one per file —
    # the same argument the ancestor walk's memo makes.
    def app_managed_repo?
      return @app_managed_repo if defined?(@app_managed_repo)

      @app_managed_repo = Maker::GitRepo.exists?(project_id: @project.id)
    end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/attach_to_project_test.rb`
Expected: PASS, both tests.

- [ ] **Step 5: Mutation-check in BOTH directions**

This guard has two failure modes and one assertion catches only one of them.

- Change the condition to `if in_working_tree?(node)` (relaxation removed) → the *first* test goes RED.
- Change it to `if false` (protection removed) → the *second* test goes RED.

Confirm each independently, then restore. A single-direction check would let "always allow" through.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/attach_to_project.rb test/services/maker/attach_to_project_test.rb
git commit -m "Relax :in_working_tree for repos this app manages, and only those"
```

---

### Task 5: Wire into `ScanJob`

**Files:**
- Create: `app/jobs/maker/git/commit_job.rb`
- Modify: `app/jobs/library/scan_job.rb`
- Modify: `config/recurring.yml`
- Modify: `test/jobs/library/scan_job_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/jobs/library/scan_job_test.rb — append

# ORDER IS LOAD-BEARING. The intake MOVES files; committing before it would record every file at
# its old path and then again at its new one, doubling the history and making the first commit a
# lie. The same argument ScanJob's own header makes about discovery preceding intake.
test "the commit step runs after project intake" do
  calls = []
  Maker::ProjectIntakeJob.stub(:perform_now, ->(**) { calls << :intake }) do
    Maker::Git::CommitJob.stub(:perform_now, ->(**) { calls << :commit }) do
      Library::ScanJob.perform_now(user_id: @user.id)
    end
  end

  assert_equal [ :intake, :commit ], calls.select { |c| [ :intake, :commit ].include?(c) }
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/jobs/library/scan_job_test.rb`
Expected: FAIL — `:commit` never appears.

- [ ] **Step 3: Implement the job**

```ruby
# app/jobs/maker/git/commit_job.rb
module Maker
  module Git
    # One commit pass per user, fanning over their projects.
    #
    # ONE PROJECT'S FAILURE MUST NOT STALL THE REST. A project whose bytes are briefly unreachable
    # is a normal thing on a NAS, and letting it raise would leave every later project in the loop
    # uncommitted with no record of why — the shape ProjectIntakeJob's own report exists to avoid.
    class CommitJob < ApplicationJob
      queue_as :background

      def perform(user_id:, scan_started_at: Time.current)
        user = User.find(user_id)
        user.maker_projects.find_each do |project|
          next if project.folder_node_id.blank?

          begin
            ProjectCommit.new(project:, scan_started_at:).call!
          rescue StandardError => e
            Rails.logger.warn("[git] project #{project.id}: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Wire into `ScanJob`**

In `Library::ScanJob#perform`, **after** the `Maker::ProjectIntakeJob.perform_now` call and after
the model intake:

```ruby
      # AFTER the intake, never before: the intake MOVES files, and committing first would record
      # every file at its old path and then again at its new one — doubling the history and making
      # the first commit describe a layout that no longer exists.
      Maker::Git::CommitJob.perform_now(user_id: user.id, scan_started_at: scan_started_at)
```

`scan_started_at` must be captured at the **top** of `#perform`, before the reconcile, and threaded
through — settle detection compares against the start of this scan, not the moment the commit step
happens to be reached.

- [ ] **Step 5: Add the chunk_remote schedule**

`ScanJob` no-ops off `scannable` backends, so chunk_remote needs its own recurring entry, exactly as
`project_folder_intake` and `model_catalog_intake` already do:

```yaml
  # Commit each project's settled files. CHUNK DEPLOYMENTS ONLY — commit_all! declines when the
  # backend is `scannable`, because on share/s3 Library::ScanJob calls this at the end of its own
  # sequence, strictly AFTER the project intake. A second caller there would commit files the
  # intake is about to move.
  #
  # EVERY 15 MINUTES, matching its siblings — and arbitrary for the same reason they state: on
  # chunk_remote there is no poll behind it, so this interval is the only latency bound the
  # history gets.
  git_project_commit:
    command: "Maker::Git::CommitJob.commit_all!"
    schedule: every 15 minutes
```

Add the matching `self.commit_all!` class method with the `scannable?` gate — in the class, not in
`recurring.yml`, because Solid Queue resolves `class:` at load and reads one file with no merge
mechanism.

- [ ] **Step 6: Run to verify it passes**

Run: `bin/rails test test/jobs/library/scan_job_test.rb`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/jobs/ config/recurring.yml test/jobs/library/scan_job_test.rb
git commit -m "Wire the commit step into ScanJob, after project intake"
```

---

### Task 6: Close the phase, and roll out carefully

- [ ] **Step 1:** `bin/ci` — all seven gates green, three backend legs identical.

- [ ] **Step 2: Verify intake still files things.** This is the regression this phase is most likely
      to cause and least likely to notice.

```bash
bin/rails test test/services/maker/project_intake_test.rb test/services/maker/attach_to_project_test.rb
```

- [ ] **Step 3: Deploy to ONE destination first.** Not bare `deploy`, which covers all three.
      Use `share`, because that is where the real data is and where `git log` in Finder makes a
      wrong result immediately visible.

- [ ] **Step 4: Watch one project for two scan intervals**, then check on the box:

```bash
git -C /mnt/library/Projects/<slug> log --oneline
git -C /mnt/library/Projects/<slug> fsck --full
du -sh /mnt/library/Projects/<slug>/.git
```

Expected: commits appearing at most one interval behind a save; `fsck` clean; `.git` in the
single-digit MB for a text project. **A `.git` in the hundreds of MB means task 1's routing is
wrong** — stop and check `Tracking.mode_for` against the actual file names in that folder.

- [ ] **Step 5:** Open the PR, then `bin/log arc --from-pr <n>` in the same breath (§15).

---

## Phase 3 is done when

- Projects accumulate history automatically, at most one scan interval behind a save.
- A file still being written is **never** committed, mutation-checked.
- Binaries are pointers; `.git` stays small on a real library.
- Project intake still files loose files — verified by running its own suite, not by reasoning.
- A repo the app does **not** manage still gets the `:in_working_tree` refusal, mutation-checked in
  both directions.
