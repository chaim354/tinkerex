# Maker Library Pillar — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the server side of the maker-app **Library/Catalog pillar** — a findable catalog layered over the existing file-sync engine, so a maker can store 3D models / CAD / LightBurn files (made or downloaded) with titles, instructions, tags, and collections, and find them again later.

**Architecture:** A new `Maker::`-namespaced product layer **inside the existing Rails 8 app** (the 37signals majestic-monolith choice — same DB, same `users` table, same device-token auth). Product records are **server-authoritative** (normal integer-PK Rails CRUD over a new `/v1/maker/*` API), *not* synced into the local SQLite tree. They reference synced files only by the file layer's stable string `node_id` (+ optional `version_id`). The core object is a `Maker::Item` — a "grouped thing" (a model file + its instructions + variant files + images), with files attached polymorphically by role. Findability comes from tags + collections + a filtered list endpoint. Tasks are first-class and standalone (optional polymorphic owner). Previews/thumbnails and the heavier Projects/Inventory/BOM pillars are **out of scope** for this plan (separate plans follow).

**Tech Stack:** Rails 8.1, Ruby 3.4, SQLite (dev/test) + Postgres (prod) — adapter-agnostic (no DB-level FK constraints, explicit indexes, `user_id` integer scoping, matching the existing `nodes`/`versions` schema). Minitest (`ActiveSupport::TestCase` for models, `ActionDispatch::IntegrationTest` for the API).

**Conventions to follow (from the existing codebase):**
- Models: `belongs_to :user`; enum-like value sets as frozen constants + `validates :x, inclusion:`; uniqueness scoped `{ scope: :user_id }`; `scope`s for common filters. See `app/models/node.rb`.
- Migrations: `t.integer :user_id, null: false` (no `foreign_key:` constraint — the codebase has none), explicit `t.index`. Timestamp-prefixed filenames `YYYYMMDDHHMMSS_*`.
- Controllers: `V1::Maker::XController < V1::BaseController` (inherits device-token auth + JSON rescue handlers); scope **everything** through `current_user.maker_items` etc. (tenant isolation); `render json:`.
- Tests: API tests register a device via `POST /v1/auth/register` and send `Authorization: Bearer <token>`. See `test/integration/v1/sync_flow_test.rb`.

**Routes:** new block inside the existing `namespace :v1 do … end` in `config/routes.rb`:
```ruby
namespace :maker do
  resources :items do
    resources :file_attachments, only: %i[create destroy], shallow: true
    resources :taggings, only: %i[create destroy], shallow: true
    member { post "collections" }   # add/remove this item to a collection
  end
  resources :tags, only: %i[index create destroy]
  resources :collections do
    member { get "items" }
  end
  resources :tasks
end
```
(Add only the routes each task needs, as that task is implemented — not all at once.)

---

## File Structure

**Migrations** (`db/migrate/`): one per table group — `*_create_maker_items.rb`, `*_create_maker_file_attachments.rb`, `*_create_maker_tags.rb`, `*_create_maker_taggings.rb`, `*_create_maker_collections.rb`, `*_create_maker_collection_items.rb`, `*_create_maker_tasks.rb`.

**Models** (`app/models/maker/`): `item.rb`, `file_attachment.rb`, `tag.rb`, `tagging.rb`, `collection.rb`, `collection_item.rb`, `task.rb`. Each `Maker::X < ApplicationRecord`. Plus 7 `has_many` lines added to `app/models/user.rb`.

**Controllers** (`app/controllers/v1/maker/`): `items_controller.rb`, `file_attachments_controller.rb`, `taggings_controller.rb`, `tags_controller.rb`, `collections_controller.rb`, `tasks_controller.rb`.

**Tests**: model tests in `test/models/maker/`, API tests in `test/integration/v1/maker/`.

Responsibilities: `Maker::Item` is the catalog record + the "grouped thing" root. `Maker::FileAttachment` is the polymorphic file↔object link (the file-layer seam). `Maker::Tag`/`Tagging` are the polymorphic tagging spine. `Maker::Collection`/`CollectionItem` are cross-cutting groups. `Maker::Task` is the standalone-capable task. Each controller is thin CRUD scoped to `current_user`.

---

## Task 1: `Maker::Item` model + migration

**Files:**
- Create: `db/migrate/20260615000001_create_maker_items.rb`
- Create: `app/models/maker/item.rb`
- Modify: `app/models/user.rb` (add `has_many :maker_items`)
- Test: `test/models/maker/item_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000001_create_maker_items.rb`:
```ruby
class CreateMakerItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_items do |t|
      t.integer :user_id, null: false
      t.string  :title, null: false
      t.string  :summary
      t.text    :description
      t.text    :instructions
      t.string  :item_type, null: false, default: "other"
      t.string  :origin, null: false, default: "downloaded"
      t.string  :source_url
      t.string  :source_name
      t.string  :primary_node_id
      t.boolean :favorited, null: false, default: false
      t.timestamps
    end
    add_index :maker_items, [ :user_id, :item_type ]
    add_index :maker_items, [ :user_id, :title ]
    add_index :maker_items, [ :user_id, :favorited ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_items)` succeeds; `db/schema.rb` now contains `maker_items`.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/item_test.rb`:
```ruby
require "test_helper"

module Maker
  class ItemTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "item@example.com") }

    test "valid with a title" do
      item = @user.maker_items.build(title: "Benchy")
      assert item.valid?
    end

    test "title is required" do
      item = @user.maker_items.build(title: nil)
      assert_not item.valid?
      assert_includes item.errors[:title], "can't be blank"
    end

    test "item_type must be in the allowed set" do
      item = @user.maker_items.build(title: "x", item_type: "bogus")
      assert_not item.valid?
    end

    test "defaults item_type to other and origin to downloaded" do
      item = @user.maker_items.create!(title: "x")
      assert_equal "other", item.item_type
      assert_equal "downloaded", item.origin
    end

    test "scoped to the user via the association" do
      @user.maker_items.create!(title: "mine")
      other = User.create!(email: "other@example.com")
      other.maker_items.create!(title: "theirs")
      assert_equal [ "mine" ], @user.maker_items.pluck(:title)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/item_test.rb`
Expected: FAIL — `uninitialized constant Maker::Item` (and `undefined method 'maker_items'`).

- [ ] **Step 5: Write the model**

Create `app/models/maker/item.rb`:
```ruby
module Maker
  class Item < ApplicationRecord
    self.table_name = "maker_items"

    belongs_to :user

    ITEM_TYPES = %w[model_3d cad lightburn electronics other].freeze
    ORIGINS    = %w[self_made downloaded modified].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"

    validates :title, presence: true
    validates :item_type, inclusion: { in: ITEM_TYPES }
    validates :origin, inclusion: { in: ORIGINS }

    scope :of_type, ->(t) { where(item_type: t) if t.present? }
    scope :favorited, -> { where(favorited: true) }
  end
end
```
(The `file_attachments`/`taggings` associations point at models built in Tasks 2–3; they don't break this task's tests because nothing exercises them yet.)

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, add to the `has_many` block (after `has_many :file_locks, dependent: :destroy`):
```ruby
  has_many :maker_items, class_name: "Maker::Item", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/item_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000001_create_maker_items.rb db/schema.rb \
        app/models/maker/item.rb app/models/user.rb test/models/maker/item_test.rb
git commit -m "feat(maker): Maker::Item catalog model + migration"
```

---

## Task 2: `Maker::FileAttachment` (the file-layer seam)

**Files:**
- Create: `db/migrate/20260615000002_create_maker_file_attachments.rb`
- Create: `app/models/maker/file_attachment.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/file_attachment_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000002_create_maker_file_attachments.rb`:
```ruby
class CreateMakerFileAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_file_attachments do |t|
      t.integer :user_id, null: false
      t.string  :attachable_type, null: false
      t.integer :attachable_id, null: false
      t.string  :node_id, null: false
      t.string  :version_id
      t.string  :role, null: false, default: "other"
      t.string  :label
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_file_attachments, [ :user_id, :attachable_type, :attachable_id ],
              name: "index_maker_file_attachments_on_attachable"
    add_index :maker_file_attachments, [ :user_id, :node_id ]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_file_attachments)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/file_attachment_test.rb`:
```ruby
require "test_helper"

module Maker
  class FileAttachmentTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "att@example.com")
      @item = @user.maker_items.create!(title: "Lamp")
    end

    test "attaches a file to an item by node_id" do
      att = @item.file_attachments.create!(
        user: @user, node_id: "node-123", role: "model"
      )
      assert_equal @item, att.attachable
      assert_equal "node-123", att.node_id
    end

    test "node_id is required" do
      att = @item.file_attachments.build(user: @user, node_id: nil)
      assert_not att.valid?
    end

    test "role must be in the allowed set" do
      att = @item.file_attachments.build(user: @user, node_id: "n", role: "bogus")
      assert_not att.valid?
    end

    test "destroying the item destroys its attachments" do
      @item.file_attachments.create!(user: @user, node_id: "n1")
      assert_difference -> { Maker::FileAttachment.count }, -1 do
        @item.destroy
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/file_attachment_test.rb`
Expected: FAIL — `uninitialized constant Maker::FileAttachment`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/file_attachment.rb`:
```ruby
module Maker
  class FileAttachment < ApplicationRecord
    self.table_name = "maker_file_attachments"

    belongs_to :user
    belongs_to :attachable, polymorphic: true

    ROLES = %w[model instructions image source_archive gcode other].freeze

    validates :node_id, presence: true
    validates :role, inclusion: { in: ROLES }
  end
end
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after the `maker_items` line:
```ruby
  has_many :maker_file_attachments, class_name: "Maker::FileAttachment", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/file_attachment_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000002_create_maker_file_attachments.rb db/schema.rb \
        app/models/maker/file_attachment.rb app/models/user.rb \
        test/models/maker/file_attachment_test.rb
git commit -m "feat(maker): Maker::FileAttachment polymorphic file-layer link"
```

---

## Task 3: `Maker::Tag` + `Maker::Tagging` (findability spine)

**Files:**
- Create: `db/migrate/20260615000003_create_maker_tags.rb`
- Create: `db/migrate/20260615000004_create_maker_taggings.rb`
- Create: `app/models/maker/tag.rb`, `app/models/maker/tagging.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/tag_test.rb`

- [ ] **Step 1: Write the migrations**

Create `db/migrate/20260615000003_create_maker_tags.rb`:
```ruby
class CreateMakerTags < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_tags do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :color
      t.timestamps
    end
    add_index :maker_tags, [ :user_id, :name ], unique: true
  end
end
```

Create `db/migrate/20260615000004_create_maker_taggings.rb`:
```ruby
class CreateMakerTaggings < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_taggings do |t|
      t.integer :user_id, null: false
      t.integer :tag_id, null: false
      t.string  :taggable_type, null: false
      t.integer :taggable_id, null: false
      t.timestamps
    end
    add_index :maker_taggings, [ :user_id, :taggable_type, :taggable_id ],
              name: "index_maker_taggings_on_taggable"
    add_index :maker_taggings, [ :tag_id, :taggable_type, :taggable_id ],
              unique: true, name: "index_maker_taggings_unique"
  end
end
```

- [ ] **Step 2: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both tables created.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/tag_test.rb`:
```ruby
require "test_helper"

module Maker
  class TagTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "tag@example.com")
      @item = @user.maker_items.create!(title: "Gear")
    end

    test "tag name is unique per user" do
      @user.maker_tags.create!(name: "printed")
      dup = @user.maker_tags.build(name: "printed")
      assert_not dup.valid?
    end

    test "same name allowed for a different user" do
      @user.maker_tags.create!(name: "printed")
      other = User.create!(email: "o@example.com")
      assert other.maker_tags.build(name: "printed").valid?
    end

    test "tagging links a tag to an item" do
      tag = @user.maker_tags.create!(name: "useful")
      @item.taggings.create!(user: @user, tag: tag)
      assert_equal [ "useful" ], @item.reload.tags.pluck(:name)
    end

    test "destroying a tag removes its taggings" do
      tag = @user.maker_tags.create!(name: "useful")
      @item.taggings.create!(user: @user, tag: tag)
      assert_difference -> { Maker::Tagging.count }, -1 do
        tag.destroy
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/tag_test.rb`
Expected: FAIL — `uninitialized constant Maker::Tag`.

- [ ] **Step 5: Write the models**

Create `app/models/maker/tag.rb`:
```ruby
module Maker
  class Tag < ApplicationRecord
    self.table_name = "maker_tags"

    belongs_to :user
    has_many :taggings, class_name: "Maker::Tagging", dependent: :destroy

    normalizes :name, with: ->(n) { n.to_s.strip.downcase }
    validates :name, presence: true, uniqueness: { scope: :user_id }
  end
end
```

Create `app/models/maker/tagging.rb`:
```ruby
module Maker
  class Tagging < ApplicationRecord
    self.table_name = "maker_taggings"

    belongs_to :user
    belongs_to :tag, class_name: "Maker::Tag"
    belongs_to :taggable, polymorphic: true

    validates :tag_id, uniqueness: { scope: %i[taggable_type taggable_id] }
  end
end
```

- [ ] **Step 6: Add the user associations**

In `app/models/user.rb`, after `maker_file_attachments`:
```ruby
  has_many :maker_tags, class_name: "Maker::Tag", dependent: :destroy
  has_many :maker_taggings, class_name: "Maker::Tagging", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/tag_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000003_create_maker_tags.rb \
        db/migrate/20260615000004_create_maker_taggings.rb db/schema.rb \
        app/models/maker/tag.rb app/models/maker/tagging.rb app/models/user.rb \
        test/models/maker/tag_test.rb
git commit -m "feat(maker): Maker::Tag + polymorphic Maker::Tagging"
```

---

## Task 4: `Maker::Collection` + `Maker::CollectionItem`

**Files:**
- Create: `db/migrate/20260615000005_create_maker_collections.rb`
- Create: `db/migrate/20260615000006_create_maker_collection_items.rb`
- Create: `app/models/maker/collection.rb`, `app/models/maker/collection_item.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/collection_test.rb`

- [ ] **Step 1: Write the migrations**

Create `db/migrate/20260615000005_create_maker_collections.rb`:
```ruby
class CreateMakerCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_collections do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.text    :description
      t.timestamps
    end
    add_index :maker_collections, [ :user_id, :name ]
  end
end
```

Create `db/migrate/20260615000006_create_maker_collection_items.rb`:
```ruby
class CreateMakerCollectionItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_collection_items do |t|
      t.integer :user_id, null: false
      t.integer :collection_id, null: false
      t.integer :item_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_collection_items, [ :collection_id, :item_id ],
              unique: true, name: "index_maker_collection_items_unique"
    add_index :maker_collection_items, [ :user_id, :collection_id, :position ],
              name: "index_maker_collection_items_on_position"
  end
end
```

- [ ] **Step 2: Run the migrations**

Run: `bin/rails db:migrate`
Expected: both tables created.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/collection_test.rb`:
```ruby
require "test_helper"

module Maker
  class CollectionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "coll@example.com")
      @item = @user.maker_items.create!(title: "Knob")
      @collection = @user.maker_collections.create!(name: "Lamp v2 parts")
    end

    test "name is required" do
      assert_not @user.maker_collections.build(name: nil).valid?
    end

    test "adds an item to the collection" do
      @collection.collection_items.create!(user: @user, item: @item)
      assert_equal [ "Knob" ], @collection.reload.items.pluck(:title)
    end

    test "the same item cannot be added twice" do
      @collection.collection_items.create!(user: @user, item: @item)
      dup = @collection.collection_items.build(user: @user, item: @item)
      assert_not dup.valid?
    end

    test "destroying the collection removes memberships but not items" do
      @collection.collection_items.create!(user: @user, item: @item)
      @collection.destroy
      assert Maker::Item.exists?(@item.id)
      assert_equal 0, Maker::CollectionItem.count
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/collection_test.rb`
Expected: FAIL — `uninitialized constant Maker::Collection`.

- [ ] **Step 5: Write the models**

Create `app/models/maker/collection.rb`:
```ruby
module Maker
  class Collection < ApplicationRecord
    self.table_name = "maker_collections"

    belongs_to :user
    has_many :collection_items, -> { order(:position) },
             class_name: "Maker::CollectionItem", dependent: :destroy
    has_many :items, through: :collection_items, class_name: "Maker::Item"

    validates :name, presence: true
  end
end
```

Create `app/models/maker/collection_item.rb`:
```ruby
module Maker
  class CollectionItem < ApplicationRecord
    self.table_name = "maker_collection_items"

    belongs_to :user
    belongs_to :collection, class_name: "Maker::Collection"
    belongs_to :item, class_name: "Maker::Item"

    validates :item_id, uniqueness: { scope: :collection_id }
  end
end
```

- [ ] **Step 6: Add the user associations**

In `app/models/user.rb`, after `maker_taggings`:
```ruby
  has_many :maker_collections, class_name: "Maker::Collection", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/collection_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000005_create_maker_collections.rb \
        db/migrate/20260615000006_create_maker_collection_items.rb db/schema.rb \
        app/models/maker/collection.rb app/models/maker/collection_item.rb \
        app/models/user.rb test/models/maker/collection_test.rb
git commit -m "feat(maker): Maker::Collection + CollectionItem grouping"
```

---

## Task 5: `Maker::Task` (standalone, optional polymorphic owner)

**Files:**
- Create: `db/migrate/20260615000007_create_maker_tasks.rb`
- Create: `app/models/maker/task.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/task_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260615000007_create_maker_tasks.rb`:
```ruby
class CreateMakerTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_tasks do |t|
      t.integer  :user_id, null: false
      t.string   :title, null: false
      t.text     :notes
      t.string   :status, null: false, default: "todo"
      t.integer  :position, null: false, default: 0
      t.datetime :completed_at
      t.string   :taskable_type          # nullable — a task can stand alone
      t.integer  :taskable_id
      t.timestamps
    end
    add_index :maker_tasks, [ :user_id, :status ]
    add_index :maker_tasks, [ :user_id, :taskable_type, :taskable_id ],
              name: "index_maker_tasks_on_taskable"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:maker_tasks)` succeeds.

- [ ] **Step 3: Write the failing model test**

Create `test/models/maker/task_test.rb`:
```ruby
require "test_helper"

module Maker
  class TaskTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "task@example.com")
      @item = @user.maker_items.create!(title: "Bracket")
    end

    test "a standalone task with no owner is valid" do
      task = @user.maker_tasks.build(title: "Buy M3 bolts")
      assert task.valid?
      assert_nil task.taskable
    end

    test "a task can be owned by an item" do
      task = @user.maker_tasks.create!(title: "Print this", taskable: @item)
      assert_equal @item, task.taskable
    end

    test "status must be in the allowed set" do
      assert_not @user.maker_tasks.build(title: "x", status: "bogus").valid?
    end

    test "complete! stamps completed_at and sets status done" do
      task = @user.maker_tasks.create!(title: "x")
      task.complete!
      assert_equal "done", task.status
      assert_not_nil task.completed_at
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `bin/rails test test/models/maker/task_test.rb`
Expected: FAIL — `uninitialized constant Maker::Task`.

- [ ] **Step 5: Write the model**

Create `app/models/maker/task.rb`:
```ruby
module Maker
  class Task < ApplicationRecord
    self.table_name = "maker_tasks"

    belongs_to :user
    belongs_to :taskable, polymorphic: true, optional: true

    STATUSES = %w[todo doing done].freeze

    validates :title, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :open, -> { where.not(status: "done") }

    def complete!
      update!(status: "done", completed_at: Time.current)
    end
  end
end
```

- [ ] **Step 6: Add the user association**

In `app/models/user.rb`, after `maker_collections`:
```ruby
  has_many :maker_tasks, class_name: "Maker::Task", dependent: :destroy
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/models/maker/task_test.rb`
Expected: PASS (4 runs, 0 failures).

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260615000007_create_maker_tasks.rb db/schema.rb \
        app/models/maker/task.rb app/models/user.rb test/models/maker/task_test.rb
git commit -m "feat(maker): Maker::Task standalone + optional polymorphic owner"
```

---

## Task 6: `Maker::ItemsController` — CRUD + serialization

**Files:**
- Modify: `config/routes.rb` (add the `namespace :maker` block, items only for now)
- Create: `app/controllers/v1/maker/items_controller.rb`
- Test: `test/integration/v1/maker/items_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the existing `namespace :v1 do … end` block (after the `nodes` routes), add:
```ruby
    namespace :maker do
      resources :items
    end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/items_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class ItemsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "m@example.com", device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup { @token = register }

      test "create returns the item json" do
        post "/v1/maker/items",
             params: { item: { title: "Benchy", item_type: "model_3d", origin: "downloaded",
                               source_url: "https://printables.com/benchy" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Benchy", body["title"]
        assert_equal "model_3d", body["item_type"]
        assert body["id"].present?
      end

      test "index lists only the current user's items" do
        post "/v1/maker/items", params: { item: { title: "Mine" } }, as: :json, headers: auth(@token)
        # a second user
        post "/v1/auth/register", params: { email: "two@example.com", device_name: "d" }, as: :json
        other = JSON.parse(response.body)["device_token"]
        post "/v1/maker/items", params: { item: { title: "Theirs" } }, as: :json, headers: auth(other)

        get "/v1/maker/items", headers: auth(@token)
        assert_response :success
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Mine" ], titles
      end

      test "show returns an item with its attachments and tags" do
        post "/v1/maker/items", params: { item: { title: "Lamp" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "Lamp", body["title"]
        assert_equal [], body["file_attachments"]
        assert_equal [], body["tags"]
      end

      test "update changes fields" do
        post "/v1/maker/items", params: { item: { title: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/items/#{id}", params: { item: { title: "New", favorited: true } },
              as: :json, headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "New", body["title"]
        assert_equal true, body["favorited"]
      end

      test "destroy removes the item" do
        post "/v1/maker/items", params: { item: { title: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :not_found
      end

      test "another user cannot show my item" do
        post "/v1/maker/items", params: { item: { title: "Private" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        post "/v1/auth/register", params: { email: "x@example.com", device_name: "d" }, as: :json
        other = JSON.parse(response.body)["device_token"]
        get "/v1/maker/items/#{id}", headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/items"
        assert_response :unauthorized
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/items_test.rb`
Expected: FAIL — routing error / `uninitialized constant V1::Maker::ItemsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/items_controller.rb`:
```ruby
module V1
  module Maker
    class ItemsController < V1::BaseController
      def index
        items = current_user.maker_items.order(updated_at: :desc)
        render json: { items: items.map { |i| item_json(i) } }
      end

      def show
        item = current_user.maker_items.find(params[:id])
        render json: item_json(item, full: true)
      end

      def create
        item = current_user.maker_items.new(item_params)
        item.save!
        render json: item_json(item, full: true), status: :created
      end

      def update
        item = current_user.maker_items.find(params[:id])
        item.update!(item_params)
        render json: item_json(item, full: true)
      end

      def destroy
        current_user.maker_items.find(params[:id]).destroy!
        head :no_content
      end

      private

      def item_params
        params.require(:item).permit(
          :title, :summary, :description, :instructions, :item_type, :origin,
          :source_url, :source_name, :primary_node_id, :favorited
        )
      end

      def item_json(item, full: false)
        base = {
          id: item.id, title: item.title, summary: item.summary,
          item_type: item.item_type, origin: item.origin, source_url: item.source_url,
          source_name: item.source_name, primary_node_id: item.primary_node_id,
          favorited: item.favorited, created_at: item.created_at, updated_at: item.updated_at
        }
        return base unless full
        base.merge(
          description: item.description,
          instructions: item.instructions,
          file_attachments: item.file_attachments.map { |a| attachment_json(a) },
          tags: item.tags.map(&:name)
        )
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

Run: `bin/rails test test/integration/v1/maker/items_test.rb`
Expected: PASS (7 runs, 0 failures). (Cross-user `find` returns 404 because `BaseController` rescues `ActiveRecord::RecordNotFound`.)

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/items_controller.rb \
        test/integration/v1/maker/items_test.rb
git commit -m "feat(maker): v1 items CRUD API"
```

---

## Task 7: `Maker::FileAttachmentsController` — attach/detach files

**Files:**
- Modify: `config/routes.rb` (nest `file_attachments` under items)
- Create: `app/controllers/v1/maker/file_attachments_controller.rb`
- Test: `test/integration/v1/maker/file_attachments_test.rb`

- [ ] **Step 1: Add the nested routes**

In `config/routes.rb`, change the `maker` block to:
```ruby
    namespace :maker do
      resources :items do
        resources :file_attachments, only: %i[create destroy], shallow: true
      end
    end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/file_attachments_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class FileAttachmentsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "fa@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Lamp" } }, as: :json, headers: auth(@token)
        @item_id = JSON.parse(response.body)["id"]
      end

      test "attach a file to an item by node_id" do
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "node-abc", role: "model", label: "body.step" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "node-abc", body["node_id"]
        assert_equal "model", body["role"]

        get "/v1/maker/items/#{@item_id}", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["file_attachments"].size
      end

      test "detach a file" do
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "n1" } }, as: :json, headers: auth(@token)
        att_id = JSON.parse(response.body)["id"]
        delete "/v1/maker/file_attachments/#{att_id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/items/#{@item_id}", headers: auth(@token)
        assert_equal 0, JSON.parse(response.body)["file_attachments"].size
      end

      test "cannot attach to another user's item" do
        other = register_other
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "n" } }, as: :json, headers: auth(other)
        assert_response :not_found
      end

      def register_other
        post "/v1/auth/register", params: { email: "other-fa@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/file_attachments_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::FileAttachmentsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/file_attachments_controller.rb`:
```ruby
module V1
  module Maker
    class FileAttachmentsController < V1::BaseController
      def create
        item = current_user.maker_items.find(params[:item_id])
        att = item.file_attachments.new(attachment_params.merge(user: current_user))
        att.save!
        render json: attachment_json(att), status: :created
      end

      def destroy
        att = current_user.maker_file_attachments.find(params[:id])
        att.destroy!
        head :no_content
      end

      private

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

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/file_attachments_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/file_attachments_controller.rb \
        test/integration/v1/maker/file_attachments_test.rb
git commit -m "feat(maker): attach/detach files to items by node_id"
```

---

## Task 8: `Maker::TagsController` + `Maker::TaggingsController` — tag & filter

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/tags_controller.rb`, `app/controllers/v1/maker/taggings_controller.rb`
- Modify: `app/controllers/v1/maker/items_controller.rb` (filter `index` by `?tag=` / `?type=` / `?q=`)
- Test: `test/integration/v1/maker/tags_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, expand the `maker` block:
```ruby
    namespace :maker do
      resources :items do
        resources :file_attachments, only: %i[create destroy], shallow: true
        resources :taggings, only: %i[create destroy], shallow: true
      end
      resources :tags, only: %i[index create destroy]
    end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/tags_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class TagsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "tg@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Vase", item_type: "model_3d" } },
             as: :json, headers: auth(@token)
        @vase = JSON.parse(response.body)["id"]
        post "/v1/maker/items", params: { item: { title: "Plate", item_type: "cad" } },
             as: :json, headers: auth(@token)
        @plate = JSON.parse(response.body)["id"]
      end

      test "tag an item by name (creating the tag on the fly)" do
        post "/v1/maker/items/#{@vase}/taggings",
             params: { name: "printed" }, as: :json, headers: auth(@token)
        assert_response :created
        get "/v1/maker/items/#{@vase}", headers: auth(@token)
        assert_equal [ "printed" ], JSON.parse(response.body)["tags"]
      end

      test "tags index lists the user's tags" do
        post "/v1/maker/items/#{@vase}/taggings", params: { name: "useful" }, as: :json, headers: auth(@token)
        get "/v1/maker/tags", headers: auth(@token)
        assert_response :success
        assert_equal [ "useful" ], JSON.parse(response.body)["tags"].map { |t| t["name"] }
      end

      test "filter items by tag" do
        post "/v1/maker/items/#{@vase}/taggings", params: { name: "printed" }, as: :json, headers: auth(@token)
        get "/v1/maker/items", params: { tag: "printed" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Vase" ], titles
      end

      test "filter items by type" do
        get "/v1/maker/items", params: { type: "cad" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Plate" ], titles
      end

      test "search items by title text" do
        get "/v1/maker/items", params: { q: "vas" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Vase" ], titles
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/tags_test.rb`
Expected: FAIL — missing `taggings`/`tags` routes and controllers.

- [ ] **Step 4: Write the taggings controller**

Create `app/controllers/v1/maker/taggings_controller.rb`:
```ruby
module V1
  module Maker
    class TaggingsController < V1::BaseController
      # POST /v1/maker/items/:item_id/taggings { name: "printed" }
      def create
        item = current_user.maker_items.find(params[:item_id])
        tag  = current_user.maker_tags.find_or_create_by!(name: params.require(:name))
        item.taggings.find_or_create_by!(user: current_user, tag: tag)
        render json: { tag: tag.name }, status: :created
      end

      # DELETE /v1/maker/taggings/:id  (id = tagging id)
      def destroy
        current_user.maker_taggings.find(params[:id]).destroy!
        head :no_content
      end
    end
  end
end
```

- [ ] **Step 5: Write the tags controller**

Create `app/controllers/v1/maker/tags_controller.rb`:
```ruby
module V1
  module Maker
    class TagsController < V1::BaseController
      def index
        tags = current_user.maker_tags.order(:name)
        render json: { tags: tags.map { |t| { id: t.id, name: t.name, color: t.color } } }
      end

      def create
        tag = current_user.maker_tags.create!(params.require(:tag).permit(:name, :color))
        render json: { id: tag.id, name: tag.name, color: tag.color }, status: :created
      end

      def destroy
        current_user.maker_tags.find(params[:id]).destroy!
        head :no_content
      end
    end
  end
end
```

- [ ] **Step 6: Add filtering to the items `index`**

In `app/controllers/v1/maker/items_controller.rb`, replace the `index` method with:
```ruby
      def index
        items = current_user.maker_items.order(updated_at: :desc)
        items = items.of_type(params[:type])
        if params[:tag].present?
          tag = current_user.maker_tags.find_by(name: params[:tag].to_s.strip.downcase)
          ids = tag ? tag.taggings.where(taggable_type: "Maker::Item").pluck(:taggable_id) : []
          items = items.where(id: ids)
        end
        if params[:q].present?
          like = "%#{params[:q].to_s.strip}%"
          items = items.where("title LIKE :q OR summary LIKE :q OR description LIKE :q", q: like)
        end
        render json: { items: items.map { |i| item_json(i) } }
      end
```
(`of_type` is the scope defined on `Maker::Item` in Task 1; it no-ops when `type` is blank. `LIKE` is case-insensitive on SQLite by default for ASCII and works on Postgres; tag names are normalized to lowercase by the model.)

- [ ] **Step 7: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/tags_test.rb test/integration/v1/maker/items_test.rb`
Expected: PASS (all green — confirms filtering didn't break the base CRUD).

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/tags_controller.rb \
        app/controllers/v1/maker/taggings_controller.rb \
        app/controllers/v1/maker/items_controller.rb \
        test/integration/v1/maker/tags_test.rb
git commit -m "feat(maker): tagging + tag/type/text filtering on items"
```

---

## Task 9: `Maker::CollectionsController` — grouping

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/collections_controller.rb`
- Test: `test/integration/v1/maker/collections_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add inside the `maker` block (after `tags`):
```ruby
      resources :collections do
        member do
          get  "items"
          post "items", action: :add_item
          delete "items/:item_id", action: :remove_item
        end
      end
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/collections_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class CollectionsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "cl@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Knob" } }, as: :json, headers: auth(@token)
        @item = JSON.parse(response.body)["id"]
      end

      test "create a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Lamp parts" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "Lamp parts", JSON.parse(response.body)["name"]
      end

      test "add and list items in a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Box" } }, as: :json, headers: auth(@token)
        cid = JSON.parse(response.body)["id"]
        post "/v1/maker/collections/#{cid}/items", params: { item_id: @item }, as: :json, headers: auth(@token)
        assert_response :created
        get "/v1/maker/collections/#{cid}/items", headers: auth(@token)
        assert_equal [ "Knob" ], JSON.parse(response.body)["items"].map { |i| i["title"] }
      end

      test "remove an item from a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Box" } }, as: :json, headers: auth(@token)
        cid = JSON.parse(response.body)["id"]
        post "/v1/maker/collections/#{cid}/items", params: { item_id: @item }, as: :json, headers: auth(@token)
        delete "/v1/maker/collections/#{cid}/items/#{@item}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/collections/#{cid}/items", headers: auth(@token)
        assert_equal [], JSON.parse(response.body)["items"]
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/collections_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::CollectionsController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/collections_controller.rb`:
```ruby
module V1
  module Maker
    class CollectionsController < V1::BaseController
      def index
        render json: { collections: current_user.maker_collections.order(:name).map { |c| collection_json(c) } }
      end

      def create
        c = current_user.maker_collections.create!(params.require(:collection).permit(:name, :description))
        render json: collection_json(c), status: :created
      end

      def update
        c = current_user.maker_collections.find(params[:id])
        c.update!(params.require(:collection).permit(:name, :description))
        render json: collection_json(c)
      end

      def destroy
        current_user.maker_collections.find(params[:id]).destroy!
        head :no_content
      end

      # GET /v1/maker/collections/:id/items
      def items
        c = current_user.maker_collections.find(params[:id])
        render json: { items: c.items.map { |i| { id: i.id, title: i.title, item_type: i.item_type } } }
      end

      # POST /v1/maker/collections/:id/items { item_id }
      def add_item
        c = current_user.maker_collections.find(params[:id])
        item = current_user.maker_items.find(params.require(:item_id))
        c.collection_items.find_or_create_by!(user: current_user, item: item)
        head :created
      end

      # DELETE /v1/maker/collections/:id/items/:item_id
      def remove_item
        c = current_user.maker_collections.find(params[:id])
        c.collection_items.where(item_id: params[:item_id]).destroy_all
        head :no_content
      end

      private

      def collection_json(c)
        { id: c.id, name: c.name, description: c.description,
          item_count: c.collection_items.count, updated_at: c.updated_at }
      end
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/collections_test.rb`
Expected: PASS (3 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/collections_controller.rb \
        test/integration/v1/maker/collections_test.rb
git commit -m "feat(maker): collections + membership API"
```

---

## Task 10: `Maker::TasksController` — standalone tasks

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/v1/maker/tasks_controller.rb`
- Test: `test/integration/v1/maker/tasks_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add inside the `maker` block (after `collections`):
```ruby
      resources :tasks
```

- [ ] **Step 2: Write the failing integration test**

Create `test/integration/v1/maker/tasks_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    class TasksTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "tk@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create a standalone task" do
        post "/v1/maker/tasks", params: { task: { title: "Buy filament" } }, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Buy filament", body["title"]
        assert_equal "todo", body["status"]
      end

      test "create a task owned by an item" do
        post "/v1/maker/items", params: { item: { title: "Bracket" } }, as: :json, headers: auth(@token)
        item_id = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks",
             params: { task: { title: "Print it", taskable_type: "Maker::Item", taskable_id: item_id } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal item_id, JSON.parse(response.body)["taskable_id"]
      end

      test "index lists tasks; open scope excludes done" do
        post "/v1/maker/tasks", params: { task: { title: "A" } }, as: :json, headers: auth(@token)
        post "/v1/maker/tasks", params: { task: { title: "B" } }, as: :json, headers: auth(@token)
        id_b = JSON.parse(response.body)["id"]
        patch "/v1/maker/tasks/#{id_b}", params: { task: { status: "done" } }, as: :json, headers: auth(@token)
        get "/v1/maker/tasks", params: { open: true }, headers: auth(@token)
        titles = JSON.parse(response.body)["tasks"].map { |t| t["title"] }
        assert_equal [ "A" ], titles
      end

      test "update can complete a task" do
        post "/v1/maker/tasks", params: { task: { title: "X" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/tasks/#{id}", params: { task: { status: "done" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "done", JSON.parse(response.body)["status"]
        assert_not_nil JSON.parse(response.body)["completed_at"]
      end

      test "destroy removes a task" do
        post "/v1/maker/tasks", params: { task: { title: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/tasks/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bin/rails test test/integration/v1/maker/tasks_test.rb`
Expected: FAIL — `uninitialized constant V1::Maker::TasksController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/v1/maker/tasks_controller.rb`:
```ruby
module V1
  module Maker
    class TasksController < V1::BaseController
      def index
        tasks = current_user.maker_tasks.order(:position, :created_at)
        tasks = tasks.open if ActiveModel::Type::Boolean.new.cast(params[:open])
        render json: { tasks: tasks.map { |t| task_json(t) } }
      end

      def show
        render json: task_json(current_user.maker_tasks.find(params[:id]))
      end

      def create
        task = current_user.maker_tasks.new(task_params)
        task.completed_at ||= Time.current if task.status == "done"
        task.save!
        render json: task_json(task), status: :created
      end

      def update
        task = current_user.maker_tasks.find(params[:id])
        attrs = task_params.to_h
        attrs["completed_at"] = Time.current if attrs["status"] == "done" && task.completed_at.nil?
        attrs["completed_at"] = nil if attrs["status"].present? && attrs["status"] != "done"
        task.update!(attrs)
        render json: task_json(task)
      end

      def destroy
        current_user.maker_tasks.find(params[:id]).destroy!
        head :no_content
      end

      private

      def task_params
        params.require(:task).permit(:title, :notes, :status, :position, :taskable_type, :taskable_id)
      end

      def task_json(t)
        { id: t.id, title: t.title, notes: t.notes, status: t.status, position: t.position,
          completed_at: t.completed_at, taskable_type: t.taskable_type, taskable_id: t.taskable_id,
          created_at: t.created_at, updated_at: t.updated_at }
      end
    end
  end
end
```
(The `taskable_type` is set verbatim from params; only `Maker::Item` is a valid owner today. A later task can validate the type against an allow-list when more owner types exist — YAGNI now.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `bin/rails test test/integration/v1/maker/tasks_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/v1/maker/tasks_controller.rb \
        test/integration/v1/maker/tasks_test.rb
git commit -m "feat(maker): standalone tasks API"
```

---

## Task 11: Full-suite green + tenant-isolation sweep

**Files:**
- Test: `test/integration/v1/maker/isolation_test.rb`

- [ ] **Step 1: Write a focused cross-user isolation test**

Create `test/integration/v1/maker/isolation_test.rb`:
```ruby
require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every maker resource must 404 (never leak) across users.
    class IsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-iso@example.com")
        @b = register("b-iso@example.com")
        post "/v1/maker/items", params: { item: { title: "A's item" } }, as: :json, headers: auth(@a)
        @item = JSON.parse(response.body)["id"]
        post "/v1/maker/collections", params: { collection: { name: "A's coll" } }, as: :json, headers: auth(@a)
        @coll = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks", params: { task: { title: "A's task" } }, as: :json, headers: auth(@a)
        @task = JSON.parse(response.body)["id"]
      end

      test "B cannot read, update, or delete A's resources" do
        get    "/v1/maker/items/#{@item}", headers: auth(@b);                          assert_response :not_found
        patch  "/v1/maker/items/#{@item}", params: { item: { title: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/items/#{@item}", headers: auth(@b);                          assert_response :not_found
        get    "/v1/maker/collections/#{@coll}/items", headers: auth(@b);              assert_response :not_found
        delete "/v1/maker/tasks/#{@task}", headers: auth(@b);                          assert_response :not_found
      end

      test "B's index is empty" do
        get "/v1/maker/items", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["items"]
      end
    end
  end
end
```

- [ ] **Step 2: Run the new test**

Run: `bin/rails test test/integration/v1/maker/isolation_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 3: Run the entire suite**

Run: `bin/rails test`
Expected: PASS — all maker tests plus the pre-existing ~144 server tests green, 0 failures, 0 errors.

- [ ] **Step 4: Commit**

```bash
git add test/integration/v1/maker/isolation_test.rb
git commit -m "test(maker): cross-user isolation sweep for the library API"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** items (Task 1/6), grouped-thing file attachment by node_id (Task 2/7), tags+taggings findability (Task 3/8), collections (Task 4/9), standalone tasks with optional polymorphic owner (Task 5/10), search/filter by tag/type/text (Task 8), tenant isolation (Task 11). Previews + Projects/Inventory/BOM are explicitly out of scope (separate plans). ✓
- **Type consistency:** `Maker::Item.of_type` scope (Task 1) is used by the items `index` filter (Task 8); `file_attachments`/`taggings` associations declared in Task 1 are populated in Tasks 2–3; `taskable` optional polymorphic (Task 5) matches the controller params (Task 10); JSON key names (`file_attachments`, `tags`, `taskable_id`) are consistent across model/controller/test. ✓
- **Placeholder scan:** every step ships complete code, exact paths, exact commands, and expected output. ✓

---

## Out of scope (follow-on plans)

- **Plan 2 — Library, Tauri client:** `sync-client` API methods (`list_items`, `create_item`, `attach_file`, `tag_item`, `list_tags`, …) mirroring `ServerClient`'s existing method style, Tauri `#[tauri::command]` wrappers, and the library browse/detail/tag UI in `client/maker-app`.
- **Plan 3 — Previews:** `maker_previews` + ActiveStorage (`rails active_storage:install`) + a server render job (Three.js/FreeCAD/CadQuery) producing thumbnails per `(node_id, version_id)`.
- **Plan 4+ — Projects / Inventory (items+locations+suppliers+ledger) / BOM** pillars (data model already designed in the planning session).
