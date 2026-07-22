# Local 3D-Print Model Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "model library" — import a downloaded 3D-print bundle (a `.zip` of model files + an instructions PDF + a cover image) into one organized `Maker::Model` entry you can browse, tag, and track prints against.

**Architecture:** Two new user-scoped tables (`maker_models`, `maker_print_runs`); everything else is reused — the polymorphic `Maker::FileAttachment` (roles) and `Maker::Tagging`, `Maker::LibraryFolder`, the `Maker::Previews` thumbnail system, and the existing per-backend upload paths. The import runs client-side (browser unzips with JSZip, then uploads each file through the *existing* two-phase-presigned (chunk) or multipart (share/s3) flow, so **§15 stays intact and §10 is never touched**). Models is a curated view over library nodes living at `Models/<slug>/`.

**Tech Stack:** Rails 8, Minitest, Hotwire/Stimulus, importmap (vendored JSZip), the existing `FileLayer` port + `LibraryCapabilities` concern.

**Spec:** `docs/superpowers/specs/2026-07-22-local-3d-print-model-library-design.md`

---

## File Structure

**Create**
- `db/migrate/*_create_maker_models.rb`, `db/migrate/*_create_maker_print_runs.rb`
- `app/models/maker/model.rb` — the catalog entry (slug, status, cover resolution, folder, tags helper)
- `app/models/maker/print_run.rb` — a logged print + `print_status` recompute
- `app/controllers/models_controller.rb` — index/show/new/create(JSON import)/edit/update/destroy
- `app/controllers/models/attachments_controller.rb` — attach an uploaded node (JSON) / detach (HTML)
- `app/controllers/models/print_runs_controller.rb` — create/destroy a print run
- `app/views/models/{index,new,show,edit}.html.erb` + `_card`, `_print_run`, `_print_form` partials
- `app/javascript/lib/chunk_upload.js` — the extracted two-phase chunk upload (one file → node_id)
- `app/javascript/controllers/importer_controller.js` — unzip + classify + orchestrate uploads + attach
- `app/assets/stylesheets/models.css` — model status badges + detail layout
- Tests: `test/models/maker/model_test.rb`, `test/models/maker/print_run_test.rb`, `test/integration/web/models_flow_test.rb`, `test/integration/web/models_import_test.rb`, `test/integration/web/print_runs_test.rb`

**Modify**
- `app/models/user.rb` — `has_many :maker_models`, `:maker_print_runs`
- `config/routes.rb` — `resources :models` + nested attachments/print_runs
- `config/importmap.rb` — pin `jszip` + `lib/chunk_upload`
- `app/views/layouts/application.html.erb` — "Models" nav link + `models` stylesheet tag
- `app/javascript/controllers/uploader_controller.js` — use the extracted `chunk_upload` helper

**Testing reality (read before Task 6):** this repo has **no JS unit runner and no system tests** (`test/system/` is empty). So the browser unzip/orchestration in `importer_controller.js` is verified by a **manual smoke test** (Task 6). Everything it calls on the server — model create + folder-map, attach + role derivation + cover, and the upload endpoints themselves (`test/integration/web/files_flow_test.rb`, already present) — **is** covered by Minitest. Task 5's `models_import_test.rb` drives the exact server sequence the JS makes.

---

## Task 1: `Maker::Model` — table, model, associations

**Files:**
- Create: `db/migrate/*_create_maker_models.rb`, `app/models/maker/model.rb`, `test/models/maker/model_test.rb`
- Modify: `app/models/user.rb`

- [ ] **Step 1: Write the failing model test**

Create `test/models/maker/model_test.rb`:

```ruby
require "test_helper"

module Maker
  class ModelTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "model-#{SecureRandom.hex(4)}@example.com") }

    test "valid with a title" do
      assert @user.maker_models.build(title: "Articulated Dragon").valid?
    end

    test "title is required" do
      m = @user.maker_models.build(title: nil)
      assert_not m.valid?
      assert_includes m.errors[:title], "can't be blank"
    end

    test "slug is auto-generated from the title" do
      m = @user.maker_models.create!(title: "Articulated Dragon v2!")
      assert_equal "articulated-dragon-v2", m.slug
    end

    test "slug disambiguates on collision instead of failing" do
      first  = @user.maker_models.create!(title: "Benchy")
      second = @user.maker_models.create!(title: "Benchy")
      assert_equal "benchy", first.slug
      assert_equal "benchy-2", second.slug
    end

    test "same slug allowed for a different user" do
      @user.maker_models.create!(title: "Benchy")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      assert_equal "benchy", other.maker_models.create!(title: "Benchy").slug
    end

    test "print_status defaults to want_to_print and is validated" do
      m = @user.maker_models.create!(title: "x")
      assert_equal "want_to_print", m.print_status
      assert_not @user.maker_models.build(title: "y", print_status: "bogus").valid?
    end

    test "to_param is the slug" do
      m = @user.maker_models.create!(title: "Cool Thing")
      assert_equal "cool-thing", m.to_param
    end

    test "destroyed with the user" do
      @user.maker_models.create!(title: "x")
      assert_difference "Maker::Model.count", -1 do
        @user.destroy!
      end
    end
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `bin/rails test test/models/maker/model_test.rb`
Expected: FAIL — `uninitialized constant Maker::Model` / no `maker_models` association.

- [ ] **Step 3: Create the migration**

Run: `bin/rails generate migration CreateMakerModels`

Replace the generated file's body with:

```ruby
class CreateMakerModels < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_models do |t|
      t.integer :user_id,        null: false
      t.string  :title,          null: false
      t.string  :slug,           null: false
      t.string  :source_url
      t.string  :designer
      t.string  :license
      t.string  :print_status,   null: false, default: "want_to_print"
      t.text    :notes
      t.string  :folder_node_id
      t.string  :cover_node_id
      t.timestamps
    end
    add_index :maker_models, [ :user_id, :slug ], unique: true
    add_index :maker_models, [ :user_id, :print_status ]
  end
end
```

- [ ] **Step 4: Create the model**

Create `app/models/maker/model.rb`:

```ruby
module Maker
  # A 3D-print model in the catalog: a cover, metadata, its files (via the polymorphic
  # FileAttachment), tags, and a print log. Distinct from Maker::Project (a build). Its files
  # live at Models/<slug>/ in the ordinary file library — this record is a curated view over
  # them, so nothing here touches sync/changelog/mounts (§10).
  class Model < ApplicationRecord
    self.table_name = "maker_models"

    PRINT_STATUSES = %w[want_to_print printed failed].freeze

    belongs_to :user

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"
    has_many :print_runs, -> { order(:printed_on, :id) },
             class_name: "Maker::PrintRun", dependent: :destroy

    before_validation :ensure_slug

    validates :title, presence: true
    validates :slug, presence: true, uniqueness: { scope: :user_id }
    validates :print_status, inclusion: { in: PRINT_STATUSES }

    scope :by_status, ->(s) { where(print_status: s) if s.present? }

    def to_param = slug

    # Friendly URLs + collision-proof: two "Benchy" imports must both succeed, so a taken slug
    # gets -2, -3, ... (Project fails validation on collision; import can't afford that).
    def ensure_slug
      base = (slug.presence || title).to_s.strip.downcase
               .gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      return if base.blank?
      candidate = base
      n = 2
      while user && user.maker_models.where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{n}"
        n += 1
      end
      self.slug = candidate
    end
  end
end
```

- [ ] **Step 5: Add the User associations**

In `app/models/user.rb`, after the `has_many :maker_notes` line (27), add:

```ruby
  has_many :maker_models, class_name: "Maker::Model", dependent: :destroy
  has_many :maker_print_runs, through: :maker_models, source: :print_runs
```

- [ ] **Step 6: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/model_test.rb`
Expected: PASS (7 runs, 0 failures). (`cover_node_id`/folder helpers come in later tasks — these tests don't touch them.)

- [ ] **Step 7: Commit**

```bash
git add db/migrate app/models/maker/model.rb app/models/user.rb db/schema.rb test/models/maker/model_test.rb
git commit -m "feat(models): Maker::Model — table, slug disambiguation, associations"
```

---

## Task 2: `Maker::PrintRun` — table, model, auto-status recompute

**Files:**
- Create: `db/migrate/*_create_maker_print_runs.rb`, `app/models/maker/print_run.rb`, `test/models/maker/print_run_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/maker/print_run_test.rb`:

```ruby
require "test_helper"

module Maker
  class PrintRunTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pr-#{SecureRandom.hex(4)}@example.com")
      @model = @user.maker_models.create!(title: "Dragon")
    end

    test "requires outcome in the allowed set" do
      assert_not @model.print_runs.build(printed_on: Date.today, outcome: "meh").valid?
      assert @model.print_runs.build(printed_on: Date.today, outcome: "success").valid?
    end

    test "a success run flips the model to printed" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "success", printer: "MK4")
      assert_equal "printed", @model.reload.print_status
    end

    test "a failed run flips the model to failed" do
      @model.print_runs.create!(printed_on: Date.today, outcome: "failed")
      assert_equal "failed", @model.reload.print_status
    end

    test "the most recent run wins" do
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 20), outcome: "failed")
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success")
      assert_equal "printed", @model.reload.print_status
    end

    test "destroying the latest run recomputes from what remains" do
      @model.print_runs.create!(printed_on: Date.new(2026, 7, 20), outcome: "success")
      latest = @model.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "failed")
      assert_equal "failed", @model.reload.print_status
      latest.destroy!
      assert_equal "printed", @model.reload.print_status
    end

    test "removing the last run leaves the status untouched" do
      @model.update!(print_status: "want_to_print")
      run = @model.print_runs.create!(printed_on: Date.today, outcome: "success")
      assert_equal "printed", @model.reload.print_status
      run.destroy!
      assert_equal "printed", @model.reload.print_status # NOT reset to want_to_print
    end
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `bin/rails test test/models/maker/print_run_test.rb`
Expected: FAIL — `uninitialized constant Maker::PrintRun`.

- [ ] **Step 3: Migration**

Run: `bin/rails generate migration CreateMakerPrintRuns`

Body:

```ruby
class CreateMakerPrintRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_print_runs do |t|
      t.integer :user_id,        null: false
      t.integer :model_id,       null: false
      t.date    :printed_on,     null: false
      t.string  :printer
      t.string  :material
      t.string  :outcome,        null: false
      t.decimal :duration_hours, precision: 6, scale: 2
      t.integer :filament_grams
      t.text    :notes
      t.timestamps
    end
    add_index :maker_print_runs, [ :model_id, :printed_on ]
    add_index :maker_print_runs, :user_id
  end
end
```

- [ ] **Step 4: Model**

Create `app/models/maker/print_run.rb`:

```ruby
module Maker
  # One logged print of a Model. On every save/destroy it recomputes the parent model's
  # print_status from the MOST RECENT run (latest printed_on, tie-break id): success -> printed,
  # failed -> failed. If no runs remain, the status is left untouched (never reset) — it may have
  # been set manually. The pill stays manually editable, so this is a convenience default.
  class PrintRun < ApplicationRecord
    self.table_name = "maker_print_runs"

    OUTCOMES = %w[success failed].freeze

    belongs_to :user
    belongs_to :model, class_name: "Maker::Model"

    before_validation { self.user ||= model&.user }

    validates :printed_on, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }

    after_save    :sync_model_status
    after_destroy :sync_model_status

    private

    def sync_model_status
      latest = Maker::PrintRun.where(model_id: model_id).order(:printed_on, :id).last
      return unless latest
      model.update_column(:print_status, latest.outcome == "success" ? "printed" : "failed")
    end
  end
end
```

- [ ] **Step 5: Migrate + run**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/print_run_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add db/migrate app/models/maker/print_run.rb db/schema.rb test/models/maker/print_run_test.rb
git commit -m "feat(models): Maker::PrintRun — print log + latest-run-wins status recompute"
```

---

## Task 3: Cover resolution + tag-list helper on `Maker::Model`

**Files:**
- Modify: `app/models/maker/model.rb`, `test/models/maker/model_test.rb`

- [ ] **Step 1: Add the failing tests**

Append inside `Maker::ModelTest` (before the final `end`):

```ruby
    test "cover_node_id prefers an explicit override, then image, then model, else nil" do
      m = @user.maker_models.create!(title: "Lamp")
      assert_nil m.cover_node_id

      m.file_attachments.create!(user: @user, node_id: "mdl", role: "model", position: 0)
      m.file_attachments.create!(user: @user, node_id: "img", role: "image", position: 1)
      assert_equal "img", m.reload.cover_node_id, "image wins over model"

      m.update!(cover_node_id: "mdl")
      assert_equal "mdl", m.reload.cover_node_id, "explicit override wins over image"
    end

    test "cover falls back to the first model file when there is no image" do
      m = @user.maker_models.create!(title: "Gear")
      m.file_attachments.create!(user: @user, node_id: "src", role: "source_archive", position: 0)
      m.file_attachments.create!(user: @user, node_id: "g1", role: "model", position: 1)
      assert_equal "g1", m.reload.cover_node_id
    end

    test "tag_list reads and writes tags, normalized and de-duped" do
      m = @user.maker_models.create!(title: "Dragon")
      m.tag_list = "Dragon, articulated ,, dragon"
      m.save!
      assert_equal %w[articulated dragon], m.reload.tag_list.split(", ").sort
      assert_equal 2, @user.maker_tags.count
    end
```

- [ ] **Step 2: Run, expect failure**

Run: `bin/rails test test/models/maker/model_test.rb`
Expected: FAIL — `cover_node_id` returns nil (no override logic) / `tag_list` undefined.

- [ ] **Step 3: Implement**

In `app/models/maker/model.rb`, add these methods (inside the class, after `ensure_slug`):

```ruby
    # The node whose thumbnail/image represents this model: explicit override, else first image,
    # else first model file (its rendered 3D thumbnail via Maker::Previews), else nil. Overrides
    # the AR attribute reader; self[:cover_node_id] reads the raw column.
    def cover_node_id
      self[:cover_node_id].presence || derived_cover_node_id
    end

    # Comma-separated tag names, for the edit form. Writing find-or-creates the user's tags and
    # replaces the set (Maker::Tag normalizes name to stripped-downcase and is unique per user).
    def tag_list
      tags.map(&:name).sort.join(", ")
    end

    def tag_list=(str)
      names = str.to_s.split(",").map { |n| n.strip.downcase }.reject(&:blank?).uniq
      self.tags = names.map { |n| user.maker_tags.find_or_create_by!(name: n) }
    end

    private

    def derived_cover_node_id
      atts = file_attachments.sort_by { |a| [ a.position, a.id ] }
      pick = atts.find { |a| a.role == "image" } ||
             atts.find { |a| a.role == "model" } ||
             atts.first
      pick&.node_id
    end
```

Move the existing `ensure_slug` above the new `private` if it isn't already public-then-private — `ensure_slug` is called from `before_validation` so it may be private; keep it private alongside `derived_cover_node_id`. (Both under `private` is fine.)

- [ ] **Step 4: Run, expect pass**

Run: `bin/rails test test/models/maker/model_test.rb`
Expected: PASS (11 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add app/models/maker/model.rb test/models/maker/model_test.rb
git commit -m "feat(models): cover resolution (override->image->model) + tag_list helper"
```

---

## Task 4: `ensure_library_folder!` + routes + nav + stylesheet

**Files:**
- Modify: `app/models/maker/model.rb`, `config/routes.rb`, `app/views/layouts/application.html.erb`, `test/models/maker/model_test.rb`
- Create: `app/assets/stylesheets/models.css`

- [ ] **Step 1: Failing test for the folder helper**

Append inside `Maker::ModelTest`:

```ruby
    test "ensure_library_folder! creates Models/<slug> and stores its node_id" do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      m = @user.maker_models.create!(title: "Desk Dragon")
      folder = m.ensure_library_folder!(@user)
      assert_equal m.folder_node_id, folder.node_id
      assert_equal "dir", folder.kind
      assert_equal "desk-dragon", folder.name
      assert_equal "Models", @user.nodes.find_by!(node_id: folder.parent_node_id).name
    end
```

`pin_file_layer_backend` is defined in `test/test_helper.rb:52` and is available to `ActiveSupport::TestCase`.

- [ ] **Step 2: Run, expect failure**

Run: `bin/rails test test/models/maker/model_test.rb -n /ensure_library_folder/`
Expected: FAIL — `undefined method 'ensure_library_folder!'`.

- [ ] **Step 3: Implement the helper** (mirrors `Maker::Project#ensure_library_folder!`)

In `app/models/maker/model.rb`, add (public, before `private`):

```ruby
    # Return the model's library folder node, (re)creating Models/<slug> if folder_node_id is nil
    # or points at a deleted/missing node. Idempotent (Maker::LibraryFolder.ensure_path! is).
    def ensure_library_folder!(acting_user)
      if folder_node_id.present?
        live = acting_user.nodes.present.find_by(node_id: folder_node_id, kind: "dir")
        return live if live
      end
      folder = Maker::LibraryFolder.ensure_path!(acting_user, [ "Models", slug ])
      update_column(:folder_node_id, folder.node_id)
      folder
    end
```

- [ ] **Step 4: Run, expect pass**

Run: `bin/rails test test/models/maker/model_test.rb -n /ensure_library_folder/`
Expected: PASS.

- [ ] **Step 5: Add routes**

In `config/routes.rb`, after the Projects block (after line 63's `end`, before the Addons/Tools comment on line 72), add:

```ruby
  # --- Maker: Models (3D-print model library; server-rendered web UI, session auth) ---
  # A curated view over library files at Models/<slug>/. `create` is the JSON import endpoint the
  # importer Stimulus controller calls; there is no plain-HTML create (import IS the new flow).
  resources :models do
    resources :attachments, only: %i[create destroy], module: :models, shallow: true
    resources :print_runs, only: %i[create destroy], module: :models, shallow: true
  end
```

- [ ] **Step 6: Add the nav link + stylesheet tag**

In `app/views/layouts/application.html.erb`, line 33-35, add "Models" after Files:

```erb
          <%= link_to "Files", files_path, class: "linkbtn" %>
          <%= link_to "Models", models_path, class: "linkbtn" %>
          <%= link_to "Projects", projects_path, class: "linkbtn" %>
          <%= link_to "Tools", tools_path, class: "linkbtn" %>
```

And after the `notes` stylesheet tag (line 24), add:

```erb
    <%= stylesheet_link_tag "models", "data-turbo-track": "reload" %>
```

- [ ] **Step 7: Create the stylesheet**

Create `app/assets/stylesheets/models.css`:

```css
/* Model library — reuses .badge / .projects-grid / .project-card from projects.css. */
.badge.mstatus-want_to_print { background: #eff6ff; color: #1e40af; }
.badge.mstatus-printed       { background: #ecfdf5; color: #065f46; }
.badge.mstatus-failed        { background: #fef2f2; color: #991b1b; }

.models-toolbar { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin: 12px 0 18px; }
.models-toolbar .filter.active { font-weight: 600; text-decoration: underline; }
.models-toolbar input[type="search"] { flex: 1; min-width: 160px; }

.model-detail { display: flex; gap: 24px; align-items: flex-start; flex-wrap: wrap; }
.model-detail .cover-col { flex: 0 0 320px; }
.model-detail .files-col { flex: 1; min-width: 280px; }
.model-cover img, .model-cover .thumb { width: 100%; border-radius: 8px; }
.file-role-group { margin-bottom: 18px; }
.preview-pdf { width: 100%; height: 420px; border: 0; }
.image-gallery { display: flex; gap: 8px; flex-wrap: wrap; }
.image-gallery img { width: 90px; height: 72px; object-fit: cover; border-radius: 6px; }

.print-log .print-run { padding: 8px 0; border-bottom: 1px solid #eee; font-size: 14px; }
.print-form { display: grid; gap: 8px; max-width: 480px; }
.print-form .row { display: flex; gap: 10px; }
```

- [ ] **Step 8: Commit**

```bash
git add app/models/maker/model.rb config/routes.rb app/views/layouts/application.html.erb app/assets/stylesheets/models.css test/models/maker/model_test.rb
git commit -m "feat(models): Models/<slug> folder helper + routes + nav + styles"
```

---

## Task 5: `ModelsController` + attachments — index/show/edit/update/destroy + import (create) + attach

**Files:**
- Create: `app/controllers/models_controller.rb`, `app/controllers/models/attachments_controller.rb`, `test/integration/web/models_flow_test.rb`, `test/integration/web/models_import_test.rb`
- Create (views used by tests): `app/views/models/index.html.erb`, `app/views/models/show.html.erb`, `app/views/models/new.html.erb`, `app/views/models/edit.html.erb`, `app/views/models/_card.html.erb`

- [ ] **Step 1: Write the failing flow test**

Create `test/integration/web/models_flow_test.rb`:

```ruby
require "test_helper"

module Web
  class ModelsFlowTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Views READ file metadata + capabilities through FileLayer.current; pin a real backend so a
    # LIBRARY_BACKEND=share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "requires login" do
      get models_path
      assert_redirected_to new_user_session_path
    end

    test "index lists the user's models with an empty state otherwise" do
      user = sign_in
      get models_path
      assert_response :success
      assert_select "h1", "Models"
      assert_select ".models-empty"

      user.maker_models.create!(title: "Dragon", print_status: "printed")
      get models_path
      assert_select ".model-card .model-name", text: "Dragon"
      assert_select ".model-card .badge.mstatus-printed"
    end

    test "index shows only the current user's models" do
      sign_in("a@example.com").maker_models.create!(title: "Mine")
      User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
          .maker_models.create!(title: "Theirs")
      get models_path
      assert_select ".model-name", text: "Mine"
      assert_select ".model-name", text: "Theirs", count: 0
    end

    test "index filters by status and searches by title" do
      user = sign_in
      user.maker_models.create!(title: "Printed Dragon", print_status: "printed")
      user.maker_models.create!(title: "Wanted Gear", print_status: "want_to_print")
      get models_path(status: "printed")
      assert_select ".model-name", text: "Printed Dragon"
      assert_select ".model-name", text: "Wanted Gear", count: 0
      get models_path(q: "gear")
      assert_select ".model-name", text: "Wanted Gear"
      assert_select ".model-name", text: "Printed Dragon", count: 0
    end

    test "show renders title, status pill, metadata, and grouped files" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon", designer: "cults", license: "CC BY",
                                    source_url: "https://printables.com/model/1", print_status: "printed")
      user.nodes.create!(node_id: "mdl1", name: "body.stl", kind: "file")
      m.file_attachments.create!(user:, node_id: "mdl1", role: "model")
      get model_path(m)
      assert_response :success
      assert_select "h1", text: /Dragon/
      assert_select ".badge.mstatus-printed"
      assert_select ".file-role-group", text: /body\.stl/
      assert_select "a[href=?]", "https://printables.com/model/1"
    end

    test "show 404s for another user's model" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      m = other.maker_models.create!(title: "Theirs")
      get model_path(m)
      assert_response :not_found
    end

    test "edit + update changes metadata, status, and tags" do
      user = sign_in
      m = user.maker_models.create!(title: "Old")
      get edit_model_path(m)
      assert_response :success
      patch model_path(m), params: { model: { title: "New", designer: "me",
                                              print_status: "failed", tag_list: "dragon, toy" } }
      m.reload
      assert_equal "New", m.title
      assert_equal "failed", m.print_status
      assert_equal %w[dragon toy], m.tag_list.split(", ").sort
      assert_redirected_to model_path(m)
    end

    test "destroy removes the model record but leaves library files" do
      user = sign_in
      m = user.maker_models.create!(title: "Doomed")
      user.nodes.create!(node_id: "keep1", name: "keep.stl", kind: "file")
      m.file_attachments.create!(user:, node_id: "keep1", role: "model")
      assert_difference "Maker::Model.count", -1 do
        delete model_path(m)
      end
      assert_redirected_to models_path
      assert user.nodes.exists?(node_id: "keep1"), "the library file must survive deleting the model"
    end
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `bin/rails test test/integration/web/models_flow_test.rb`
Expected: FAIL — no `ModelsController` / no routes render.

- [ ] **Step 3: Create the controller**

Create `app/controllers/models_controller.rb`:

```ruby
# Server-rendered web UI for the 3D-print model library. Session auth (NOT the device-token v1
# API). Reads file metadata + capabilities through FileLayer.current; `create` writes FOLDERS only
# (via LibraryFolder), never bytes — the importer uploads files through the existing /files
# endpoints, so §15/§10 are untouched here.
class ModelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_model, only: %i[show edit update destroy]

  include LibraryCapabilities

  SORTS = { "recent" => { updated_at: :desc }, "title" => { title: :asc },
            "status" => { print_status: :asc, title: :asc } }.freeze

  def index
    models = current_user.maker_models.includes(:file_attachments)
    models = models.by_status(params[:status])
    if params[:q].present?
      models = models.where("title LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%")
    end
    if params[:tag].present?
      models = models.joins(:tags).where(maker_tags: { name: params[:tag].to_s.strip.downcase })
    end
    @models = models.order(SORTS.fetch(params[:sort], SORTS["recent"])).to_a
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @models.map(&:cover_node_id))
    @all_tags = current_user.maker_tags.order(:name).pluck(:name)
    @status = params[:status]
  end

  def show
    @attachments = @model.file_attachments.order(:position).to_a
    att_ids = @attachments.map(&:node_id)
    @nodes = current_user.nodes.present.where(node_id: att_ids).index_by(&:node_id)
    @by_role = @attachments.group_by(&:role)
    @covers = Maker::Previews::ThumbnailMap.for(current_user, [ @model.cover_node_id ].compact)
    @print_runs = @model.print_runs.reorder(printed_on: :desc, id: :desc).to_a
    @printers = current_user.maker_print_runs.where.not(printer: [ nil, "" ]).distinct.pluck(:printer)
    @materials = current_user.maker_print_runs.where.not(material: [ nil, "" ]).distinct.pluck(:material)
  end

  # GET /models/new — the import form (the importer Stimulus controller drives it).
  def new
    @model = current_user.maker_models.new
  end

  # POST /models (JSON only) — import step 1: create the record + ensure Models/<slug> and every
  # requested subfolder, returning a folder map the browser uploads each file into.
  def create
    @model = current_user.maker_models.new(title: params.require(:title), source_url: params[:source_url])
    @model.save!
    render json: {
      slug: @model.slug,
      model_url: model_path(@model),
      attach_url: model_attachments_path(@model),
      port_writable: capabilities.port_writable?,
      folder_map: ensure_folders(@model, Array(params[:dirs]))
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def edit; end

  def update
    if @model.update(model_params)
      redirect_to model_path(@model), notice: "Model updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Delete the CATALOG ENTRY (record + attachments + print runs). The library files at
  # Models/<slug>/ are deliberately left intact — same stance as archiving a Project.
  def destroy
    @model.destroy!
    redirect_to models_path, notice: "Deleted #{@model.title}."
  end

  # An unmounted NAS / bucket blip while ensuring folders: 503, not a 500 or a fake "gone".
  rescue_from FileLayer::FetchError do
    respond_to do |format|
      format.html { redirect_to models_path, alert: "Couldn't reach your library. Try again." }
      format.any  { render json: { error: "fetch_error" }, status: :service_unavailable }
    end
  end

  private

  def set_model
    @model = current_user.maker_models.find_by!(slug: params[:id])
  end

  def model_params
    params.require(:model).permit(:title, :source_url, :designer, :license, :notes, :print_status, :tag_list)
  end

  # { "" => <Models/slug node>, "sub/dir" => <node>, ... }. Always includes the model root.
  def ensure_folders(model, dirs)
    root = model.ensure_library_folder!(current_user)
    map = { "" => root.node_id }
    dirs.reject(&:blank?).uniq.each do |rel|
      segs = rel.split("/").reject(&:blank?)
      next if segs.empty?
      map[rel] = Maker::LibraryFolder.ensure_path!(current_user, [ "Models", model.slug, *segs ]).node_id
    end
    map
  end
end
```

- [ ] **Step 4: Create the attachments controller**

Create `app/controllers/models/attachments_controller.rb`:

```ruby
module Models
  # Attach an already-uploaded library node to a model (import's final step, JSON) or detach it
  # (HTML, from the detail page). Attaching is a reference (node_id + role); it never moves or
  # uploads bytes, so no capability gating and no §10 surface. Role is derived SERVER-SIDE from the
  # node name (authoritative), mirroring Projects::AttachmentsController.
  class AttachmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_model, only: :create

    # POST /models/:model_id/attachments (JSON) { node_id, cover? }
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      return render(json: { error: "not_found" }, status: :not_found) unless node
      att = @model.file_attachments.create!(user: current_user, node_id: node.node_id,
                                            role: Maker::FileAttachment.role_for(node.name))
      @model.update!(cover_node_id: node.node_id) if ActiveModel::Type::Boolean.new.cast(params[:cover])
      render json: { id: att.id, node_id: att.node_id, role: att.role }, status: :created
    end

    # DELETE /attachments/:id (shallow) — remove the reference only; the library file is untouched.
    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      model = att.attachable
      att.destroy!
      redirect_back_or_to model_path(model), notice: "Removed from model."
    end

    private

    def set_model
      @model = current_user.maker_models.find_by!(slug: params[:model_id])
    end
  end
end
```

- [ ] **Step 5: Create the views**

`app/views/models/index.html.erb`:

```erb
<% content_for :title, "Models — Tinkerex" %>

<div class="page-head">
  <h1>Models</h1>
  <%= link_to "Import model", new_model_path, class: "btn primary" %>
</div>

<form class="models-toolbar" method="get" action="<%= models_path %>">
  <input type="search" name="q" value="<%= params[:q] %>" placeholder="Search models…">
  <% [["", "All"], %w[want_to_print Wanted], %w[printed Printed], %w[failed Failed]].each do |val, label| %>
    <%= link_to label, models_path(status: val.presence, q: params[:q]),
                class: "filter#{' active' if @status.to_s == val}" %>
  <% end %>
  <% if @all_tags.any? %>
    <select name="tag" onchange="this.form.requestSubmit()">
      <option value="">All tags</option>
      <% @all_tags.each do |t| %><option value="<%= t %>" <%= "selected" if params[:tag] == t %>><%= t %></option><% end %>
    </select>
  <% end %>
  <select name="sort" onchange="this.form.requestSubmit()">
    <% [%w[recent Recent], %w[title Title], %w[status Status]].each do |val, label| %>
      <option value="<%= val %>" <%= "selected" if params[:sort] == val %>><%= label %></option>
    <% end %>
  </select>
</form>

<% if @models.empty? %>
  <p class="models-empty muted">No models yet. Import your first one.</p>
<% else %>
  <div class="projects-grid" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <% @models.each do |model| %>
      <%= render "card", model:, thumb: @covers.thumb(model.cover_node_id) %>
    <% end %>
  </div>
<% end %>
```

`app/views/models/_card.html.erb`:

```erb
<%= link_to model_path(model), class: "project-card model-card" do %>
  <% if model.cover_node_id %>
    <span class="thumb file-cell" data-thumbs-target="cell"
          data-node-id="<%= model.cover_node_id %>" data-ext="">
      <%= render "files/thumb", thumb:, ext_label: "" %>
    </span>
  <% else %>
    <span class="thumb project-thumb-empty" aria-hidden="true">🧊</span>
  <% end %>
  <span class="project-name model-name"><%= model.title %></span>
  <span class="badge mstatus-<%= model.print_status %>"><%= model.print_status.tr("_", " ") %></span>
<% end %>
```

`app/views/models/show.html.erb`:

```erb
<% content_for :title, "#{@model.title} — Tinkerex" %>

<nav class="breadcrumb" aria-label="Model path">
  <%= link_to "Models", models_path %>
  <span class="sep" aria-hidden="true">/</span>
  <span aria-current="page"><%= @model.title %></span>
</nav>

<div class="page-head">
  <div>
    <h1><%= @model.title %></h1>
    <span class="badge mstatus-<%= @model.print_status %>"><%= @model.print_status.tr("_", " ") %></span>
  </div>
  <div class="head-actions">
    <%= link_to "Edit", edit_model_path(@model), class: "linkbtn" %>
    <% if @model.folder_node_id %>
      <%= link_to "Open in Files", files_path(folder: @model.folder_node_id), class: "linkbtn" %>
    <% end %>
    <%= button_to "Delete", model_path(@model), method: :delete, class: "linkbtn danger",
                  form: { data: { turbo_confirm: "Delete #{@model.title}? (files are kept)" } } %>
  </div>
</div>

<div class="model-detail">
  <div class="cover-col">
    <div class="model-cover">
      <% if @model.cover_node_id %>
        <span class="thumb file-cell" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>"
              data-thumbs-target="cell" data-node-id="<%= @model.cover_node_id %>" data-ext="">
          <%= render "files/thumb", thumb: @covers.thumb(@model.cover_node_id), ext_label: "" %>
        </span>
      <% else %>
        <span class="thumb project-thumb-empty" aria-hidden="true">🧊</span>
      <% end %>
    </div>
    <dl class="meta">
      <% if @model.designer.present? %><dt>Designer</dt><dd><%= @model.designer %></dd><% end %>
      <% if @model.license.present? %><dt>License</dt><dd><%= @model.license %></dd><% end %>
      <% if @model.source_url.present? %>
        <dt>Source</dt><dd><%= link_to @model.source_url, @model.source_url, target: "_blank", rel: "noopener" %></dd>
      <% end %>
      <% if @model.tags.any? %><dt>Tags</dt><dd><%= @model.tag_list %></dd><% end %>
      <dt>Added</dt><dd><%= @model.created_at.strftime("%Y-%m-%d") %></dd>
    </dl>
    <% if @model.notes.present? %><div class="model-notes"><%= render_note(@model.notes) %></div><% end %>
  </div>

  <div class="files-col">
    <% { "model" => "Model files", "instructions" => "Instructions", "image" => "Images" }.each do |role, heading| %>
      <% atts = @by_role[role] %>
      <% next if atts.blank? %>
      <section class="file-role-group">
        <h2><%= heading %> <span class="muted">(<%= atts.size %>)</span></h2>
        <% if role == "instructions" %>
          <% atts.each do |a| %>
            <iframe class="preview-pdf" src="<%= blob_file_path(a.node_id) %>" title="<%= @nodes[a.node_id]&.name %>"></iframe>
          <% end %>
        <% elsif role == "image" %>
          <div class="image-gallery">
            <% atts.each do |a| %><%= image_tag blob_file_path(a.node_id), alt: @nodes[a.node_id]&.name %><% end %>
          </div>
        <% else %>
          <ul class="file-list">
            <% atts.each do |a| %>
              <li><%= link_to (@nodes[a.node_id]&.name || a.node_id), file_path(a.node_id) %></li>
            <% end %>
          </ul>
        <% end %>
      </section>
    <% end %>

    <%= render "print_log" %>
  </div>
</div>
```

> Note: `show.html.erb` renders `_print_log`, added in Task 7. Add a temporary empty partial now so the show test passes: create `app/views/models/_print_log.html.erb` containing only `<%# print log — Task 7 %>`.

`app/views/models/edit.html.erb`:

```erb
<% content_for :title, "Edit #{@model.title} — Tinkerex" %>
<div class="page-head"><h1>Edit <%= @model.title %></h1></div>

<%= form_with model: @model, scope: :model, url: model_path(@model), method: :patch, class: "project-form" do |f| %>
  <% if @model.errors.any? %>
    <div class="form-errors flash-alert"><%= @model.errors.full_messages.to_sentence %></div>
  <% end %>
  <label class="field"><span>Title</span><%= f.text_field :title, required: true %></label>
  <label class="field"><span>Designer</span><%= f.text_field :designer %></label>
  <label class="field"><span>License</span><%= f.text_field :license %></label>
  <label class="field"><span>Source URL</span><%= f.url_field :source_url %></label>
  <label class="field"><span>Tags (comma-separated)</span><%= f.text_field :tag_list, value: @model.tag_list %></label>
  <label class="field"><span>Status</span>
    <%= f.select :print_status, Maker::Model::PRINT_STATUSES.map { |s| [ s.tr("_", " ").capitalize, s ] } %>
  </label>
  <label class="field"><span>Notes</span><%= f.text_area :notes, rows: 5, placeholder: "Markdown supported…" %></label>
  <div class="form-actions">
    <%= f.submit "Save changes", class: "btn primary" %>
    <%= link_to "Cancel", model_path(@model), class: "linkbtn" %>
  </div>
<% end %>
```

`app/views/models/new.html.erb` (import form — the JS wiring lands in Task 6; this shell makes `new` render):

```erb
<% content_for :title, "Import model — Tinkerex" %>
<div class="page-head"><h1>Import model</h1></div>
<p class="muted">Import wiring is added in Task 6.</p>
```

- [ ] **Step 6: Run the flow test, expect pass**

Run: `bin/rails test test/integration/web/models_flow_test.rb`
Expected: PASS (9 runs, 0 failures).

- [ ] **Step 7: Write the import-sequence test** (drives the exact server calls the JS makes)

Create `test/integration/web/models_import_test.rb`:

```ruby
require "test_helper"

module Web
  # Exercises the SERVER side of the import sequence the importer Stimulus controller drives:
  #   POST /models (create + folder map)  ->  [browser uploads each file via /files/*]  ->
  #   POST /models/:slug/attachments (attach uploaded node, role derived, cover set).
  # The actual in-browser unzip + byte upload is manual-smoke only (no JS runner); the upload
  # endpoints themselves are covered by files_flow_test. Here we simulate an already-uploaded node.
  class ModelsImportTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "create returns a folder map including requested subfolders" do
      user = sign_in
      post models_path(format: :json),
           params: { title: "Articulated Dragon", source_url: "https://printables.com/model/1",
                     dirs: [ "tail_segments" ] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "articulated-dragon", body["slug"]
      root_id = body.dig("folder_map", "")
      sub_id  = body.dig("folder_map", "tail_segments")
      assert root_id.present? && sub_id.present?
      assert_equal "tail_segments", user.nodes.find_by!(node_id: sub_id).name
      assert_equal root_id, user.nodes.find_by!(node_id: sub_id).parent_node_id
    end

    test "attach derives the role from the node name and can set the cover" do
      user = sign_in
      post models_path(format: :json), params: { title: "Dragon", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      body = JSON.parse(response.body)
      model = user.maker_models.find_by!(slug: body["slug"])
      root_id = body.dig("folder_map", "")

      # Simulate the browser having uploaded two files into the model folder.
      user.nodes.create!(node_id: "hero", name: "dragon_hero.jpg", kind: "file", parent_node_id: root_id)
      user.nodes.create!(node_id: "body", name: "body.3mf", kind: "file", parent_node_id: root_id)

      post model_attachments_path(model, format: :json),
           params: { node_id: "hero", cover: true }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :created
      assert_equal "image", JSON.parse(response.body)["role"]

      post model_attachments_path(model, format: :json), params: { node_id: "body" }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_equal "model", JSON.parse(response.body)["role"]

      model.reload
      assert_equal "hero", model.cover_node_id, "cover flag set the cover"
      assert_equal %w[body hero].sort, model.file_attachments.pluck(:node_id).sort
    end

    test "a blank title is a 422, not a 500" do
      sign_in
      post models_path(format: :json), params: { title: "", dirs: [] }.to_json,
           headers: { "CONTENT_TYPE" => "application/json" }
      assert_response :unprocessable_entity
    end
  end
end
```

- [ ] **Step 8: Run it, expect pass**

Run: `bin/rails test test/integration/web/models_import_test.rb`
Expected: PASS (3 runs, 0 failures). If create 500s on JSON parsing, confirm `params.require(:title)` reads the JSON body (Rails parses `application/json` into params automatically).

- [ ] **Step 9: Commit**

```bash
git add app/controllers/models_controller.rb app/controllers/models/attachments_controller.rb app/views/models test/integration/web/models_flow_test.rb test/integration/web/models_import_test.rb
git commit -m "feat(models): ModelsController + attachments (CRUD, JSON import + folder map, cover)"
```

---

## Task 6: The importer — JSZip + reusable chunk-upload helper + Stimulus controller + form

**Files:**
- Modify: `config/importmap.rb`, `app/javascript/controllers/uploader_controller.js`, `app/views/models/new.html.erb`
- Create: `vendor/javascript/jszip.js` (via importmap), `app/javascript/lib/chunk_upload.js`, `app/javascript/controllers/importer_controller.js`

This task has **no automated test** (no JS runner). Its server calls are already covered (Task 5). Verify with the **manual smoke** in Step 7.

- [ ] **Step 1: Vendor JSZip + pin the helper**

Run: `bin/importmap pin jszip --download`
Expected: writes `vendor/javascript/jszip.js` and adds `pin "jszip", to: "jszip.js"` to `config/importmap.rb`.

Then add to `config/importmap.rb` (after the `pin_all_from` line):

```ruby
pin "lib/chunk_upload", to: "lib/chunk_upload.js"
```

- [ ] **Step 2: Extract the chunk two-phase upload into a helper**

Create `app/javascript/lib/chunk_upload.js`:

```js
// One file -> a committed library node_id, via the two-phase presigned flow (bytes go
// browser -> storage, never through Rails; §15). Extracted from uploader_controller so the
// importer and the single-file uploader share exactly one implementation.
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}

async function postJSON(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body)
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
  return data
}

// Upload a File/Blob (with a name) into parentNodeId. Returns the new node_id.
export async function uploadChunkFile(file, { beginUrl, finalizeUrl, parentNodeId }) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const hash = await sha256Hex(bytes)
  const manifest = [{ hash, offset: 0, length: bytes.length }]
  const begin = await postJSON(beginUrl, { name: file.name, size: bytes.length, manifest, parent_node_id: parentNodeId || null })
  for (const [, url] of Object.entries(begin.put_urls || {})) {
    const res = await fetch(url, { method: "PUT", body: bytes })
    if (!res.ok) throw new Error(`chunk PUT failed (${res.status})`)
  }
  await postJSON(finalizeUrl, { commit_id: begin.commit_id })
  return begin.node_id
}

// Upload via the share/s3 multipart door (FilesController#create). Returns the new node_id.
export async function uploadPortFile(file, { createUrl, parentNodeId }) {
  const form = new FormData()
  form.append("file", file, file.name)
  if (parentNodeId) form.append("parent_node_id", parentNodeId)
  const res = await fetch(createUrl, {
    method: "POST", headers: { "Accept": "application/json", "X-CSRF-Token": csrfToken() }, body: form
  })
  if (!res.ok) throw new Error(`upload failed (${res.status})`)
  // FilesController#create redirects (HTML) on success; request JSON node id via the Location slug.
  const loc = res.headers.get("Location") || res.url
  const m = loc && loc.match(/\/files\/([^/?]+)/)
  if (!m) throw new Error("could not resolve uploaded node id")
  return decodeURIComponent(m[1])
}
```

> **Note on `uploadPortFile`:** `FilesController#create` currently `redirect_to file_path(info.node_id)`. `fetch` follows the redirect, so `res.url` ends at `/files/<node_id>` — the regex recovers the id. This needs no controller change. (If a future change makes `#create` answer JSON, prefer that.)

- [ ] **Step 3: Point `uploader_controller` at the helper (DRY)**

Replace the body of `app/javascript/controllers/uploader_controller.js`'s `upload()` and remove its private `sha256`/`postJSON`/`csrfToken`, delegating to the helper. New file:

```js
import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile } from "lib/chunk_upload"

// Browser-side single-file upload (chunk two-phase). Thin wrapper over lib/chunk_upload so the
// importer and this control share one implementation.
export default class extends Controller {
  static targets = ["input", "status"]
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String }

  async upload() {
    const file = this.inputTarget.files[0]
    if (!file) return
    try {
      this.setStatus(`Uploading ${file.name}…`)
      const nodeId = await uploadChunkFile(file, {
        beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: this.parentNodeIdValue
      })
      if (this.hasAttachUrlValue && this.attachUrlValue) {
        this.setStatus("Attaching…")
        await this.postAttach(nodeId)
      }
      this.setStatus("Done.")
      if (this.hasRedirectUrlValue && this.redirectUrlValue) window.location.href = this.redirectUrlValue
      else window.location.reload()
    } catch (e) {
      this.setStatus(`Upload failed: ${e.message}`); console.error(e)
    } finally {
      this.inputTarget.value = ""
    }
  }

  async postAttach(nodeId) {
    await fetch(this.attachUrlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      body: JSON.stringify({ node_id: nodeId })
    })
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
```

- [ ] **Step 4: Create the importer controller**

Create `app/javascript/controllers/importer_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import JSZip from "jszip"
import { uploadChunkFile, uploadPortFile } from "lib/chunk_upload"

// Import a downloaded model bundle from ONE selection. Unzips any .zip in the browser, classifies
// entries by extension, then creates the Model (+ folder map) and uploads every file through the
// existing per-backend flow, attaching each. No zip bytes ever reach Rails; §15/§10 untouched.
const IMAGE_EXT = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
const MODEL_EXT = ["stl", "3mf", "obj", "step", "stp"]
const roleFor = (name) => {
  const ext = name.split(".").pop().toLowerCase()
  if (IMAGE_EXT.includes(ext)) return "image"
  if (MODEL_EXT.includes(ext)) return "model"
  if (ext === "pdf") return "instructions"
  return "other"
}

export default class extends Controller {
  static targets = ["input", "title", "sourceUrl", "summary", "submit", "status"]
  static values  = { createUrl: String, beginUrl: String, finalizeUrl: String, portCreateUrl: String, portWritable: Boolean }

  // Files collected from the selection: { name, dir, blob, role }.
  files = []

  async choose() {
    this.files = []
    for (const f of this.inputTarget.files) {
      if (f.name.toLowerCase().endsWith(".zip")) {
        const zip = await JSZip.loadAsync(f)
        for (const entry of Object.values(zip.files)) {
          if (entry.dir) continue
          const blob = await entry.async("blob")
          const parts = entry.name.split("/")
          const name = parts.pop()
          if (!name || name.startsWith(".")) continue
          this.files.push({ name, dir: parts.join("/"), blob: new File([blob], name), role: roleFor(name) })
        }
      } else {
        this.files.push({ name: f.name, dir: "", blob: f, role: roleFor(f.name) })
      }
    }
    if (!this.titleTarget.value && this.inputTarget.files[0]) {
      this.titleTarget.value = this.inputTarget.files[0].name.replace(/\.zip$/i, "").replace(/[_-]+/g, " ").trim()
    }
    this.renderSummary()
  }

  renderSummary() {
    const n = (r) => this.files.filter((f) => f.role === r).length
    this.summaryTarget.textContent =
      `${n("model")} model files · ${n("image")} images · ${n("instructions")} PDF`
    this.submitTarget.disabled = this.files.length === 0
  }

  // The first image is the cover; else the first model file (its rendered thumbnail becomes cover).
  coverIndex() {
    const img = this.files.findIndex((f) => f.role === "image")
    return img >= 0 ? img : this.files.findIndex((f) => f.role === "model")
  }

  async submit(event) {
    event.preventDefault()
    if (this.files.length === 0) return
    this.submitTarget.disabled = true
    try {
      const dirs = [...new Set(this.files.map((f) => f.dir).filter(Boolean))]
      this.setStatus("Creating model…")
      const created = await this.postJSON(this.createUrlValue, {
        title: this.titleTarget.value, source_url: this.sourceUrlTarget.value, dirs
      })
      const cover = this.coverIndex()
      for (let i = 0; i < this.files.length; i++) {
        const f = this.files[i]
        const parent = created.folder_map[f.dir] ?? created.folder_map[""]
        this.setStatus(`Uploading ${f.name} (${i + 1}/${this.files.length})…`)
        const nodeId = this.portWritableValue
          ? await uploadPortFile(f.blob, { createUrl: this.portCreateUrlValue, parentNodeId: parent })
          : await uploadChunkFile(f.blob, { beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: parent })
        await this.postJSON(created.attach_url, { node_id: nodeId, cover: i === cover })
      }
      this.setStatus("Done.")
      window.location.href = created.model_url
    } catch (e) {
      this.setStatus(`Import failed: ${e.message}`); console.error(e); this.submitTarget.disabled = false
    }
  }

  async postJSON(url, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json",
                 "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      body: JSON.stringify(body)
    })
    const data = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
    return data
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
```

- [ ] **Step 5: Build the import form**

Replace `app/views/models/new.html.erb`:

```erb
<% content_for :title, "Import model — Tinkerex" %>
<div class="page-head"><h1>Import model</h1></div>

<section class="import-form project-form"
         data-controller="importer"
         data-importer-create-url-value="<%= models_path(format: :json) %>"
         data-importer-begin-url-value="<%= begin_upload_files_path %>"
         data-importer-finalize-url-value="<%= finalize_upload_files_path %>"
         data-importer-port-create-url-value="<%= files_path %>"
         data-importer-port-writable-value="<%= capabilities.port_writable? %>">
  <label class="field">
    <span>Select the Printables .zip (drop extra image / PDF too if they weren't bundled)</span>
    <input type="file" multiple data-importer-target="input" data-action="importer#choose">
  </label>
  <p class="muted" data-importer-target="summary">No files selected.</p>

  <label class="field"><span>Title</span>
    <input type="text" data-importer-target="title" placeholder="Auto-filled from the zip name">
  </label>
  <label class="field"><span>Source URL (optional)</span>
    <input type="url" data-importer-target="sourceUrl" placeholder="https://printables.com/model/…">
  </label>

  <div class="form-actions">
    <button class="btn primary" data-importer-target="submit" data-action="importer#submit" disabled>Create model</button>
    <%= link_to "Cancel", models_path, class: "linkbtn" %>
    <span class="muted" data-importer-target="status"></span>
  </div>
  <p class="muted">Designer, license &amp; tags are edited on the model page after import.</p>
</section>
```

- [ ] **Step 6: Verify assets compile + the app boots**

Run: `bin/rails test test/integration/web/models_flow_test.rb test/integration/web/models_import_test.rb`
Expected: PASS (unchanged — server behavior didn't change). Then confirm importmap resolves:
Run: `bin/importmap json | grep -E "jszip|chunk_upload"`
Expected: both appear in the import map.

- [ ] **Step 7: Manual smoke test** (the JS path — do this once, it is the only coverage for the browser flow)

```
STORAGE_BACKEND=memory bin/rails server -p 3001
```
Sign in, go to `/models` → Import model. Make a test zip:
```bash
mkdir -p /tmp/dragon/tail_segments && printf 'x' > /tmp/dragon/body.3mf && printf 'x' > /tmp/dragon/tail_segments/seg1.stl && cd /tmp/dragon && zip -r /tmp/dragon.zip . && cd -
```
Select `/tmp/dragon.zip`. Confirm: summary shows "2 model files…", title auto-fills "dragon", Create redirects to the model page, both files appear (one under a `tail_segments` folder in Files at `Models/dragon/`), and the model shows a cover (rendered 3MF/STL thumbnail). Also drop a `.jpg` alongside and confirm it becomes the cover.

**Regression check for the `uploader_controller` refactor** (Step 3 changed working, CI-untested JS): on the same running server, go to `/files` and upload a single file with the ordinary "Upload a file" control — confirm it still lands (the chunk two-phase path now runs through `lib/chunk_upload`). Then open a Project and attach a file via its inline upload — confirm attach still works. If either breaks, the extraction changed behavior; diff against the pre-refactor `upload()`.

- [ ] **Step 8: Commit**

```bash
git add config/importmap.rb vendor/javascript/jszip.js app/javascript/lib/chunk_upload.js app/javascript/controllers/importer_controller.js app/javascript/controllers/uploader_controller.js app/views/models/new.html.erb
git commit -m "feat(models): browser import — JSZip unzip + classify + per-backend upload + attach"
```

---

## Task 7: The print log — controller, form, history, auto-status wiring

**Files:**
- Create: `app/controllers/models/print_runs_controller.rb`, `app/views/models/_print_log.html.erb`, `test/integration/web/print_runs_test.rb`
- Modify: `app/views/models/_print_log.html.erb` (replace the Task 5 stub)

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/print_runs_test.rb`:

```ruby
require "test_helper"

module Web
  class PrintRunsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "the show page renders the log form and history" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      m.print_runs.create!(printed_on: Date.new(2026, 7, 22), outcome: "success", printer: "MK4")
      get model_path(m)
      assert_select "form.print-form"
      assert_select ".print-run", text: /MK4/
    end

    test "logging a success print creates a run and flips status to printed" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      assert_difference "Maker::PrintRun.count", 1 do
        post model_print_runs_path(m), params: { print_run: {
          printed_on: "2026-07-22", outcome: "success", printer: "MK4", material: "PLA",
          duration_hours: "6.5", filament_grams: "82", notes: "0.2mm"
        } }
      end
      assert_redirected_to model_path(m)
      assert_equal "printed", m.reload.print_status
    end

    test "deleting a run recomputes status and is scoped to the owner" do
      user = sign_in
      m = user.maker_models.create!(title: "Dragon")
      run = m.print_runs.create!(printed_on: Date.today, outcome: "failed")
      assert_equal "failed", m.reload.print_status
      assert_difference "Maker::PrintRun.count", -1 do
        delete print_run_path(run)
      end
      assert_redirected_to model_path(m)
    end

    test "cannot log a print on another user's model" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      m = other.maker_models.create!(title: "Theirs")
      # find_by!(slug:) on the current user's scope misses -> RecordNotFound, which this app
      # rescues to a 404 (same as the projects flow test), NOT a raised exception in the test.
      assert_no_difference "Maker::PrintRun.count" do
        post model_print_runs_path(m), params: { print_run: { printed_on: "2026-07-22", outcome: "success" } }
      end
      assert_response :not_found
    end
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `bin/rails test test/integration/web/print_runs_test.rb`
Expected: FAIL — no `Models::PrintRunsController` / `.print-form` not rendered.

- [ ] **Step 3: Create the controller**

Create `app/controllers/models/print_runs_controller.rb`:

```ruby
module Models
  # Log a print against a model / delete a logged print. The Maker::PrintRun after_save/destroy
  # callback keeps the model's print_status in sync (latest run wins).
  class PrintRunsController < ApplicationController
    before_action :authenticate_user!

    # POST /models/:model_id/print_runs
    def create
      model = current_user.maker_models.find_by!(slug: params[:model_id])
      model.print_runs.create!(run_params.merge(user: current_user))
      redirect_to model_path(model), notice: "Logged a print."
    end

    # DELETE /print_runs/:id (shallow)
    def destroy
      run = current_user.maker_print_runs.find(params[:id])
      model = run.model
      run.destroy!
      redirect_to model_path(model), notice: "Removed the print."
    end

    private

    def run_params
      params.require(:print_run).permit(:printed_on, :printer, :material, :outcome,
                                        :duration_hours, :filament_grams, :notes)
    end
  end
end
```

- [ ] **Step 4: Replace the print-log partial**

Replace `app/views/models/_print_log.html.erb` (the Task 5 stub):

```erb
<section class="print-log">
  <h2>Print log <span class="muted">(<%= @print_runs.size %>)</span></h2>

  <%# scope: :print_run (no model object) -> fields serialize under print_run[...], which the
      controller's params.require(:print_run) expects. Same reason projects' _form uses scope. %>
  <%= form_with scope: :print_run, url: model_print_runs_path(@model), class: "print-form" do |f| %>
    <div class="row">
      <label class="field"><span>Date</span><%= f.date_field :printed_on, value: Date.today %></label>
      <label class="field"><span>Outcome</span>
        <%= f.select :outcome, Maker::PrintRun::OUTCOMES.map { |o| [ o.capitalize, o ] } %>
      </label>
    </div>
    <div class="row">
      <label class="field"><span>Printer</span>
        <%= f.text_field :printer, list: "printer-options" %>
        <datalist id="printer-options"><% @printers.each do |p| %><option value="<%= p %>"><% end %></datalist>
      </label>
      <label class="field"><span>Material</span>
        <%= f.text_field :material, list: "material-options" %>
        <datalist id="material-options"><% @materials.each do |mm| %><option value="<%= mm %>"><% end %></datalist>
      </label>
    </div>
    <div class="row">
      <label class="field"><span>Duration (h)</span><%= f.number_field :duration_hours, step: "0.1" %></label>
      <label class="field"><span>Filament (g)</span><%= f.number_field :filament_grams %></label>
    </div>
    <label class="field"><span>Notes</span><%= f.text_field :notes %></label>
    <%= f.submit "Log a print", class: "btn small" %>
  <% end %>

  <% @print_runs.each do |run| %>
    <div class="print-run">
      <strong><%= run.outcome == "success" ? "✓" : "✕" %> <%= run.printed_on.strftime("%Y-%m-%d") %></strong>
      <%= " · #{run.printer}" if run.printer.present? %>
      <div class="muted">
        <%= [ run.material, ("#{run.duration_hours}h" if run.duration_hours),
              ("#{run.filament_grams}g" if run.filament_grams) ].compact.join(" · ") %>
      </div>
      <% if run.notes.present? %><div class="muted"><%= run.notes %></div><% end %>
      <%= button_to "Delete", print_run_path(run), method: :delete, class: "linkbtn danger small",
                    form: { data: { turbo_confirm: "Delete this print?" } } %>
    </div>
  <% end %>
</section>
```

- [ ] **Step 5: Run, expect pass**

Run: `bin/rails test test/integration/web/print_runs_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/models/print_runs_controller.rb app/views/models/_print_log.html.erb test/integration/web/print_runs_test.rb
git commit -m "feat(models): print log — log/delete a print, datalist reuse, auto-status"
```

---

## Task 8: Full-suite verification on all three backend legs

**Files:** none (verification only).

- [ ] **Step 1: Run the whole server suite (default chunk backend)**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. (Note the new counts; the suite was ~978 before this feature.)

- [ ] **Step 2: Run on the share backend leg**

Run: `LIBRARY_BACKEND=share bin/rails test test/models/maker/model_test.rb test/models/maker/print_run_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_import_test.rb test/integration/web/print_runs_test.rb`
Expected: 0 failures. (These pin `chunk` in setup, so they exercise the model/controller logic; the point is they don't depend on the ambient backend.)

- [ ] **Step 3: Run on the s3 backend leg**

Run: `LIBRARY_BACKEND=s3 bin/rails test test/models/maker/model_test.rb test/models/maker/print_run_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_import_test.rb test/integration/web/print_runs_test.rb`
Expected: 0 failures.

- [ ] **Step 4: Lint / boot check**

Run: `bin/rails runner 'puts [Maker::Model, Maker::PrintRun].map(&:name).inspect'`
Expected: `["Maker::Model", "Maker::PrintRun"]` (constants load; no autoload errors).

- [ ] **Step 5: Confirm §10 was not breached** (models must not reach into sync)

Run: `grep -rn "Sync::\|changelog\|manifest_chunks\|ChunkStore" app/controllers/models_controller.rb app/controllers/models/ app/models/maker/model.rb app/models/maker/print_run.rb`
Expected: no matches. (Folder creation goes through `Maker::LibraryFolder`, which is the sanctioned seam; bytes go through the existing `/files` endpoints. The maker layer never names sync internals.)

- [ ] **Step 6: Final commit (if any doc/tidy changes)**

```bash
git add -A
git commit -m "test(models): verify model library green on chunk/share/s3 legs" --allow-empty
```

---

## Self-Review notes (for the implementer)

- **Task 5 `show.html.erb` renders `_print_log` which is created as a stub in Task 5 and filled in Task 7.** Do not skip the Task 5 stub, or the flow test fails to render.
- **`uploadPortFile` relies on `FilesController#create` redirecting to `/files/<node_id>`** (it does today). If you change `#create`, keep a way to recover the node id (prefer a JSON response).
- **Roles are derived server-side** in the attach endpoint (`FileAttachment.role_for`), so the client's classification is UX-only and can't corrupt data.
- **The importer is the only untested-by-CI code.** Keep its logic thin; anything non-trivial belongs server-side where Task 5's tests cover it.
