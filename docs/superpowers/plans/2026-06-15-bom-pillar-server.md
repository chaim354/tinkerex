# Maker BOM Pillar — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server side of the maker-app **BOM (Bill of Materials) pillar** — a project has one or more **revisioned** BOMs; each BOM is a list of lines, where every line links to **exactly one** target: an inventory item, a design file (by `node_id`), or a free-text part (name + optional supplier). A "roll up" view resolves each line's target so a client can render the whole bill (with the inventory balance / file id / vendor) in one call.

**Architecture:** A continuation of the `Maker::`-namespaced product layer **inside the existing Rails 8 app** (the same DB, the same `users` table, the same device-token auth established by the Library + Projects + Inventory pillars). Records are **server-authoritative** (integer-PK Rails CRUD over the `/v1/maker/*` API). The "exactly one target" rule is enforced by a **model validation** (works on SQLite + Postgres — no DB CHECK constraint). Design files are referenced only by the file layer's stable string `node_id`. A line linking an inventory item could, in future, drive a `consumed` inventory transaction when a build consumes it — that is a **FUTURE hook, not built here**.

**Dependency / ordering:** This is the **third and last** of the remaining product pillars (Projects → Inventory → **BOM**). It **depends on both**:
- the **Projects pillar** (`docs/superpowers/plans/2026-06-15-projects-pillar-server.md`) — a BOM `belongs_to` a `Maker::Project` (its `maker_projects` table must exist), and
- the **Inventory pillar** (`docs/superpowers/plans/2026-06-15-inventory-pillar-server.md`) — a BOM line can link a `Maker::InventoryItem` and a `Maker::Supplier`.

Both must be merged before this plan runs. It also depends on the **Library pillar** (`V1::BaseController`, the `namespace :maker` routes, the `app/models/maker/` + `app/controllers/v1/maker/` directories).

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite (dev/test) + Postgres (prod) — adapter-agnostic (no DB-level FK or CHECK constraints, explicit indexes, `user_id` integer scoping, `decimal` columns). Minitest (`ActiveSupport::TestCase` for models, `ActionDispatch::IntegrationTest` for the API).

**Conventions to follow (from the existing pillars):**
- Models: `belongs_to :user`; `self.table_name = "maker_*"`; enum-like value sets as frozen constants + `validates :x, inclusion:`; `dependent: :destroy`; ownership validations for cross-model references. See `app/models/maker/project.rb`, `app/models/maker/inventory_item.rb`.
- Migrations: `t.integer :user_id, null: false` (no `foreign_key:` constraint), `t.decimal …, precision: 12, scale: 3`, explicit `add_index`. Filenames continue the sequence — Inventory used `20260615000010`–`20260615000013`, so this plan uses `20260615000014`–`20260615000015`.
- Controllers: `V1::Maker::XController < V1::BaseController`; scope **everything** through `current_user.maker_*`; `render json:`; `only:`-restricted routes; inherited JSON rescue handlers (`RecordNotFound`→404, `RecordInvalid`→422, `ParameterMissing`→400).
- Tests: API tests register a device via `POST /v1/auth/register` and send `Authorization: Bearer <token>`. See `test/integration/v1/maker/inventory_items_test.rb`.

**Routes:** inside the existing `namespace :maker do … end` block in `config/routes.rb`, this plan adds BOMs nested under projects + lines nested under BOMs (shallow), plus a roll-up member route:
```ruby
resources :projects, only: [] do
  resources :boms, only: %i[index create], shallow: true
end
resources :boms, only: %i[show update destroy] do
  member { get "rollup" }
  resources :bom_lines, only: %i[index create update destroy], shallow: true
end
```
(The `projects` re-open with `only: []` adds only the nested `boms` collection/create routes under a project, without redefining the Projects pillar's own `resources :projects` block. Add only the routes each task needs, as that task is implemented.)

---

## File Structure

**Migrations** (`db/migrate/`): `20260615000014_create_maker_boms.rb`, `20260615000015_create_maker_bom_lines.rb`.

**Models** (`app/models/maker/`): `bom.rb`, `bom_line.rb`. Plus 2 `has_many` lines added to `app/models/user.rb`.

**Controllers** (`app/controllers/v1/maker/`): `boms_controller.rb`, `bom_lines_controller.rb`.

**Tests**: model tests in `test/models/maker/`, API tests in `test/integration/v1/maker/`.

Responsibilities: `Maker::Bom` is a revisioned bill belonging to a project. `Maker::BomLine` is one line with exactly one of three link targets (inventory item / design file `node_id` / free-text part) enforced by a model validation, plus the roll-up resolution helper.

---

## Task 1: `Maker::Bom` (revisioned, belongs to a project)

**Files:**
- Create: `db/migrate/20260615000014_create_maker_boms.rb`
- Create: `app/models/maker/bom.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/bom_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000014_create_maker_boms.rb`:
```ruby
class CreateMakerBoms < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_boms do |t|
      t.integer :user_id, null: false
      t.integer :project_id, null: false
      t.string  :name, null: false, default: "BOM"
      t.integer :revision, null: false, default: 1
      t.timestamps
    end
    add_index :maker_boms, [ :user_id, :project_id ]
    add_index :maker_boms, [ :project_id, :revision ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_boms)` succeeds; `db/schema.rb` now contains `maker_boms`.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/bom_test.rb`:
```ruby
require "test_helper"

module Maker
  class BomTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "bom@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid belonging to a project" do
      bom = @project.boms.build(user: @user)
      assert bom.valid?
    end

    test "defaults name to BOM and revision to 1" do
      bom = @project.boms.create!(user: @user)
      assert_equal "BOM", bom.name
      assert_equal 1, bom.revision
    end

    test "revision must be positive" do
      bom = @project.boms.build(user: @user, revision: 0)
      assert_not bom.valid?
    end

    test "the project must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_projects.create!(name: "Theirs")
      bom = Maker::Bom.new(user: @user, project_id: foreign.id)
      assert_not bom.valid?
      assert_includes bom.errors[:project_id], "must reference your own project"
    end

    test "a project can have many revisions" do
      @project.boms.create!(user: @user, revision: 1)
      @project.boms.create!(user: @user, revision: 2)
      assert_equal [ 1, 2 ], @project.boms.order(:revision).pluck(:revision)
    end

    test "destroying the project destroys its boms" do
      @project.boms.create!(user: @user)
      assert_difference -> { Maker::Bom.count }, -1 do
        @project.destroy
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/bom_test.rb`
Expected: FAIL — `uninitialized constant Maker::Bom` (and `undefined method 'boms'` on Project).

- [ ] **Step 5: Write the model + wire the Project association**

Create `app/models/maker/bom.rb`:
```ruby
module Maker
  class Bom < ApplicationRecord
    self.table_name = "maker_boms"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"
    has_many :lines, -> { order(:position, :id) },
             class_name: "Maker::BomLine", foreign_key: :bom_id, dependent: :destroy

    validates :name, presence: true
    validates :revision, numericality: { only_integer: true, greater_than: 0 }
    validate :project_belongs_to_user

    private

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
```

In `app/models/maker/project.rb`, add inside the `Maker::Project` class (after the existing `has_many :tasks, …` line):
```ruby
    has_many :boms, class_name: "Maker::Bom", foreign_key: :project_id, dependent: :destroy
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, add to the `has_many` block (after the inventory associations from the Inventory pillar):
```ruby
  has_many :maker_boms, class_name: "Maker::Bom", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/bom_test.rb`
Expected: PASS (6 runs, 0 failures). (The `lines` association references the model built in Task 2 but nothing exercises it yet.)

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000014_create_maker_boms.rb db/schema.rb \
        app/models/maker/bom.rb app/models/maker/project.rb app/models/user.rb \
        test/models/maker/bom_test.rb
git commit -m "feat(maker): Maker::Bom revisioned bill belonging to a project"
```

---

## Task 2: `Maker::BomLine` (exactly-one target + roll-up resolution)

**Files:**
- Create: `db/migrate/20260615000015_create_maker_bom_lines.rb`
- Create: `app/models/maker/bom_line.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/bom_line_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000015_create_maker_bom_lines.rb`:
```ruby
class CreateMakerBomLines < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_bom_lines do |t|
      t.integer :user_id, null: false
      t.integer :bom_id, null: false
      t.string  :reference                 # designator, e.g. "R1", "M3x10"
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 1
      t.string  :unit, null: false, default: "each"
      # exactly ONE of the three target shapes is set (enforced by model validation):
      t.integer :inventory_item_id         # (1) link an inventory item
      t.string  :node_id                   # (2) link a design file by its stable node_id
      t.string  :part_name                 # (3a) free-text part name …
      t.integer :supplier_id               # (3b) … with an optional supplier
      t.text    :notes
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_bom_lines, [ :user_id, :bom_id, :position ],
              name: "index_maker_bom_lines_on_bom_position"
    add_index :maker_bom_lines, [ :user_id, :inventory_item_id ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_bom_lines)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/bom_line_test.rb`:
```ruby
require "test_helper"

module Maker
  class BomLineTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "line@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @bom = @project.boms.create!(user: @user)
      @inv = @user.maker_inventory_items.create!(name: "M3 bolt", quantity_cached: 40)
      @sup = @user.maker_suppliers.create!(name: "Digikey")
    end

    test "an inventory-item line is valid" do
      line = @bom.lines.build(user: @user, inventory_item_id: @inv.id, quantity: 4, reference: "B1")
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a design-file line (node_id) is valid" do
      line = @bom.lines.build(user: @user, node_id: "node-step", quantity: 1)
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a free-text part line is valid (with optional supplier)" do
      line = @bom.lines.build(user: @user, part_name: "Generic LED", supplier_id: @sup.id, quantity: 10)
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a line with NO target is invalid" do
      line = @bom.lines.build(user: @user, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:base], "a line must link exactly one of: inventory item, design file, or free-text part"
    end

    test "a line with TWO targets is invalid" do
      line = @bom.lines.build(user: @user, inventory_item_id: @inv.id, node_id: "node-x", quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:base], "a line must link exactly one of: inventory item, design file, or free-text part"
    end

    test "supplier_id alone (no part_name) does not count as a target" do
      line = @bom.lines.build(user: @user, supplier_id: @sup.id, quantity: 1)
      assert_not line.valid?
    end

    test "quantity must be positive" do
      line = @bom.lines.build(user: @user, node_id: "n", quantity: 0)
      assert_not line.valid?
    end

    test "the inventory item must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_inventory_items.create!(name: "Theirs")
      line = @bom.lines.build(user: @user, inventory_item_id: foreign.id, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:inventory_item_id], "must reference your own inventory item"
    end

    test "the supplier must belong to the same user" do
      other = User.create!(email: "o2@example.com")
      foreign = other.maker_suppliers.create!(name: "Theirs")
      line = @bom.lines.build(user: @user, part_name: "x", supplier_id: foreign.id, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:supplier_id], "must reference your own supplier"
    end

    test "target_kind reports which target shape a line uses" do
      assert_equal :inventory_item, @bom.lines.build(inventory_item_id: @inv.id).target_kind
      assert_equal :design_file,    @bom.lines.build(node_id: "n").target_kind
      assert_equal :free_text,      @bom.lines.build(part_name: "x").target_kind
      assert_nil    @bom.lines.build.target_kind
    end

    test "resolved_target returns the linked inventory item with its balance" do
      line = @bom.lines.create!(user: @user, inventory_item_id: @inv.id, quantity: 4)
      resolved = line.resolved_target
      assert_equal :inventory_item, resolved[:kind]
      assert_equal @inv.id, resolved[:inventory_item][:id]
      assert_equal 40, resolved[:inventory_item][:quantity_cached]
    end

    test "resolved_target for a free-text line includes the supplier name" do
      line = @bom.lines.create!(user: @user, part_name: "Generic LED", supplier_id: @sup.id, quantity: 10)
      resolved = line.resolved_target
      assert_equal :free_text, resolved[:kind]
      assert_equal "Generic LED", resolved[:part_name]
      assert_equal "Digikey", resolved[:supplier_name]
    end

    test "destroying the bom destroys its lines" do
      @bom.lines.create!(user: @user, node_id: "n", quantity: 1)
      assert_difference -> { Maker::BomLine.count }, -1 do
        @bom.destroy
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/bom_line_test.rb`
Expected: FAIL — `uninitialized constant Maker::BomLine`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/bom_line.rb`:
```ruby
module Maker
  class BomLine < ApplicationRecord
    self.table_name = "maker_bom_lines"

    UNITS = Maker::InventoryItem::UNITS

    belongs_to :user
    belongs_to :bom, class_name: "Maker::Bom"
    belongs_to :inventory_item, class_name: "Maker::InventoryItem", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true

    validates :quantity, numericality: { greater_than: 0 }
    validates :unit, inclusion: { in: UNITS }
    validate  :exactly_one_target
    validate  :inventory_item_belongs_to_user, if: -> { inventory_item_id.present? }
    validate  :supplier_belongs_to_user,       if: -> { supplier_id.present? }

    # Which of the three target shapes this line uses (nil if none/invalid).
    def target_kind
      kinds = []
      kinds << :inventory_item if inventory_item_id.present?
      kinds << :design_file    if node_id.present?
      kinds << :free_text      if part_name.present?
      kinds.one? ? kinds.first : nil
    end

    # Resolve the line's target for the roll-up view (one hash per line).
    def resolved_target
      case target_kind
      when :inventory_item
        item = inventory_item
        { kind: :inventory_item,
          inventory_item: item && {
            id: item.id, name: item.name, part_number: item.part_number,
            unit: item.unit, quantity_cached: item.quantity_cached
          } }
      when :design_file
        { kind: :design_file, node_id: node_id }
      when :free_text
        { kind: :free_text, part_name: part_name,
          supplier_id: supplier_id, supplier_name: supplier&.name }
      else
        { kind: nil }
      end
    end

    private

    def exactly_one_target
      count = [ inventory_item_id.present?, node_id.present?, part_name.present? ].count(true)
      unless count == 1
        errors.add(:base,
          "a line must link exactly one of: inventory item, design file, or free-text part")
      end
    end

    def inventory_item_belongs_to_user
      unless Maker::InventoryItem.exists?(id: inventory_item_id, user_id: user_id)
        errors.add(:inventory_item_id, "must reference your own inventory item")
      end
    end

    def supplier_belongs_to_user
      unless Maker::Supplier.exists?(id: supplier_id, user_id: user_id)
        errors.add(:supplier_id, "must reference your own supplier")
      end
    end
  end
end
```
(`exactly_one_target` counts the three target shapes; a `supplier_id` alone — without `part_name` — is *not* a target, so it fails. `UNITS` is reused from `Maker::InventoryItem` for a consistent unit vocabulary. The "exactly one" rule is pure Ruby — no DB CHECK — so it's identical on SQLite + Postgres.)

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after `maker_boms`:
```ruby
  has_many :maker_bom_lines, class_name: "Maker::BomLine", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/bom_line_test.rb`
Expected: PASS (13 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000015_create_maker_bom_lines.rb db/schema.rb \
        app/models/maker/bom_line.rb app/models/user.rb \
        test/models/maker/bom_line_test.rb
git commit -m "feat(maker): Maker::BomLine exactly-one-target + roll-up resolution"
```

---

## Task 3: `Maker::BomsController` — nested-under-project create/list + show/update/destroy + rollup

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/boms_controller.rb`
- Test: `test/integration/v1/maker/boms_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the existing `namespace :maker` block, add:
```ruby
      resources :projects, only: [] do
        resources :boms, only: %i[index create], shallow: true
      end
      resources :boms, only: %i[show update destroy] do
        member { get "rollup" }
      end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/boms_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class BomsTest < ActionDispatch::IntegrationTest
      def register(email = "b@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
      end

      test "create a BOM under a project" do
        post "/v1/maker/projects/#{@project}/boms",
             params: { bom: { name: "Main BOM", revision: 1 } }, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Main BOM", body["name"]
        assert_equal 1, body["revision"]
        assert_equal @project, body["project_id"]
      end

      test "create defaults name and revision" do
        post "/v1/maker/projects/#{@project}/boms", params: {}, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "BOM", body["name"]
        assert_equal 1, body["revision"]
      end

      test "index lists a project's BOM revisions" do
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { revision: 1 } }, as: :json, headers: auth(@token)
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { revision: 2 } }, as: :json, headers: auth(@token)
        get "/v1/maker/projects/#{@project}/boms", headers: auth(@token)
        assert_response :success
        assert_equal [ 1, 2 ], JSON.parse(response.body)["boms"].map { |b| b["revision"] }.sort
      end

      test "show, update, and destroy a BOM" do
        post "/v1/maker/projects/#{@project}/boms", params: { bom: { name: "v1" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/boms/#{id}", headers: auth(@token)
        assert_response :success
        patch "/v1/maker/boms/#{id}", params: { bom: { name: "v1-final", revision: 2 } },
              as: :json, headers: auth(@token)
        assert_equal "v1-final", JSON.parse(response.body)["name"]
        assert_equal 2, JSON.parse(response.body)["revision"]
        delete "/v1/maker/boms/#{id}", headers: auth(@token)
        assert_response :no_content
      end

      test "cannot create a BOM under another user's project" do
        other = register("o@example.com")
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(other)
        assert_response :not_found
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/boms_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::BomsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/boms_controller.rb`:
```ruby
module V1
  module Maker
    class BomsController < V1::BaseController
      def index
        project = current_user.maker_projects.find(params[:project_id])
        render json: { boms: project.boms.order(:revision).map { |b| bom_json(b) } }
      end

      def create
        project = current_user.maker_projects.find(params[:project_id])
        bom = project.boms.new(bom_params.merge(user: current_user))
        bom.save!
        render json: bom_json(bom), status: :created
      end

      def show
        render json: bom_json(current_user.maker_boms.find(params[:id]), full: true)
      end

      def update
        bom = current_user.maker_boms.find(params[:id])
        bom.update!(bom_params)
        render json: bom_json(bom, full: true)
      end

      def destroy
        current_user.maker_boms.find(params[:id]).destroy!
        head :no_content
      end

      # GET /v1/maker/boms/:id/rollup — every line with its resolved target.
      def rollup
        bom = current_user.maker_boms.find(params[:id])
        render json: {
          bom: bom_json(bom),
          lines: bom.lines.map { |line| rollup_line_json(line) }
        }
      end

      private

      def bom_params
        params.fetch(:bom, {}).permit(:name, :revision)
      end

      def bom_json(bom, full: false)
        base = { id: bom.id, project_id: bom.project_id, name: bom.name, revision: bom.revision,
                 created_at: bom.created_at, updated_at: bom.updated_at }
        return base unless full
        base.merge(line_count: bom.lines.count)
      end

      def rollup_line_json(line)
        { id: line.id, reference: line.reference, quantity: line.quantity, unit: line.unit,
          notes: line.notes, position: line.position,
          target_kind: line.target_kind, target: line.resolved_target }
      end
    end
  end
end
```
(`bom_params` uses `params.fetch(:bom, {})` so a `POST …/boms` with no body still creates a default-named, revision-1 BOM — `name`/`revision` have DB defaults.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/boms_test.rb`
Expected: PASS (5 runs, 0 failures). (Cross-user project `find` → 404.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/boms_controller.rb \
        test/integration/v1/maker/boms_test.rb
git commit -m "feat(maker): BOMs nested under projects + rollup endpoint"
```

---

## Task 4: `Maker::BomLinesController` — line CRUD

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/bom_lines_controller.rb`
- Test: `test/integration/v1/maker/bom_lines_test.rb`

- [ ] **Step 1: Add the nested routes**

In `config/routes.rb`, change the second `resources :boms` block (from Task 3) to also nest `bom_lines`:
```ruby
      resources :boms, only: %i[show update destroy] do
        member { get "rollup" }
        resources :bom_lines, only: %i[index create update destroy], shallow: true
      end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/bom_lines_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class BomLinesTest < ActionDispatch::IntegrationTest
      def register(email = "bl@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(@token)
        @bom = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "M3 bolt" } },
             as: :json, headers: auth(@token)
        @inv = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items/#{@inv}/adjust", params: { delta: 40, reason: "initial" },
             as: :json, headers: auth(@token)
      end

      test "add an inventory-item line" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, quantity: 4, reference: "B1" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal @inv, body["inventory_item_id"]
        assert_equal "inventory_item", body["target_kind"]
      end

      test "add a design-file line by node_id" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { node_id: "node-step", quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "design_file", JSON.parse(response.body)["target_kind"]
      end

      test "add a free-text part line" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { part_name: "Generic LED", quantity: 10 } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "free_text", JSON.parse(response.body)["target_kind"]
      end

      test "a line with two targets is rejected with 422" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, node_id: "n", quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "a line with no target is rejected with 422" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { quantity: 1 } }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "index lists a BOM's lines; update and destroy a line" do
        post "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "n1", quantity: 1 } },
             as: :json, headers: auth(@token)
        line = JSON.parse(response.body)["id"]
        get "/v1/maker/boms/#{@bom}/bom_lines", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["bom_lines"].size
        patch "/v1/maker/bom_lines/#{line}", params: { bom_line: { quantity: 5, reference: "X" } },
              as: :json, headers: auth(@token)
        assert_equal 5.0, JSON.parse(response.body)["quantity"].to_f
        delete "/v1/maker/bom_lines/#{line}", headers: auth(@token)
        assert_response :no_content
      end

      test "rollup resolves every line's target" do
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: @inv, quantity: 4 } }, as: :json, headers: auth(@token)
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { part_name: "Generic LED", quantity: 10 } }, as: :json, headers: auth(@token)
        get "/v1/maker/boms/#{@bom}/rollup", headers: auth(@token)
        assert_response :success
        lines = JSON.parse(response.body)["lines"]
        inv_line = lines.find { |l| l["target_kind"] == "inventory_item" }
        assert_equal 40.0, inv_line["target"]["inventory_item"]["quantity_cached"].to_f
        free_line = lines.find { |l| l["target_kind"] == "free_text" }
        assert_equal "Generic LED", free_line["target"]["part_name"]
      end

      test "cannot link another user's inventory item (422)" do
        other = register("o@example.com")
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "Theirs" } },
             as: :json, headers: auth(other)
        foreign = JSON.parse(response.body)["id"]
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { inventory_item_id: foreign, quantity: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "cannot add a line to another user's BOM (404)" do
        other = register("o2@example.com")
        post "/v1/maker/boms/#{@bom}/bom_lines",
             params: { bom_line: { node_id: "n", quantity: 1 } }, as: :json, headers: auth(other)
        assert_response :not_found
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/bom_lines_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::BomLinesController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/bom_lines_controller.rb`:
```ruby
module V1
  module Maker
    class BomLinesController < V1::BaseController
      def index
        bom = current_user.maker_boms.find(params[:bom_id])
        render json: { bom_lines: bom.lines.map { |l| line_json(l) } }
      end

      def create
        bom = current_user.maker_boms.find(params[:bom_id])
        line = bom.lines.new(line_params.merge(user: current_user))
        line.save!
        render json: line_json(line), status: :created
      end

      def update
        line = current_user.maker_bom_lines.find(params[:id])
        line.update!(line_params)
        render json: line_json(line)
      end

      def destroy
        current_user.maker_bom_lines.find(params[:id]).destroy!
        head :no_content
      end

      private

      def line_params
        params.require(:bom_line).permit(
          :reference, :quantity, :unit, :inventory_item_id, :node_id,
          :part_name, :supplier_id, :notes, :position
        )
      end

      def line_json(line)
        { id: line.id, bom_id: line.bom_id, reference: line.reference,
          quantity: line.quantity, unit: line.unit, notes: line.notes, position: line.position,
          inventory_item_id: line.inventory_item_id, node_id: line.node_id,
          part_name: line.part_name, supplier_id: line.supplier_id,
          target_kind: line.target_kind, created_at: line.created_at, updated_at: line.updated_at }
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/bom_lines_test.rb`
Expected: PASS (9 runs, 0 failures). (The exactly-one-target + ownership validations surface as 422 via the `RecordInvalid` rescue; a cross-user BOM `find` → 404.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/bom_lines_controller.rb \
        test/integration/v1/maker/bom_lines_test.rb
git commit -m "feat(maker): BOM line CRUD with exactly-one-target enforcement"
```

---

## Task 5: Full-suite green + tenant-isolation sweep

**Files:**
- Test: `test/integration/v1/maker/bom_isolation_test.rb`

- [ ] **Step 1: Write a focused cross-user isolation test**

Create `test/integration/v1/maker/bom_isolation_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every BOM resource must 404 (never leak) across users.
    class BomIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-bomiso@example.com")
        @b = register("b-bomiso@example.com")
        post "/v1/maker/projects", params: { project: { name: "A's project" } }, as: :json, headers: auth(@a)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/boms", params: { bom: {} }, as: :json, headers: auth(@a)
        @bom = JSON.parse(response.body)["id"]
        post "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "n", quantity: 1 } },
             as: :json, headers: auth(@a)
        @line = JSON.parse(response.body)["id"]
      end

      test "B cannot read, roll up, or mutate A's BOM and lines" do
        get    "/v1/maker/projects/#{@project}/boms", headers: auth(@b);                       assert_response :not_found
        get    "/v1/maker/boms/#{@bom}", headers: auth(@b);                                    assert_response :not_found
        get    "/v1/maker/boms/#{@bom}/rollup", headers: auth(@b);                             assert_response :not_found
        patch  "/v1/maker/boms/#{@bom}", params: { bom: { name: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/boms/#{@bom}", headers: auth(@b);                                    assert_response :not_found
        get    "/v1/maker/boms/#{@bom}/bom_lines", headers: auth(@b);                          assert_response :not_found
        post   "/v1/maker/boms/#{@bom}/bom_lines", params: { bom_line: { node_id: "x", quantity: 1 } },
               as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/bom_lines/#{@line}", headers: auth(@b);                              assert_response :not_found
      end
    end
  end
end
```

- [ ] **Step 2: Run the new test**

Run: `bin/rails test test/integration/v1/maker/bom_isolation_test.rb`
Expected: PASS (1 run, 0 failures).

- [ ] **Step 3: Run the entire suite**

Run: `bin/rails test`
Expected: PASS — all BOM tests plus the pre-existing Library + Projects + Inventory + server tests green, 0 failures, 0 errors.

- [ ] **Step 4: Commit**

```bash
git add test/integration/v1/maker/bom_isolation_test.rb
git commit -m "test(maker): cross-user isolation sweep for the BOM API"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** `maker_boms` project_id/name(default "BOM")/revision(default 1) with many revisions per project (Task 1); `maker_bom_lines` reference/quantity(decimal default 1)/unit + exactly ONE of inventory_item_id | node_id | part_name(+supplier_id?) + notes/position (Task 2); **"exactly one target" enforced by a model validation** (`exactly_one_target`, pure Ruby — SQLite+PG, no DB CHECK) (Task 2); BOMs nested under projects (Task 3); bom_lines CRUD (Task 4); a **roll-up view** resolving each line's inventory/file/free-text target (`resolved_target` + `boms#rollup`) (Tasks 2–4); tenant isolation (Task 5). ✓
- **Cross-pillar FUTURE hook (mentioned, not built):** a BOM line linking an inventory item could drive a `consumed` inventory transaction when a build consumes it — called out in the architecture header and the Out-of-scope section; no consumption code is written. ✓
- **Exactly-one-target enforcement is adapter-agnostic:** `exactly_one_target` counts `[inventory_item_id, node_id, part_name].count(&:present?)` and requires exactly 1 — identical on SQLite + Postgres, no DB CHECK constraint. `supplier_id` alone is correctly *not* a target (tested). ✓
- **Dependencies wired:** `Maker::Bom belongs_to :project` (Projects pillar) with an ownership validation; `Maker::BomLine` links `Maker::InventoryItem` + `Maker::Supplier` (Inventory pillar) with ownership validations; `UNITS` reused from `Maker::InventoryItem`. The plan header states both prerequisite pillars must be merged first. ✓
- **Migration numbering:** continues at `20260615000014`–`20260615000015` (Inventory ended at `0013`), contiguous. ✓
- **Type consistency:** `target_kind`/`resolved_target` (Task 2) drive both the line JSON and the `rollup` endpoint (Tasks 3–4); `lines` association (Task 1) populated by Task 2; JSON keys (`boms`, `bom_lines`, `target_kind`, `target`, `inventory_item_id`, `node_id`, `part_name`) consistent across model/controller/test; `params.fetch(:bom, {})` matches the no-body create test. ✓
- **Placeholder scan:** every step ships complete code, exact paths, exact commands, and expected output — no `TODO`/`add validation`/`...` stubs. ✓

---

## Out of scope (follow-on work)

- **The build-consumption hook:** posting a `consumed` `Maker::InventoryTransaction` for each inventory-linked BOM line when a project "build" is recorded (e.g. `POST /v1/maker/boms/:id/consume` → ledger entries with `reason: "consumed"`, `project_id:` set, `delta: -quantity`). Designed-for (the ledger already accepts `project_id`), not built here.
- **BOM diff / revision compare** (what changed between revision N and N+1), CSV/CSV-BOM export, and BOM templates.
- **Tauri client + web UI** for BOMs (line editor + roll-up table with live inventory balances) — mirrors the Library client groundwork in `client/maker-app`.
