# Phase 4 — Seeing it: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.
>
> **Read first:** [`00-overview.md`](2026-08-27-git-tracked-projects-00-overview.md), the design's
> §8.2, and `docs/invariants/files-preview.md`. **Phases 1–3 must be merged.**

**Goal:** history is visible on the project page, with per-version thumbnails for models and CAD and
a side-by-side visual compare — the part that earns the feature, because a text diff of a STEP file
is worthless.

**Architecture:** a history panel on the project page reading `Maker::Git::Repo#log`. Historical
renders are generated **on demand and cached in their own table**, leaving `Maker::Preview` exactly
as §14b collapsed it.

**Tech stack:** Rails 8, Hotwire/Turbo, Stimulus, `diff-lcs` (MIT), the existing renderers
(`stl-thumbnailer`, `f3d`, `resvg`, `pdfium`).

---

## The invariant this phase is most likely to break

§14b: *"A `Maker::Preview` is ONE ROW PER `(user, node, kind)`, REPOINTED as content moves — was one
per **version**, which leaked a row + blob on every save."*

A thumbnail per version is asking for exactly what was deliberately removed. **The way through is
that the leak was eager generation on every save, not the existence of old thumbnails.** So:

- Historical renders live in their **own table**, `maker_version_previews`. `Maker::Preview` is not
  touched, and `GeneratePreviewJob#commit_if_current` keeps its compare-and-set.
- They are generated **only when someone opens History**, never on save.
- They carry retention, so the cache cannot grow without bound.

Break any of those three and this phase re-creates the bug §14b exists to record.

---

## File structure

| file | responsibility |
|---|---|
| `db/migrate/*_create_maker_version_previews.rb` | the historical render cache |
| `app/models/maker/version_preview.rb` | one row per (user, node, content_token, kind) |
| `app/services/maker/git/version_history.rb` | "what versions does this file have", per backend |
| `app/controllers/projects/history_controller.rb` | the panel + the per-file version list |
| `app/jobs/maker/render_version_preview_job.rb` | on-demand render |
| `app/views/projects/history/*` | the views |
| `app/javascript/controllers/version_compare_controller.js` | the A/B slider |
| `Gemfile` | `gem "diff-lcs"` |

---

### Task 1: The version history service

**Files:**
- Create: `app/services/maker/git/version_history.rb`
- Create: `test/services/maker/git/version_history_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/maker/git/version_history_test.rb
require "test_helper"

class Maker::Git::VersionHistoryTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @project = @user.maker_projects.create!(title: "Lamp")
    @project.ensure_library_folder!(@user)
  end

  test "a text file's versions come from the commits that touched it" do
    repo = Maker::Git::Repo.for(@project)
    repo.hydrate!
    repo.commit!(paths: { "notes.md" => "one\n" }, message: "one")
    repo.commit!(paths: { "notes.md" => "two\n" }, message: "two")

    versions = Maker::Git::VersionHistory.new(project: @project).for_path("notes.md")

    assert_equal 2, versions.size
    assert_equal "two", versions.first.message.strip, "newest first"
    assert versions.first.content_available?, "text content is always available from the repo"
  end

  # THE HONEST CASE. A pointer records that a version EXISTED; the bytes are retained only where
  # the store kept them — nowhere on share, where the Finder overwrite destroyed them before any
  # scan ran. The UI must say "not kept" rather than pretend the version never happened.
  test "a superseded pointer version is listed but marked unavailable on share" do
    skip "share-specific" unless FileLayer.current.is_a?(FileLayer::Share)

    repo = Maker::Git::Repo.for(@project)
    repo.hydrate!
    repo.commit!(paths: { "b.stl.ptr" => "version tinkerex/v1\noid sha256:#{'a' * 64}\nsize 10\n" }, message: "v1")
    repo.commit!(paths: { "b.stl.ptr" => "version tinkerex/v1\noid sha256:#{'b' * 64}\nsize 12\n" }, message: "v2")

    versions = Maker::Git::VersionHistory.new(project: @project).for_path("b.stl")

    assert_equal 2, versions.size
    assert versions.first.content_available?,  "the current version resolves"
    assert_not versions.last.content_available?, "a superseded version's bytes are gone on share"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/maker/git/version_history_test.rb`
Expected: FAIL — `NameError: uninitialized constant Maker::Git::VersionHistory`

- [ ] **Step 3: Implement**

```ruby
# app/services/maker/git/version_history.rb
module Maker
  module Git
    # "What versions does this file have, and can I actually see each one?"
    #
    # TWO KINDS OF VERSION, AND THE DIFFERENCE IS VISIBLE TO THE USER:
    #
    #   content  the bytes are IN the repo. Always available, on every backend, forever.
    #   pointer  the repo holds a content hash. The bytes resolve only where the store kept them:
    #            the sync server on chunk_remote, bucket versioning on s3, and NOWHERE on share.
    #
    # THE UNAVAILABLE CASE IS RENDERED, NOT HIDDEN. A greyed "not kept" tile is the truth; omitting
    # the version would tell the user their file has less history than it does, and quietly. This
    # is the same choice §14a makes for an unmounted share: never let a recoverable-looking state
    # and a permanent one render identically.
    # `available` IS A MEMBER, NOT AN IVAR SET AFTER CONSTRUCTION. A Data instance is FROZEN, so
    # the obvious `def available!(v) = (@available = v; self)` raises FrozenError at runtime — and
    # only on the path that actually renders a version list, which is late to find out.
    Version = Data.define(:oid, :message, :time, :author, :mode, :content_token, :path, :available) do
      def pointer? = mode == :pointer
      def content_available? = available
    end

    class VersionHistory
      def initialize(project:)
        @project = project
        @user = project.user
        @repo = Repo.for(project)
      end

      # `path` is the file's path within the project folder, WITHOUT the `.ptr` suffix — callers
      # hold a real filename, not a storage detail.
      def for_path(path)
        @repo.hydrate!
        mode = Tracking.mode_for(File.basename(path))
        repo_path = mode == :pointer ? "#{path}.ptr" : path

        commits_touching(repo_path).map do |commit, blob|
          token = mode == :pointer ? blob[/^oid (\S+)$/, 1] : commit.oid
          Version.new(oid: commit.oid, message: commit.message, time: commit.time,
                      author: commit.author, mode:, content_token: token, path:,
                      available: mode == :content || retained?(token))
        end
      end

      private

      # Does the STORE still have these bytes? Never asks git — a pointer's whole point is that
      # the bytes are not in the repo.
      def retained?(token)
        return false if token.blank?

        @user.nodes.present.exists?(content_hash: token) ||
          FileLayer.current.capabilities.versioned? && remote_retains?(token)
      end

      def remote_retains?(token)
        FileLayer.current.stat(@user, node_id: token) && true
      rescue FileLayer::NotFound, FileLayer::FetchError, NotImplementedError
        false
      end

      # One walk, keeping only the commits where this path's blob CHANGED. A commit that touched
      # other files is not a version of this one, and listing it would make every file look like it
      # changed on every scan.
      def commits_touching(repo_path)
        seen = nil
        @repo.log(limit: 500).filter_map do |commit|
          blob = begin
            @repo.blob_at(oid: commit.oid, path: repo_path)
          rescue FileLayer::NotFound
            nil
          end
          next if blob.nil? || blob == seen

          seen = blob
          [ commit, blob ]
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/maker/git/version_history_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/maker/git/version_history.rb test/services/maker/git/version_history_test.rb
git commit -m "Maker::Git::VersionHistory: versions per file, honest about unavailable bytes"
```

---

### Task 2: The historical render cache

**Files:**
- Create: `db/migrate/<ts>_create_maker_version_previews.rb`
- Create: `app/models/maker/version_preview.rb`
- Create: `app/jobs/maker/render_version_preview_job.rb`
- Create: `test/models/maker/version_preview_test.rb`

- [ ] **Step 1: Write the migration**

```ruby
class CreateMakerVersionPreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_version_previews do |t|
      t.references :user, null: false, foreign_key: true
      t.string   :node_id,       null: false
      t.string   :content_token, null: false
      t.string   :kind,          null: false
      t.string   :state,         null: false, default: "pending"
      t.datetime :last_viewed_at
      t.timestamps
      t.index %i[user_id node_id content_token kind], unique: true,
              name: "index_maker_version_previews_uniqueness"
    end
  end
end
```

- [ ] **Step 2: Write the model**

```ruby
# app/models/maker/version_preview.rb
module Maker
  # A thumbnail of a HISTORICAL version. A SEPARATE TABLE FROM Maker::Preview, deliberately.
  #
  # §14b collapsed Maker::Preview to one row per (user, node, kind) BECAUSE one-row-per-version
  # leaked a row and a blob on every save. Rendering history would appear to need that back — it
  # does not. The leak was EAGER GENERATION ON EVERY SAVE, not the existence of old thumbnails, and
  # the two are separable:
  #
  #   Maker::Preview          one row, repointed, generated on save. UNTOUCHED by this table.
  #   Maker::VersionPreview   one row per version, generated ONLY when someone opens History,
  #                           with retention.
  #
  # Keeping them apart is what preserves GeneratePreviewJob#commit_if_current: the CURRENT row
  # still repoints, and a historical render can never claim it — which was the exact failure the
  # row-per-version key had made impossible by construction.
  #
  # `last_viewed_at` IS THE RETENTION KEY, not created_at: a version nobody looks at should age
  # out even if it was rendered recently, and one people keep opening should stay.
  class VersionPreview < ApplicationRecord
    self.table_name = "maker_version_previews"
    belongs_to :user
    has_one_attached :asset

    STATES = %w[pending ready failed unavailable].freeze
    validates :state, inclusion: { in: STATES }

    scope :reapable, ->(before) { where(last_viewed_at: ...before).or(where(last_viewed_at: nil).where(created_at: ...before)) }

    def touch_viewed! = update_column(:last_viewed_at, Time.current)
  end
end
```

- [ ] **Step 3: Write the on-demand job**

```ruby
# app/jobs/maker/render_version_preview_job.rb
module Maker
  # Render ONE historical version's thumbnail. Enqueued when History is opened, never on save —
  # see Maker::VersionPreview for why that distinction is the whole design.
  class RenderVersionPreviewJob < ApplicationJob
    queue_as :background

    def perform(version_preview_id:)
      row = Maker::VersionPreview.find_by(id: version_preview_id)
      return unless row&.state == "pending"

      bytes = fetch_bytes(row)
      return row.update!(state: "unavailable") if bytes.nil?

      renderer = Maker::Previews::Registry.for_filename(row.kind)
      return row.update!(state: "unsupported") unless renderer

      png = renderer.render(bytes)
      row.asset.attach(io: StringIO.new(png), filename: "v.png", content_type: "image/png")
      row.update!(state: "ready")
    rescue StandardError => e
      Rails.logger.warn("[version-preview] #{version_preview_id}: #{e.class}: #{e.message}")
      row&.update(state: "failed")
    end

    private

    # nil means "the store no longer has these bytes" — the honest, expected case on share, not an
    # error. It becomes the greyed "not kept" tile.
    def fetch_bytes(row)
      node = row.user.nodes.present.find_by(content_hash: row.content_token)
      return nil unless node

      FileLayer.current.read(row.user, node_id: node.node_id)
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end
  end
end
```

- [ ] **Step 4: Run**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/version_preview_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check that `Maker::Preview` is untouched**

```ruby
# test/models/maker/version_preview_test.rb
test "rendering a historical version does not create or repoint a Maker::Preview row" do
  node = @user.nodes.create!(node_id: "n1", name: "b.stl", kind: "file",
                             content_hash: "sha256:#{'a' * 64}")
  current = Maker::Preview.create!(user: @user, node_id: node.node_id, kind: "stl",
                                   version_id: node.content_hash, state: "ready")
  row = Maker::VersionPreview.create!(user: @user, node_id: node.node_id,
                                      content_token: "sha256:#{'b' * 64}", kind: "b.stl")

  assert_no_difference "Maker::Preview.count" do
    Maker::RenderVersionPreviewJob.perform_now(version_preview_id: row.id)
  end
  assert_equal node.content_hash, current.reload.version_id,
               "a historical render must never repoint the current preview row"
end
```

Then mutate: make the job write to `Maker::Preview` instead. Confirm **RED**. Restore.

- [ ] **Step 6: Commit**

```bash
git add db/ app/models/maker/version_preview.rb app/jobs/maker/render_version_preview_job.rb test/models/maker/version_preview_test.rb
git commit -m "Historical render cache, on demand, leaving Maker::Preview collapsed"
```

---

### Task 3: The history panel

**Files:**
- Create: `app/controllers/projects/history_controller.rb`
- Create: `app/views/projects/history/index.html.erb`, `_version_strip.html.erb`
- Modify: `config/routes.rb`
- Create: `test/integration/web/project_history_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/integration/web/project_history_test.rb
require "test_helper"

class ProjectHistoryTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user
    @project = @user.maker_projects.create!(title: "Lamp")
    @project.ensure_library_folder!(@user)
  end

  test "the history page lists commits newest first" do
    repo = Maker::Git::Repo.for(@project)
    repo.hydrate!
    repo.commit!(paths: { "notes.md" => "one\n" }, message: "older")
    repo.commit!(paths: { "notes.md" => "two\n" }, message: "newer")
    repo.consolidate!
    repo.persist!

    get project_history_path(@project)

    assert_response :success
    assert_select ".commit-row", 2
    assert_select ".commit-row:first-child", /newer/
  end

  test "a project with no repo renders an empty state rather than 500ing" do
    get project_history_path(@project)

    assert_response :success
    assert_select ".history-empty"
  end

  # ASSERT THE RENDERED FIELD NAME, not a Ruby hash (§14d). A form_with missing `scope:` emits
  # param names the controller's `require` rejects, and a nested-hash test cannot see it.
  test "the compare form posts the parameter names the controller requires" do
    get project_history_path(@project)
    assert_select "form.version-compare input[name=?]", "compare[from]"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/integration/web/project_history_test.rb`
Expected: FAIL — no route matches `project_history_path`.

- [ ] **Step 3: Add the route**

```ruby
# config/routes.rb — inside the existing `resources :projects` block
    get "history", to: "projects/history#index", as: :history
```

- [ ] **Step 4: Implement the controller**

```ruby
# app/controllers/projects/history_controller.rb
module Projects
  class HistoryController < ApplicationController
    before_action :set_project

    # THE EMPTY STATE IS A FIRST-CLASS CASE, not an error. A project created before this feature
    # shipped, or one whose files have never settled, genuinely has no history — and 500ing on the
    # ordinary case is how a feature gets turned off in production.
    def index
      @repo = Maker::Git::Repo.for(@project)
      @repo.hydrate!
      @commits = @repo.head_oid ? @repo.log(limit: 100) : []
    rescue FileLayer::FetchError => e
      # An unmounted share is transient. Say so; do not render "you have no history".
      @commits = []
      @unreachable = e.message
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end
  end
end
```

- [ ] **Step 5: Implement the views**

`index.html.erb` renders the breadcrumb, an `.history-empty` block when `@commits` is empty, and one
`.commit-row` per commit showing `short_oid`, message, author and time. `_version_strip.html.erb`
renders the per-file tiles, each either an `<img>` for a ready `Maker::VersionPreview`, a spinner for
`pending`, or a `.not-kept` tile for `unavailable`.

**Do not put `<%= … %>` or a bare `%>` inside an ERB comment** — an ERB comment ends at its first
`%>`, so one quoting a snippet prints its own prose into the page, and **no `assert_select` in this
suite can see it** because the defect produces a text node (§14d). Describe the spelling in words.

- [ ] **Step 6: Run to verify it passes**

Run: `bin/rails test test/integration/web/project_history_test.rb`
Expected: PASS.

- [ ] **Step 7: Add a query budget guard**

```ruby
# test/integration/web/page_query_budget_test.rb — append
test "project history is constant in the number of commits" do
  # ASSERT CONSTANCY, NEVER A LITERAL: the counts differ per LIBRARY_BACKEND, so a literal pins
  # one leg and fails the other two (§14e).
  baseline = count_queries { get project_history_path(@project) }
  add_commits(20)
  assert_equal baseline, count_queries { get project_history_path(@project) }
end
```

- [ ] **Step 8: Commit**

```bash
git add app/controllers/projects/history_controller.rb app/views/projects/history/ config/routes.rb test/integration/web/
git commit -m "Project history panel, with an empty state and a query budget"
```

---

### Task 4: Visual compare for meshes

**Files:**
- Create: `app/javascript/controllers/version_compare_controller.js`
- Modify: `app/views/projects/history/_version_strip.html.erb`
- Modify: `test/stimulus_hygiene_test.rb` (nothing to edit — it derives identifiers from filenames)

- [ ] **Step 1: Write the failing test**

```ruby
# test/integration/web/project_history_test.rb — append
test "the compare panel attaches its stimulus controller" do
  seed_two_versions_of("b.stl")
  get project_history_path(@project)

  assert_select "[data-controller~=version-compare]"
end
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — no element carries the attribute.

- [ ] **Step 3: Implement**

Write `version_compare_controller.js` with targets `before`, `after` and `slider`, clipping the
`after` image by the slider's percentage.

**A `data-controller` name that resolves to nothing is a silent no-op** — Stimulus neither throws nor
warns, so the page renders perfectly and the behaviour is simply absent. Two deleted controllers
once left a feature inert for nine days with a green request test throughout (§14d).
`test/stimulus_hygiene_test.rb` derives registered identifiers from filenames, so a correctly-named
file needs no test edit — but the filename must be `version_compare_controller.js` exactly.

- [ ] **Step 4: Run to verify it passes** — then open the page in a browser and drag the slider.
      A request test proves the endpoint works and **nothing** about whether the only thing that
      calls it has gone inert.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/controllers/version_compare_controller.js app/views/projects/history/
git commit -m "Side-by-side visual compare for mesh and CAD versions"
```

---

### Task 5: Text diffs

- [ ] **Step 1:** Add `gem "diff-lcs"` (MIT — clears §9) to the Gemfile and `bundle install`.
- [ ] **Step 2:** Write a failing test asserting that comparing two text versions renders added and
      removed lines with distinct classes.
- [ ] **Step 3:** Implement a `Maker::Git::TextDiff` service wrapping `Diff::LCS.sdiff`, rendering
      only for `Tracking.mode_for(name) == :content`. **A pointer version never gets a text diff** —
      diffing two hashes is noise, and that is what task 4's visual compare is for.
- [ ] **Step 4:** Run, then commit.

---

### Task 6: Close the phase

- [ ] `bin/ci` green; three backend legs identical.
- [ ] Open the page in a real browser and check the console for SEVERE entries — the system tests'
      console check is what caught two CSP defects that every integration test passed (§14e).
- [ ] Open the PR, then `bin/log arc --from-pr <n>` in the same breath.

## Phase 4 is done when

- History renders on the project page with per-version thumbnails for models and CAD.
- An unavailable version renders as **"not kept"**, never omitted.
- `Maker::Preview` is untouched and `commit_if_current` still holds — mutation-checked.
- Historical renders happen **only** on opening History, never on save.
