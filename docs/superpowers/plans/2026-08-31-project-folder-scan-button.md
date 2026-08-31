# Per-project folder scan button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This repo overrides the generic subagent loop:** `.claude/commands/execute-plan.md` is the default — batch by FILE, run independent tasks in PARALLEL, no spec-compliance stage, cap each quality review to named claims.

**Goal:** Give every project page a button that refreshes the library from storage now, so files dropped into `Projects/<slug>/` outside the app appear without waiting for a 15-minute (share/s3) or 2-minute (chunk_remote) poll.

**Architecture:** A new `Projects::ScansController#create` picks the refresh mechanism by capability and relies entirely on existing chains for the filing. On share/s3 it enqueues `Library::ScanJob`, which already runs `discover_projects → intake_project_folders → intake_models` inline and strictly ordered — the controller must **not** file anything itself, because a move racing the Scanner's observations is the §14f pairing bug. On chunk_remote there is no scan and therefore no race, so it pulls the changelog and runs `Maker::ProjectIntake.for_project` synchronously and reports real counts.

**Tech Stack:** Rails 8, Hotwire/Stimulus (importmap, eager-loaded by filename), Solid Queue, Minitest.

**Spec:** `docs/superpowers/specs/2026-08-31-project-folder-scan-button-design.md`

---

## File structure

| File | Responsibility |
|---|---|
| `app/jobs/library/scan_job.rb` (modify) | Gains `.enqueue_for(user)` — the single home for "which args may be serialized into the queue". `.scan_all!` starts calling it. |
| `config/routes.rb` (modify) | `resource :scan, only: :create, module: :projects` inside the existing `resources :projects` block. |
| `app/controllers/projects/scans_controller.rb` (create) | The whole feature's decision: throttle, capability branch, flash wording. |
| `app/controllers/projects_controller.rb` (modify) | `@scan_started` off `params[:scanning]` in `#show`. |
| `app/views/projects/_attachments.html.erb` (modify) | The button, and the `scanreload` element on the async path. |
| `app/javascript/controllers/scanreload_controller.js` (create) | One reload, to the param-free URL. |
| `docs/invariants/project-intake.md` (modify) | The new rule: an interactive scan door must not file on a scannable backend. |
| `test/integration/web/project_scan_button_test.rb` (create) | Every assertion below. |

**Why one test file, not three:** the three CI legs (`test`, `test-s3`, `test-chunk-remote`) must report **identical run counts** (§15). So no test may `skip` on the ambient `LIBRARY_BACKEND`. Every test below **forces** its backend with `FileLayer.current = …`, the established pattern at `test/integration/v1/capability_gating_test.rb:82`. All tests therefore run on all three legs.

---

## Task 1: `Library::ScanJob.enqueue_for` — one home for the queue-args rule

`ScanJob#perform`'s header states the rule: a Share root is a path, safe to serialize into the queue's database and useful in a failed-jobs row; an S3 library's target is a bucket **plus credentials**, which must never be written there. `.scan_all!` encodes that today. The new controller needs the same decision, and a second copy is the drift this repo names as its dominant failure shape.

**Files:**
- Modify: `app/jobs/library/scan_job.rb`
- Test: `test/jobs/library/scan_job_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `test/jobs/library/scan_job_test.rb` (add a new class at the bottom of the file, outside any existing class, matching the file's existing multi-class layout):

```ruby
# .enqueue_for is the ONE place that decides which args may be serialized into the queue's
# database. Extracted from .scan_all! when Projects::ScansController became a second caller:
# an S3 library's target is a bucket plus credentials and must never be written there, so a
# second copy of that branch is exactly the drift CLAUDE.md warns about.
class ScanJobEnqueueForTest < ActiveJob::TestCase
  setup { @user = User.create!(email: "ef-#{SecureRandom.hex(4)}@example.com",
                               password: "correct horse battery staple", confirmed_at: Time.current) }
  teardown { FileLayer.reset! }

  test "a share library enqueues WITH its root, which is a path and safe to serialize" do
    root = Dir.mktmpdir("enqueue-for")
    FileLayer.current = FileLayer::Share.new(root:)
    assert_enqueued_with(job: Library::ScanJob,
                         args: [ { user_id: @user.id, root: root } ]) do
      Library::ScanJob.enqueue_for(@user)
    end
  ensure
    FileUtils.remove_entry(root) if root && File.exist?(root)
  end

  test "an s3 library enqueues with NO root — a bucket plus credentials must not reach the queue" do
    require_relative "../../support/fake_s3"
    FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                          secret_access_key: "sk", client: FakeS3.new.client)
    assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id } ]) do
      Library::ScanJob.enqueue_for(@user)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/jobs/library/scan_job_test.rb -n "/enqueue_for|enqueues/"
```

Expected: FAIL — `NoMethodError: undefined method 'enqueue_for' for Library::ScanJob`.

- [ ] **Step 3: Implement**

In `app/jobs/library/scan_job.rb`, replace the body of `self.scan_all!` and add `enqueue_for` above it:

```ruby
    # THE ONE PLACE THAT DECIDES WHAT MAY BE SERIALIZED INTO THE QUEUE. #perform's header states
    # the rule: a Share root is a PATH, safe to persist in the queue's database and genuinely
    # useful in a failed-jobs row (an operator sees WHICH root refused); an s3 library's target is
    # a bucket PLUS THE CREDENTIALS to reach it, which must never be written there, so the s3
    # fan-out names only the user and #perform re-resolves FileLayer.current.
    #
    # EXTRACTED WHEN Projects::ScansController BECAME A SECOND CALLER. A second copy of this branch
    # is the drift CLAUDE.md's §14d names a service to end — and the failure mode of getting it
    # wrong is a bucket's secret access key sitting in solid_queue_jobs.arguments forever.
    def self.enqueue_for(user)
      adapter = FileLayer.current
      # .to_s because ActiveJob cannot serialize a Pathname (SerializationError at enqueue).
      args = adapter.is_a?(FileLayer::Share) ? { root: adapter.root.to_s } : {}
      perform_later(user_id: user.id, **args)
    end

    def self.scan_all!
      return unless FileLayer.current.capabilities.scannable?

      User.find_each { |user| enqueue_for(user) }
    end
```

Delete the now-duplicated `args = adapter.is_a?…` line and its comment from the old `scan_all!` body, and the now-unused local `adapter = FileLayer.current` there. Keep every other comment in `scan_all!` intact — its gate reasoning (why it asks the factory, the Phase 3 trap) is unchanged and still correct.

- [ ] **Step 4: Run to verify it passes**

```bash
bin/rails test test/jobs/library/scan_job_test.rb
```

Expected: PASS, with no other test in that file regressing.

- [ ] **Step 5: Mutation-check the credentials rule (§15)**

Temporarily change `enqueue_for`'s branch to `args = { root: adapter.try(:root).to_s }`, re-run the two new tests, and confirm the **s3** test goes RED (it would ship a root for a bucket). Restore.

- [ ] **Step 6: Commit**

```bash
git add app/jobs/library/scan_job.rb test/jobs/library/scan_job_test.rb
git commit -m "One home for what a scan may write into the queue"
```

---

## Task 2: the route and the share/s3 branch

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/projects/scans_controller.rb`
- Test: `test/integration/web/project_scan_button_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_scan_button_test.rb`:

```ruby
require "test_helper"

module Web
  # The per-project "Scan folder" button: refresh the library from storage NOW, instead of waiting
  # for library_scan's 15 minutes (share/s3) or remote_changelog_pull's 2 (chunk_remote).
  #
  # EVERY TEST FORCES ITS BACKEND rather than reading the ambient LIBRARY_BACKEND, so all of them
  # run on all three CI legs. §15 requires the three legs to report IDENTICAL run counts; a test
  # that skipped on two of them would make this file the reason they diverge.
  class ProjectScanButtonTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      @user = User.create!(email: "scan-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    teardown { FileLayer.reset! }

    def use_share!
      @root = Pathname.new(Dir.mktmpdir("scan-btn"))
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    end

    # `client:` from FakeS3, matching every other S3 construction in this suite
    # (s3_write_test.rb, s3_delivery_test.rb, repo_history_flow_test.rb). Without it the adapter
    # builds a REAL Aws::S3::Client at construction — nothing here would call it, but the house
    # pattern exists so no test can ever accidentally reach the network.
    def use_s3!
      require_relative "../../support/fake_s3"
      @fake_s3 = FakeS3.new
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", client: @fake_s3.client)
    end

    test "on share the button enqueues a library scan and says one is running" do
      use_share!
      assert_enqueued_with(job: Library::ScanJob,
                           args: [ { user_id: @user.id, root: @root.to_s } ]) do
        post project_scan_path(@project)
      end
      assert_redirected_to project_path(@project, scanning: 1)
      assert_match(/scanning your library/i, flash[:notice].to_s)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "on s3 the enqueued scan carries NO root — no bucket credentials into the queue" do
      use_s3!
      assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id } ]) do
        post project_scan_path(@project)
      end
      assert_redirected_to project_path(@project, scanning: 1)
    end

    # THE §14f RACE. Library::ScanJob files inline, strictly after observer.call. A second filer
    # started from here would move a file after the Scanner captured its observations; the
    # Reconciler pairs it back by (content_hash, size) and repoints the node to its OLD path while
    # the bytes sit at the new one — and in that window library_present? still reads true, so
    # Share#download's ENOENT maps to NotFound and the user gets a TERMINAL 404 for a file that is
    # not gone. The button must enqueue and stop.
    test "a scannable backend does NOT file synchronously — that would race the Scanner" do
      use_share!
      called = false
      Maker::ProjectIntake.stub(:for_project, ->(**) { called = true }) do
        post project_scan_path(@project)
      end
      assert_not called, "the scan door must not run the intake on a scannable backend"
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "another user's project is not scannable through this door" do
      use_share!
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Not Mine")
      assert_no_enqueued_jobs(only: Library::ScanJob) do
        post project_scan_path(theirs)
      end
      assert_response :not_found
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb
```

Expected: FAIL — `NameError: undefined local variable or method 'project_scan_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, inside the existing `resources :projects do` block, after the `resources :uploads, only: :create, module: :projects` line:

```ruby
    # "Look at my library NOW" — the per-project scan button. SINGULAR: there is no scan record
    # and nothing to identify, only a verb. It is nested rather than shallow because the project is
    # what the redirect and the flash are about, and the door files nothing on a scannable backend
    # (docs/invariants/project-intake.md), so the project is context, not a target.
    resource :scan, only: :create, module: :projects
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/projects/scans_controller.rb`:

```ruby
module Projects
  # "Refresh my library from storage NOW", from a project page.
  #
  # WHAT IT DOES NOT DO: scan one folder. Library::Reconciler compares observations against the
  # WHOLE user catalog (#observable_live_paths -> #live_file_paths), so a Scanner rooted at a
  # project subfolder would list every file outside that subtree in #vanished_paths and trip the
  # mass-deletion guard. Library::ScanJob's own `root:` means A SHARE ROOT, not an arbitrary
  # folder. So this refreshes the LIBRARY and lets the existing chains do the per-project filing.
  #
  # IT ADDS NO FILING LOGIC. On share/s3 Library::ScanJob already runs
  # discover_projects -> intake_project_folders -> intake_models inline and strictly ordered; on
  # chunk_remote ChangelogSync nudges Maker::ProjectIntakeJob for live arrivals. This controller is
  # a new CALLER of unmodified machinery, which is why it can be this small.
  class ScansController < ApplicationController
    # For #project_intake_sentence / #unfiled_by_conflict on the chunk_remote branch. The conflict
    # clause has ONE home (docs/invariants/project-intake.md: the doors differ on the LEAD-IN and
    # must not differ on what follows), and a scan door is a fourth door onto that same sentence.
    include ProjectFolderIntake

    # DECLARED BEFORE the project lookup, deliberately: a throttle that does a database round-trip
    # before deciding to throttle is a weaker throttle, and `with:` therefore names the project by
    # its slug param rather than an ivar that does not exist yet.
    #
    # KEYED BY USER, not `by:`'s default request.remote_ip. This is a signed-in action, and the
    # thing being protected is one user's library walk, not an address.
    #
    # IT IS ALSO THE HONEST ANSWER TO A DOUBLE CLICK. Library::ScanJob carries
    # `limits_concurrency ... on_conflict: :discard`, so a second enqueue during a running scan is
    # SILENTLY DROPPED — without this the user would get "Scanning…" and nothing would happen.
    #
    # Counts in config.action_controller.cache_store. The test env sets :memory_store for exactly
    # this reason (§14e: NullStore#increment returns nil, so a throttle on the default test store
    # fires NEVER and its test passes for the wrong reason).
    rate_limit to: 3, within: 1.minute, by: -> { current_user.id },
               with: -> {
                 redirect_to project_path(params[:project_id]),
                             alert: "A scan just started for this library — give it a moment."
               }

    before_action :set_project

    def create
      if FileLayer.current.capabilities.scannable?
        enqueue_scan
      else
        pull_and_file
      end
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    # SHARE/S3 — ASYNC, AND IT MUST NOT FILE ANYTHING HERE. A NAS walk is why library_scan polls
    # every 15 minutes rather than every 15 seconds, so it cannot run in a request. And a move made
    # from here would race the Scanner's own observations: the Reconciler pairs the file back by
    # (content_hash, size) and repoints the node to its OLD path while the bytes sit at the new one,
    # a window in which a download gets a TERMINAL 404 for a file that is not gone. Running the
    # intake inline inside Library::ScanJob, after observer.call, is what makes that impossible.
    #
    # `scanning: 1` is what the page reads to schedule its one reload; scanreload_controller.js
    # navigates to the param-FREE url, which is what stops it looping.
    def enqueue_scan
      Library::ScanJob.enqueue_for(current_user)
      redirect_to project_path(@project, scanning: 1),
                  notice: "Scanning your library for new files. This page will refresh in a " \
                          "moment — a large library takes longer, so reload again if nothing " \
                          "has appeared yet."
    end

    # CHUNK_REMOTE — SYNCHRONOUS, AND THE ASYMMETRY IS THE POINT. There is no scan here, so there is
    # no race; a no-op pull is ONE GET (changelog_sync_test pins the count at exactly one) and the
    # intake is capped, so the work is bounded and belongs in the request, where it can report real
    # counts instead of a promise.
    #
    # THE INTAKE IS NOT REDUNDANT WITH THE PULL'S OWN NUDGE. ChangelogSync nudges
    # Maker::ProjectIntakeJob for LIVE FILE ARRIVALS ONLY, so files already in the mirror but
    # unfiled — a prior collision, a folder discovery has just adopted — get no nudge at all, and a
    # pull-only button would find nothing to do and read as broken. That case is the reason this
    # call is here.
    #
    # THIS IS NOT THE SYNCHRONOUS PULL §14a FORBIDS. That rule bars closing mirror staleness from
    # FilesController#index "or any other READ path". This is a POST — an explicit user command.
    # The journey test that pins a plain read as NOT seeing a server-side node is untouched.
    def pull_and_file
      FileLayer::RemoteChangelogPullJob.perform_now(user_id: current_user.id)
      result = Maker::ProjectIntake.for_project(user: current_user, project: @project)
      redirect_to project_path(@project), notice: scan_notice(result)
    end

    # The lead-in is this door's own; everything after it belongs to ProjectFolderIntake, so the
    # four doors cannot drift about how they phrase one collision. NO TRAILING PUNCTUATION on the
    # lead — the conflict form turns the period into a comma.
    def scan_notice(result)
      return "Scanned your library. #{@project.name} has no folder yet, so nothing was filed." if
        result.status == :no_folder

      lead = if result.attached.zero? && result.moved.zero?
               "Scanned your library — nothing new for #{@project.name}"
             else
               "Scanned your library — attached #{result.attached}, filed #{result.moved}"
             end
      project_intake_sentence(lead, result, unfiled_by_conflict(result, result.skips.map(&:first)))
    end
  end
end
```

- [ ] **Step 5: Run to verify the share/s3 tests pass**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb
```

Expected: PASS (4 tests). The chunk_remote path is not exercised yet — Task 3 adds it.

- [ ] **Step 6: Mutation-check the §14f guard (§15)**

Add `Maker::ProjectIntake.for_project(user: current_user, project: @project)` to `#enqueue_scan`, re-run, and confirm **"a scannable backend does NOT file synchronously"** goes RED. Remove it again. A guard that has never failed has not been shown to work.

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/projects/scans_controller.rb test/integration/web/project_scan_button_test.rb
git commit -m "A door that asks the library to look now, and refuses to file while it looks"
```

---

## Task 3: the chunk_remote branch

**Files:**
- Test: `test/integration/web/project_scan_button_test.rb` (modify)

The controller code already exists from Task 2; this task proves it and pins the ordering.

- [ ] **Step 1: Write the failing tests**

Add to `ProjectScanButtonTest`, above the final `end`:

```ruby
    # ORDER IS THE ASSERTION, not merely that both ran: filing before the pull would report on a
    # stale mirror, which is the whole failure this button exists to end.
    test "on chunk_remote the pull runs first and the intake second" do
      FileLayer.current = FileLayer::ChunkRemote.new
      order = []
      pull = ->(**) { order << :pull }
      file = ->(**) { order << :file
                      Maker::ProjectIntake::Result.new(attached: 2, moved: 1, skipped: 0,
                                                       skips: [], plan: [], status: :ok) }
      FileLayer::RemoteChangelogPullJob.stub(:perform_now, pull) do
        Maker::ProjectIntake.stub(:for_project, file) do
          post project_scan_path(@project)
        end
      end
      assert_equal %i[pull file], order
      assert_redirected_to project_path(@project)
      assert_match(/attached 2/i, flash[:notice].to_s)
      assert_match(/filed 1/i, flash[:notice].to_s)
    end

    test "on chunk_remote a project with no folder is told so, and no folder is created" do
      FileLayer.current = FileLayer::ChunkRemote.new
      none = Maker::ProjectIntake::Result.new(attached: 0, moved: 0, skipped: 0, skips: [],
                                              plan: [], status: :no_folder)
      FileLayer::RemoteChangelogPullJob.stub(:perform_now, ->(**) {}) do
        Maker::ProjectIntake.stub(:for_project, ->(**) { none }) do
          post project_scan_path(@project)
        end
      end
      assert_match(/no folder yet/i, flash[:notice].to_s)
      assert_nil @project.reload.folder_node_id,
                 "the scan door must never call ensure_library_folder! — a folder minted as a " \
                 "side effect of merely looking is the bug #relocate shipped"
    end

    # The conflict clause has ONE home (ProjectFolderIntake#project_intake_sentence). This door is
    # its fourth caller and must not paraphrase it.
    test "a collision left at the project root is named in the same words every other door uses" do
      FileLayer.current = FileLayer::ChunkRemote.new
      clash = Maker::ProjectIntake::Result.new(attached: 1, moved: 0, skipped: 1,
                                               skips: [ [ "panel.stl", :conflict ] ],
                                               plan: [], status: :ok)
      FileLayer::RemoteChangelogPullJob.stub(:perform_now, ->(**) {}) do
        Maker::ProjectIntake.stub(:for_project, ->(**) { clash }) do
          post project_scan_path(@project)
        end
      end
      assert_match(/already in #{Maker::ProjectFolders.folder_for('panel.stl')}\//,
                   flash[:notice].to_s)
      assert_match(/stayed at the project root/i, flash[:notice].to_s)
    end
```

- [ ] **Step 2: Run to verify**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb
```

Expected: PASS (7 tests). If the ordering test fails with `%i[file pull]`, the controller's `pull_and_file` has its two lines the wrong way round.

- [ ] **Step 3: Mutation-check the ordering (§15)**

Swap the two lines in `#pull_and_file` so the intake runs first. Confirm **"the pull runs first and the intake second"** goes RED. Restore.

- [ ] **Step 4: Commit**

```bash
git add test/integration/web/project_scan_button_test.rb
git commit -m "The pull before the filing, because filing first reports on a stale mirror"
```

---

## Task 4: the throttle

**Files:**
- Test: `test/integration/web/project_scan_button_test.rb` (modify)

- [ ] **Step 1: Write the failing test**

Add to `ProjectScanButtonTest`:

```ruby
    # NOT ONLY ABUSE CONTROL. Library::ScanJob's `on_conflict: :discard` silently DROPS a second
    # enqueue while one is running, so without this the user gets "Scanning…" and nothing happens.
    # The throttle is what turns that silence into a sentence.
    test "a fourth scan in a minute is refused with a message rather than silently discarded" do
      use_share!
      3.times do
        post project_scan_path(@project)
        assert_redirected_to project_path(@project, scanning: 1), "under the limit"
      end
      post project_scan_path(@project)
      assert_redirected_to project_path(@project)
      assert_match(/give it a moment/i, flash[:alert].to_s)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # Guards the counter itself. With a NullStore, increment returns nil and ActionController's
    # `count && count > to` makes every throttle here a no-op that no other assertion would notice.
    test "the store backing this throttle is real, not a null store" do
      assert_not_kind_of ActiveSupport::Cache::NullStore, ActionController::Base.cache_store
    end
```

- [ ] **Step 2: Run to verify it passes**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb -n "/throttl|fourth scan|null store/"
```

Expected: PASS — the `rate_limit` line from Task 2 already implements it.

- [ ] **Step 3: Mutation-check the throttle (§15)**

Comment out the whole `rate_limit` block in `app/controllers/projects/scans_controller.rb`, re-run, and confirm **"a fourth scan in a minute is refused"** goes RED. Restore.

- [ ] **Step 4: Commit**

```bash
git add test/integration/web/project_scan_button_test.rb
git commit -m "Three scans a minute, and the fourth says why"
```

---

## Task 5: the button on the page

**Files:**
- Modify: `app/controllers/projects_controller.rb`
- Modify: `app/views/projects/_attachments.html.erb`
- Test: `test/integration/web/project_scan_button_test.rb` (modify)

- [ ] **Step 1: Write the failing test**

Add to `ProjectScanButtonTest`:

```ruby
    # ASSERT THE RENDERED MARKUP, not a Ruby hash. §14d records two shipped bugs invisible to a
    # green suite because the tests POSTed `params: { x: {...} }` and bypassed the form entirely.
    test "the project page renders a scan button pointing at this project's scan path" do
      use_share!
      get project_path(@project)
      assert_response :success
      assert_select "form[action=?]", project_scan_path(@project) do
        assert_select "button", text: /scan folder/i
      end
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "the reload element appears only after a scan started, never on a plain view" do
      use_share!
      get project_path(@project)
      assert_select "[data-controller~=?]", "scanreload", false,
                    "a plain project view must not schedule a reload"

      get project_path(@project, scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", 1
      # The reload target is the param-FREE url. That is what stops it looping: the reloaded page
      # carries no ?scanning=1, renders no scanreload element, and schedules nothing.
      assert_select "[data-scanreload-url-value=?]", project_path(@project)
    ensure
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # chunk_remote finishes its work inside the request, so there is nothing to wait for.
    test "chunk_remote never renders the reload element" do
      FileLayer.current = FileLayer::ChunkRemote.new
      get project_path(@project, scanning: 1)
      assert_select "[data-controller~=?]", "scanreload", false
    end
```

- [ ] **Step 2: Run to verify it fails**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb -n "/renders a scan button|reload element/"
```

Expected: FAIL — no form with that action; no `scanreload` element.

- [ ] **Step 3: Set the flag in the controller**

In `app/controllers/projects_controller.rb#show`, immediately after the `@move_conflict = move_conflict_prompt` line:

```ruby
    # `== "1"`, not `.present?` — the same reading #index applies to `archived`. Set by
    # Projects::ScansController's async branch; it is a one-shot render hint, not state, which is
    # why it rides in the url rather than in the session: the reload navigates to the param-free
    # url and the hint is gone by construction.
    @scan_started = params[:scanning] == "1"
```

- [ ] **Step 4: Add the button and the reload element**

In `app/views/projects/_attachments.html.erb`, inside `<div class="panel-actions">`, **before** the "Attach existing" link:

```erb
    <%# "Look at my library NOW", instead of waiting on library_scan's 15 minutes (share/s3) or
        remote_changelog_pull's 2 (chunk_remote). It scans the LIBRARY, not this folder — a scan
        cannot be aimed at a subfolder (Library::Reconciler compares against the whole catalog), so
        the door refreshes the store and the existing chains do the per-project filing. %>
      <%= button_to "Scan folder", project_scan_path(@project), method: :post, class: "linkbtn" %>
```

Then, immediately **after** the closing `</div>` of `panel-actions` and before the `<% if @attachments.empty? … %>` line:

```erb
  <%# A share/s3 scan is a BACKGROUND job — an unbounded NAS walk or bucket listing — so the page
      that started it cannot show the result. One reload, to the param-free url, which is what
      stops it looping. Rendered only on the async path: chunk_remote finished inside the request.
      §14d — a data-controller name that resolves to nothing is a SILENT no-op, which is why
      app/javascript/controllers/scanreload_controller.js must exist and stimulus_hygiene_test
      guards that it does. %>
  <% if @scan_started && capabilities.scannable? %>
    <span data-controller="scanreload"
          data-scanreload-url-value="<%= project_path(@project) %>"></span>
  <% end %>
```

`capabilities` is already available — `ProjectsController` includes `LibraryCapabilities`, which exposes it as a helper method.

- [ ] **Step 5: Run to verify it passes**

```bash
bin/rails test test/integration/web/project_scan_button_test.rb
```

Expected: PASS (12 tests). `stimulus_hygiene_test` will now FAIL — the view declares `scanreload` and no controller file exists. That is the guard working; Task 6 satisfies it.

- [ ] **Step 6: Confirm the hygiene guard is red for the right reason**

```bash
bin/rails test test/stimulus_hygiene_test.rb
```

Expected: FAIL naming `scanreload`. Do not proceed past Task 6 with this red.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projects_controller.rb app/views/projects/_attachments.html.erb test/integration/web/project_scan_button_test.rb
git commit -m "The button beside the files it is about"
```

---

## Task 6: the Stimulus controller

**Files:**
- Create: `app/javascript/controllers/scanreload_controller.js`

The identifier is derived from the filename by `eagerLoadControllersFrom` — `scanreload_controller.js` registers as `scanreload`. All-lowercase single word matches the repo's existing names (`thumbfallback`, `commitgroup`, `modelviewer`).

- [ ] **Step 1: Write the controller**

Create `app/javascript/controllers/scanreload_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// A share/s3 library scan is a BACKGROUND job — an unbounded NAS walk or bucket listing, which is
// why library_scan polls every 15 minutes rather than every 15 seconds — so the page that started
// it cannot show the result. Reload once, after a delay.
//
// IT NAVIGATES TO A URL RATHER THAN CALLING reload(), AND THAT IS WHAT STOPS IT LOOPING. The page
// renders this element only when ?scanning=1 is present; urlValue is the same page WITHOUT that
// param, so the reloaded page renders no scanreload element and schedules nothing. A bare
// location.reload() would carry the param forward and reload forever.
//
// THE DELAY IS A GUESS, KNOWINGLY. A large library outlasts it and the reloaded page will show no
// new files — which is why the flash that accompanies this says a large library takes longer and
// to reload again. A status endpoint to poll is the upgrade path if that proves unsatisfying.
export default class extends Controller {
  static values = {
    url: String,
    delay: { type: Number, default: 6000 }
  }

  connect() {
    this.timer = setTimeout(() => window.location.replace(this.urlValue), this.delayValue)
  }

  // Turbo caches and restores pages, so a timer left running after the user navigates away would
  // yank them back to a project page they had left.
  disconnect() {
    clearTimeout(this.timer)
  }
}
```

`replace`, not `assign`: the scan-started URL should not sit in history, where Back would re-trigger the reload.

- [ ] **Step 2: Run the hygiene guard to verify it passes**

```bash
bin/rails test test/stimulus_hygiene_test.rb
```

Expected: PASS.

- [ ] **Step 3: Mutation-check the guard (§15)**

```bash
mv app/javascript/controllers/scanreload_controller.js /tmp/scanreload.js && bin/rails test test/stimulus_hygiene_test.rb; mv /tmp/scanreload.js app/javascript/controllers/scanreload_controller.js
```

Expected: RED while moved away, naming `scanreload`; green again after. This is the guard that would have caught the nine-day OpenSCAD outage.

- [ ] **Step 4: Commit**

```bash
git add app/javascript/controllers/scanreload_controller.js
git commit -m "One reload, to the url without the marker, so it cannot loop"
```

---

## Task 7: record the new rule where the next editor will find it

The design decided something a future editor could undo by accident: **an interactive scan door must not file on a scannable backend.** That binds inside project intake, so it belongs in the area file under §14f, not in CLAUDE.md (which is at a line ceiling and whose rule is "one line, consequence named, story elsewhere").

**Files:**
- Modify: `docs/invariants/project-intake.md`

- [ ] **Step 1: Add the bullet**

In `docs/invariants/project-intake.md`, in the **Filing** section, immediately after the bullet beginning **"THE SCANJOB ORDERING — INTAKE STRICTLY AFTER THE RECONCILE, SAME JOB"**:

```markdown
- **AN INTERACTIVE SCAN DOOR MUST NOT FILE ON A SCANNABLE BACKEND — IT ENQUEUES AND STOPS.**
  `Projects::ScansController` (the per-project "Scan folder" button) is the first door that
  refreshes the store on a user's command. On share/s3 it calls `Library::ScanJob.enqueue_for` and
  files NOTHING itself: a move started from the request races the Scanner's own observations, and
  the bullet above is what that costs — a terminal 404 for a file that is not gone. The filing is
  already inside `ScanJob#perform`, after `observer.call`, and that is the only place it may be.
  Pinned by `project_scan_button_test.rb`'s "a scannable backend does NOT file synchronously",
  mutation-checked by adding the forbidden call.
  **On `chunk_remote` the same door DOES file synchronously, and the asymmetry is the rule, not an
  inconsistency**: there is no scan there, so there is no race, and the pull's own nudge
  (`ChangelogSync#nudge_project_intake`) covers LIVE ARRIVALS ONLY — a file already in the mirror
  but unfiled gets no nudge, so a pull-only button would find nothing to do and read as broken.
  The synchronous pull is **not** the one §14a forbids: that bars a pull in a READ path, and this
  is a POST.
```

- [ ] **Step 2: Verify the docs guard still passes**

```bash
bin/rails test test/docs_hygiene_test.rb
```

Expected: PASS — the §14f stub still points at a file that exists, and CLAUDE.md is unchanged so its line ceiling is untouched.

- [ ] **Step 3: Commit**

```bash
git add docs/invariants/project-intake.md
git commit -m "The rule the next editor would undo: enqueue, do not file"
```

---

## Task 8: full gates, then finish the branch

- [ ] **Step 1: Run the whole local suite**

```bash
bin/ci
```

Expected: every gate green. **Read the three backend legs' run counts and compare them** — `bin/ci` prints them and never compares (§15). They must match; a ±2 assertion / ±1 skip flap is the known one recorded at `tinkerex#131`, a structural difference means a test in this branch depends on the ambient `LIBRARY_BACKEND` and is a real bug.

From a worktree, `test-chunk-remote` needs the sibling checkout — set `TINKEREX_SYNC_DIR` or clone `../tinkerex-sync`.

- [ ] **Step 2: Drive the real page once**

§14e: "Checking beats reasoning", and §14d records an ERB comment that printed itself into a page through a fully green run. Start the app, open a project, click **Scan folder**, and confirm: the flash appears, the page reloads once after ~6s, and it does **not** reload again.

- [ ] **Step 3: Finish the branch**

Use `/finish-branch`. Per §15 this is standing authorization on a `claude/*` branch once gates are green: commit, push, open the PR, then `bin/log arc --from-pr <n>` **as the PR opens** — not as a tidy-up afterwards. State plainly in the PR that the reload delay is a fixed 6s guess and what that means on a large library. Merging still needs an explicit go-ahead.

---

## Self-review

**Spec coverage:** route + controller → Task 2; share/s3 async branch → Task 2; chunk_remote sync branch → Tasks 2–3; `enqueue_for` / no-credentials rule → Task 1; conflict-clause reuse → Tasks 2–3; throttle → Tasks 2, 4; button placement → Task 5; `scanreload` + no-loop → Tasks 5–6; no-folder behaviour → Task 3; testing section → Tasks 1–6; invariant capture → Task 7. No gaps.

**Placeholders:** none — every code step carries its full code, every command its expected output.

**Type consistency:** `Maker::ProjectIntake::Result` is `Data.define(:attached, :moved, :skipped, :skips, :plan, :status)` with integer counts, `skips` as `[[name, reason], …]`, and `status` `:ok` / `:no_folder` — matching every construction in Tasks 3 and the reads in Task 2's `#scan_notice`. `.enqueue_for(user)` takes a `User` and is called that way in Task 1 and Task 2. `project_intake_sentence(lead, result, filename)` and `unfiled_by_conflict(result, names)` match `app/controllers/concerns/project_folder_intake.rb`.
