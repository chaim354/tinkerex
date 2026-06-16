# Maker Projects Pillar — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server side of the maker-app **Projects pillar** — a project is the place a maker tracks a piece of work (hardware + firmware + software): a named project with a status lifecycle, a chronological **build log**, attached design files, and **tasks** (which already exist and just gain Projects as a valid owner).

**Architecture:** A continuation of the `Maker::`-namespaced product layer **inside the existing Rails 8 app** (the same DB, the same `users` table, the same device-token auth established by the Library pillar). Project records are **server-authoritative** (normal integer-PK Rails CRUD over the `/v1/maker/*` API), *not* synced into the local SQLite file tree. Files are referenced only by the file layer's stable string `node_id` (+ optional `version_id`) via the **existing polymorphic `Maker::FileAttachment`** — no new attachment table. Tasks already exist (`Maker::Task`, optional polymorphic `taskable`); this pillar makes `Maker::Project` a second valid `taskable` owner. Inventory and BOM are separate pillars (separate plans).

**Dependency / ordering:** This is the **first** of the three remaining product pillars (Projects → Inventory → BOM). It depends only on the **already-merged Library pillar** (`Maker::Task`, `Maker::FileAttachment`, `Maker::Item`, the `V1::BaseController` + `namespace :maker` routes, the `app/models/maker/` + `app/controllers/v1/maker/` directories). It has **no dependency** on Inventory or BOM. BOM (the third plan) depends on this pillar's `maker_projects` table.

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite (dev/test) + Postgres (prod) — adapter-agnostic (no DB-level FK constraints, explicit indexes, `user_id` integer scoping, matching the existing `nodes`/`maker_*` schema). Minitest (`ActiveSupport::TestCase` for models, `ActionDispatch::IntegrationTest` for the API).

**Conventions to follow (from the existing Library pillar):**
- Models: `belongs_to :user`; `self.table_name = "maker_*"`; enum-like value sets as frozen constants + `validates :x, inclusion:`; uniqueness scoped `{ scope: :user_id }`; `dependent: :destroy`; polymorphic `as:`/`attachable`/`taskable`. See `app/models/maker/item.rb`, `app/models/maker/task.rb`.
- Migrations: `t.integer :user_id, null: false` (no `foreign_key:` constraint — the codebase has none), explicit `add_index`. Timestamp-prefixed filenames; **continue the existing sequence — Library used `20260615000001`–`20260615000007`, so this plan uses `20260615000008`–`20260615000009`.**
- Controllers: `V1::Maker::XController < V1::BaseController` (inherits device-token auth + JSON rescue handlers — `RecordNotFound`→404, `RecordInvalid`→422, `ParameterMissing`→400); scope **everything** through `current_user.maker_projects` etc. (tenant isolation); `render json:`; `only:`-restricted routes.
- Tests: API tests register a device via `POST /v1/auth/register` and send `Authorization: Bearer <token>`. See `test/integration/v1/maker/items_test.rb`.

**Routes:** the `namespace :maker do … end` block already exists in `config/routes.rb` (added by the Library pillar). This plan adds, inside it:
```ruby
resources :projects, only: %i[index show create update destroy] do
  resources :build_log_entries, only: %i[index create destroy], shallow: true
  resources :file_attachments, only: %i[create destroy], shallow: true
end
```
(`build_log_entries` and `file_attachments` are nested + `shallow:` so member ops use a top-level id, matching the items↔file_attachments pattern. Tasks already have their own `resources :tasks` route — no change there; a task gets a Project owner via its `taskable_type`/`taskable_id` params.) Add only the routes each task needs, as that task is implemented.

---

## File Structure

**Migrations** (`db/migrate/`): `20260615000008_create_maker_projects.rb`, `20260615000009_create_maker_build_log_entries.rb`.

**Models** (`app/models/maker/`): `project.rb`, `build_log_entry.rb`. Plus 2 `has_many` lines added to `app/models/user.rb`, and an edit to the existing `app/models/maker/task.rb` (add `Maker::Project` to `TASKABLE_TYPES` + extend the ownership validation).

**Controllers** (`app/controllers/v1/maker/`): `projects_controller.rb`, `build_log_entries_controller.rb`. (`file_attachments_controller.rb` already exists from the Library pillar and is reused unchanged — it already scopes through `current_user.maker_file_attachments`; we only need its `create` to resolve the parent polymorphically, see Task 5.)

**Tests**: model tests in `test/models/maker/`, API tests in `test/integration/v1/maker/`.

Responsibilities: `Maker::Project` is the project record + the build-log + file-attachment + task owner. `Maker::BuildLogEntry` is a timestamped note/milestone belonging to a project (and itself a file-attachment owner). The existing `Maker::FileAttachment` (polymorphic `attachable`) is reused for both. `Maker::Task` gains Project as a second valid owner.

---

## Task 1: `Maker::Project` model + migration

**Files:**
- Create: `db/migrate/20260615000008_create_maker_projects.rb`
- Create: `app/models/maker/project.rb`
- Modify: `app/models/user.rb` (add `has_many :maker_projects`)
- Test: `test/models/maker/project_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000008_create_maker_projects.rb`:
```ruby
class CreateMakerProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_projects do |t|
      t.integer  :user_id, null: false
      t.string   :name, null: false
      t.string   :slug, null: false
      t.text     :description
      t.string   :status, null: false, default: "planning"
      t.datetime :archived_at
      t.timestamps
    end
    add_index :maker_projects, [ :user_id, :slug ], unique: true
    add_index :maker_projects, [ :user_id, :status ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_projects)` succeeds; `db/schema.rb` now contains `maker_projects`.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/project_test.rb`:
```ruby
require "test_helper"

module Maker
  class ProjectTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "proj@example.com") }

    test "valid with a name" do
      project = @user.maker_projects.build(name: "Smart Lamp")
      assert project.valid?
    end

    test "name is required" do
      project = @user.maker_projects.build(name: nil)
      assert_not project.valid?
      assert_includes project.errors[:name], "can't be blank"
    end

    test "slug is auto-generated from the name on create" do
      project = @user.maker_projects.create!(name: "Smart Lamp v2!")
      assert_equal "smart-lamp-v2", project.slug
    end

    test "explicit slug is respected and normalized" do
      project = @user.maker_projects.create!(name: "Lamp", slug: "My Custom Slug")
      assert_equal "my-custom-slug", project.slug
    end

    test "slug is unique per user" do
      @user.maker_projects.create!(name: "Lamp")
      dup = @user.maker_projects.build(name: "Lamp")
      assert_not dup.valid?
      assert_includes dup.errors[:slug], "has already been taken"
    end

    test "same slug allowed for a different user" do
      @user.maker_projects.create!(name: "Lamp")
      other = User.create!(email: "other@example.com")
      assert other.maker_projects.build(name: "Lamp").valid?
    end

    test "status must be in the allowed set" do
      assert_not @user.maker_projects.build(name: "x", status: "bogus").valid?
    end

    test "defaults status to planning" do
      project = @user.maker_projects.create!(name: "x")
      assert_equal "planning", project.status
    end

    test "archive! stamps archived_at and sets status archived" do
      project = @user.maker_projects.create!(name: "x")
      project.archive!
      assert_equal "archived", project.status
      assert_not_nil project.archived_at
    end

    test "scoped to the user via the association" do
      @user.maker_projects.create!(name: "mine")
      other = User.create!(email: "o2@example.com")
      other.maker_projects.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_projects.pluck(:name)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/project_test.rb`
Expected: FAIL — `uninitialized constant Maker::Project` (and `undefined method 'maker_projects'`).

- [ ] **Step 5: Write the model**

Create `app/models/maker/project.rb`:
```ruby
module Maker
  class Project < ApplicationRecord
    self.table_name = "maker_projects"

    belongs_to :user

    STATUSES = %w[planning active paused done archived].freeze

    has_many :build_log_entries, -> { order(:logged_at) },
             class_name: "Maker::BuildLogEntry", dependent: :destroy
    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :tasks, as: :taskable, class_name: "Maker::Task", dependent: :destroy

    before_validation :ensure_slug

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :status, inclusion: { in: STATUSES }

    scope :by_status, ->(s) { where(status: s) if s.present? }
    scope :active, -> { where(status: "active") }

    def archive!
      update!(status: "archived", archived_at: Time.current)
    end

    private

    def ensure_slug
      source = slug.presence || name
      return if source.blank?
      self.slug = source.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end
  end
end
```
(The `build_log_entries` association points at the model built in Task 2; it doesn't break this task's tests because nothing exercises it yet. `file_attachments`/`tasks` reuse the existing `Maker::FileAttachment`/`Maker::Task` polymorphic spines from the Library pillar.)

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, add to the `has_many` block (after `has_many :maker_tasks, class_name: "Maker::Task", dependent: :destroy`):
```ruby
  has_many :maker_projects, class_name: "Maker::Project", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/project_test.rb`
Expected: PASS (10 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000008_create_maker_projects.rb db/schema.rb \
        app/models/maker/project.rb app/models/user.rb \
        test/models/maker/project_test.rb
git commit -m "feat(maker): Maker::Project model + migration"
```

---

## Task 2: `Maker::BuildLogEntry` model + migration

**Files:**
- Create: `db/migrate/20260615000009_create_maker_build_log_entries.rb`
- Create: `app/models/maker/build_log_entry.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/build_log_entry_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000009_create_maker_build_log_entries.rb`:
```ruby
class CreateMakerBuildLogEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_build_log_entries do |t|
      t.integer  :user_id, null: false
      t.integer  :project_id, null: false
      t.text     :body, null: false
      t.string   :entry_type, null: false, default: "note"
      t.datetime :logged_at, null: false
      t.timestamps
    end
    add_index :maker_build_log_entries, [ :user_id, :project_id, :logged_at ],
              name: "index_maker_build_log_entries_on_project_logged_at"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_build_log_entries)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/build_log_entry_test.rb`:
```ruby
require "test_helper"

module Maker
  class BuildLogEntryTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "log@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid with a body" do
      entry = @project.build_log_entries.build(user: @user, body: "Soldered the board")
      assert entry.valid?
    end

    test "body is required" do
      entry = @project.build_log_entries.build(user: @user, body: nil)
      assert_not entry.valid?
    end

    test "entry_type must be in the allowed set" do
      entry = @project.build_log_entries.build(user: @user, body: "x", entry_type: "bogus")
      assert_not entry.valid?
    end

    test "defaults entry_type to note and stamps logged_at on create" do
      entry = @project.build_log_entries.create!(user: @user, body: "x")
      assert_equal "note", entry.entry_type
      assert_not_nil entry.logged_at
    end

    test "an explicit logged_at is preserved" do
      ts = 3.days.ago.change(usec: 0)
      entry = @project.build_log_entries.create!(user: @user, body: "x", logged_at: ts)
      assert_equal ts, entry.logged_at
    end

    test "destroying the project destroys its build log entries" do
      @project.build_log_entries.create!(user: @user, body: "x")
      assert_difference -> { Maker::BuildLogEntry.count }, -1 do
        @project.destroy
      end
    end

    test "an entry can own file attachments" do
      entry = @project.build_log_entries.create!(user: @user, body: "x")
      att = entry.file_attachments.create!(user: @user, node_id: "node-9")
      assert_equal entry, att.attachable
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/build_log_entry_test.rb`
Expected: FAIL — `uninitialized constant Maker::BuildLogEntry`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/build_log_entry.rb`:
```ruby
module Maker
  class BuildLogEntry < ApplicationRecord
    self.table_name = "maker_build_log_entries"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    ENTRY_TYPES = %w[note milestone].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy

    before_validation :ensure_logged_at, on: :create

    validates :body, presence: true
    validates :entry_type, inclusion: { in: ENTRY_TYPES }
    validates :logged_at, presence: true

    private

    def ensure_logged_at
      self.logged_at ||= Time.current
    end
  end
end
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after the `maker_projects` line:
```ruby
  has_many :maker_build_log_entries, class_name: "Maker::BuildLogEntry", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/build_log_entry_test.rb`
Expected: PASS (7 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000009_create_maker_build_log_entries.rb db/schema.rb \
        app/models/maker/build_log_entry.rb app/models/user.rb \
        test/models/maker/build_log_entry_test.rb
git commit -m "feat(maker): Maker::BuildLogEntry model + migration"
```

---

## Task 3: Make `Maker::Project` a valid task owner

**Files:**
- Modify: `app/models/maker/task.rb` (add `Maker::Project` to `TASKABLE_TYPES`, extend ownership validation)
- Test: `test/models/maker/task_test.rb` (append project-owner cases)

The existing `Maker::Task` (from the Library pillar) already supports an optional polymorphic `taskable`, but its `TASKABLE_TYPES` allow-list is `%w[Maker::Item]` and its ownership validation only checks `Maker::Item`. This task extends both so a task can be owned by a Project.

- [ ] **Step 1: Write the failing model test (append to the existing file)**

In `test/models/maker/task_test.rb`, add these two tests inside the `Maker::TaskTest` class (after the existing `"a task can be owned by an item"` test):
```ruby
    test "a task can be owned by a project" do
      project = @user.maker_projects.create!(name: "Lamp")
      task = @user.maker_tasks.create!(title: "Wire the LEDs", taskable: project)
      assert_equal project, task.taskable
    end

    test "a task cannot be owned by another user's project" do
      other = User.create!(email: "owner@example.com")
      project = other.maker_projects.create!(name: "Theirs")
      task = @user.maker_tasks.build(title: "x", taskable_type: "Maker::Project", taskable_id: project.id)
      assert_not task.valid?
      assert_includes task.errors[:taskable_id], "must reference your own project"
    end

    test "an unknown taskable_type is rejected" do
      task = @user.maker_tasks.build(title: "x", taskable_type: "Maker::Bogus", taskable_id: 1)
      assert_not task.valid?
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/task_test.rb`
Expected: FAIL — `"a task can be owned by a project"` fails (`taskable_type` not in `TASKABLE_TYPES`, so `inclusion` rejects it) and the ownership case fails (no Project branch yet).

- [ ] **Step 3: Update the model**

In `app/models/maker/task.rb`, change the `TASKABLE_TYPES` constant:
```ruby
    TASKABLE_TYPES = %w[Maker::Item Maker::Project].freeze
```

Then replace the private `taskable_belongs_to_owner` method with:
```ruby
    def taskable_belongs_to_owner
      owner_class =
        case taskable_type
        when "Maker::Item"    then Maker::Item
        when "Maker::Project" then Maker::Project
        end
      return unless owner_class

      unless owner_class.exists?(id: taskable_id, user_id: user_id)
        errors.add(:taskable_id, "must reference your own #{owner_class.model_name.element}")
      end
    end
```
(`model_name.element` yields `"item"` / `"project"`, so the error message reads `"must reference your own item"` / `"must reference your own project"` — keeping the Library pillar's existing message wording for items.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/task_test.rb`
Expected: PASS (all task model tests green — the new project cases plus the pre-existing item cases).

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/task.rb test/models/maker/task_test.rb
git commit -m "feat(maker): allow Maker::Project as a task owner"
```

---

## Task 4: `Maker::ProjectsController` — CRUD + serialization

**Files:**
- Modify: `config/routes.rb` (add `resources :projects` inside the existing `maker` block)
- Create: `app/controllers/v1/maker/projects_controller.rb`
- Test: `test/integration/v1/maker/projects_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the existing `namespace :maker do … end` block (after `resources :tasks`), add:
```ruby
      resources :projects, only: %i[index show create update destroy]
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/projects_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class ProjectsTest < ActionDispatch::IntegrationTest
      def register(email = "p@example.com")
        post "/v1/auth/register", params: { email:, device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup { @token = register }

      test "create returns the project json with a derived slug" do
        post "/v1/maker/projects",
             params: { project: { name: "Smart Lamp", status: "active", description: "RGB lamp" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Smart Lamp", body["name"]
        assert_equal "smart-lamp", body["slug"]
        assert_equal "active", body["status"]
        assert body["id"].present?
      end

      test "index lists only the current user's projects, filterable by status" do
        post "/v1/maker/projects", params: { project: { name: "Active one", status: "active" } },
             as: :json, headers: auth(@token)
        post "/v1/maker/projects", params: { project: { name: "Done one", status: "done" } },
             as: :json, headers: auth(@token)
        other = register("two@example.com")
        post "/v1/maker/projects", params: { project: { name: "Theirs" } }, as: :json, headers: auth(other)

        get "/v1/maker/projects", headers: auth(@token)
        assert_response :success
        assert_equal %w[Active\ one Done\ one].sort,
                     JSON.parse(response.body)["projects"].map { |p| p["name"] }.sort

        get "/v1/maker/projects", params: { status: "active" }, headers: auth(@token)
        assert_equal [ "Active one" ], JSON.parse(response.body)["projects"].map { |p| p["name"] }
      end

      test "show returns a project with empty build log and attachments" do
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "Lamp", body["name"]
        assert_equal [], body["build_log_entries"]
        assert_equal [], body["file_attachments"]
      end

      test "update changes fields" do
        post "/v1/maker/projects", params: { project: { name: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/projects/#{id}", params: { project: { name: "New", status: "paused" } },
              as: :json, headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "New", body["name"]
        assert_equal "paused", body["status"]
      end

      test "rejects an invalid status with 422" do
        post "/v1/maker/projects", params: { project: { name: "X", status: "bogus" } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "destroy removes the project" do
        post "/v1/maker/projects", params: { project: { name: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :not_found
      end

      test "another user cannot show my project" do
        post "/v1/maker/projects", params: { project: { name: "Private" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        other = register("x@example.com")
        get "/v1/maker/projects/#{id}", headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/projects"
        assert_response :unauthorized
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/projects_test.rb`
Expected: FAIL — routing error / `uninitialized constant V1::Maker::ProjectsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/projects_controller.rb`:
```ruby
module V1
  module Maker
    class ProjectsController < V1::BaseController
      def index
        projects = current_user.maker_projects.by_status(params[:status]).order(updated_at: :desc)
        render json: { projects: projects.map { |p| project_json(p) } }
      end

      def show
        project = current_user.maker_projects.find(params[:id])
        render json: project_json(project, full: true)
      end

      def create
        project = current_user.maker_projects.new(project_params)
        project.save!
        render json: project_json(project, full: true), status: :created
      end

      def update
        project = current_user.maker_projects.find(params[:id])
        project.update!(project_params)
        render json: project_json(project, full: true)
      end

      def destroy
        current_user.maker_projects.find(params[:id]).destroy!
        head :no_content
      end

      private

      def project_params
        params.require(:project).permit(:name, :slug, :description, :status, :archived_at)
      end

      def project_json(project, full: false)
        base = {
          id: project.id, name: project.name, slug: project.slug, status: project.status,
          archived_at: project.archived_at, created_at: project.created_at, updated_at: project.updated_at
        }
        return base unless full
        base.merge(
          description: project.description,
          build_log_entries: project.build_log_entries.map { |e| build_log_entry_json(e) },
          file_attachments: project.file_attachments.map { |a| attachment_json(a) }
        )
      end

      def build_log_entry_json(entry)
        { id: entry.id, body: entry.body, entry_type: entry.entry_type, logged_at: entry.logged_at }
      end

      def attachment_json(att)
        { id: att.id, node_id: att.node_id, version_id: att.version_id,
          role: att.role, label: att.label, position: att.position }
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/projects_test.rb`
Expected: PASS (8 runs, 0 failures). (Cross-user `find` returns 404 because `BaseController` rescues `ActiveRecord::RecordNotFound`; an invalid status returns 422 via the `RecordInvalid` rescue.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/projects_controller.rb \
        test/integration/v1/maker/projects_test.rb
git commit -m "feat(maker): v1 projects CRUD API"
```

---

## Task 5: `Maker::BuildLogEntriesController` + project file attachments

**Files:**
- Modify: `config/routes.rb` (nest `build_log_entries` + `file_attachments` under projects)
- Create: `app/controllers/v1/maker/build_log_entries_controller.rb`
- Modify: `app/controllers/v1/maker/file_attachments_controller.rb` (resolve the polymorphic parent for projects + build-log entries, not just items)
- Test: `test/integration/v1/maker/build_log_entries_test.rb`

- [ ] **Step 1: Add the nested routes**

In `config/routes.rb`, change the `resources :projects` line (from Task 4) to a block:
```ruby
      resources :projects, only: %i[index show create update destroy] do
        resources :build_log_entries, only: %i[index create destroy], shallow: true
        resources :file_attachments, only: %i[create destroy], shallow: true
      end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/build_log_entries_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class BuildLogEntriesTest < ActionDispatch::IntegrationTest
      def register(email = "bl@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project_id = JSON.parse(response.body)["id"]
      end

      test "add a build log entry to a project" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "Soldered the board", entry_type: "milestone" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Soldered the board", body["body"]
        assert_equal "milestone", body["entry_type"]
        assert body["logged_at"].present?
      end

      test "index lists a project's build log in logged_at order" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "First", logged_at: 2.days.ago.iso8601 } },
             as: :json, headers: auth(@token)
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "Second", logged_at: 1.day.ago.iso8601 } },
             as: :json, headers: auth(@token)
        get "/v1/maker/projects/#{@project_id}/build_log_entries", headers: auth(@token)
        assert_response :success
        assert_equal %w[First Second], JSON.parse(response.body)["build_log_entries"].map { |e| e["body"] }
      end

      test "delete a build log entry" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "x" } }, as: :json, headers: auth(@token)
        entry_id = JSON.parse(response.body)["id"]
        delete "/v1/maker/build_log_entries/#{entry_id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/projects/#{@project_id}/build_log_entries", headers: auth(@token)
        assert_equal [], JSON.parse(response.body)["build_log_entries"]
      end

      test "cannot add to another user's project" do
        other = register("other-bl@example.com")
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "x" } }, as: :json, headers: auth(other)
        assert_response :not_found
      end

      test "attach a design file to a project by node_id" do
        post "/v1/maker/projects/#{@project_id}/file_attachments",
             params: { file_attachment: { node_id: "node-step", role: "model", label: "enclosure.step" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "node-step", JSON.parse(response.body)["node_id"]
        get "/v1/maker/projects/#{@project_id}", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["file_attachments"].size
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/build_log_entries_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::BuildLogEntriesController`, and the file-attachment-to-project case fails because the existing `FileAttachmentsController#create` only resolves an `item_id` parent.

- [ ] **Step 4: Write the build-log-entries controller**

Create `app/controllers/v1/maker/build_log_entries_controller.rb`:
```ruby
module V1
  module Maker
    class BuildLogEntriesController < V1::BaseController
      def index
        project = current_user.maker_projects.find(params[:project_id])
        render json: { build_log_entries: project.build_log_entries.map { |e| entry_json(e) } }
      end

      def create
        project = current_user.maker_projects.find(params[:project_id])
        entry = project.build_log_entries.new(entry_params.merge(user: current_user))
        entry.save!
        render json: entry_json(entry), status: :created
      end

      def destroy
        current_user.maker_build_log_entries.find(params[:id]).destroy!
        head :no_content
      end

      private

      def entry_params
        params.require(:build_log_entry).permit(:body, :entry_type, :logged_at)
      end

      def entry_json(entry)
        { id: entry.id, project_id: entry.project_id, body: entry.body,
          entry_type: entry.entry_type, logged_at: entry.logged_at,
          created_at: entry.created_at, updated_at: entry.updated_at }
      end
    end
  end
end
```

- [ ] **Step 5: Generalize the file-attachments controller to any maker parent**

The Library pillar's `app/controllers/v1/maker/file_attachments_controller.rb` resolves only `item_id`. Replace its `create` (and add a private resolver) so it attaches to whichever parent the nested route provides — item, project, or build-log entry — always scoped to `current_user`. Replace the file's contents with:
```ruby
module V1
  module Maker
    class FileAttachmentsController < V1::BaseController
      # Nested under items, projects, or build_log_entries; the route supplies exactly one
      # of :item_id / :project_id / :build_log_entry_id.
      PARENTS = {
        item_id: :maker_items,
        project_id: :maker_projects,
        build_log_entry_id: :maker_build_log_entries
      }.freeze

      def create
        parent = resolve_parent
        att = parent.file_attachments.new(attachment_params.merge(user: current_user))
        att.save!
        render json: attachment_json(att), status: :created
      end

      def destroy
        current_user.maker_file_attachments.find(params[:id]).destroy!
        head :no_content
      end

      private

      def resolve_parent
        key = PARENTS.keys.find { |k| params[k].present? }
        raise ActiveRecord::RecordNotFound, "no parent" unless key
        current_user.public_send(PARENTS[key]).find(params[key])
      end

      def attachment_params
        params.require(:file_attachment).permit(:node_id, :version_id, :role, :label, :position)
      end

      def attachment_json(att)
        { id: att.id, node_id: att.node_id, version_id: att.version_id,
          role: att.role, label: att.label, position: att.position }
      end
    end
  end
end
```
(`maker_build_log_entries` is the `has_many` added to `User` in Task 2; `maker_projects` is from Task 1. The Library pillar's `file_attachments_test.rb` still passes — its `item_id`-nested calls resolve via `PARENTS[:item_id]` exactly as before.)

- [ ] **Step 6: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/build_log_entries_test.rb test/integration/v1/maker/file_attachments_test.rb`
Expected: PASS (the new build-log + project-attachment cases AND the pre-existing item-attachment cases — confirms the generalization didn't break Library).

- [ ] **Step 7: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/build_log_entries_controller.rb \
        app/controllers/v1/maker/file_attachments_controller.rb \
        test/integration/v1/maker/build_log_entries_test.rb
git commit -m "feat(maker): build log entries + project file attachments"
```

---

## Task 6: Project-owned tasks via the existing tasks API

**Files:**
- Test: `test/integration/v1/maker/project_tasks_test.rb`

No controller change is needed — the existing `Maker::TasksController` (Library pillar) already accepts `taskable_type` / `taskable_id` params, and Task 3 made `Maker::Project` a valid, ownership-validated owner. This task documents + tests that a task can be owned by a project through the existing API.

- [ ] **Step 1: Write the integration test**

Create `test/integration/v1/maker/project_tasks_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class ProjectTasksTest < ActionDispatch::IntegrationTest
      def register(email = "pt@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project_id = JSON.parse(response.body)["id"]
      end

      test "create a task owned by a project" do
        post "/v1/maker/tasks",
             params: { task: { title: "Wire the LEDs", taskable_type: "Maker::Project",
                               taskable_id: @project_id } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Maker::Project", body["taskable_type"]
        assert_equal @project_id, body["taskable_id"]
      end

      test "cannot own a task with another user's project" do
        other = register("other-pt@example.com")
        post "/v1/maker/projects", params: { project: { name: "Theirs" } }, as: :json, headers: auth(other)
        their_project = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks",
             params: { task: { title: "Sneaky", taskable_type: "Maker::Project",
                               taskable_id: their_project } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "an unknown taskable_type is rejected" do
        post "/v1/maker/tasks",
             params: { task: { title: "x", taskable_type: "Maker::Bogus", taskable_id: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/project_tasks_test.rb`
Expected: PASS (3 runs, 0 failures). (The ownership + allow-list validations from Task 3 surface as 422 via the `RecordInvalid` rescue in `BaseController`.)

- [ ] **Step 3: Commit**

```bash
git add test/integration/v1/maker/project_tasks_test.rb
git commit -m "test(maker): tasks can be owned by a project via the tasks API"
```

---

## Task 7: Full-suite green + tenant-isolation sweep

**Files:**
- Test: `test/integration/v1/maker/projects_isolation_test.rb`

- [ ] **Step 1: Write a focused cross-user isolation test**

Create `test/integration/v1/maker/projects_isolation_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every project resource must 404 (never leak) across users.
    class ProjectsIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-piso@example.com")
        @b = register("b-piso@example.com")
        post "/v1/maker/projects", params: { project: { name: "A's project" } }, as: :json, headers: auth(@a)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "A's log" } }, as: :json, headers: auth(@a)
        @entry = JSON.parse(response.body)["id"]
      end

      test "B cannot read, update, or delete A's project or its children" do
        get    "/v1/maker/projects/#{@project}", headers: auth(@b);                          assert_response :not_found
        patch  "/v1/maker/projects/#{@project}", params: { project: { name: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/projects/#{@project}", headers: auth(@b);                          assert_response :not_found
        get    "/v1/maker/projects/#{@project}/build_log_entries", headers: auth(@b);        assert_response :not_found
        delete "/v1/maker/build_log_entries/#{@entry}", headers: auth(@b);                   assert_response :not_found
        post   "/v1/maker/projects/#{@project}/file_attachments",
               params: { file_attachment: { node_id: "n" } }, as: :json, headers: auth(@b)
        assert_response :not_found
      end

      test "B's project index is empty" do
        get "/v1/maker/projects", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["projects"]
      end
    end
  end
end
```

- [ ] **Step 2: Run the new test**

Run: `bin/rails test test/integration/v1/maker/projects_isolation_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 3: Run the entire suite**

Run: `bin/rails test`
Expected: PASS — all Projects tests plus the pre-existing Library + server tests green, 0 failures, 0 errors.

- [ ] **Step 4: Commit**

```bash
git add test/integration/v1/maker/projects_isolation_test.rb
git commit -m "test(maker): cross-user isolation sweep for the projects API"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** `maker_projects` with name/slug(unique per user)/description/status(planning/active/paused/done/archived)/archived_at (Task 1); `maker_build_log_entries` with project_id/body/entry_type(note/milestone)/logged_at (Task 2); Project added to `Maker::Task::TASKABLE_TYPES` + ownership validation extended (Task 3); projects CRUD (Task 4); nested build_log_entries CRUD + **reused** polymorphic `Maker::FileAttachment` for Project + BuildLogEntry, no new attachment table (Task 5); a task gets a project owner via `taskable_type`/`taskable_id` (Task 6); tenant isolation (Task 7). ✓
- **No new attachment table:** `has_many :file_attachments, as: :attachable` added to both `Maker::Project` (Task 1) and `Maker::BuildLogEntry` (Task 2); the existing `Maker::FileAttachment` and its controller are reused (the controller generalized to resolve any of the three parents in Task 5). ✓
- **Migration numbering:** continues the Library sequence at `20260615000008`–`20260615000009` (Library ended at `0007`), contiguous. ✓
- **Type consistency:** `Project.by_status` scope (Task 1) drives the index filter (Task 4); `build_log_entries` association declared in Task 1 is populated in Task 2; the `TASKABLE_TYPES` allow-list (Task 3) gates both the model (Task 3) and the API (Task 6); JSON key names (`build_log_entries`, `file_attachments`, `taskable_type`, `taskable_id`) are consistent across model/controller/test. ✓
- **Adapter-agnostic:** no DB FK constraints, explicit `add_index`, `user_id` integer scoping; slug derivation is pure Ruby (no DB function); no PG-only SQL. ✓
- **Placeholder scan:** every step ships complete code, exact paths, exact commands, and expected output — no `TODO`/`add validation`/`...` stubs. ✓

---

## Out of scope (follow-on plans)

- **Inventory pillar** (`docs/superpowers/plans/2026-06-15-inventory-pillar-server.md`) — locations, suppliers, inventory items, and the immutable transaction ledger. Independent of this pillar.
- **BOM pillar** (`docs/superpowers/plans/2026-06-15-bom-pillar-server.md`) — depends on **this** pillar's `maker_projects` (a BOM belongs to a project) AND the Inventory pillar's `maker_inventory_items`.
- **Tauri client + web UI** for projects (browse/detail/build-log/task surfaces) — mirrors the Library client groundwork in `client/maker-app`.
