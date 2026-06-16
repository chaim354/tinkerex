# Maker Inventory Pillar — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server side of the maker-app **Inventory pillar** — track materials/components on hand: what they are, how many, where they live (nested bins/locations), who supplies them, and an **immutable transaction ledger** that is the source of truth for every quantity. The item carries a **denormalized cached balance** (`quantity_cached`) kept in lock-step with the ledger so list/low-stock queries are cheap.

**Architecture:** A continuation of the `Maker::`-namespaced product layer **inside the existing Rails 8 app** (the same DB, the same `users` table, the same device-token auth established by the Library + Projects pillars). All records are **server-authoritative** (normal integer-PK Rails CRUD over the `/v1/maker/*` API), *not* synced into the local SQLite file tree. The ledger pattern: `maker_inventory_transactions` is append-only (no `updated_at`); creating a transaction **atomically** inserts the ledger row and increments the item's `quantity_cached`, inside a single DB transaction with a row lock so concurrent adjustments can't lose an update. A `rebuild_quantity_cached!` method recomputes `quantity_cached = SUM(delta)` from the ledger (the safety net / migration tool). Decimals + the cached-balance update are written to work identically on SQLite and Postgres (no PG-only SQL).

**Dependency / ordering:** This is the **second** of the three remaining product pillars (Projects → **Inventory** → BOM). It depends only on the **already-merged Library pillar** (`V1::BaseController`, the `namespace :maker` routes, the `app/models/maker/` + `app/controllers/v1/maker/` directories) and the `users` table. The transaction model has an **optional** `project_id` (what consumed the stock) which is a plain nullable integer — it does **not** require the Projects pillar to be present (it's a soft reference, no FK, validated only if the Projects pillar exists; see Task 3). The **BOM pillar (third plan) depends on this pillar's `maker_inventory_items`.**

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite (dev/test) + Postgres (prod) — adapter-agnostic (no DB-level FK constraints, explicit indexes, `user_id` integer scoping, `decimal` columns with explicit precision/scale). Minitest (`ActiveSupport::TestCase` for models, `ActionDispatch::IntegrationTest` for the API).

**Conventions to follow (from the existing Library + Projects pillars):**
- Models: `belongs_to :user`; `self.table_name = "maker_*"`; enum-like value sets as frozen constants + `validates :x, inclusion:`; `dependent: :destroy` (or `:nullify` where a parent disappearing shouldn't delete children — see locations/suppliers); self-referential `belongs_to`/`has_many` for nested bins. See `app/models/maker/item.rb`, `app/models/maker/project.rb`.
- Migrations: `t.integer :user_id, null: false` (no `foreign_key:` constraint), `t.decimal …, precision: 12, scale: 3`, explicit `add_index`. Filenames continue the sequence — Projects used `20260615000008`–`20260615000009`, so this plan uses `20260615000010`–`20260615000013`.
- Controllers: `V1::Maker::XController < V1::BaseController`; scope **everything** through `current_user.maker_*`; `render json:`; `only:`-restricted routes; JSON rescue handlers inherited (`RecordNotFound`→404, `RecordInvalid`→422, `ParameterMissing`→400).
- Tests: API tests register a device via `POST /v1/auth/register` and send `Authorization: Bearer <token>`. See `test/integration/v1/maker/projects_test.rb`.

**Routes:** inside the existing `namespace :maker do … end` block in `config/routes.rb`, this plan adds:
```ruby
resources :locations, only: %i[index show create update destroy]
resources :suppliers, only: %i[index show create update destroy]
resources :inventory_items, only: %i[index show create update destroy] do
  member do
    post "adjust"          # create a stock transaction (delta + reason)
    get  "transactions"    # the item's ledger
  end
  collection { get "low_stock" }
end
```
(Add only the routes each task needs, as that task is implemented.)

---

## File Structure

**Migrations** (`db/migrate/`): `20260615000010_create_maker_locations.rb`, `20260615000011_create_maker_suppliers.rb`, `20260615000012_create_maker_inventory_items.rb`, `20260615000013_create_maker_inventory_transactions.rb`.

**Models** (`app/models/maker/`): `location.rb`, `supplier.rb`, `inventory_item.rb`, `inventory_transaction.rb`. Plus 4 `has_many` lines added to `app/models/user.rb`.

**Controllers** (`app/controllers/v1/maker/`): `locations_controller.rb`, `suppliers_controller.rb`, `inventory_items_controller.rb`. (The ledger is exposed through `inventory_items#adjust` + `#transactions`, not its own resource controller.)

**Tests**: model tests in `test/models/maker/`, API tests in `test/integration/v1/maker/`.

Responsibilities: `Maker::Location` is a self-referential nested bin tree. `Maker::Supplier` is a vendor reference. `Maker::InventoryItem` is the stocked thing carrying the denormalized `quantity_cached`. `Maker::InventoryTransaction` is the immutable ledger row + the atomic balance-update logic (the heart of this pillar).

---

## Task 1: `Maker::Location` (self-referential nested bins)

**Files:**
- Create: `db/migrate/20260615000010_create_maker_locations.rb`
- Create: `app/models/maker/location.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/location_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000010_create_maker_locations.rb`:
```ruby
class CreateMakerLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_locations do |t|
      t.integer :user_id, null: false
      t.integer :parent_id
      t.string  :name, null: false
      t.text    :description
      t.timestamps
    end
    add_index :maker_locations, [ :user_id, :parent_id ]
    add_index :maker_locations, [ :user_id, :name ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_locations)` succeeds; `db/schema.rb` now contains `maker_locations`.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/location_test.rb`:
```ruby
require "test_helper"

module Maker
  class LocationTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "loc@example.com") }

    test "valid with a name" do
      assert @user.maker_locations.build(name: "Shelf A").valid?
    end

    test "name is required" do
      assert_not @user.maker_locations.build(name: nil).valid?
    end

    test "a location can nest under a parent bin" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      bin = @user.maker_locations.create!(name: "Bin 1", parent: shelf)
      assert_equal shelf, bin.parent
      assert_equal [ "Bin 1" ], shelf.children.pluck(:name)
    end

    test "the parent must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_locations.create!(name: "Theirs")
      bin = @user.maker_locations.build(name: "Bin", parent_id: foreign.id)
      assert_not bin.valid?
      assert_includes bin.errors[:parent_id], "must reference your own location"
    end

    test "destroying a parent nullifies its children's parent_id (children survive)" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      bin = @user.maker_locations.create!(name: "Bin 1", parent: shelf)
      shelf.destroy
      assert Maker::Location.exists?(bin.id)
      assert_nil bin.reload.parent_id
    end

    test "scoped to the user via the association" do
      @user.maker_locations.create!(name: "mine")
      other = User.create!(email: "o2@example.com")
      other.maker_locations.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_locations.pluck(:name)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/location_test.rb`
Expected: FAIL — `uninitialized constant Maker::Location`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/location.rb`:
```ruby
module Maker
  class Location < ApplicationRecord
    self.table_name = "maker_locations"

    belongs_to :user
    belongs_to :parent, class_name: "Maker::Location", optional: true
    has_many :children, class_name: "Maker::Location", foreign_key: :parent_id,
             dependent: :nullify

    validates :name, presence: true
    validate :parent_belongs_to_user, if: -> { parent_id.present? }

    private

    def parent_belongs_to_user
      unless Maker::Location.exists?(id: parent_id, user_id: user_id)
        errors.add(:parent_id, "must reference your own location")
      end
    end
  end
end
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, add to the `has_many` block (after the maker associations from earlier pillars):
```ruby
  has_many :maker_locations, class_name: "Maker::Location", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/location_test.rb`
Expected: PASS (6 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000010_create_maker_locations.rb db/schema.rb \
        app/models/maker/location.rb app/models/user.rb \
        test/models/maker/location_test.rb
git commit -m "feat(maker): Maker::Location self-referential nested bins"
```

---

## Task 2: `Maker::Supplier`

**Files:**
- Create: `db/migrate/20260615000011_create_maker_suppliers.rb`
- Create: `app/models/maker/supplier.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/supplier_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000011_create_maker_suppliers.rb`:
```ruby
class CreateMakerSuppliers < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_suppliers do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :url
      t.text    :notes
      t.timestamps
    end
    add_index :maker_suppliers, [ :user_id, :name ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_suppliers)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/supplier_test.rb`:
```ruby
require "test_helper"

module Maker
  class SupplierTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "sup@example.com") }

    test "valid with a name" do
      assert @user.maker_suppliers.build(name: "McMaster-Carr").valid?
    end

    test "name is required" do
      assert_not @user.maker_suppliers.build(name: nil).valid?
    end

    test "stores url and notes" do
      s = @user.maker_suppliers.create!(name: "Digikey", url: "https://digikey.com", notes: "fast")
      assert_equal "https://digikey.com", s.url
      assert_equal "fast", s.notes
    end

    test "scoped to the user via the association" do
      @user.maker_suppliers.create!(name: "mine")
      other = User.create!(email: "o@example.com")
      other.maker_suppliers.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_suppliers.pluck(:name)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/supplier_test.rb`
Expected: FAIL — `uninitialized constant Maker::Supplier`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/supplier.rb`:
```ruby
module Maker
  class Supplier < ApplicationRecord
    self.table_name = "maker_suppliers"

    belongs_to :user

    validates :name, presence: true
  end
end
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after `maker_locations`:
```ruby
  has_many :maker_suppliers, class_name: "Maker::Supplier", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/supplier_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000011_create_maker_suppliers.rb db/schema.rb \
        app/models/maker/supplier.rb app/models/user.rb \
        test/models/maker/supplier_test.rb
git commit -m "feat(maker): Maker::Supplier model + migration"
```

---

## Task 3: `Maker::InventoryItem` (the stocked thing + cached balance)

**Files:**
- Create: `db/migrate/20260615000012_create_maker_inventory_items.rb`
- Create: `app/models/maker/inventory_item.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/inventory_item_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000012_create_maker_inventory_items.rb`:
```ruby
class CreateMakerInventoryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_inventory_items do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :part_number
      t.string  :category
      t.string  :unit, null: false, default: "each"
      t.decimal :quantity_cached, precision: 12, scale: 3, null: false, default: 0
      t.decimal :min_quantity, precision: 12, scale: 3, null: false, default: 0
      t.decimal :unit_cost, precision: 12, scale: 4
      t.integer :location_id
      t.integer :supplier_id
      t.text    :notes
      t.timestamps
    end
    add_index :maker_inventory_items, [ :user_id, :name ]
    add_index :maker_inventory_items, [ :user_id, :category ]
    add_index :maker_inventory_items, [ :user_id, :location_id ]
    add_index :maker_inventory_items, [ :user_id, :supplier_id ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_inventory_items)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/inventory_item_test.rb`:
```ruby
require "test_helper"

module Maker
  class InventoryItemTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "inv@example.com") }

    test "valid with a name" do
      assert @user.maker_inventory_items.build(name: "M3x10 bolt").valid?
    end

    test "name is required" do
      assert_not @user.maker_inventory_items.build(name: nil).valid?
    end

    test "unit must be in the allowed set" do
      assert_not @user.maker_inventory_items.build(name: "x", unit: "furlong").valid?
    end

    test "defaults unit to each and quantity_cached to 0" do
      item = @user.maker_inventory_items.create!(name: "x")
      assert_equal "each", item.unit
      assert_equal 0, item.quantity_cached
      assert_equal 0, item.min_quantity
    end

    test "location must belong to the same user" do
      other = User.create!(email: "o@example.com")
      loc = other.maker_locations.create!(name: "Theirs")
      item = @user.maker_inventory_items.build(name: "x", location_id: loc.id)
      assert_not item.valid?
      assert_includes item.errors[:location_id], "must reference your own location"
    end

    test "supplier must belong to the same user" do
      other = User.create!(email: "o2@example.com")
      sup = other.maker_suppliers.create!(name: "Theirs")
      item = @user.maker_inventory_items.build(name: "x", supplier_id: sup.id)
      assert_not item.valid?
      assert_includes item.errors[:supplier_id], "must reference your own supplier"
    end

    test "low_stock scope returns items at or below min_quantity" do
      low  = @user.maker_inventory_items.create!(name: "low",  min_quantity: 10, quantity_cached: 3)
      ok   = @user.maker_inventory_items.create!(name: "ok",   min_quantity: 10, quantity_cached: 50)
      edge = @user.maker_inventory_items.create!(name: "edge", min_quantity: 10, quantity_cached: 10)
      names = @user.maker_inventory_items.low_stock.pluck(:name)
      assert_includes names, "low"
      assert_includes names, "edge"
      assert_not_includes names, "ok"
    end

    test "rebuild_quantity_cached! recomputes from the ledger" do
      item = @user.maker_inventory_items.create!(name: "x", quantity_cached: 999)
      item.transactions.create!(user: @user, delta: 5, reason: "initial")
      item.transactions.create!(user: @user, delta: -2, reason: "consumed")
      item.update_column(:quantity_cached, 999) # simulate drift
      assert_equal 3, item.rebuild_quantity_cached!
      assert_equal 3, item.reload.quantity_cached
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/inventory_item_test.rb`
Expected: FAIL — `uninitialized constant Maker::InventoryItem` (and the ledger cases reference `transactions`, built in Task 4 — they'll pass once both this model and Task 4's model exist; this task focuses the item model first).

- [ ] **Step 5: Write the model**

Create `app/models/maker/inventory_item.rb`:
```ruby
module Maker
  class InventoryItem < ApplicationRecord
    self.table_name = "maker_inventory_items"

    UNITS = %w[each g kg m mm cm ml l pack roll sheet other].freeze

    belongs_to :user
    belongs_to :location, class_name: "Maker::Location", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true
    has_many :transactions, -> { order(created_at: :asc, id: :asc) },
             class_name: "Maker::InventoryTransaction", foreign_key: :inventory_item_id,
             dependent: :destroy

    validates :name, presence: true
    validates :unit, inclusion: { in: UNITS }
    validates :quantity_cached, :min_quantity, numericality: true
    validate :location_belongs_to_user, if: -> { location_id.present? }
    validate :supplier_belongs_to_user, if: -> { supplier_id.present? }

    # quantity_cached <= min_quantity  ==>  needs restocking.
    scope :low_stock, -> { where("quantity_cached <= min_quantity") }

    # Recompute the denormalized balance from the immutable ledger (drift repair / migration).
    def rebuild_quantity_cached!
      total = transactions.sum(:delta)
      update_column(:quantity_cached, total)
      total
    end

    private

    def location_belongs_to_user
      unless Maker::Location.exists?(id: location_id, user_id: user_id)
        errors.add(:location_id, "must reference your own location")
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
(The `transactions` association points at the model built in Task 4. `where("quantity_cached <= min_quantity")` is column-to-column SQL valid on both SQLite and Postgres.)

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after `maker_suppliers`:
```ruby
  has_many :maker_inventory_items, class_name: "Maker::InventoryItem", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/inventory_item_test.rb`
Expected: FAIL still — the two ledger cases need `Maker::InventoryTransaction` (Task 4). The validation/scope/default cases pass. Proceed to Task 4, then re-run this file (it goes fully green at the end of Task 4 Step 4).

- [ ] **Step 8: Commit (item model so far)**

```bash
git add db/migrate/20260615000012_create_maker_inventory_items.rb db/schema.rb \
        app/models/maker/inventory_item.rb app/models/user.rb \
        test/models/maker/inventory_item_test.rb
git commit -m "feat(maker): Maker::InventoryItem with cached balance + rebuild"
```

---

## Task 4: `Maker::InventoryTransaction` (immutable ledger + atomic balance update)

**Files:**
- Create: `db/migrate/20260615000013_create_maker_inventory_transactions.rb`
- Create: `app/models/maker/inventory_transaction.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/inventory_transaction_test.rb`

- [ ] **Step 1: Write the migration**

The ledger is **immutable** — no `updated_at`. Use `t.datetime :created_at` explicitly (not `t.timestamps`).

Create `db/migrate/20260615000013_create_maker_inventory_transactions.rb`:
```ruby
class CreateMakerInventoryTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_inventory_transactions do |t|
      t.integer  :user_id, null: false
      t.integer  :inventory_item_id, null: false
      t.decimal  :delta, precision: 12, scale: 3, null: false
      t.string   :reason, null: false, default: "adjusted"
      t.integer  :project_id
      t.text     :note
      t.datetime :created_at, null: false   # immutable ledger — no updated_at
    end
    add_index :maker_inventory_transactions, [ :user_id, :inventory_item_id, :created_at ],
              name: "index_maker_inventory_transactions_on_item_created_at"
    add_index :maker_inventory_transactions, [ :user_id, :project_id ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_inventory_transactions)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/inventory_transaction_test.rb`:
```ruby
require "test_helper"

module Maker
  class InventoryTransactionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "txn@example.com")
      @item = @user.maker_inventory_items.create!(name: "M3 bolt", quantity_cached: 0)
    end

    test "creating a transaction increments the item's cached balance atomically" do
      @item.transactions.create!(user: @user, delta: 25, reason: "initial")
      assert_equal 25, @item.reload.quantity_cached
      @item.transactions.create!(user: @user, delta: -4, reason: "consumed")
      assert_equal 21, @item.reload.quantity_cached
    end

    test "delta is required" do
      assert_not @item.transactions.build(user: @user, delta: nil).valid?
    end

    test "reason must be in the allowed set" do
      assert_not @item.transactions.build(user: @user, delta: 1, reason: "bogus").valid?
    end

    test "the ledger is immutable (no updated_at column)" do
      assert_not Maker::InventoryTransaction.column_names.include?("updated_at")
    end

    test "Apply helper inserts the row and updates the balance in one transaction" do
      txn = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      assert txn.persisted?
      assert_equal 7, @item.reload.quantity_cached
    end

    test "a failed balance update rolls back the ledger insert" do
      # An out-of-range reason fails validation BEFORE any write, so the count is unchanged.
      assert_no_difference -> { Maker::InventoryTransaction.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 1, reason: "bogus")
        end
      end
      assert_equal 0, @item.reload.quantity_cached
    end

    test "project_id is a soft reference (optional, nullable)" do
      txn = @item.transactions.create!(user: @user, delta: -1, reason: "consumed", project_id: nil)
      assert_nil txn.project_id
    end

    test "concurrent-style sequential applies sum correctly" do
      10.times { Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 3, reason: "restocked") }
      assert_equal 30, @item.reload.quantity_cached
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails, then write the model**

Run: `bin/rails test test/models/maker/inventory_transaction_test.rb`
Expected: FAIL — `uninitialized constant Maker::InventoryTransaction`.

Create `app/models/maker/inventory_transaction.rb`:
```ruby
module Maker
  class InventoryTransaction < ApplicationRecord
    self.table_name = "maker_inventory_transactions"

    # Immutable append-only ledger: no updated_at. Rails sets created_at on create.
    REASONS = %w[consumed restocked adjusted initial].freeze

    belongs_to :user
    belongs_to :inventory_item, class_name: "Maker::InventoryItem"

    validates :delta, presence: true, numericality: true
    validates :reason, inclusion: { in: REASONS }

    after_create :apply_to_cached_balance

    # Block edits/deletes of a posted ledger row from ordinary code paths.
    before_update  { raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable" }
    before_destroy :allow_destroy_only_with_parent

    # Atomic post: insert the ledger row AND move the item's cached balance in one DB transaction,
    # holding a row lock on the item so concurrent posts can't lose an update. Works on SQLite + PG.
    def self.apply!(item:, user:, delta:, reason: "adjusted", project_id: nil, note: nil)
      transaction do
        locked = Maker::InventoryItem.lock.find(item.id)   # SELECT ... FOR UPDATE on PG; serialized on SQLite
        txn = locked.transactions.create!(
          user: user, delta: delta, reason: reason, project_id: project_id, note: note
        )
        item.reload if item.equal?(locked) == false
        txn
      end
    end

    private

    # Keep quantity_cached == SUM(delta) without re-summing the whole ledger on the hot path:
    # increment by this row's delta. Runs inside apply!'s transaction (and the item is row-locked
    # there); a bare create! (e.g. in tests/seed) still keeps the balance correct.
    def apply_to_cached_balance
      Maker::InventoryItem.where(id: inventory_item_id)
                          .update_all([ "quantity_cached = quantity_cached + ?", delta ])
    end

    def allow_destroy_only_with_parent
      # Permit row removal only when the parent item is being destroyed (dependent: :destroy),
      # so the immutable ledger can't be cherry-picked apart while the item still exists.
      unless inventory_item.nil? || inventory_item.destroyed? || inventory_item.marked_for_destruction?
        raise ActiveRecord::ReadOnlyRecord, "inventory transactions are immutable"
      end
    end
  end
end
```
(`update_all(["quantity_cached = quantity_cached + ?", delta])` is a single atomic SQL UPDATE — no read-modify-write race — and is valid on both SQLite and Postgres. `apply!` additionally row-locks the item so a concurrent reader sees a consistent balance; the `after_create` increment fires inside that lock. A bare `transactions.create!` (used in some tests/seeds) still keeps the balance correct via the same `after_create` hook, just without the explicit lock.)

- [ ] **Step 5: Add the user association**

In `app/models/user.rb`, after `maker_inventory_items`:
```ruby
  has_many :maker_inventory_transactions, class_name: "Maker::InventoryTransaction", dependent: :destroy
```

- [ ] **Step 6: Run the transaction + item model tests to verify they pass**

Run: `bin/rails test test/models/maker/inventory_transaction_test.rb test/models/maker/inventory_item_test.rb`
Expected: PASS — both files fully green now (the ledger cases in `inventory_item_test.rb` from Task 3 resolve because `Maker::InventoryTransaction` exists).

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260615000013_create_maker_inventory_transactions.rb db/schema.rb \
        app/models/maker/inventory_transaction.rb app/models/user.rb \
        test/models/maker/inventory_transaction_test.rb \
        test/models/maker/inventory_item_test.rb
git commit -m "feat(maker): immutable inventory ledger + atomic cached-balance update"
```

---

## Task 5: `Maker::LocationsController` + `Maker::SuppliersController`

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/locations_controller.rb`, `app/controllers/v1/maker/suppliers_controller.rb`
- Test: `test/integration/v1/maker/locations_test.rb`, `test/integration/v1/maker/suppliers_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the existing `namespace :maker` block, add:
```ruby
      resources :locations, only: %i[index show create update destroy]
      resources :suppliers, only: %i[index show create update destroy]
```

- [ ] **Step 2: Write the failing integration tests**

Create `test/integration/v1/maker/locations_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class LocationsTest < ActionDispatch::IntegrationTest
      def register(email = "lc@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create and nest a location" do
        post "/v1/maker/locations", params: { location: { name: "Shelf A" } }, as: :json, headers: auth(@token)
        assert_response :created
        shelf = JSON.parse(response.body)["id"]
        post "/v1/maker/locations", params: { location: { name: "Bin 1", parent_id: shelf } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal shelf, JSON.parse(response.body)["parent_id"]
      end

      test "index lists only my locations" do
        post "/v1/maker/locations", params: { location: { name: "Mine" } }, as: :json, headers: auth(@token)
        other = register("o@example.com")
        post "/v1/maker/locations", params: { location: { name: "Theirs" } }, as: :json, headers: auth(other)
        get "/v1/maker/locations", headers: auth(@token)
        assert_equal [ "Mine" ], JSON.parse(response.body)["locations"].map { |l| l["name"] }
      end

      test "cannot nest under another user's location (422)" do
        other = register("o2@example.com")
        post "/v1/maker/locations", params: { location: { name: "Theirs" } }, as: :json, headers: auth(other)
        foreign = JSON.parse(response.body)["id"]
        post "/v1/maker/locations", params: { location: { name: "Bin", parent_id: foreign } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "destroy removes a location" do
        post "/v1/maker/locations", params: { location: { name: "X" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/locations/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
```

Create `test/integration/v1/maker/suppliers_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class SuppliersTest < ActionDispatch::IntegrationTest
      def register(email = "sp@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create a supplier" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Digikey", url: "https://digikey.com" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Digikey", body["name"]
        assert_equal "https://digikey.com", body["url"]
      end

      test "index lists only my suppliers" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Mine" } }, as: :json, headers: auth(@token)
        other = register("o@example.com")
        post "/v1/maker/suppliers", params: { supplier: { name: "Theirs" } }, as: :json, headers: auth(other)
        get "/v1/maker/suppliers", headers: auth(@token)
        assert_equal [ "Mine" ], JSON.parse(response.body)["suppliers"].map { |s| s["name"] }
      end

      test "update and destroy" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/suppliers/#{id}", params: { supplier: { name: "New" } }, as: :json, headers: auth(@token)
        assert_equal "New", JSON.parse(response.body)["name"]
        delete "/v1/maker/suppliers/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/integration/v1/maker/locations_test.rb test/integration/v1/maker/suppliers_test.rb`
Expected: FAIL — missing controllers.

- [ ] **Step 4: Write the controllers**

Create `app/controllers/v1/maker/locations_controller.rb`:
```ruby
module V1
  module Maker
    class LocationsController < V1::BaseController
      def index
        render json: { locations: current_user.maker_locations.order(:name).map { |l| location_json(l) } }
      end

      def show
        render json: location_json(current_user.maker_locations.find(params[:id]))
      end

      def create
        loc = current_user.maker_locations.new(location_params)
        loc.save!
        render json: location_json(loc), status: :created
      end

      def update
        loc = current_user.maker_locations.find(params[:id])
        loc.update!(location_params)
        render json: location_json(loc)
      end

      def destroy
        current_user.maker_locations.find(params[:id]).destroy!
        head :no_content
      end

      private

      def location_params
        params.require(:location).permit(:name, :description, :parent_id)
      end

      def location_json(loc)
        { id: loc.id, name: loc.name, description: loc.description, parent_id: loc.parent_id,
          created_at: loc.created_at, updated_at: loc.updated_at }
      end
    end
  end
end
```

Create `app/controllers/v1/maker/suppliers_controller.rb`:
```ruby
module V1
  module Maker
    class SuppliersController < V1::BaseController
      def index
        render json: { suppliers: current_user.maker_suppliers.order(:name).map { |s| supplier_json(s) } }
      end

      def show
        render json: supplier_json(current_user.maker_suppliers.find(params[:id]))
      end

      def create
        sup = current_user.maker_suppliers.create!(supplier_params)
        render json: supplier_json(sup), status: :created
      end

      def update
        sup = current_user.maker_suppliers.find(params[:id])
        sup.update!(supplier_params)
        render json: supplier_json(sup)
      end

      def destroy
        current_user.maker_suppliers.find(params[:id]).destroy!
        head :no_content
      end

      private

      def supplier_params
        params.require(:supplier).permit(:name, :url, :notes)
      end

      def supplier_json(sup)
        { id: sup.id, name: sup.name, url: sup.url, notes: sup.notes,
          created_at: sup.created_at, updated_at: sup.updated_at }
      end
    end
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/integration/v1/maker/locations_test.rb test/integration/v1/maker/suppliers_test.rb`
Expected: PASS (locations 4 runs + suppliers 3 runs, 0 failures). (Cross-user parent → 422 via the `RecordInvalid` rescue.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb \
        app/controllers/v1/maker/locations_controller.rb \
        app/controllers/v1/maker/suppliers_controller.rb \
        test/integration/v1/maker/locations_test.rb \
        test/integration/v1/maker/suppliers_test.rb
git commit -m "feat(maker): locations + suppliers CRUD API"
```

---

## Task 6: `Maker::InventoryItemsController` — CRUD + adjust + transactions + low_stock

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/inventory_items_controller.rb`
- Test: `test/integration/v1/maker/inventory_items_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the `maker` block (after `suppliers`), add:
```ruby
      resources :inventory_items, only: %i[index show create update destroy] do
        member do
          post "adjust"
          get  "transactions"
        end
        collection { get "low_stock" }
      end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/inventory_items_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class InventoryItemsTest < ActionDispatch::IntegrationTest
      def register(email = "ii@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      def create_item(attrs = {}, token: @token)
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "M3 bolt" }.merge(attrs) },
             as: :json, headers: auth(token)
        JSON.parse(response.body)["id"]
      end

      test "create returns the item with a zero balance" do
        post "/v1/maker/inventory_items",
             params: { inventory_item: { name: "M3 bolt", unit: "each", min_quantity: 50 } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "M3 bolt", body["name"]
        assert_equal "0.0", body["quantity_cached"].to_s.sub(/\.0+\z/, ".0")
        assert_equal "50.0", body["min_quantity"].to_s.sub(/\.0+\z/, ".0")
      end

      test "adjust posts a transaction and moves the cached balance" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 100, reason: "restocked" }, as: :json, headers: auth(@token)
        assert_response :created
        assert_equal 100.0, JSON.parse(response.body)["quantity_cached"].to_f

        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: -7, reason: "consumed" }, as: :json, headers: auth(@token)
        assert_equal 93.0, JSON.parse(response.body)["quantity_cached"].to_f
      end

      test "adjust rejects an invalid reason with 422" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 1, reason: "bogus" }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "transactions lists the ledger newest-first" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 10, reason: "initial" },
             as: :json, headers: auth(@token)
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: -2, reason: "consumed" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/#{id}/transactions", headers: auth(@token)
        assert_response :success
        deltas = JSON.parse(response.body)["transactions"].map { |t| t["delta"].to_f }
        assert_equal [ -2.0, 10.0 ], deltas
      end

      test "low_stock returns items at or below min_quantity" do
        low = create_item({ name: "low", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{low}/adjust", params: { delta: 3, reason: "initial" },
             as: :json, headers: auth(@token)
        ok = create_item({ name: "ok", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{ok}/adjust", params: { delta: 99, reason: "initial" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/low_stock", headers: auth(@token)
        assert_response :success
        names = JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
        assert_includes names, "low"
        assert_not_includes names, "ok"
      end

      test "index is filterable by category" do
        create_item({ name: "bolt", category: "fasteners" })
        create_item({ name: "wire", category: "electronics" })
        get "/v1/maker/inventory_items", params: { category: "fasteners" }, headers: auth(@token)
        assert_equal [ "bolt" ], JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
      end

      test "another user cannot adjust my item" do
        id = create_item
        other = register("o@example.com")
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 1, reason: "restocked" },
             as: :json, headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/inventory_items"
        assert_response :unauthorized
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/inventory_items_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::InventoryItemsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/inventory_items_controller.rb`:
```ruby
module V1
  module Maker
    class InventoryItemsController < V1::BaseController
      def index
        items = current_user.maker_inventory_items.order(:name)
        items = items.where(category: params[:category]) if params[:category].present?
        items = items.where(location_id: params[:location_id]) if params[:location_id].present?
        render json: { inventory_items: items.map { |i| item_json(i) } }
      end

      def show
        render json: item_json(current_user.maker_inventory_items.find(params[:id]), full: true)
      end

      def create
        item = current_user.maker_inventory_items.new(item_params)
        item.save!
        render json: item_json(item, full: true), status: :created
      end

      def update
        item = current_user.maker_inventory_items.find(params[:id])
        item.update!(item_params)
        render json: item_json(item, full: true)
      end

      def destroy
        current_user.maker_inventory_items.find(params[:id]).destroy!
        head :no_content
      end

      # POST /v1/maker/inventory_items/:id/adjust { delta, reason, project_id?, note? }
      def adjust
        item = current_user.maker_inventory_items.find(params[:id])
        Maker::InventoryTransaction.apply!(
          item: item, user: current_user,
          delta: params.require(:delta), reason: params.fetch(:reason, "adjusted"),
          project_id: params[:project_id], note: params[:note]
        )
        render json: item_json(item.reload, full: true), status: :created
      end

      # GET /v1/maker/inventory_items/:id/transactions
      def transactions
        item = current_user.maker_inventory_items.find(params[:id])
        ledger = item.transactions.reorder(created_at: :desc, id: :desc)
        render json: { transactions: ledger.map { |t| txn_json(t) } }
      end

      # GET /v1/maker/inventory_items/low_stock
      def low_stock
        items = current_user.maker_inventory_items.low_stock.order(:name)
        render json: { inventory_items: items.map { |i| item_json(i) } }
      end

      private

      def item_params
        params.require(:inventory_item).permit(
          :name, :part_number, :category, :unit, :min_quantity, :unit_cost,
          :location_id, :supplier_id, :notes
        )
      end

      def item_json(item, full: false)
        base = {
          id: item.id, name: item.name, part_number: item.part_number, category: item.category,
          unit: item.unit, quantity_cached: item.quantity_cached, min_quantity: item.min_quantity,
          location_id: item.location_id, supplier_id: item.supplier_id,
          updated_at: item.updated_at
        }
        return base unless full
        base.merge(unit_cost: item.unit_cost, notes: item.notes, created_at: item.created_at)
      end

      def txn_json(t)
        { id: t.id, delta: t.delta, reason: t.reason, project_id: t.project_id,
          note: t.note, created_at: t.created_at }
      end
    end
  end
end
```
(`apply!` posts the ledger row + moves the balance atomically — the controller never touches `quantity_cached` directly. `quantity_cached` not being in `item_params` means a client can't set the balance out-of-band; it only ever moves through the ledger.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/inventory_items_test.rb`
Expected: PASS (8 runs, 0 failures). (Cross-user `find` → 404; invalid reason → 422 via `RecordInvalid` from inside `apply!`'s transaction, which rolls back the row.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/inventory_items_controller.rb \
        test/integration/v1/maker/inventory_items_test.rb
git commit -m "feat(maker): inventory items CRUD + adjust/ledger/low_stock API"
```

---

## Task 7: Full-suite green + tenant-isolation sweep

**Files:**
- Test: `test/integration/v1/maker/inventory_isolation_test.rb`

- [ ] **Step 1: Write a focused cross-user isolation test**

Create `test/integration/v1/maker/inventory_isolation_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every inventory resource must 404 (never leak) across users.
    class InventoryIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-iiso@example.com")
        @b = register("b-iiso@example.com")
        post "/v1/maker/locations", params: { location: { name: "A's shelf" } }, as: :json, headers: auth(@a)
        @loc = JSON.parse(response.body)["id"]
        post "/v1/maker/suppliers", params: { supplier: { name: "A's vendor" } }, as: :json, headers: auth(@a)
        @sup = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "A's bolt" } },
             as: :json, headers: auth(@a)
        @item = JSON.parse(response.body)["id"]
      end

      test "B cannot read, mutate, or adjust A's inventory resources" do
        get    "/v1/maker/locations/#{@loc}", headers: auth(@b);                       assert_response :not_found
        delete "/v1/maker/suppliers/#{@sup}", headers: auth(@b);                       assert_response :not_found
        get    "/v1/maker/inventory_items/#{@item}", headers: auth(@b);                assert_response :not_found
        patch  "/v1/maker/inventory_items/#{@item}", params: { inventory_item: { name: "hax" } },
               as: :json, headers: auth(@b)
        assert_response :not_found
        post   "/v1/maker/inventory_items/#{@item}/adjust", params: { delta: 1, reason: "restocked" },
               as: :json, headers: auth(@b)
        assert_response :not_found
        get    "/v1/maker/inventory_items/#{@item}/transactions", headers: auth(@b);   assert_response :not_found
      end

      test "B's inventory index is empty" do
        get "/v1/maker/inventory_items", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["inventory_items"]
      end
    end
  end
end
```

- [ ] **Step 2: Run the new test**

Run: `bin/rails test test/integration/v1/maker/inventory_isolation_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 3: Run the entire suite**

Run: `bin/rails test`
Expected: PASS — all Inventory tests plus the pre-existing Library + Projects + server tests green, 0 failures, 0 errors.

- [ ] **Step 4: Commit**

```bash
git add test/integration/v1/maker/inventory_isolation_test.rb
git commit -m "test(maker): cross-user isolation sweep for the inventory API"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** `maker_locations` self-ref nested bins (Task 1); `maker_suppliers` name/url/notes (Task 2); `maker_inventory_items` with name/part_number/category/unit/quantity_cached(denormalized)/min_quantity/unit_cost/location_id/supplier_id/notes + `low_stock` + `rebuild_quantity_cached!` (Task 3); `maker_inventory_transactions` immutable ledger (no `updated_at`) with delta/reason(consumed/restocked/adjusted/initial)/project_id?/note/created_at + **atomic** insert-row + increment-cached-balance + a rebuild method (Task 4); locations/suppliers CRUD (Task 5); inventory CRUD + `adjust` (creates a transaction) + `transactions` ledger + `low_stock` query (Task 6); tenant isolation (Task 7). ✓
- **Ledger atomicity (the heart of the pillar):** `InventoryTransaction.apply!` opens a DB transaction, row-locks the item (`.lock.find` → `FOR UPDATE` on PG, serialized on SQLite), creates the ledger row, and the `after_create` hook increments `quantity_cached` with a single atomic `update_all("quantity_cached = quantity_cached + ?")` — no read-modify-write race. A validation failure (e.g. bad reason) rolls the whole thing back (tested). `rebuild_quantity_cached!` recomputes `SUM(delta)` (drift repair). ✓
- **Adapter-agnostic:** `decimal(precision, scale)` columns; `where("quantity_cached <= min_quantity")` and `update_all("… + ?")` are column/parameterized SQL valid on SQLite + Postgres; no PG-only functions; explicit `created_at` (no `updated_at`) on the ledger; no DB FK constraints; explicit `add_index`. ✓
- **Project soft-reference:** `maker_inventory_transactions.project_id` is a plain nullable integer with no FK and no model validation requiring the Projects pillar — Inventory installs and passes its full suite whether or not Projects is present. ✓
- **Migration numbering:** continues at `20260615000010`–`20260615000013` (Projects ended at `0009`), contiguous. ✓
- **Type consistency:** `low_stock` scope (Task 3) drives both `InventoryItem#low_stock` (model) and `inventory_items#low_stock` (controller, Task 6); `transactions` association (Task 3) is populated by Task 4 and serialized in Task 6; `apply!` signature (Task 4) matches the controller call (Task 6); JSON keys (`quantity_cached`, `min_quantity`, `inventory_items`, `transactions`, `delta`, `reason`) consistent across model/controller/test. ✓
- **Placeholder scan:** every step ships complete code, exact paths, exact commands, and expected output — no `TODO`/`add validation`/`...` stubs. ✓

---

## Out of scope (follow-on plans)

- **BOM pillar** (`docs/superpowers/plans/2026-06-15-bom-pillar-server.md`) — depends on **this** pillar's `maker_inventory_items` (a BOM line can link an inventory item) and the Projects pillar's `maker_projects` (a BOM belongs to a project). A FUTURE hook there: a BOM line that links an inventory item could drive a `consumed` transaction when a build consumes it — designed but not built.
- **Tauri client + web UI** for inventory (stock list/adjust/low-stock/locations/suppliers) — mirrors the Library client groundwork in `client/maker-app`.
- **Barcode/label scanning, reorder automation, multi-location stock splits** — later product features, not part of the data-model baseline.
