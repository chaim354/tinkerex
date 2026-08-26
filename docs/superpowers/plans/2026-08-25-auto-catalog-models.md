# Auto-catalogued Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every `.stl`/`.3mf` (and the rest of the `model` role) in the library appears at `/models`
without anyone walking the Import flow.

**Architecture:** A folder is either a *shelf* or a *model*; the nearest shelf ancestor decides which.
Shelves are user-editable path patterns; models are keyed by `node_id` so a rename keeps one entry.
A sweep over the `nodes` catalog -- never a hook per upload door (CLAUDE.md §14f) -- creates the rows.

**Tech Stack:** Rails 8, Minitest, Solid Queue recurring jobs, server-rendered Hotwire.

**Spec:** `docs/superpowers/specs/2026-08-25-auto-catalog-models-design.md`. Read it first; it holds
the arguments this plan implements.

---

## Read before you start

You are working in the **maker app**. Five things about this repo will bite you if you skip them:

1. **CLAUDE.md §15 requires you to mutation-check every guard you write.** After a test that exists
   to *forbid* something goes green, break the thing it guards, confirm the test goes **RED**, then
   restore. A guard that has never failed has not been shown to work. Several steps below make this
   explicit; do it for the others too.
2. **The three backend legs must behave identically.** Nothing in this feature may branch on
   `LIBRARY_BACKEND`. **The sweep never calls the port at all** -- it creates database rows and
   nothing else -- which is why its tests need no share library on disk, unlike
   `test/services/maker/project_intake_test.rb`, which moves real files and therefore needs one.
3. **Never call `Maker::Model#ensure_library_folder!` from the sweep.** It *creates*
   `Models/<slug>` as a side effect of looking, which at sweep scale would mint a folder per model.
   §14f records the same bug in `Projects::AttachmentsController#relocate`.
4. **Assert query counts as constant in N, never as a literal.** The counts differ per backend, so
   a literal pins one leg and fails the other two. `test/integration/web/page_query_budget_test.rb`
   is the pattern to copy.
5. **`docs/STATUS.md` is part of this branch, not a follow-up** (§15). Task 9.

Run the whole suite with `bin/rails test`. Run one file with
`bin/rails test test/path/to/file_test.rb`, one case with `-n test_name`.

---

## File structure

**Created:**

| path | responsibility |
|---|---|
| `db/migrate/20260825150000_create_maker_shelves.rb` | the `maker_shelves` table |
| `db/migrate/20260825150100_add_auto_catalog_to_maker_models.rb` | `origin`, `auto_node_id`, `dismissed_at` on models; `shelves_seeded_at` on users |
| `app/models/maker/shelf.rb` | one shelf row: path validation, pattern matching, seeding |
| `app/services/maker/library_tree.rb` | in-memory index of live dir nodes; node_id to path |
| `app/services/maker/model_intake.rb` | the rule, and the sweep that applies it |
| `app/jobs/maker/model_intake_job.rb` | the scheduled fan-out |
| `app/controllers/shelves_controller.rb` | the settings page |
| `app/views/shelves/index.html.erb` | the shelf list and add form |
| `lib/tasks/models.rake` | `rake models:catalog` |
| `docs/invariants/model-intake.md` | the area invariants, anchored at §14k |

**Modified:** `app/models/user.rb`, `app/models/maker/model.rb`, `app/controllers/models_controller.rb`,
`app/views/models/index.html.erb`, `app/jobs/library/scan_job.rb`, `config/recurring.yml`,
`config/routes.rb`, `CLAUDE.md`, `docs/STATUS.md`.

---

## Task 1: The `maker_shelves` table and `Maker::Shelf`

**Files:**
- Create: `db/migrate/20260825150000_create_maker_shelves.rb`
- Create: `app/models/maker/shelf.rb`
- Modify: `app/models/user.rb`
- Test: `test/models/maker/shelf_test.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260825150000_create_maker_shelves.rb`:

```ruby
# frozen_string_literal: true

# A SHELF IS A FOLDER THAT IS NOT ITSELF A MODEL -- its loose model-role files are each their own
# model and each of its subfolders is one model. See docs/invariants/model-intake.md.
#
# THE KEY IS A PATH PATTERN, NOT A node_id, and that is deliberate: the seeded
# `Projects/*/models` rule covers a folder per project, none of which need exist yet, and no
# node_id can express that. The cost -- a renamed folder silently stops matching -- is made
# visible in the settings UI rather than argued away.
class CreateMakerShelves < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_shelves do |t|
      t.integer :user_id, null: false
      # "" is the library root. Segments joined by "/". One "*" per segment is a wildcard.
      t.string :path, null: false, default: ""
      t.timestamps
    end
    add_index :maker_shelves, %i[user_id path], unique: true
  end
end
```

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/shelf_test.rb`:

```ruby
require "test_helper"

module Maker
  class ShelfTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shelf-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    test "the root is a valid path and matches the root" do
      shelf = @user.maker_shelves.create!(path: "")
      assert_predicate shelf, :persisted?
      assert Maker::Shelf.matches?("", "")
    end

    test "a literal path matches only itself" do
      assert Maker::Shelf.matches?("Models", "Models")
      assert_not Maker::Shelf.matches?("Models", "models")
      assert_not Maker::Shelf.matches?("Models", "Models/Benchy")
      assert_not Maker::Shelf.matches?("Models", "")
    end

    test "a star matches exactly one segment" do
      assert Maker::Shelf.matches?("Projects/*/models", "Projects/desk-lamp/models")
      assert_not Maker::Shelf.matches?("Projects/*/models", "Projects/models")
      assert_not Maker::Shelf.matches?("Projects/*/models", "Projects/desk-lamp/models/parts")
    end

    # THE REJECTIONS ARE THE POINT. A shelf path is compared against real library paths, so a
    # traversal segment or a reserved name is a typo worth refusing at the door -- and this asks
    # the SAME two questions LibraryBrowseController#create_folder asks rather than a private,
    # weaker spelling (§14b).
    test "traversal, absolute, empty and reserved segments are refused" do
      [ "..", "a/../b", "/Models", "Models/", "Models//parts", ".trash", "a/.trash/b",
        ".maker-tmp-x" ].each do |bad|
        shelf = @user.maker_shelves.new(path: bad)
        assert_not shelf.valid?, "#{bad.inspect} should be refused"
        assert_includes shelf.errors[:path].join, "isn't allowed"
      end
    end

    test "a star is allowed only as a whole segment" do
      assert @user.maker_shelves.new(path: "Projects/*/models").valid?
      assert_not @user.maker_shelves.new(path: "Projects/*x/models").valid?
    end

    test "paths are unique per user" do
      @user.maker_shelves.create!(path: "Models")
      assert_not @user.maker_shelves.new(path: "Models").valid?
    end

    # EVERY SEEDED PATH MUST SURVIVE THIS CLASS'S OWN VALIDATION. Nothing else checks that: once
    # seeding is wired up, an invalid SEEDS entry surfaces as create! raising for every user on
    # their first visit, at the door rather than here.
    test "every seeded path is valid" do
      Maker::Shelf::SEEDS.each do |seeded|
        assert @user.maker_shelves.new(path: seeded).valid?, "#{seeded.inspect} should be valid"
      end
    end

    # NIL IS NOT THE ROOT. "" is; a missing path is a caller that forgot one, and letting it
    # validate defers the failure to the database's NOT NULL as a 500.
    test "a nil path is refused rather than deferred to the database" do
      shelf = @user.maker_shelves.new(path: nil)
      assert_not shelf.valid?
      assert_includes shelf.errors[:path].join, "isn't allowed"
    end
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

Run: `bin/rails test test/models/maker/shelf_test.rb`
Expected: FAIL with `uninitialized constant Maker::Shelf`.

- [ ] **Step 4: Write the model**

Create `app/models/maker/shelf.rb`:

```ruby
module Maker
  # A folder that is NOT itself a model: its loose model-role files are each their own model, and
  # each of its subfolders is one model claiming its whole subtree. The nearest shelf ancestor of a
  # file decides which. Rules and reasoning: docs/invariants/model-intake.md.
  class Shelf < ApplicationRecord
    self.table_name = "maker_shelves"

    belongs_to :user

    # What ships. All three are ordinary deletable rows -- see .seed_once! for why they are seeded
    # exactly once rather than ensured on every sweep.
    SEEDS = [ "", "Models", "Projects/*/models" ].freeze

    # A whole segment may be this and nothing else. `*x` is not a wildcard, it is a filename we
    # cannot match, so it is refused rather than silently never matching.
    WILDCARD = "*".freeze

    validates :path, uniqueness: { scope: :user_id }
    validate  :path_segments_are_allowed

    # Does `pattern` name `path`? Both are "" for the library root, segments joined by "/".
    # A "*" segment matches exactly one segment -- never zero, never several.
    def self.matches?(pattern, path)
      ps = pattern.to_s.split("/")
      xs = path.to_s.split("/")
      return false unless ps.size == xs.size

      ps.zip(xs).all? { |p, x| p == WILDCARD || p == x }
    end

    # ONCE PER USER, GUARDED BY users.shelves_seeded_at. Called from both doors that can be the
    # first a user reaches -- the settings page and the sweep -- so neither has to be first.
    #
    # WITHOUT THE STAMP, deleting every shelf resurrects all three on the next tick: the
    # fight-the-user shape §14f exists to prevent, and the same argument that makes a dismissed
    # model stay dismissed.
    def self.seed_once!(user)
      return if user.shelves_seeded_at.present?

      SEEDS.each { |path| user.maker_shelves.create!(path:) }
      user.update_column(:shelves_seeded_at, Time.current)
    end

    private

    # THE SAME TWO QUESTIONS EVERY OTHER LEAF-NAME DOOR ASKS, composed rather than re-spelled:
    # Maker::MoveNode.valid_leaf_name? for syntax and Library::ReservedNames.reserved? for the
    # library's own namespace (§14b -- a private, weaker spelling is how `..` becomes a live node).
    def path_segments_are_allowed
      # NIL IS NOT THE ROOT, AND THE DIFFERENCE MATTERS AT A DOOR. `""` is the library root and is
      # valid; a MISSING path is a caller that forgot one. Without this the record validates and
      # then dies on the database's NOT NULL, turning a routine form error into a 500 in
      # ShelvesController.
      return errors.add(:path, "isn't allowed - a shelf needs a path (\"\" is the library root)") if path.nil?

      raw = path
      # The library root, which is a perfectly ordinary shelf and has no segments to check.
      return if raw.empty?

      if raw.start_with?("/") || raw.end_with?("/") || raw.include?("//")
        errors.add(:path, "isn't allowed - use folder names joined by /, with no leading or trailing slash")
        return
      end

      raw.split("/").each do |segment|
        next if segment == WILDCARD
        # THE WILDCARD CLAUSE IS THIS CLASS'S OWN AND CANNOT BE DELEGATED. `*` is an ordinary legal
        # filename byte, so valid_leaf_name?("*x") is TRUE and reserved?("*x") is FALSE -- neither
        # composed check knows this class has a wildcard syntax at all. Without it `Projects/*x/models`
        # saves happily and then matches nothing, forever, silently.
        next if !segment.include?(WILDCARD) &&
                Maker::MoveNode.valid_leaf_name?(segment) &&
                !Library::ReservedNames.reserved?(segment)

        errors.add(:path, "isn't allowed - #{segment.inspect} can't be a folder name")
        return
      end
    end
  end
end
```

- [ ] **Step 5: Add the association**

In `app/models/user.rb`, beside the other `has_many :maker_*` lines:

```ruby
has_many :maker_shelves, class_name: "Maker::Shelf", dependent: :destroy
```

- [ ] **Step 6: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/shelf_test.rb`
Expected: PASS, 8 runs.

- [ ] **Step 7: Mutation-check the rejection guard**

Comment out the `path_segments_are_allowed` validation line, run the test, confirm the
"traversal, absolute, empty and reserved segments are refused" case goes **RED**, then restore.

- [ ] **Step 8: Commit**

```bash
git add db/migrate/20260825150000_create_maker_shelves.rb app/models/maker/shelf.rb app/models/user.rb test/models/maker/shelf_test.rb db/schema.rb
git commit -m "Add maker_shelves: a folder that is not itself a model"
```

---

## Task 2: The catalog columns and the seeding stamp

**Files:**
- Create: `db/migrate/20260825150100_add_auto_catalog_to_maker_models.rb`
- Modify: `app/models/maker/model.rb`
- Test: `test/models/maker/shelf_test.rb` (append), `test/models/maker/model_test.rb` (append)

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260825150100_add_auto_catalog_to_maker_models.rb`:

```ruby
# frozen_string_literal: true

# THE CATALOG BECOMES A VIEW OVER THE LIBRARY, so a Maker::Model now has to say where it came from.
#
# `origin` DEFAULTS TO "import" so every existing row is correct with no backfill -- every model
# that exists today came through models#new.
#
# `auto_node_id` IS A node_id AND NOT A PATH, unlike a shelf. Library::Reconciler's pairing by
# (content_hash, size) keeps a renamed node's node_id -- §14b's headline promise -- so renaming
# `3D Models/Enclosure` to `3D Models/Enclosure v2` keeps ONE catalog entry where a path key would
# abandon the old row and mint a second.
#
# `dismissed_at` IS WHY DELETING AN AUTO MODEL DOES NOT DESTROY IT. A destroyed row is recreated by
# the next sweep and the user deletes it again -- §14f's recorded fight-the-user failure, which on
# chunk_remote also costs a changelog entry per round.
class AddAutoCatalogToMakerModels < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_models, :origin, :string, null: false, default: "import"
    add_column :maker_models, :auto_node_id, :string
    add_column :maker_models, :dismissed_at, :datetime
    # Partial: only auto rows carry the key, and two import rows must both be allowed a NULL.
    add_index :maker_models, %i[user_id auto_node_id], unique: true,
              where: "auto_node_id IS NOT NULL", name: "index_maker_models_on_auto_node_id"

    add_column :users, :shelves_seeded_at, :datetime
  end
end
```

- [ ] **Step 2: Write the failing tests**

Append to `test/models/maker/shelf_test.rb`, inside the class:

```ruby
    test "seeding is idempotent and does not resurrect deleted rows" do
      Maker::Shelf.seed_once!(@user)
      assert_equal [ "", "Models", "Projects/*/models" ], @user.maker_shelves.order(:path).pluck(:path)

      Maker::Shelf.seed_once!(@user)
      assert_equal 3, @user.maker_shelves.count

      @user.maker_shelves.destroy_all
      Maker::Shelf.seed_once!(@user.reload)
      assert_empty @user.maker_shelves.reload
    end
```

Append to `test/models/maker/model_test.rb`, inside the class (create the file with the same
`require "test_helper"` / `module Maker` / `class ModelTest < ActiveSupport::TestCase` wrapper and a
`setup` block creating `@user` if it does not exist):

```ruby
    test "an existing model is import-origin without a backfill" do
      model = @user.maker_models.create!(title: "Benchy")
      assert_equal "import", model.origin
      assert_nil model.auto_node_id
      assert_nil model.dismissed_at
    end

    test "two auto models cannot claim one node" do
      @user.maker_models.create!(title: "A", origin: "auto", auto_node_id: "n-1")
      assert_raises(ActiveRecord::RecordNotUnique) do
        @user.maker_models.create!(title: "B", origin: "auto", auto_node_id: "n-1")
      end
    end

    test "catalogued excludes dismissed auto models and keeps import models" do
      keep      = @user.maker_models.create!(title: "Imported")
      auto      = @user.maker_models.create!(title: "Auto", origin: "auto", auto_node_id: "n-2")
      dismissed = @user.maker_models.create!(title: "Gone", origin: "auto", auto_node_id: "n-3",
                                             dismissed_at: Time.current)

      ids = @user.maker_models.catalogued.pluck(:id)
      assert_includes ids, keep.id
      assert_includes ids, auto.id
      assert_not_includes ids, dismissed.id
    end
```

- [ ] **Step 3: Run them and watch them fail**

Run: `bin/rails test test/models/maker/shelf_test.rb test/models/maker/model_test.rb`
Expected: FAIL - `unknown attribute 'origin'` and `undefined method 'catalogued'`.

- [ ] **Step 4: Add the scope and the constant**

In `app/models/maker/model.rb`, below `PRINT_STATUSES`:

```ruby
    # Where this ROW came from. "import" is models#new; "auto" is Maker::ModelIntake's sweep over
    # the library. The two differ in exactly one user-visible way -- see ModelsController#destroy.
    #
    # NOT Maker::Item::ORIGINS, which is a DIFFERENT vocabulary under the same constant name one
    # file away (self_made/downloaded/modified). That one is about how the physical thing was
    # obtained; this one is about which door wrote the database row. Nothing may map between them.
    ORIGINS = %w[import auto].freeze
```

Below the existing `scope :by_status`:

```ruby
    # WHAT /models SHOWS. A dismissed auto model is the user's "I do not want this" and is
    # permanent; the row survives only so the next sweep does not recreate it.
    scope :catalogued, -> { where(dismissed_at: nil) }

    def auto? = origin == "auto"
```

And beside the other validations:

```ruby
    validates :origin, inclusion: { in: ORIGINS }
```

- [ ] **Step 5: Migrate and run**

Run: `bin/rails db:migrate && bin/rails test test/models/maker/shelf_test.rb test/models/maker/model_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add db/migrate/20260825150100_add_auto_catalog_to_maker_models.rb app/models/maker/model.rb test/models/maker/shelf_test.rb test/models/maker/model_test.rb db/schema.rb
git commit -m "Models record their origin, the node they came from, and a dismissal"
```

---

## Task 3: `Maker::LibraryTree` - the dir index

The sweep must not walk a file's ancestors with a query per level. One `pluck` of the user's live
**directory** nodes builds the whole index; dirs are a small fraction of a library.

**Files:**
- Create: `app/services/maker/library_tree.rb`
- Test: `test/services/maker/library_tree_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/library_tree_test.rb`:

```ruby
require "test_helper"

module Maker
  class LibraryTreeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "tree-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      # BACKEND-NEUTRAL FIXTURES ON PURPOSE. This class reads `nodes` and never touches the port,
      # so a bare create! is a complete fixture here -- unlike project_intake_test.rb, which moves
      # real files and therefore needs a real share library (§14a's NULL storage_path trap).
      dir("d-models", "3D Models", nil)
      dir("d-enc", "Enclosure", "d-models")
      dir("d-parts", "parts", "d-enc")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    test "the root is the empty path" do
      assert_equal "", Maker::LibraryTree.new(@user).path_for(nil)
    end

    test "a nested dir resolves to its slash-joined path" do
      tree = Maker::LibraryTree.new(@user)
      assert_equal "3D Models", tree.path_for("d-models")
      assert_equal "3D Models/Enclosure", tree.path_for("d-enc")
      assert_equal "3D Models/Enclosure/parts", tree.path_for("d-parts")
    end

    test "ancestors run nearest-first and end at the root" do
      assert_equal [ "d-parts", "d-enc", "d-models", nil ],
                   Maker::LibraryTree.new(@user).ancestors_of("d-parts")
    end

    test "an unknown or tombstoned dir resolves to nil rather than raising" do
      dir("d-dead", "Dead", nil).update!(deleted: true)
      tree = Maker::LibraryTree.new(@user)
      assert_nil tree.path_for("d-dead")
      assert_nil tree.path_for("nope")
    end

    # A CYCLE IS UNREPRESENTABLE ON A MOUNT BUT REACHABLE IN A ROW SET, and an unguarded walk
    # hangs the sweep rather than failing it. FilesController#folder_crumbs guards the same way.
    test "a parent cycle terminates instead of hanging" do
      @user.nodes.find_by!(node_id: "d-models").update!(parent_node_id: "d-parts")
      assert_nil Maker::LibraryTree.new(@user).path_for("d-enc")
    end

    test "the index costs one query regardless of how many dirs there are" do
      before = count_queries { Maker::LibraryTree.new(@user) }
      12.times { |i| dir("bulk-#{i}", "bulk#{i}", nil) }
      after = count_queries { Maker::LibraryTree.new(@user) }
      assert_equal before, after
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/services/maker/library_tree_test.rb`
Expected: FAIL - `uninitialized constant Maker::LibraryTree`.

- [ ] **Step 3: Write the class**

Create `app/services/maker/library_tree.rb`:

```ruby
module Maker
  # An in-memory index of one user's live DIRECTORY nodes, built with ONE pluck.
  #
  # WHY IT EXISTS: Maker::ModelIntake has to ask "what is the nearest shelf above this file" for
  # every model-role file in the library. Walking parent_node_id per file is a query per level per
  # file. Dirs are a small fraction of any library, so loading all of them once and walking in
  # memory makes the sweep's query count constant in the number of files.
  #
  # IT READS `nodes`, THE CATALOG ALL THREE BACKENDS POPULATE, and touches the port not at all.
  class LibraryTree
    Entry = Data.define(:node_id, :parent_node_id, :name)

    def initialize(user)
      rows = user.nodes.present.where(kind: "dir")
                 .pluck(:node_id, :parent_node_id, :name)
      @dirs = rows.to_h { |id, parent, name| [ id, Entry.new(node_id: id, parent_node_id: parent, name:) ] }
    end

    # "" for the library root (node_id nil). nil when the chain is broken -- a tombstoned or
    # missing ancestor, or a cycle. NIL IS AN ANSWER, NOT AN ERROR: a caller sweeping a whole
    # library must skip an unresolvable node, not abort the pass over the other ten thousand.
    def path_for(node_id)
      segments = []
      each_ancestor(node_id) do |entry|
        return nil if entry == :broken

        segments.unshift(entry.name)
      end
      segments.join("/")
    end

    # Nearest-first, ending with nil for the library root: ["d-parts", "d-enc", "d-models", nil].
    # An unresolvable chain answers nil, for the same reason path_for does.
    def ancestors_of(node_id)
      out = []
      each_ancestor(node_id) do |entry|
        return nil if entry == :broken

        out << entry.node_id
      end
      out << nil
      out
    end

    def dir?(node_id) = @dirs.key?(node_id)

    private

    # Climbs parent_node_id, yielding each dir Entry nearest-first, stopping at the root. Yields
    # :broken exactly once instead if the chain hits a missing dir or revisits a node -- a cycle is
    # unrepresentable on a mount but perfectly representable in a row set, and an unguarded walk
    # HANGS the sweep rather than failing it.
    def each_ancestor(node_id)
      seen = Set.new
      current = node_id
      while current
        return yield(:broken) if seen.include?(current)

        seen << current
        entry = @dirs[current]
        return yield(:broken) unless entry

        yield entry
        current = entry.parent_node_id
      end
    end
  end
end
```

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/services/maker/library_tree_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 5: Mutation-check the cycle guard**

Delete the `return yield(:broken) if seen.include?(current)` line. Run the test with a timeout:
`timeout 30 bin/rails test test/services/maker/library_tree_test.rb -n test_a_parent_cycle_terminates_instead_of_hanging`
Expected: the run **hangs and is killed** (exit 124) rather than passing. Restore the line.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/library_tree.rb test/services/maker/library_tree_test.rb
git commit -m "Add Maker::LibraryTree: one pluck, in-memory ancestor walks"
```

---

## Task 4: The rule - classification

This is the unit that has to be right; everything after it is plumbing. It is a **pure function**
over the tree, the shelf patterns and the file nodes. No writes.

**Files:**
- Create: `app/services/maker/model_intake.rb` (classification only for now)
- Test: `test/services/maker/model_intake_classify_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/model_intake_classify_test.rb`:

```ruby
require "test_helper"

module Maker
  # THE RULE, table-driven, with no writes anywhere. A folder is either a shelf or a model, and the
  # nearest shelf ancestor decides which.
  class ModelIntakeClassifyTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "cls-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      #   3D Models/                 <- shelf
      #     benchy.stl               -> its own model
      #     notes.pdf                -> not a model, and not attached to one
      #     Enclosure/               -> one model
      #       body.stl
      #       manual.pdf
      #       parts/
      #         clip.stl
      dir("d-shelf", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-shelf")
      file("f-notes",  "notes.pdf",  "d-shelf")
      dir("d-enc", "Enclosure", "d-shelf")
      file("f-body",   "body.stl",   "d-enc")
      file("f-manual", "manual.pdf", "d-enc")
      dir("d-parts", "parts", "d-enc")
      file("f-clip", "clip.stl", "d-parts")

      @user.maker_shelves.create!(path: "3D Models")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    def classify = Maker::ModelIntake.classify(@user)

    test "a loose model file directly under a shelf is its own model" do
      assert_includes classify.model_keys, "f-benchy"
    end

    test "a subfolder of a shelf is one model claiming its whole subtree" do
      plan = classify
      assert_includes plan.model_keys, "d-enc"
      assert_equal %w[f-body f-clip f-manual], plan.files_for("d-enc").sort
    end

    test "a part deep in a model folder is not a model of its own" do
      plan = classify
      assert_not_includes plan.model_keys, "d-parts"
      assert_not_includes plan.model_keys, "f-clip"
    end

    test "a non-model file loose on a shelf becomes nothing" do
      plan = classify
      assert_not_includes plan.model_keys, "f-notes"
      assert_empty plan.model_keys.select { |k| plan.files_for(k).include?("f-notes") }
    end

    test "a one-file model claims only itself" do
      assert_equal [ "f-benchy" ], classify.files_for("f-benchy")
    end

    # THE NESTED CASE: marking the inner folder a shelf makes its children models instead, and the
    # outer model stops at it. Nearest ancestor wins.
    test "a shelf inside a model folder takes over its children" do
      @user.maker_shelves.create!(path: "3D Models/Enclosure")
      plan = classify
      assert_not_includes plan.model_keys, "d-enc"
      assert_includes plan.model_keys, "f-body"
      assert_includes plan.model_keys, "d-parts"
      assert_equal [ "f-clip" ], plan.files_for("d-parts")
    end

    test "a wildcard shelf matches one segment" do
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "desk-lamp", "d-projects")
      dir("d-lampmodels", "models", "d-lamp")
      file("f-shade", "shade.stl", "d-lampmodels")
      @user.maker_shelves.create!(path: "Projects/*/models")

      assert_includes classify.model_keys, "f-shade"
    end

    # DELETING THE ROOT SHELF IS A LEGITIMATE CHOICE, not a gap -- loose root files are simply not
    # catalogued. The fixture has no root shelf, so this is already the state under test.
    test "a file with no shelf ancestor is not catalogued" do
      file("f-orphan", "orphan.stl", nil)
      plan = classify
      assert_not_includes plan.model_keys, "f-orphan"
      assert_includes plan.skips.map(&:last), :no_shelf
    end

    test "a tombstoned file is invisible" do
      @user.nodes.find_by!(node_id: "f-body").update!(deleted: true)
      assert_equal %w[f-clip f-manual], classify.files_for("d-enc").sort
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/services/maker/model_intake_classify_test.rb`
Expected: FAIL - `uninitialized constant Maker::ModelIntake`.

- [ ] **Step 3: Write the classifier**

Create `app/services/maker/model_intake.rb`:

```ruby
module Maker
  # Make the model catalog agree with what is in the library: every model-role file belongs to a
  # model, and which model is decided by the nearest SHELF above it.
  #
  # WHY A SWEEP RATHER THAN A HOOK ON EVERY WRITE -- the same argument Maker::ProjectIntake makes,
  # one level up. A file can reach the library seven ways (FilesController#create,
  # #finalize_upload, Library::Reconciler, a device push landing on the sync server,
  # Maker::Addons::LibraryOutput, Maker::MoveNode, a trash restore) and there is no funnel. Hooking
  # each is seven sites that must agree and an eighth that silently skips the rule. This reads
  # `nodes`, the catalog ALL THREE BACKENDS populate, so it covers every door and any future one.
  #
  # IT NEVER TOUCHES THE PORT. Cataloguing writes database rows only -- no mkdir, no move, no
  # bytes -- which is what makes it identical on all three backends and testable without a library
  # on disk.
  class ModelIntake
    # The classification, before anything is written. `owners` maps a file node_id to the KEY of
    # the model that claims it; a key is either a DIR node_id (a folder model) or a FILE node_id (a
    # loose one-file model). `model_keys` is the subset of keys that at least one MODEL-ROLE file
    # maps to -- which is what stops a stray PDF loose on a shelf from becoming a model while still
    # letting the PDF inside a model folder attach to it. `dir_keys` remembers which keys are
    # folders, so the sweep can set folder_node_id without asking the database again per model.
    # `names` carries every file's name so the sweep derives roles without a second query.
    Plan = Data.define(:owners, :model_keys, :dir_keys, :titles, :names, :skips) do
      def files_for(key) = owners.select { |_file, owner| owner == key }.keys
    end

    MODEL_ROLE = "model".freeze

    # PURE. Reads `nodes` and `maker_shelves`, writes nothing, and is the whole rule.
    def self.classify(user)
      tree     = Maker::LibraryTree.new(user)
      patterns = user.maker_shelves.pluck(:path)
      shelves  = shelf_dir_ids(tree, patterns, user)

      owners = {}
      titles = {}
      names  = {}
      skips  = []
      model_keys = Set.new
      dir_keys   = Set.new

      user.nodes.present.where(kind: "file")
          .pluck(:node_id, :name, :parent_node_id).each do |node_id, name, parent_id|
        key, title = owner_key(tree, shelves, node_id:, name:, parent_id:)
        if key.nil?
          skips << [ node_id, :no_shelf ]
          next
        end

        owners[node_id] = key
        titles[key] = title
        names[node_id] = name
        dir_keys << key if tree.dir?(key)
        model_keys << key if Maker::FileAttachment.role_for(name) == MODEL_ROLE
      end

      # A key nothing model-role claims is not a model, so neither it nor the files under it are in
      # the plan at all -- that is how `notes.pdf` loose on a shelf becomes nothing.
      owners.select! { |_file, key| model_keys.include?(key) }
      Plan.new(owners:, model_keys: model_keys.to_a, dir_keys:, titles:, names:, skips:)
    end

    # Which DIR node_ids (plus nil, the library root) the shelf patterns name.
    def self.shelf_dir_ids(tree, patterns, user)
      ids = Set.new
      ids << nil if patterns.any? { |p| Maker::Shelf.matches?(p, "") }
      user.nodes.present.where(kind: "dir").pluck(:node_id).each do |dir_id|
        path = tree.path_for(dir_id)
        next if path.nil?

        ids << dir_id if patterns.any? { |p| Maker::Shelf.matches?(p, path) }
      end
      ids
    end
    private_class_method :shelf_dir_ids

    # THE RULE ITSELF. Walk up to the nearest shelf: a direct child of one is its own model, and
    # anything deeper belongs to the shelf's direct child folder on the way down. Returns
    # [key, title], or [nil, nil] when no ancestor is a shelf.
    def self.owner_key(tree, shelves, node_id:, name:, parent_id:)
      chain = tree.ancestors_of(parent_id)
      return [ nil, nil ] if chain.nil?

      index = chain.index { |dir_id| shelves.include?(dir_id) }
      return [ nil, nil ] if index.nil?

      # index 0 means the shelf IS the file's own parent -> the file is its own model. Otherwise
      # the model is the entry one step BELOW the shelf, which is the dir directly under it.
      return [ node_id, File.basename(name.to_s, ".*") ] if index.zero?

      dir_id = chain[index - 1]
      [ dir_id, tree.path_for(dir_id).to_s.split("/").last ]
    end
    private_class_method :owner_key
  end
end
```

- [ ] **Step 4: Run the test**

Run: `bin/rails test test/services/maker/model_intake_classify_test.rb`
Expected: PASS, 10 runs.

- [ ] **Step 5: Mutation-check the nearest-shelf rule**

Change `chain.index { ... }` to `chain.rindex { ... }` (furthest shelf instead of nearest). Run the
test. Expected: **RED** on "a shelf inside a model folder takes over its children". Restore.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/model_intake.rb test/services/maker/model_intake_classify_test.rb
git commit -m "Classify library files into models by the nearest shelf above them"
```

---

## Task 5: The sweep - creating rows and attaching files

**Files:**
- Modify: `app/services/maker/model_intake.rb`
- Test: `test/services/maker/model_intake_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/services/maker/model_intake_test.rb`:

```ruby
require "test_helper"

module Maker
  class ModelIntakeTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "mi-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      dir("d-shelf", "3D Models", nil)
      file("f-benchy", "benchy.stl", "d-shelf")
      dir("d-enc", "Enclosure", "d-shelf")
      file("f-body", "body.stl", "d-enc")
      file("f-manual", "manual.pdf", "d-enc")
      @user.maker_shelves.create!(path: "3D Models")
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    def file(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 1)
    end

    test "it creates one model per key, titled from the folder or file name" do
      Maker::ModelIntake.for_user(user: @user)

      titles = @user.maker_models.order(:title).pluck(:title, :origin, :auto_node_id)
      assert_equal [ [ "Enclosure", "auto", "d-enc" ], [ "benchy", "auto", "f-benchy" ] ], titles
    end

    test "a folder model attaches every file in its subtree with the derived role" do
      Maker::ModelIntake.for_user(user: @user)

      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      assert_equal [ [ "f-body", "model" ], [ "f-manual", "instructions" ] ],
                   model.file_attachments.order(:node_id).pluck(:node_id, :role)
    end

    test "a folder model points at the folder without creating one" do
      Maker::ModelIntake.for_user(user: @user)

      assert_equal "d-enc", @user.maker_models.find_by!(auto_node_id: "d-enc").folder_node_id
      # ensure_library_folder! would have minted Models/<slug>; the sweep must never call it (§14f).
      assert_nil @user.nodes.present.find_by(name: "Models", kind: "dir")
    end

    test "a second sweep creates nothing and attaches nothing" do
      Maker::ModelIntake.for_user(user: @user)
      models = @user.maker_models.count
      atts   = Maker::FileAttachment.where(user: @user).count

      Maker::ModelIntake.for_user(user: @user)

      assert_equal models, @user.maker_models.count
      assert_equal atts, Maker::FileAttachment.where(user: @user).count
    end

    test "a file added later attaches to the model that already exists" do
      Maker::ModelIntake.for_user(user: @user)
      file("f-render", "render.png", "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      model = @user.maker_models.find_by!(auto_node_id: "d-enc")
      assert_includes model.file_attachments.pluck(:node_id), "f-render"
    end

    # DISMISSAL IS PERMANENT AND THE SWEEP MUST RESPECT IT -- otherwise the next tick recreates the
    # row the user just deleted, and they delete it again (§14f).
    test "a dismissed model is not recreated" do
      Maker::ModelIntake.for_user(user: @user)
      @user.maker_models.find_by!(auto_node_id: "d-enc").update!(dismissed_at: Time.current)

      Maker::ModelIntake.for_user(user: @user)

      # ASSERTED ON THE ROW, NOT A TIMESTAMP. 15: a timestamp compared at .to_i cannot fail when
      # both writes land in the same second.
      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
      assert_predicate @user.maker_models.find_by!(auto_node_id: "d-enc"), :dismissed_at
    end

    test "a folder an imported model already claims is skipped" do
      @user.maker_models.create!(title: "Hand imported", folder_node_id: "d-enc")

      Maker::ModelIntake.for_user(user: @user)

      assert_nil @user.maker_models.find_by(auto_node_id: "d-enc")
      assert_equal 1, @user.maker_models.where(folder_node_id: "d-enc").count
    end

    test "the cap bounds one run and says so" do
      20.times do |i|
        dir("d-cap-#{i}", "cap#{i}", "d-shelf")
        file("f-cap-#{i}", "part.stl", "d-cap-#{i}")
      end

      run = Maker::ModelIntake.for_user(user: @user, cap: 5)

      assert_equal 5, run.created
      assert_equal :capped, run.status
      assert_equal 5, @user.maker_models.count
    end

    # THE STEADY-STATE PASS IS THE ONE THAT RUNS FOREVER -- every 15 minutes, on a library that is
    # already catalogued -- so its cost must not grow with the library. ASSERTED AS CONSTANT, NEVER
    # AS A LITERAL: the counts differ per LIBRARY_BACKEND, so a literal pins one leg and fails the
    # other two (page_query_budget_test.rb's rule).
    #
    # A pass that CREATES models is unavoidably linear (each row needs an INSERT and a slug
    # uniqueness check); this asserts the pass that creates nothing, which is where an N+1 would
    # otherwise hide undetected for the life of the deployment.
    test "a no-op sweep costs the same on a big library as on a small one" do
      Maker::ModelIntake.for_user(user: @user)
      small = count_queries { Maker::ModelIntake.for_user(user: @user) }

      10.times do |i|
        dir("d-more-#{i}", "more#{i}", "d-shelf")
        file("f-more-#{i}", "part.stl", "d-more-#{i}")
        file("f-doc-#{i}", "notes.pdf", "d-more-#{i}")
      end
      Maker::ModelIntake.for_user(user: @user)
      big = count_queries { Maker::ModelIntake.for_user(user: @user) }

      assert_equal small, big
    end

    def count_queries(&block)
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      n
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/services/maker/model_intake_test.rb`
Expected: FAIL - `undefined method 'for_user' for Maker::ModelIntake`.

- [ ] **Step 3: Write the sweep**

Append to `app/services/maker/model_intake.rb`, inside `class ModelIntake`, below `MODEL_ROLE`:

```ruby
    # What one run did. `status` is :ok or :capped -- a caller has to be able to tell "your library
    # is catalogued" from "there is more of it than one run will do".
    RunResult = Data.define(:created, :attached, :skipped, :status, :cap)

    # The ceiling on models created in one UNATTENDED run. ABSOLUTE, NOT A PERCENTAGE, for the
    # reason Maker::ProjectIntake::MAX_MOVES gives at length: the intended first run catalogues
    # 100% of what is there, so a percentage would be guarding against success.
    #
    # THERE IS DELIBERATELY NO SECOND, SMALLER CAP. Maker::ProjectIntake carries MAX_MOVES AND
    # EAGER_MAX_MOVES because it has an entry point that runs inside a browser request. This class
    # does not: nothing in a web request sweeps. If a nudge is ever added it needs its own cap, for
    # the reason §14f states at both of those constants.
    MAX_MODELS = 200

    def self.max_models
      Integer(ENV.fetch("MODEL_CATALOG_MAX_MODELS", MAX_MODELS))
    rescue ArgumentError
      MAX_MODELS
    end

    def self.for_user(user:, cap: nil)
      Maker::Shelf.seed_once!(user)
      cap ||= max_models
      plan = classify(user)

      existing = user.maker_models.where(auto_node_id: plan.model_keys).index_by(&:auto_node_id)
      # A folder an IMPORT-origin model already claims is that model's, not ours (§14f's "reads
      # folder_node_id, never calls ensure_library_folder!" has the same shape: look, do not take).
      claimed = user.maker_models.where(origin: "import")
                    .where(folder_node_id: plan.model_keys).pluck(:folder_node_id).to_set

      # DETERMINISTIC ORDER so a capped run is reproducible and a second run continues where the
      # first stopped instead of re-rolling the dice.
      todo = plan.model_keys.reject { |k| existing.key?(k) || claimed.include?(k) }.sort
      capped = todo.size > cap
      todo = todo.first(cap)

      created = 0
      todo.each do |key|
        model = user.maker_models.create!(
          title: plan.titles.fetch(key, key),
          origin: "auto",
          auto_node_id: key,
          # A DIR KEY IS ALREADY THE MODEL'S FOLDER. Setting it here creates nothing; calling
          # ensure_library_folder! would mint Models/<slug> per model as a side effect of looking
          # (§14f, and Projects::AttachmentsController#relocate's recorded bug).
          folder_node_id: plan.dir_keys.include?(key) ? key : nil
        )
        existing[key] = model
        created += 1
      end

      attached = attach_all(user, plan, existing)
      RunResult.new(created:, attached:, skipped: plan.skips.size,
                    status: capped ? :capped : :ok, cap:)
    end

    # ONE STATEMENT, NOT ONE QUERY PER FILE. `unique_by` names the existing uniqueness index, so a
    # re-sweep of an already-attached library inserts nothing rather than raising. insert_all
    # bypasses timestamp autofill, hence the explicit stamps.
    def self.attach_all(user, plan, models)
      now = Time.current
      rows = plan.owners.filter_map do |file_id, key|
        model = models[key]
        next unless model
        next if model.dismissed_at.present?

        { user_id: user.id, attachable_type: "Maker::Model", attachable_id: model.id,
          node_id: file_id, role: Maker::FileAttachment.role_for(plan.names[file_id]), position: 0,
          created_at: now, updated_at: now }
      end
      return 0 if rows.empty?

      result = Maker::FileAttachment.insert_all(
        rows, unique_by: %i[user_id attachable_type attachable_id node_id]
      )
      result.rows.size
    end
    private_class_method :attach_all
```

**No memo anywhere in this class, and that is deliberate.** The role of a file is looked up from
`plan.names`, which the classifier already collected. The tempting alternative -- a
`@role_names ||=` hash keyed on `user.id` -- is the process-wide-state bug §14a records for
`ChunkRemote#transport`: a class-level memo is not a per-request cache, it is state that outlives
every request in the process, and the next user gets the first user's answer.

- [ ] **Step 4: Run the tests**

Run: `bin/rails test test/services/maker/model_intake_test.rb test/services/maker/model_intake_classify_test.rb`
Expected: PASS, 19 runs (10 classify + 9 sweep).

- [ ] **Step 5: Mutation-check the dismissal guard**

In `for_user`, change `existing = user.maker_models.where(auto_node_id: ...)` to
`user.maker_models.catalogued.where(auto_node_id: ...)` - which hides dismissed rows from the sweep
and so recreates them. Run the test. Expected: **RED** on "a dismissed model is not recreated"
(`RecordNotUnique`, because the partial unique index catches it - note that the index is doing real
work here). Restore.

- [ ] **Step 6: Add the rename test - the whole reason a model is keyed on node_id**

Append to `test/services/maker/model_intake_test.rb`:

```ruby
    # THE POINT OF KEYING ON node_id RATHER THAN A PATH. Library::Reconciler's pairing by
    # (content_hash, size) keeps a renamed node's node_id, so renaming the folder in Finder must
    # keep ONE catalog entry -- a path key would abandon the old row and mint a second, and the
    # user would find two models for one folder.
    test "renaming a model folder keeps one model" do
      Maker::ModelIntake.for_user(user: @user)
      model = @user.maker_models.find_by!(auto_node_id: "d-enc")

      @user.nodes.find_by!(node_id: "d-enc").update!(name: "Enclosure v2")
      Maker::ModelIntake.for_user(user: @user)

      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
      assert_equal model.id, @user.maker_models.find_by!(auto_node_id: "d-enc").id
    end

    # TWO SHELVES MATCHING ONE FOLDER IS NOT AN AMBIGUITY. Shelves are a SET, not an ordered list,
    # so a folder named by both a literal and a wildcard resolves identically either way.
    test "a folder matched by two shelves is catalogued once" do
      @user.maker_shelves.create!(path: "*")
      Maker::ModelIntake.for_user(user: @user)

      assert_equal 1, @user.maker_models.where(auto_node_id: "d-enc").count
    end
```

Run: `bin/rails test test/services/maker/model_intake_test.rb`
Expected: PASS, 11 runs.

- [ ] **Step 7: Commit**

```bash
git add app/services/maker/model_intake.rb test/services/maker/model_intake_test.rb
git commit -m "Sweep the library into the model catalog, capped and idempotent"
```

---

## Task 6: Dismissal in the web layer, and hiding an emptied model

**Files:**
- Modify: `app/controllers/models_controller.rb`
- Modify: `app/views/models/index.html.erb`
- Test: `test/integration/web/models_catalog_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/models_catalog_test.rb`:

```ruby
require "test_helper"

module Web
  class ModelsCatalogTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "mc-#{SecureRandom.hex(4)}@example.com",
                           password: "password123", confirmed_at: Time.current)
      sign_in_as(@user)
    end

    test "deleting an auto model dismisses it and says so" do
      model = @user.maker_models.create!(title: "Enclosure", origin: "auto", auto_node_id: "d-enc")

      delete model_path(model)

      assert_redirected_to models_path
      assert_match(/won't be re-added/i, flash[:notice])
      assert_predicate model.reload, :dismissed_at
    end

    test "deleting an imported model still destroys it" do
      model = @user.maker_models.create!(title: "Imported")

      delete model_path(model)

      assert_nil Maker::Model.find_by(id: model.id)
    end

    test "the index hides a dismissed model" do
      @user.maker_models.create!(title: "Gone", origin: "auto", auto_node_id: "d-x",
                                 dismissed_at: Time.current)
      get models_path
      assert_response :success
      assert_select ".grid-name", text: "Gone", count: 0
    end

    # AN EMPTIED AUTO MODEL IS HIDDEN, NOT DISMISSED AND NOT DESTROYED. The row survives holding
    # whatever title and tags the user gave it, and comes back when a file does. Dismissal must not
    # be reused here -- it is permanent, so a folder that refilled would stay gone.
    test "the index hides an auto model with no attachments and shows it again when files return" do
      model = @user.maker_models.create!(title: "Emptied", origin: "auto", auto_node_id: "d-e")

      get models_path
      assert_select ".grid-name", text: "Emptied", count: 0

      model.file_attachments.create!(user: @user, node_id: "f-1", role: "model")

      get models_path
      assert_select ".grid-name", text: "Emptied", count: 1
    end

    test "an imported model with no attachments still shows" do
      @user.maker_models.create!(title: "Fresh import")
      get models_path
      assert_select ".grid-name", text: "Fresh import", count: 1
    end
  end
end
```

`sign_in_as` is the existing helper in `test/test_helper.rb`; check its signature and match it. If
the card markup does not use `.grid-name`, open `app/views/models/_card.html.erb` and assert on the
class it actually renders - **do not** invent one.

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/integration/web/models_catalog_test.rb`
Expected: FAIL - the delete destroys instead of dismissing, and both hiding cases fail.

- [ ] **Step 3: Change `destroy`**

In `app/controllers/models_controller.rb`, replace `#destroy`:

```ruby
  # AN AUTO MODEL IS DISMISSED, NOT DESTROYED, AND THE ASYMMETRY IS THE POINT. Maker::ModelIntake
  # recreates any auto row whose node still holds a model file, so destroying one means the user
  # deletes it again on the next tick -- §14f's fight-the-user failure, which on chunk_remote costs
  # a changelog entry per round. The row IS the memory. Nothing recreates an imported model, so
  # that one keeps today's behaviour.
  def destroy
    if @model.auto?
      @model.update!(dismissed_at: Time.current)
      redirect_to models_path,
                  notice: "Removed #{@model.title} from the catalog. It won't be re-added by the next scan."
    else
      @model.destroy!
      redirect_to models_path, notice: "Deleted #{@model.title}."
    end
  end
```

- [ ] **Step 4: Change `index`**

In `ModelsController#index`, replace the first line:

```ruby
    models = current_user.maker_models.catalogued.includes(:file_attachments)
```

and, after the `@models = ...` assignment, filter empties:

```ruby
    # AN AUTO MODEL WITH NO ATTACHMENTS IS AN EMPTIED FOLDER, and it is hidden rather than dismissed
    # or destroyed: the row keeps the user's title and tags and returns the moment a file does. The
    # rows themselves are cleared on the ordinary schedule by Maker::AttachmentReaper once the
    # tombstones age out, so this is a display rule and not a second reaper. Filtering in Ruby off
    # the ALREADY-LOADED :file_attachments include -- a `where.missing` would be a second query and
    # would disagree with what the cards render.
    @models.reject! { |m| m.auto? && m.file_attachments.empty? }
```

- [ ] **Step 5: Run the test**

Run: `bin/rails test test/integration/web/models_catalog_test.rb`
Expected: PASS, 6 runs.

- [ ] **Step 6: Mutation-check both rules**

1. Change `if @model.auto?` to `if false` - expected **RED** on "deleting an auto model dismisses
   it". Restore.
2. Delete the `@models.reject!` line - expected **RED** on the emptied-model case. Restore.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/models_controller.rb test/integration/web/models_catalog_test.rb
git commit -m "Dismiss an auto model rather than destroying it; hide an emptied one"
```

---

## Task 7: Scheduling - the job, the recurring entry, and the ScanJob call

**Files:**
- Create: `app/jobs/maker/model_intake_job.rb`
- Modify: `config/recurring.yml`
- Modify: `app/jobs/library/scan_job.rb`
- Test: `test/jobs/maker/model_intake_job_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/jobs/maker/model_intake_job_test.rb`:

```ruby
require "test_helper"

module Maker
  class ModelIntakeJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(email: "mij-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # THE BACKEND GATE LIVES ON THE FAN-OUT, NOT ON #perform -- Library::ScanJob's own comment has
    # the argument: a SCHEDULE may no-op, but a COMMAND naming a user must not silently do nothing.
    test "the scheduled fan-out declines on a scannable backend" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("mij"))

      assert_no_enqueued_jobs { Maker::ModelIntakeJob.sweep_all! }
    end

    test "perform sweeps even on a scannable backend when a caller names a user" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("mij"))
      @user.maker_shelves.create!(path: "")
      @user.nodes.create!(node_id: "f-1", name: "a.stl", kind: "file", mtime: 1, size: 1)

      Maker::ModelIntakeJob.new.perform(user_id: @user.id)

      assert_equal 1, @user.maker_models.count
    end

    test "a deleted user is discarded rather than recorded as a failure" do
      assert_nothing_raised { Maker::ModelIntakeJob.new.perform(user_id: 0) }
    rescue ActiveRecord::RecordNotFound
      flunk "should be discarded by discard_on, not raised"
    end

    teardown { FileLayer.reset! }
  end
end
```

For the third case, `discard_on` is applied by ActiveJob's *perform_now/later* wrapper rather than
by calling `#perform` directly - use `Maker::ModelIntakeJob.perform_now(user_id: 0)` there and
assert it returns without raising.

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/jobs/maker/model_intake_job_test.rb`
Expected: FAIL - `uninitialized constant Maker::ModelIntakeJob`.

- [ ] **Step 3: Write the job**

Create `app/jobs/maker/model_intake_job.rb`:

```ruby
module Maker
  # The scheduled half of Maker::ModelIntake. Mirrors Maker::ProjectIntakeJob down to why each
  # decision is what it is -- read that file before changing this one.
  class ModelIntakeJob < ApplicationJob
    queue_as :background

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong (GeneratePreviewJob sets the precedent).
    discard_on ActiveRecord::RecordNotFound

    # ONE SWEEP PER USER AT A TIME, and a dropped tick is better than a backlog: the 15-minute
    # schedule IS the retry, and it re-reads the world rather than replaying a stale verdict.
    limits_concurrency to: 1, key: ->(args) { args[:user_id] },
                       duration: 15.minutes, on_conflict: :discard

    def perform(user_id:)
      user = User.find(user_id)
      run = Maker::ModelIntake.for_user(user:)
      if run.created.positive? || run.status == :capped
        Rails.logger.info("Maker::ModelIntakeJob: user #{user.id} created #{run.created}, " \
                          "attached #{run.attached}, status #{run.status}")
      end
      run
    end

    # THE GATE IS HERE AND NOT IN #perform, matching Library::ScanJob.scan_all! and
    # Maker::ProjectIntakeJob.sweep_all!: on a scannable backend Library::ScanJob already calls the
    # intake at the end of its own perform, strictly after the reconcile. A second caller would
    # catalogue paths the reconcile has not settled yet.
    def self.sweep_all!
      return if FileLayer.current.capabilities.scannable?

      User.find_each { |user| perform_later(user_id: user.id) }
    end
  end
end
```

- [ ] **Step 4: Add the recurring entry**

In `config/recurring.yml`, below the `project_folder_intake` block:

```yaml
  # Model catalog: every model-role file in the library belongs to a model, decided by the nearest
  # shelf above it. CHUNK DEPLOYMENTS ONLY -- sweep_all! declines when the backend is `scannable`,
  # because on share/s3 Library::ScanJob calls the intake at the end of its own perform, strictly
  # after the reconcile AND strictly after the project intake (a file this app is about to move has
  # no business being catalogued at its old path).
  #
  # `command:` rather than `class:`, matching every other gated entry here, because the backend gate
  # lives in a class method rather than in #perform.
  #
  # EVERY 15 MINUTES, matching project_folder_intake -- and for the same reason it is arbitrary
  # there: nothing in a web request sweeps, so this interval is the ONLY latency bound the catalog
  # gets. An upload's model appears within a tick. That is the accepted trade; see
  # docs/invariants/model-intake.md for why there is no eager nudge.
  model_catalog_intake:
    command: "Maker::ModelIntakeJob.sweep_all!"
    schedule: every 15 minutes
```

- [ ] **Step 5: Call it inline from `Library::ScanJob`**

In `app/jobs/library/scan_job.rb`, in `#perform`, immediately after `intake_project_folders(user)`:

```ruby
      intake_models(user)
```

And beside `#intake_project_folders`, add:

```ruby
    # STRICTLY AFTER THE PROJECT INTAKE, IN THIS JOB, AND THE ORDER IS LOAD-BEARING TWICE OVER.
    #
    # After the RECONCILE for the reason §14f already gives: the catalog reads paths, and a path the
    # Scanner has not settled is a wrong answer.
    #
    # After the PROJECT INTAKE because that step MOVES files. Cataloguing first would key a model
    # on a file about to be filed into Projects/<slug>/models/, so the model would be created at one
    # location and emptied moments later by the same job.
    #
    # perform_now: concurrency controls apply at ENQUEUE, so ModelIntakeJob's own limit cannot
    # discard this -- required, not incidental, exactly as the note above limits_concurrency says.
    def intake_models(user)
      Maker::ModelIntake.for_user(user:)
    rescue StandardError => e
      # A catalog failure must not fail the SCAN, whose job was done before this ran.
      Rails.logger.error("ScanJob: model intake failed for user #{user.id}: #{e.class}: #{e.message}")
    end
```

- [ ] **Step 6: Run the tests**

Run: `bin/rails test test/jobs/maker/model_intake_job_test.rb test/jobs/library/`
Expected: PASS.

- [ ] **Step 7: Mutation-check the fan-out gate**

Delete the `return if FileLayer.current.capabilities.scannable?` line. Expected: **RED** on "the
scheduled fan-out declines on a scannable backend". Restore.

- [ ] **Step 8: Commit**

```bash
git add app/jobs/maker/model_intake_job.rb app/jobs/library/scan_job.rb config/recurring.yml test/jobs/maker/model_intake_job_test.rb
git commit -m "Schedule the catalog sweep: recurring on chunk_remote, inline after the scan"
```

---

## Task 8: The shelves settings page

**Files:**
- Create: `app/controllers/shelves_controller.rb`
- Create: `app/views/shelves/index.html.erb`
- Modify: `config/routes.rb`, `app/views/models/index.html.erb`
- Test: `test/integration/web/shelves_test.rb`

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, beside the `resources :models` block:

```ruby
  # The model catalog's one setting: which folders are shelves. Path-scoped under /settings so the
  # URL reads like what it is; the controller is top-level because there is no other settings page
  # to namespace it with yet.
  resources :shelves, only: %i[index create destroy], path: "settings/shelves"
```

- [ ] **Step 2: Write the failing test**

Create `test/integration/web/shelves_test.rb`:

```ruby
require "test_helper"

module Web
  class ShelvesTest < ActionDispatch::IntegrationTest
    setup do
      @user = User.create!(email: "sh-#{SecureRandom.hex(4)}@example.com",
                           password: "password123", confirmed_at: Time.current)
      sign_in_as(@user)
    end

    test "the page seeds the three shelves on first visit" do
      get shelves_path

      assert_response :success
      assert_equal [ "", "Models", "Projects/*/models" ], @user.maker_shelves.order(:path).pluck(:path)
    end

    test "a wildcard row renders and reports how many folders it matches" do
      @user.nodes.create!(node_id: "d-p", name: "Projects", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-l", name: "lamp", kind: "dir", parent_node_id: "d-p", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-m", name: "models", kind: "dir", parent_node_id: "d-l", mtime: 1, size: 0)

      get shelves_path

      assert_response :success
      assert_select "li", text: /Projects\/\*\/models/
      assert_select ".shelf-status", text: /1 folder/
    end

    # THE INDICATOR IS WHAT MAKES PATH-KEYING HONEST. A path that resolves to nothing says so
    # instead of quietly cataloguing nothing.
    test "a path with no live folder is reported as missing" do
      @user.maker_shelves.create!(path: "Nowhere")
      @user.update_column(:shelves_seeded_at, Time.current)

      get shelves_path

      assert_select ".shelf-status", text: /no folder at this path/i
    end

    # THE CHOOSER RETURNS A node_id; THE CONTROLLER DERIVES THE PATH. A picker cannot produce a
    # path string, and deriving it server-side is the only place the two can be kept in step.
    test "adding a shelf converts the chosen node into a path" do
      @user.nodes.create!(node_id: "d-a", name: "3D Models", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-b", name: "Prints", kind: "dir", parent_node_id: "d-a", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-b" }

      assert_redirected_to shelves_path
      assert_includes @user.maker_shelves.pluck(:path), "3D Models/Prints"
    end

    test "adding the library root stores the empty path" do
      @user.update_column(:shelves_seeded_at, Time.current)
      post shelves_path, params: { node_id: "" }

      assert_includes @user.maker_shelves.pluck(:path), ""
    end

    test "adding a duplicate is refused with a message, not a 500" do
      @user.maker_shelves.create!(path: "Models")
      @user.update_column(:shelves_seeded_at, Time.current)
      @user.nodes.create!(node_id: "d-m", name: "Models", kind: "dir", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-m" }

      assert_redirected_to shelves_path
      assert_match(/already/i, flash[:alert])
      assert_equal 1, @user.maker_shelves.count
    end

    # A PICKER CAN REACH THE RESERVED-NAME REFUSAL. A library with a real `.trash` directory offers
    # that folder like any other, so the refusal has to say what is actually wrong rather than
    # falling through to the duplicate message.
    test "picking a reserved folder is refused with its own message" do
      @user.update_column(:shelves_seeded_at, Time.current)
      @user.nodes.create!(node_id: "d-trash", name: ".trash", kind: "dir", mtime: 1, size: 0)

      post shelves_path, params: { node_id: "d-trash" }

      assert_empty @user.maker_shelves
      assert_match(/can't be a folder name/i, flash[:alert])
      assert_no_match(/already/i, flash[:alert])
    end

    test "another user's node cannot be turned into a shelf" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      other.nodes.create!(node_id: "d-theirs", name: "Theirs", kind: "dir", mtime: 1, size: 0)
      @user.update_column(:shelves_seeded_at, Time.current)

      post shelves_path, params: { node_id: "d-theirs" }

      assert_empty @user.maker_shelves.where.not(path: "")
    end

    test "removing a shelf removes it" do
      get shelves_path
      shelf = @user.maker_shelves.find_by!(path: "Models")

      delete shelf_path(shelf)

      assert_redirected_to shelves_path
      assert_nil Maker::Shelf.find_by(id: shelf.id)
    end

    test "another user's shelf cannot be removed" do
      other = User.create!(email: "o2-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_shelves.create!(path: "Models")

      delete shelf_path(theirs)

      assert_response :not_found
      assert_predicate Maker::Shelf.find_by(id: theirs.id), :present?
    end
  end
end
```

If `delete shelf_path(theirs)` raises `RecordNotFound` rather than rendering 404, assert
`assert_raises(ActiveRecord::RecordNotFound)` instead - match whatever `ApplicationController`
already does for the other scoped resources rather than adding a rescue here.

- [ ] **Step 3: Run it and watch it fail**

Run: `bin/rails test test/integration/web/shelves_test.rb`
Expected: FAIL - `uninitialized constant ShelvesController`.

- [ ] **Step 4: Write the controller**

Create `app/controllers/shelves_controller.rb`:

```ruby
# Which library folders are SHELVES -- folders that are not themselves models. Session-authed web
# layer (§14d), not the device-token v1 API. Reads `nodes` and writes only maker_shelves rows; no
# bytes and no port calls, so there is nothing to capability-gate.
class ShelvesController < ApplicationController
  def index
    Maker::Shelf.seed_once!(current_user)
    @tree = Maker::LibraryTree.new(current_user)
    @shelves = current_user.maker_shelves.order(:path).map { |shelf| decorate(shelf) }
  end

  # THE CHOOSER POSTS A node_id AND THIS DERIVES THE PATH. A folder picker cannot produce a path
  # string, and deriving it here is the only place the picked node and the stored pattern can be
  # kept in step. The node is resolved through current_user, so a foreign id resolves to nothing.
  def create
    path = path_for_param(params[:node_id])
    return redirect_to(shelves_path, alert: "That folder isn't in your library.") if path.nil?

    shelf = current_user.maker_shelves.new(path:)
    return redirect_to(shelves_path, notice: "#{display(path)} is now a shelf.") if shelf.save

    # THE MODEL'S OWN MESSAGE, NOT A GUESSED ONE. Two different validations can refuse this row --
    # uniqueness, and the reserved/traversal segment check -- and a picker CAN reach the second: a
    # library with a real `.trash` directory in it offers that folder like any other. Assuming
    # "already a shelf" here would tell a user the wrong fact about their own library, which is the
    # shape §14a records for a clobber answered as "File not found."
    redirect_to shelves_path, alert: "#{display(path)} #{shelf.errors[:path].first || 'could not be added'}."
  end

  def destroy
    shelf = current_user.maker_shelves.find(params[:id])
    shelf.destroy!
    redirect_to shelves_path, notice: "#{display(shelf.path)} is no longer a shelf."
  end

  private

  # "" for the library root -- the chooser sends a blank node_id for it, and a blank id must not
  # resolve to "some folder"; it is the root, deliberately.
  def path_for_param(node_id)
    return "" if node_id.blank?

    node = current_user.nodes.present.find_by(node_id:, kind: "dir")
    return nil unless node

    Maker::LibraryTree.new(current_user).path_for(node.node_id)
  end

  # WHAT MAKES PATH-KEYING HONEST. A stored pattern is not a live folder, so the page says whether
  # it currently names one -- and a wildcard says how many. Without this a renamed folder silently
  # stops being a shelf and the catalog quietly changes shape.
  def decorate(shelf)
    matches = @tree_paths ||= begin
      ids = current_user.nodes.present.where(kind: "dir").pluck(:node_id)
      ids.filter_map { |id| @tree.path_for(id) } << ""
    end
    hits = matches.count { |path| Maker::Shelf.matches?(shelf.path, path) }
    { record: shelf, label: display(shelf.path), wildcard: shelf.path.include?("*"), hits: }
  end

  def display(path) = path.presence || "/ (library root)"
end
```

- [ ] **Step 5: Write the view**

Create `app/views/shelves/index.html.erb`:

```erb
<% content_for :title, "Shelves - Tinkerex" %>

<div class="page-head">
  <h1>Shelves</h1>
  <%= link_to "Back to models", models_path, class: "linkbtn" %>
</div>

<p class="muted">
  A shelf is a folder that is not itself a model. Loose 3D files on a shelf each become their own
  model; each subfolder of a shelf becomes one model, with everything inside it.
</p>

<ul class="shelf-list">
  <% @shelves.each do |shelf| %>
    <li>
      <span class="shelf-path"><%= shelf[:label] %></span>
      <span class="shelf-status muted">
        <% if shelf[:wildcard] %>
          <%= pluralize(shelf[:hits], "folder") %> matched
        <% elsif shelf[:hits].zero? %>
          no folder at this path
        <% else %>
          in your library
        <% end %>
      </span>
      <%= button_to "Remove", shelf_path(shelf[:record]), method: :delete, class: "linkbtn" %>
    </li>
  <% end %>
</ul>

<%= form_with url: shelves_path, method: :post, class: "shelf-add" do %>
  <%= render "shared/folder_field",
             name: "node_id",
             children_url: library_children_path,
             create_url: library_folders_path,
             root_label: "/ (library root)" %>
  <button type="submit" class="btn primary">Add shelf</button>
<% end %>
```

**Two hygiene rules this view must obey**, both guarded by tests that will otherwise fail:
`test/integration/web/template_hygiene_test.rb` - never write a `%>` inside an `<%# ... %>` comment;
`test/stimulus_hygiene_test.rb` - every `data-controller` name must resolve to a real controller
file (this view names none of its own; `shared/_folder_field` brings `filechooser`, which exists).

- [ ] **Step 6: Link it from the models page**

In `app/views/models/index.html.erb`, in the `page-head` div, after the Import button:

```erb
  <%= link_to "Shelves", shelves_path, class: "linkbtn" %>
```

- [ ] **Step 7: Run the test**

Run: `bin/rails test test/integration/web/shelves_test.rb`
Expected: PASS, 10 runs.

- [ ] **Step 8: Mutation-check the tenancy guard**

In `path_for_param`, change `current_user.nodes` to `Node`. Expected: **RED** on "another user's
node cannot be turned into a shelf". Restore.

- [ ] **Step 9: Commit**

```bash
git add app/controllers/shelves_controller.rb app/views/shelves config/routes.rb app/views/models/index.html.erb test/integration/web/shelves_test.rb
git commit -m "Add the shelves settings page, picked with the existing folder chooser"
```

---

## Task 9: The rake task, the docs, and the full gate

**Files:**
- Create: `lib/tasks/models.rake`
- Create: `docs/invariants/model-intake.md`
- Modify: `CLAUDE.md`, `docs/STATUS.md`

- [ ] **Step 1: Write the rake task**

Create `lib/tasks/models.rake`:

```ruby
namespace :models do
  desc "Catalogue every model-role file in the library (MODEL_CATALOG_MAX_MODELS to raise the cap)"
  task catalog: :environment do
    User.find_each do |user|
      run = Maker::ModelIntake.for_user(user:)
      puts "user #{user.id}: created #{run.created}, attached #{run.attached}, " \
           "skipped #{run.skipped} (no shelf above them), status #{run.status}"
      puts "  capped at #{run.cap} - run again to continue" if run.status == :capped
    end
  end
end
```

- [ ] **Step 2: Write the invariants file**

Create `docs/invariants/model-intake.md` with exactly this content:

```markdown
# The model catalog and shelves

> CLAUDE.md §14k's area file. Read before touching `app/services/maker/model_intake.rb`,
> `app/services/maker/library_tree.rb`, `app/models/maker/shelf.rb`,
> `app/controllers/shelves_controller.rb`, or the `origin` / `auto_node_id` / `dismissed_at`
> columns on `maker_models`. The arc that produced it is in `docs/STATUS.md`.

- **A FOLDER IS EITHER A SHELF OR A MODEL, AND THE NEAREST SHELF ANCESTOR DECIDES.** A model-role
  file directly under a shelf is its own one-file model; anything deeper belongs to the shelf's
  direct child folder, which claims its whole subtree. **Nearest, not furthest** -- `chain.index`,
  never `rindex`: marking a folder inside a model a shelf is how a user splits one model into
  several, and the furthest match silently ignores them.
- **A SHELF IS A PATH PATTERN AND A MODEL IS A NODE ID. The two identities differ on purpose and
  neither may be "unified".** Only a pattern can express `Projects/*/models` -- one rule over a
  folder per project, none of which need exist. Only a node_id survives a rename: `Library::
  Reconciler` pairs by `(content_hash, size)` and keeps a renamed node's `node_id` (§14b), so a path
  key would abandon a renamed folder's row and mint a second, leaving two models for one folder.
  The cost of path-keyed shelves -- a renamed folder silently stops matching -- is paid by the
  settings page's live/missing indicator, which is therefore not decoration.
- **DELETING AN AUTO MODEL DISMISSES IT; DESTROYING IT MAKES THE SWEEP RECREATE IT.** The row is
  the memory. `Maker::ModelIntake` must look up existing rows WITHOUT the `catalogued` scope --
  filtering dismissed rows out of its own lookup is exactly how they come back, and the partial
  unique index on `(user_id, auto_node_id)` turns that into a `RecordNotUnique` rather than a
  duplicate. An IMPORT-origin model still destroys: nothing recreates it.
- **AN EMPTIED AUTO MODEL IS HIDDEN, NOT DISMISSED.** Hiding is reversible and dismissal is not, so
  reusing dismissal for "its files went away" means a folder that refills stays gone forever. The
  index drops auto models with no attachments off the already-loaded association; the rows
  themselves age out through `Maker::AttachmentReaper` on the ordinary grace window. Do not add a
  second reaper for this.
- **SHELVES ARE SEEDED ONCE, GUARDED BY `users.shelves_seeded_at`.** Ensuring the three defaults on
  every sweep would resurrect every row a user deleted, the fight-the-user shape §14f exists to
  prevent. Both first-touch doors -- the settings page and the sweep -- call the same
  `Maker::Shelf.seed_once!`, so neither has to be first.
- **THE SWEEP NEVER CALLS THE PORT AND NEVER CALLS `ensure_library_folder!`.** It writes database
  rows only, which is what makes it identical on all three backends and testable without a library
  on disk. `folder_node_id` is set from the dir key the classifier already resolved; calling the
  ensure would MINT `Models/<slug>` for every model as a side effect of merely looking -- the bug
  §14f records for `Projects::AttachmentsController#relocate`, at library-sweep scale.
- **ONE CAP, NOT TWO, AND THE SECOND ONE IS OWED BY WHOEVER ADDS A NUDGE.** `MAX_MODELS` bounds an
  unattended run's churn and is absolute rather than a percentage, because the intended first run
  catalogues 100% of what is there. `Maker::ProjectIntake` carries a second, smaller cap only
  because it has an entry point inside a browser request; nothing here does. If a nudge is ever
  added it needs its own cap, for the reason §14f states at both of those constants.
- **IN `Library::ScanJob` THE CATALOG RUNS AFTER THE RECONCILE **AND** AFTER THE PROJECT INTAKE, in
  that job, and both orderings are load-bearing.** After the reconcile because the catalog reads
  paths and an unsettled path is a wrong answer (§14f). After the project intake because that step
  MOVES files: catalogue first and a model is keyed on a file about to be filed into
  `Projects/<slug>/models/`, created at one location and emptied moments later by the same job.
- **`Maker::LibraryTree`'s ancestor walk MUST keep its cycle guard.** A parent cycle is
  unrepresentable on a mount and perfectly representable in a row set, and an unguarded walk HANGS
  the sweep rather than failing it. An unresolvable chain answers `nil`, which callers skip -- a
  library-wide sweep must not abort over one broken node.
- **THE TRIGGER SET IS `Maker::FileAttachment.role_for(name) == "model"`, never a fresh extension
  list.** §14d allows one file-type vocabulary. Consequence, stated rather than discovered: `.obj`,
  `.step` and `.stp` are catalogued alongside `.stl` and `.3mf`.
```

- [ ] **Step 3: Add the CLAUDE.md stub**

In `CLAUDE.md`, after the `§14j` section, add a new anchor - **do not renumber anything**:

```markdown
### 14k. The model catalog and shelves -> **`docs/invariants/model-intake.md`**

**Read that file before touching** `app/services/maker/model_intake.rb`,
`app/services/maker/library_tree.rb`, `app/models/maker/shelf.rb`, `app/controllers/shelves_controller.rb`,
or the `origin`/`auto_node_id`/`dismissed_at` columns on `maker_models`. It holds the nearest-shelf
rule, why a shelf is a path and a model is a node_id, why dismissal is not deletion, and the
ScanJob ordering.
```

Add the file to §10's `/docs/invariants` listing beside the other four.

- [ ] **Step 4: Check the docs guard**

Run: `bin/rails test test/docs_hygiene_test.rb`
Expected: PASS. It fails if a stub loses its file, a file loses its stub, or `CLAUDE.md` passes its
line ceiling. **If the ceiling is the failure, do not raise it** - the ratchet is deliberate; move
prose into the invariants file instead.

- [ ] **Step 5: Write the STATUS entry**

Add one entry to `docs/STATUS.md` as the new **Latest** section (renaming the previous Latest to a
plain dated heading, per that file's own header rules), covering: what was broken (the catalog was
Import-only while the vocabulary already said `model`), the rule, the two identity decisions and
why they differ, the measured numbers - **run the sweep against the live share deployment and record
what it created** - and what was deliberately left out (no eager nudge, so the catalog is up to 15
minutes behind an upload).

- [ ] **Step 6: Run the whole local gate**

Run: `bin/ci`
Expected: all seven gates green. **Read the three backend legs' run counts** (`test`, `test-s3`,
`test-chunk-remote`) and confirm they match within the known flap of plus or minus 2 assertions and
1 skip. A structural difference means a test in this branch depends on the ambient
`LIBRARY_BACKEND`, which is a real bug (§15). `test-chunk-remote` needs a sibling checkout:
`gh repo clone chaim354/tinkerex-sync ../tinkerex-sync`.

- [ ] **Step 7: Commit**

```bash
git add lib/tasks/models.rake docs/invariants/model-intake.md CLAUDE.md docs/STATUS.md
git commit -m "Document the model catalog: rake task, §14k invariants, STATUS entry"
```

- [ ] **Step 8: Finish the branch**

Per §15's close-out rule, with `bin/ci` green: commit, push and open a PR without stopping to ask.
Use `/finish-branch`. **Do not merge** - that always needs an explicit go-ahead. State plainly in
the PR what was verified and what was not; in particular, whether the sweep has been run against a
real library or only against fixtures.

---

## Deferred, and recorded so it reads as a decision

- **No eager nudge.** Nothing in a web request sweeps, so a `.stl` uploaded through Files appears at
  `/models` within one 15-minute tick rather than immediately.
- **`for_node` is NOT built, which departs from the spec.** The spec's section 6 lists
  `.for_node(user:, node:)` as a surviving entry point "the rake task uses". It has no caller:
  the rake task sweeps whole users, and the nudge that would need it is deferred. An entry point
  with no caller is dead code that the next reader has to evaluate, so `for_user` is the only one.
  Whoever adds the nudge adds `for_node` with it, plus its own cap, for the reason §14f gives at
  `EAGER_MAX_MOVES`.
- **The sweep does not attach to import-origin models.** A file appearing under `Models/<slug>/`
  is left alone - Import owns those rows.
- **`importer_controller.js`'s third extension table is not touched.** It is already recorded under
  STATUS's "Still open" and fixing it means plumbing the Ruby vocabulary into JS.
