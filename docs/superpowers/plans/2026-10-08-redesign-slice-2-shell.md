# Redesign slice 2 — the places sidebar — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the seven-section rail with the places sidebar (Home, Library, your projects,
pinned places, then Tools, Inventory-when-used, Trash and Settings). Folders can be pinned to it,
and the top bar gains a New ▾ menu.

**Architecture:** The sidebar stays `aside.rail` with `.rail-link`s, so it is restyled and
restructured but nothing is renamed. One helper, `ShellHelper#sidebar_current`, decides which link
is lit, so there is always exactly one. Pins are a new `maker_pins` table keyed by `node_id`. They
are hidden while their folder is tombstoned and reaped with it by `Maker::AttachmentReaper`. The
New ▾ menu creates in the folder being viewed, reusing the existing folder, text-file, project,
tool and inventory doors.

**Tech Stack:** Rails 8, server-rendered ERB, plain CSS layers, Stimulus (the existing `menu` and
`rail` controllers), Minitest request and system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` §4 (the shell) and §9.1
(pins). Slice 1 (#381) must be merged first: this plan uses its tokens, `folder_glyph` and the
restyled shell.

---

## Decisions this plan applies

From the spec, unchanged:
- Places sidebar: Home, Library, PROJECTS (8 most recently updated active projects, then "All
  projects"), PLACES ("3D models", then pins), and in the foot Tools, Inventory, Trash, Settings and
  the account controls. Collapsed, it shows icons only.
- Pins are stored by `node_id`, so a moved folder keeps its pin. A tombstoned folder's pin is hidden
  and kept, so restoring the folder restores the pin. A pin is reaped with its node.
- **Exactly one `.rail-link` is lit on every page** (`shell_layout_test.rb` keeps asserting it).

Sequencing choices this plan makes, each recorded in the spec by Task 5:
1. **Upload stays where it is until slice 4.** Spec §11 put "top bar Upload" in slice 2, but
   Upload's destination *is* slice 4's change (folder destinations replace the current project).
   Moving the button now would mean writing its destination logic twice. The New ▾ menu ships now.
2. **The current-project card stays in the sidebar until slice 4.** `.current-project select` and
   `form[action=current_project_path] select[name=project_id]` are pinned by tests and by the addon
   host page (design-system.md rule 12). They leave in the slice that retires the concept.
3. **"Home" keeps its name until slice 6** turns the page into Recent. Renaming the link before the
   page changes would label a page with a word that describes a different one.
4. **"3D models" links to `/models` until slice 5** makes it `/files?view=models`.
5. **New ▸ Folder and New ▸ Text file create in the Files page's folder, and at the library root
   everywhere else.** Slice 4 generalises "the folder you're in" to every page. New ▸ (a tool) links
   to the tool without `?in=`, which slice 4 adds.
6. **Pinning lives in the Files page's ⋯ menu**, when you are viewing a folder. No new context-menu
   entry, because the folder's own page already has a ⋯ menu.

## Files

| file | change | task |
|---|---|---|
| `db/migrate/20261008120000_create_maker_pins.rb`, `db/schema.rb` | the `maker_pins` table | 1 |
| `app/models/maker/pin.rb` | new model | 1 |
| `app/models/user.rb` | `has_many :maker_pins` | 1 |
| `lib/schema_map.rb`, `docs/schema-map.html` | LAYOUT and EDGES entries, regenerated map | 1 |
| `test/models/tenant_cleanup_test.rb` | builder and BUILD_ORDER | 1 |
| `app/services/maker/attachment_reaper.rb`, `test/services/maker/attachment_reaper_test.rb` | pins reaped with their node | 1 |
| `app/controllers/pins_controller.rb`, `config/routes.rb` | pin and unpin | 1 |
| `app/views/files/index.html.erb` | Pin or Unpin in the ⋯ menu | 1 |
| `test/models/maker/pin_test.rb`, `test/integration/web/pins_test.rb` | new tests | 1 |
| `app/helpers/shell_helper.rb` | `sidebar_projects`, `sidebar_pins`, `sidebar_inventory?`, `sidebar_current`, `sidebar_aria`, `tabbar_links`; `rail_links` removed | 2 |
| `app/views/layouts/_rail.html.erb`, `app/views/layouts/_tabbar.html.erb` | rewritten | 2 |
| `app/assets/stylesheets/shell.css` | sidebar groups, sublinks, foot nav | 2 |
| `test/integration/web/shell_layout_test.rb`, `test/integration/web/page_query_budget_test.rb` | updated and new tests | 2 |
| `app/helpers/new_menu_helper.rb` | new | 3 |
| `app/views/layouts/_topbar.html.erb` | New ▾ menu | 3 |
| `app/controllers/library_browse_controller.rb` | an HTML answer beside the JSON one | 3 |
| `app/assets/stylesheets/components.css` | `.menu-form` | 3 |
| `test/integration/web/new_menu_test.rb` | new | 3 |
| `docs/invariants/design-system.md`, the spec | rule 8, §4.1 and §11 amendments | 4 |

**Dependencies:** Task 1 first; Task 2 needs `Maker::Pin`. **Task 3 is independent of Tasks 1 and
2**, and its files are disjoint from both, so it can run in parallel with them in its own worktree.
Task 4 last.

**Branch:** `claude/redesign-slice-2` from `origin/main` once #381 has merged.

**Running tests:** `LIBRARY_PATH=$(mktemp -d) bin/rails test <files>` (a bare run errors without
it). For the close-out, bare `bin/ci`.

---

### Task 1: Pins — table, model, reaper, door

**Files:** listed under task 1 in the table above.

- [ ] **Step 1: Write the model test**

Create `test/models/maker/pin_test.rb`:

```ruby
require "test_helper"

module Maker
  class PinTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pin-#{SecureRandom.hex(4)}@example.com")
      @dir = @user.nodes.create!(node_id: "dir-a", name: "laser", kind: "dir")
    end

    test "a pin names a live folder in its own user's library" do
      assert @user.maker_pins.create(node_id: @dir.node_id).persisted?

      file = @user.nodes.create!(node_id: "file-a", name: "a.stl", kind: "file")
      refute @user.maker_pins.new(node_id: file.node_id).valid?, "a file is not a place"

      gone = @user.nodes.create!(node_id: "dir-gone", name: "old", kind: "dir", deleted: true)
      refute @user.maker_pins.new(node_id: gone.node_id).valid?, "a tombstoned folder cannot be pinned"

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "dir-b", name: "theirs", kind: "dir")
      refute @user.maker_pins.new(node_id: "dir-b").valid?, "another user's folder is not yours to pin"
    end

    test "a folder is pinned once" do
      @user.maker_pins.create!(node_id: @dir.node_id)
      refute @user.maker_pins.new(node_id: @dir.node_id).valid?
    end

    test "pins take the next position, so the sidebar keeps the order they were pinned in" do
      b = @user.nodes.create!(node_id: "dir-c", name: "cnc", kind: "dir")
      first = @user.maker_pins.create!(node_id: @dir.node_id)
      second = @user.maker_pins.create!(node_id: b.node_id)
      assert_operator second.position, :>, first.position
      assert_equal [ first, second ], @user.maker_pins.ordered.to_a
    end

    test "the sidebar holds at most CAP pins" do
      Maker::Pin::CAP.times do |i|
        d = @user.nodes.create!(node_id: "cap-#{i}", name: "p#{i}", kind: "dir")
        @user.maker_pins.create!(node_id: d.node_id)
      end
      extra = @user.nodes.create!(node_id: "cap-extra", name: "one more", kind: "dir")
      pin = @user.maker_pins.new(node_id: extra.node_id)
      refute pin.valid?
      assert_match(/holds #{Maker::Pin::CAP}/, pin.errors.full_messages.to_sentence)
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/models/maker/pin_test.rb`
Expected: ERROR, `undefined method 'maker_pins'`.

- [ ] **Step 3: Migration, model, association**

`db/migrate/20261008120000_create_maker_pins.rb`:

```ruby
class CreateMakerPins < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_pins do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :node_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_pins, %i[user_id node_id], unique: true
    add_index :maker_pins, %i[user_id position]
  end
end
```

`app/models/maker/pin.rb`:

```ruby
module Maker
  # A FOLDER PINNED TO THE SIDEBAR'S PLACES (structural redesign spec §4.1, 2026-10-08).
  #
  # KEYED BY `node_id`, NEVER BY PATH: a move keeps a node's id (§14b), so a renamed or moved
  # folder keeps its pin. A pin whose folder is tombstoned is HIDDEN, not deleted — the sidebar
  # reads only live folders (ShellHelper#sidebar_pins) — so restoring the folder restores the pin.
  # Maker::AttachmentReaper removes it only once the node is reapable (Maker::DeadNodes), the same
  # grace an attachment gets.
  class Pin < ApplicationRecord
    self.table_name = "maker_pins"

    CAP = 12

    belongs_to :user

    before_create { self.position = (user.maker_pins.maximum(:position) || -1) + 1 }

    validates :node_id, presence: true, uniqueness: { scope: :user_id }
    validate :a_live_folder_of_this_user, on: :create
    validate :under_the_cap, on: :create

    scope :ordered, -> { order(:position, :id) }

    private

    def a_live_folder_of_this_user
      return if node_id.blank? || user.nil?
      return if user.nodes.present.exists?(node_id:, kind: "dir")

      errors.add(:base, "That folder isn't in your library.")
    end

    def under_the_cap
      return if user.nil? || user.maker_pins.count < CAP

      errors.add(:base, "The sidebar holds #{CAP} pinned places. Unpin one first.")
    end
  end
end
```

In `app/models/user.rb`, beside `has_many :maker_project_blocks`:

```ruby
  has_many :maker_pins, class_name: "Maker::Pin", dependent: :destroy
```

Run: `bin/rails db:migrate && LIBRARY_PATH=$(mktemp -d) bin/rails test test/models/maker/pin_test.rb`
Expected: PASS, 4 runs.

- [ ] **Step 4: Satisfy the new-table guards**

These four guards fail by construction for a new table, so run them before the full gate.

In `lib/schema_map.rb`, add `maker_pins` to the `"Library"` LAYOUT group's table list:

```ruby
    { "label" => "Library", "group" => "maker",
      "tables" => %w[maker_items maker_collection_items maker_collections maker_taggings
                     maker_tags maker_tasks maker_pins] },
```

Then add this EDGES entry beside `maker_project_blocks.node_id`. The `user_id` tenant edge is
derived, so do not add it.

```ruby
    [ "maker_pins.node_id",                 "nodes.node_id",      "app", "pins" ],
```

Regenerate the map: `bin/rails schema:map`.

In `test/models/tenant_cleanup_test.rb`, add a builder after `"maker_release_files"`:

```ruby
    "maker_pins" => ->(u) {
      dir = u.nodes.create!(node_id: SecureRandom.uuid, name: "pinned", kind: "dir")
      u.maker_pins.create!(node_id: dir.node_id)
    }
```

Append `maker_pins` to `BUILD_ORDER`, after `maker_release_files`.

`test/models/structural_orphan_test.rb` needs **no** case. `maker_pins` has no edge to a parent `id`
other than the tenant `user_id`, which `tenant_cleanup_test` covers, and its `node_id` edge is a
node column, which that file excludes by design (its header says why).

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/schema_map_test.rb test/models/tenant_cleanup_test.rb test/models/structural_orphan_test.rb test/integration/web/template_hygiene_test.rb`
Expected: PASS.

- [ ] **Step 5: The reaper — failing test, then the change**

Append to `test/services/maker/attachment_reaper_test.rb`, before the final `end`s:

```ruby
    test "a pin is reaped with its folder: gone for good at once, a tombstone only past the window" do
      gone  = @user.nodes.create!(node_id: "pin-gone", name: "gone", kind: "dir")
      old   = @user.nodes.create!(node_id: "pin-old", name: "old", kind: "dir")
      fresh = @user.nodes.create!(node_id: "pin-fresh", name: "fresh", kind: "dir")
      live  = @user.nodes.create!(node_id: "pin-live", name: "live", kind: "dir")
      pins = [ gone, old, fresh, live ].map { |n| @user.maker_pins.create!(node_id: n.node_id) }
      gone.destroy!
      old.update_columns(deleted: true, updated_at: 31.days.ago)
      fresh.update_columns(deleted: true)

      assert_equal 2, Maker::AttachmentReaper.reap_all!(grace: 30.days)
      assert_equal %w[pin-fresh pin-live], @user.maker_pins.order(:node_id).pluck(:node_id)
      assert_equal 4, pins.size
    end
```

Run it and expect FAIL: `0` reaped. Then, in `app/services/maker/attachment_reaper.rb`, replace the
body of `reap!` with:

```ruby
    def reap!(user, grace: GRACE, dry_run: false)
      attachments = user.maker_file_attachments.to_a
      links       = user.maker_file_links.to_a
      pins        = user.maker_pins.to_a
      covered = user.maker_projects.where.not(cover_node_id: [ nil, "" ]).to_a +
                user.maker_models.where.not(cover_node_id: [ nil, "" ]).to_a
      return 0 if attachments.empty? && covered.empty? && links.empty? && pins.empty?

      nodes  = Maker::DeadNodes.index(user, attachments.map(&:node_id) +
                                            covered.map { |p| p[:cover_node_id] } +
                                            links.flat_map { |l| [ l.from_node_id, l.to_node_id ] } +
                                            pins.map(&:node_id))
      cutoff = grace.ago

      doomed = attachments.select { |a| Maker::DeadNodes.reapable?(nodes[a.node_id], cutoff) }
      stale_covers = covered.select { |p| Maker::DeadNodes.reapable?(nodes[p[:cover_node_id]], cutoff) }
      dead_links = links.select { |l|
        Maker::DeadNodes.reapable?(nodes[l.from_node_id], cutoff) ||
          Maker::DeadNodes.reapable?(nodes[l.to_node_id], cutoff)
      }
      # A PIN GOES WITH ITS FOLDER, on the same grace (Maker::Pin's header): hidden by the sidebar
      # while the folder is a fresh tombstone, removed here once the folder is gone for good.
      dead_pins = pins.select { |p| Maker::DeadNodes.reapable?(nodes[p.node_id], cutoff) }
      total = doomed.size + stale_covers.size + dead_links.size + dead_pins.size
      return total if dry_run

      doomed.each(&:destroy!)
      stale_covers.each { |p| p.update_column(:cover_node_id, nil) }
      dead_links.each(&:destroy!)
      dead_pins.each(&:destroy!)
      total
    end
```

Keep every comment above and inside the original method that still applies. Add one sentence to
the module's header comment naming pins beside attachments, covers and links.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/services/maker/attachment_reaper_test.rb`
Expected: PASS, the existing tests included.

- [ ] **Step 6: The door — failing request test**

Create `test/integration/web/pins_test.rb`:

```ruby
require "test_helper"

module Web
  class PinsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pins-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
    end

    test "a folder's ⋯ menu offers Pin, and pinning lands back in the folder" do
      get files_path(folder: @dir.node_id)
      assert_select "details.menu form[action=?] input[name='node_id'][value=?]", pins_path, @dir.node_id
      assert_select "details.menu button", text: "Pin to sidebar"

      post pins_path, params: { node_id: @dir.node_id }
      assert_redirected_to files_path(folder: @dir.node_id)
      assert_equal [ @dir.node_id ], @user.maker_pins.pluck(:node_id)

      follow_redirect!
      assert_select "details.menu button", text: "Unpin from sidebar"
    end

    test "unpinning removes the pin and lands back in the folder" do
      @user.maker_pins.create!(node_id: @dir.node_id)
      delete pin_path(@dir.node_id)
      assert_redirected_to files_path(folder: @dir.node_id)
      assert_empty @user.maker_pins
    end

    test "the library root offers no pin" do
      get files_path
      assert_select "details.menu button", text: "Pin to sidebar", count: 0
    end

    test "a refused pin says why and creates nothing" do
      file = @user.nodes.create!(node_id: "file-a", name: "a.stl", kind: "file")
      post pins_path, params: { node_id: file.node_id }, headers: { "HTTP_REFERER" => files_url }
      assert_redirected_to files_url
      assert_equal "That folder isn't in your library.", flash[:alert]
      assert_empty @user.maker_pins
    end

    test "another user's pin cannot be removed" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "dir-theirs", name: "theirs", kind: "dir")
      other.maker_pins.create!(node_id: theirs.node_id)
      delete pin_path(theirs.node_id)
      assert_response :not_found
      assert_equal 1, other.maker_pins.count
    end
  end
end
```

Run it and expect ERROR: `undefined local variable or method 'pins_path'`.

- [ ] **Step 7: Route, controller, menu**

In `config/routes.rb`, after `resources :file_links, …`:

```ruby
  # Sidebar places (structural redesign spec §4.1). `:id` IS THE FOLDER'S node_id, not the row's,
  # so the Unpin button names the folder it unpins and a stale row id can never unpin the wrong one.
  resources :pins, only: %i[create destroy]
```

`app/controllers/pins_controller.rb`:

```ruby
# Pin and unpin a folder in the sidebar's Places (structural redesign spec §4.1). Session-authed
# web layer (§14d). Both answer with a redirect to the folder, so the maker sees the sidebar change
# where they are standing. `destroy` finds by node_id within current_user, so another user's pin
# is a 404, never a delete.
class PinsController < ApplicationController
  def create
    pin = current_user.maker_pins.new(node_id: params[:node_id].to_s)
    if pin.save
      redirect_to files_path(folder: pin.node_id), notice: "Pinned to the sidebar."
    else
      redirect_back fallback_location: files_path, alert: pin.errors.full_messages.to_sentence
    end
  end

  def destroy
    pin = current_user.maker_pins.find_by!(node_id: params[:id].to_s)
    pin.destroy!
    redirect_to files_path(folder: pin.node_id), notice: "Unpinned from the sidebar."
  end
end
```

In `app/views/files/index.html.erb`, widen the menu's condition (line 48) so a folder view always
has a ⋯ menu:

```erb
<% menu_items = capabilities.scannable? || current_project.present? ||
                @folder_project.present? || adoptable_folder || @folder.present? %>
```

Inside `<div class="menu-list">`, as the first entry:

```erb
          <%# PIN TO THE SIDEBAR (structural redesign, slice 2): the folder being viewed, never the
              library root (no @folder there), and never in flat/search mode (also no @folder). %>
          <% if @folder %>
            <% if current_user.maker_pins.exists?(node_id: @folder.node_id) %>
              <%= button_to "Unpin from sidebar", pin_path(@folder.node_id), method: :delete,
                            class: "menu-item", data: { turbo: false } %>
            <% else %>
              <%= button_to "Pin to sidebar", pins_path, params: { node_id: @folder.node_id },
                            class: "menu-item", data: { turbo: false } %>
            <% end %>
          <% end %>
```

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/pins_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/page_query_budget_test.rb`
Expected: PASS. The query budget holds because the `exists?` is one query, whatever the folder holds.

- [ ] **Step 8: Mutation-check (§15)** — report actual output for each.

1. In `Maker::Pin#a_live_folder_of_this_user`, drop `kind: "dir"`. Expected: `pin_test.rb` is red on
   "a file is not a place". Undo by hand.
2. In the reaper, delete `dead_pins.each(&:destroy!)`. Expected: the new reaper test is red. Undo.
3. In `PinsController#destroy`, replace `current_user.maker_pins` with `Maker::Pin`. Expected:
   "another user's pin cannot be removed" is red. Undo.

Undo every mutation by hand, never with `git checkout --`, since the edits are uncommitted. Run
`rm -rf tmp/cache/bootsnap*` after each undo.

- [ ] **Step 9: Commit**

Subject: `A folder can be pinned to the sidebar, and its pin goes with it`. Write the message to a
file and commit with `git commit -F`, because zsh runs backticks inside `-m`. End it with the
Co-Authored-By line.

---

### Task 2: The places sidebar

**Files:** `app/helpers/shell_helper.rb`, `app/views/layouts/_rail.html.erb`,
`app/views/layouts/_tabbar.html.erb`, `app/assets/stylesheets/shell.css`,
`test/integration/web/shell_layout_test.rb`, `test/integration/web/page_query_budget_test.rb`.
It needs Task 1's `Maker::Pin`.

- [ ] **Step 1: Rewrite the shell tests first**

In `test/integration/web/shell_layout_test.rb`:

- **"a signed-in page renders the rail with exactly one active section":** the lit text becomes
  `"Library"`.
- **"each top-level section lights its own link":** the map becomes
  `{ root_path => "Home", projects_path => "All projects", models_path => "3D models",
  inventory_items_path => "Inventory", tools_path => "Tools", trash_index_path => "Trash" }`.
- **"a nested controller lights its family":** the project page lights the project's own link
  (`text: "Desk Lamp"`), and `shelves_path` lights `"3D models"`.
- **The settings-foot test:** `suppliers_path` still lights `"Inventory"` (unchanged).

Also update any assertion that counts the phone tab bar's links to **4**. Search the file and
`test/system/shell_test.rb` for `tabbar`.

Add these tests:

```ruby
    test "the sidebar lists the eight most recently updated active projects, then All projects" do
      projects = 10.times.map { |i| @user.maker_projects.create!(name: "P#{i}") }
      projects.each_with_index { |p, i| p.update_column(:updated_at, i.days.ago) }
      @user.maker_projects.create!(name: "Shelved", status: "archived")
      get files_path
      names = css_select("aside.rail a.rail-project .rail-label").map { |e| e.text.strip }
      assert_equal %w[P0 P1 P2 P3 P4 P5 P6 P7], names
      assert_select "aside.rail a.rail-link[href=?]", projects_path, text: "All projects"
    end

    test "an older project's page lights All projects, so one link is always lit" do
      projects = 9.times.map { |i| @user.maker_projects.create!(name: "P#{i}") }
      projects.each_with_index { |p, i| p.update_column(:updated_at, i.days.ago) }
      oldest = projects.last
      get project_path(oldest)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "All projects"
    end

    test "a pinned folder sits under Places and lights when you are in it or beneath it" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      jigs = @user.nodes.create!(node_id: "dir-jigs", name: "jigs", kind: "dir", parent_node_id: laser.node_id)
      @user.maker_pins.create!(node_id: laser.node_id)

      get files_path(folder: jigs.node_id)
      assert_select "aside.rail a.rail-pin[href=?] svg.folder-glyph", files_path(folder: laser.node_id)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "laser"

      get files_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Library"
    end

    test "a pin to a tombstoned folder is hidden and kept" do
      laser = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
      @user.maker_pins.create!(node_id: laser.node_id)
      laser.update!(deleted: true)
      get files_path
      assert_select "aside.rail a.rail-pin", count: 0
      assert_equal 1, @user.maker_pins.count
    end

    test "Inventory joins the sidebar once there are items, or while you are in it" do
      get files_path
      assert_select "aside.rail a.rail-link[href=?]", inventory_items_path, count: 0
      get inventory_items_path
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "Inventory"
      @user.maker_inventory_items.create!(name: "M3 bolt")
      get files_path
      assert_select "aside.rail a.rail-link[href=?]", inventory_items_path, count: 1
    end

    test "the phone tab bar is Home, Library, Projects and Tools" do
      get files_path
      labels = css_select("nav.tabbar a.tabbar-link span").map { |e| e.text.strip }
      assert_equal %w[Home Library Projects Tools], labels
      assert_select "nav.tabbar a.tabbar-link[aria-current='page']", count: 1, text: "Library"
    end
```

In `test/integration/web/page_query_budget_test.rb`, add:

```ruby
    # THE SIDEBAR IS ON EVERY PAGE, so a per-project or per-pin query here would grow every page in
    # the app. Settings is the probe because nothing else on it grows with projects or pins.
    test "the sidebar does not grow with projects or pins" do
      grow = lambda do |upto|
        (@user.maker_projects.count...upto).each { |i| @user.maker_projects.create!(name: "P#{i}") }
        (@user.maker_pins.count...[ upto, Maker::Pin::CAP ].min).each do |i|
          dir = @user.nodes.create!(node_id: "pin-#{i}", name: "place-#{i}", kind: "dir")
          @user.maker_pins.create!(node_id: dir.node_id)
        end
      end
      grow.call(SMALL)
      get settings_path
      small = count_queries { get settings_path }
      grow.call(LARGE)
      large = count_queries { get settings_path }
      assert_equal small, large, "the sidebar's queries grew with projects or pins"
    end
```

Run them and expect FAIL, because the old rail renders.

- [ ] **Step 2: The helper**

In `app/helpers/shell_helper.rb`, delete `rail_links` (the tab bar was its last reader; grep `app/`
and `test/` to confirm). Add, after `rail_section`:

```ruby
  # --- The places sidebar (structural redesign spec §4.1, slice 2). Each list is ONE query
  # whatever it holds, so no page's query count grows with projects or pins
  # (page_query_budget_test.rb). Memoised per request: the sidebar and the tab bar both read them.
  SIDEBAR_PROJECTS = 8

  def sidebar_projects
    @sidebar_projects ||= current_user.maker_projects.where.not(status: "archived")
                                      .order(updated_at: :desc).limit(SIDEBAR_PROJECTS).to_a
  end

  # [pin, folder name] for each pin whose folder is LIVE, in pinned order. A tombstoned folder's pin
  # is skipped here and kept in the table, so restoring the folder restores the pin (Maker::Pin).
  def sidebar_pins
    @sidebar_pins ||= begin
      pins = current_user.maker_pins.ordered.to_a
      names = current_user.nodes.present.where(node_id: pins.map(&:node_id), kind: "dir")
                          .pluck(:node_id, :name).to_h
      pins.filter_map { |pin| [ pin, names[pin.node_id] ] if names.key?(pin.node_id) }
    end
  end

  # Inventory earns its sidebar entry once it is used — or while the maker is standing in it, so the
  # page they are on is never one with no lit link.
  def sidebar_inventory?
    rail_section == "inventory" || current_user.maker_inventory_items.exists?
  end

  # THE ONE ANSWER TO "WHICH LINK IS LIT", so exactly one is. A key, compared by sidebar_aria:
  #   [:home] [:library] [:pin, node_id] [:project, id] [:all_projects] [:models] [:inventory]
  #   [:tools] [:trash] [:settings]
  # On the Files page the DEEPEST pinned folder on the breadcrumb wins over Library (`@crumbs` is
  # FilesController#index's ancestor chain; absent elsewhere). On a project page the project's own
  # link wins, unless it is older than the eight listed — then All projects, never nothing.
  def sidebar_current
    @sidebar_current ||=
      case rail_section
      when "home" then [ :home ]
      when "files"
        pinned = sidebar_pins.map { |pin, _| pin.node_id }
        deepest = Array(@crumbs).map(&:node_id).reverse.find { |id| pinned.include?(id) }
        deepest ? [ :pin, deepest ] : [ :library ]
      when "projects"
        id = @project&.id
        id && sidebar_projects.any? { |p| p.id == id } ? [ :project, id ] : [ :all_projects ]
      when "models" then [ :models ]
      when "inventory" then [ :inventory ]
      when "tools" then [ :tools ]
      when "trash" then [ :trash ]
      when "settings" then [ :settings ]
      end
  end

  def sidebar_aria(key) = sidebar_current == key ? "page" : nil

  # The phone tab bar: four destinations, each lit by the same answer the sidebar uses.
  def tabbar_links
    current = sidebar_current&.first
    [
      [ "Home", root_path, :home, current == :home ],
      [ "Library", files_path, :files, %i[library pin].include?(current) ],
      [ "Projects", projects_path, :projects, %i[project all_projects].include?(current) ],
      [ "Tools", tools_path, :tools, current == :tools ]
    ]
  end
```

- [ ] **Step 3: The sidebar partial**

Replace `app/views/layouts/_rail.html.erb` entirely:

```erb
<%# The places sidebar (structural redesign spec §4.1, slice 2). Still `aside.rail` with `.rail-link`s
    — restyle and restructure, never rename (design-system.md rule 12) — and still carrying the
    current-project card, whose form and select current_project_topbar_test, box_revisions_test and
    addon_bundle_test pin until slice 4 retires the concept. EXACTLY ONE `.rail-link` carries
    aria-current: ShellHelper#sidebar_current decides which. %>
<aside class="rail" id="rail" data-controller="rail">
  <%= link_to root_path, class: "brand", "aria-label": "Tinkerex home" do %>
    <span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span>
  <% end %>

  <% choices = current_project_choices %>
  <% if choices.any? %>
    <%= form_with url: current_project_path, method: :patch, data: { turbo: false },
                  class: "current-project-form" do %>
      <label class="current-project">
        <span class="current-project-label">Current project</span>
        <span class="current-project-name"><%= current_project&.name || "None" %></span>
        <span class="current-project-hint">Uploads and tool output land here</span>
        <%= select_tag :project_id,
              options_for_select([ [ "— none —", "" ] ] + choices, current_project&.id),
              onchange: "this.form.requestSubmit()", "aria-label": "Switch current project" %>
      </label>
    <% end %>
  <% end %>

  <nav class="rail-nav" aria-label="Main">
    <ul>
      <li>
        <%= link_to root_path, class: "rail-link", title: "Home", "aria-current": sidebar_aria([ :home ]) do %>
          <%= rail_icon(:home) %><span class="rail-label">Home</span>
        <% end %>
      </li>
      <li>
        <%= link_to files_path, class: "rail-link", title: "Library", "aria-current": sidebar_aria([ :library ]) do %>
          <%= rail_icon(:files) %><span class="rail-label">Library</span>
        <% end %>
      </li>
    </ul>

    <h2 class="rail-group-head">Projects</h2>
    <ul>
      <% sidebar_projects.each do |project| %>
        <li>
          <%= link_to project_path(project), class: "rail-link rail-project", title: project.name,
                      "aria-current": sidebar_aria([ :project, project.id ]) do %>
            <span class="rail-label"><%= project.name %></span>
          <% end %>
        </li>
      <% end %>
      <li>
        <%= link_to projects_path, class: "rail-link", title: "All projects",
                    "aria-current": sidebar_aria([ :all_projects ]) do %>
          <%= rail_icon(:projects) %><span class="rail-label">All projects</span>
        <% end %>
      </li>
    </ul>

    <h2 class="rail-group-head">Places</h2>
    <ul>
      <li>
        <%= link_to models_path, class: "rail-link", title: "3D models", "aria-current": sidebar_aria([ :models ]) do %>
          <%= rail_icon(:models) %><span class="rail-label">3D models</span>
        <% end %>
      </li>
      <% sidebar_pins.each do |pin, name| %>
        <li>
          <%= link_to files_path(folder: pin.node_id), class: "rail-link rail-pin", title: name,
                      "aria-current": sidebar_aria([ :pin, pin.node_id ]) do %>
            <%= folder_glyph %><span class="rail-label"><%= name %></span>
          <% end %>
        </li>
      <% end %>
    </ul>
  </nav>

  <nav class="rail-nav rail-nav--foot" aria-label="Tools and trash">
    <ul>
      <li>
        <%= link_to tools_path, class: "rail-link", title: "Tools", "aria-current": sidebar_aria([ :tools ]) do %>
          <%= rail_icon(:tools) %><span class="rail-label">Tools</span>
        <% end %>
      </li>
      <% if sidebar_inventory? %>
        <li>
          <%= link_to inventory_items_path, class: "rail-link", title: "Inventory",
                      "aria-current": sidebar_aria([ :inventory ]) do %>
            <%= rail_icon(:inventory) %><span class="rail-label">Inventory</span>
          <% end %>
        </li>
      <% end %>
      <li>
        <%= link_to trash_index_path, class: "rail-link", title: "Trash", "aria-current": sidebar_aria([ :trash ]) do %>
          <%= rail_icon(:trash) %><span class="rail-label">Trash</span>
        <% end %>
      </li>
    </ul>
  </nav>

  <div class="rail-foot">
    <button type="button" class="rail-btn" data-controller="theme" data-action="theme#cycle"
            aria-label="Theme: <%= ui_theme %>">
      <%= rail_icon(:theme) %><span data-theme-target="label">Theme: <%= ui_theme %></span>
    </button>
    <button type="button" class="rail-btn" data-action="rail#toggle" data-rail-target="toggle"
            aria-expanded="<%= rail_collapsed? ? "false" : "true" %>" aria-label="Collapse navigation">
      <%= rail_icon(:collapse) %><span>Collapse</span>
    </button>
    <span class="rail-user" title="<%= current_user.email %>"><%= current_user.email %></span>
    <%= link_to settings_path, class: "rail-btn rail-settings",
                "aria-current": (sidebar_current == [ :settings ] ? "page" : nil) do %>
      <%= rail_icon(:settings) %><span>Settings</span>
    <% end %>
    <%= button_to "Sign out", destroy_user_session_path, method: :delete, class: "rail-btn" %>
  </div>
</aside>
```

Replace `app/views/layouts/_tabbar.html.erb`:

```erb
<%# The phone navigation (structural redesign spec §4.3): four destinations, shown below 720px by
    shell.css. Lit by ShellHelper#sidebar_current, the same answer as the sidebar. %>
<nav class="tabbar" aria-label="Main">
  <% tabbar_links.each do |label, path, icon, lit| %>
    <%= link_to path, class: "tabbar-link", "aria-current": (lit ? "page" : nil) do %>
      <%= rail_icon(icon) %><span><%= label %></span>
    <% end %>
  <% end %>
</nav>
```

- [ ] **Step 4: The sidebar's CSS**

In `app/assets/stylesheets/shell.css`, change `.rail-foot`'s `margin-top: auto` to `margin-top: 0`.
The foot nav now takes the push. Then add after the `.rail-icon` rule:

```css
  /* The places sidebar's groups (structural redesign, slice 2). A group head is a LABEL: Plex Sans,
     uppercase (cohesion decision 4). Project links carry no icon and sit indented under their head;
     a pin carries the folder glyph. The foot nav takes the auto margin that pushes it and the
     account foot to the bottom. */
  .rail-group-head { margin: var(--space-3) 10px 2px; font: 600 11px/16px var(--font-ui); text-transform: uppercase; letter-spacing: .08em; color: var(--fg-muted); }
  .rail-label { min-width: 0; overflow: hidden; text-overflow: ellipsis; }
  .rail-project { min-height: 30px; padding-left: 36px; font-weight: 400; }
  .rail-pin { font-weight: 400; }
  .rail-nav--foot { margin-top: auto; }
```

Add these to the collapsed rules (`.rail--collapsed …`) and to the `@media (max-width: 1099px)`
block, next to the existing hide lists:

```css
  .rail--collapsed .rail-group-head, .rail--collapsed .rail-project, .rail--collapsed .rail-pin { display: none; }
```

```css
    .rail-group-head, .rail-project, .rail-pin { display: none; }
```

- [ ] **Step 5: Run the shell suites**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/shell_layout_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/settings_hub_test.rb test/system/shell_test.rb test/css_hygiene_test.rb`
Expected: PASS. The 375px sweep in `shell_test.rb` covers the tab bar's new four links.

Then grep `test/` for assertions that name the old rail labels (`text: "Files"`, `text: "Models"`,
`text: "Projects"` on `a.rail-link`) and fix any outside these files.

- [ ] **Step 6: Mutation-check (§15)** — report actual output for each.

1. In `sidebar_current`'s `"files"` branch, return `[ :library ]` unconditionally. Expected: "a pinned
   folder … lights" is red.
2. In `sidebar_pins`, replace the single pluck with a per-pin
   `current_user.nodes.present.find_by(node_id: pin.node_id, kind: "dir")`. Expected: the budget
   test is red with a grown count.
3. In `sidebar_inventory?`, drop the `rail_section == "inventory"` arm. Expected: the Inventory test
   is red on the inventory page (no lit link).

Undo each by hand.

- [ ] **Step 7: Look at it**

With `bin/dev`, check expanded and collapsed, at 1440, 900 and 375px, in light and dark, with three
projects and two pins. Exactly one link is lit, a long project name ends in an ellipsis, and the
foot sits at the bottom.

- [ ] **Step 8: Commit**

Subject: `The rail becomes the places sidebar: your projects and pinned folders, one link lit`.

---

### Task 3: The New ▾ menu (independent of Tasks 1–2)

**Files:** `app/helpers/new_menu_helper.rb`, `app/views/layouts/_topbar.html.erb`,
`app/controllers/library_browse_controller.rb`, `app/assets/stylesheets/components.css`,
`test/integration/web/new_menu_test.rb`.

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/new_menu_test.rb`:

```ruby
require "test_helper"

module Web
  class NewMenuTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "new-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-laser", name: "laser", kind: "dir")
    end

    test "the top bar's New menu offers a folder, a text file, a project and an inventory item" do
      get projects_path
      assert_select "header.topbar details.menu.topbar-new" do
        assert_select "form[action=?] input[name='name']", library_folders_path
        assert_select "a.menu-item[href=?]", new_files_text_file_path, text: "Text file"
        assert_select "a.menu-item[href=?]", new_project_path, text: "Project"
        assert_select "a.menu-item[href=?]", new_inventory_item_path, text: "Inventory item"
      end
    end

    test "on a folder's page, New creates in that folder" do
      get files_path(folder: @dir.node_id)
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]",
                    library_folders_path, @dir.node_id
      assert_select "header.topbar a.menu-item[href=?]",
                    new_files_text_file_path(parent_node_id: @dir.node_id)
    end

    test "New ▸ Folder from the browser lands in the new folder" do
      post library_folders_path, params: { name: "jigs", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "text/html" }
      created = @user.nodes.present.find_by!(name: "jigs", parent_node_id: @dir.node_id)
      assert_redirected_to files_path(folder: created.node_id)
    end

    test "a refused folder name comes back as a flash, not JSON" do
      post library_folders_path, params: { name: "", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "text/html", "HTTP_REFERER" => files_url(folder: @dir.node_id) }
      assert_redirected_to files_url(folder: @dir.node_id)
      assert_equal "Folder name can't be blank.", flash[:alert]
    end

    test "the file chooser's JSON door is unchanged" do
      post library_folders_path, params: { name: "fixtures", parent_node_id: @dir.node_id }, as: :json
      assert_response :created
      assert_equal "fixtures", response.parsed_body["name"]
    end

    # AN AMBIGUOUS Accept KEEPS GETTING JSON — a caller that never said what it wants is an older
    # caller, and it was getting JSON before the HTML door existed. This is what pins the respond_to
    # ORDER; the explicit-JSON test above cannot see it.
    test "an ambiguous Accept still gets JSON" do
      post library_folders_path, params: { name: "anything", parent_node_id: @dir.node_id },
                                 headers: { "Accept" => "*/*" }
      assert_response :created
      assert_equal "application/json", response.media_type
    end
  end
end
```

Run it and expect FAIL: there is no `.topbar-new`, and the HTML post renders JSON.

- [ ] **Step 2: Helper, menu, controller, CSS**

`app/helpers/new_menu_helper.rb`:

```ruby
# The top bar's New ▾ menu (structural redesign spec §4.2, slice 2). What it creates lands in the
# folder the maker is standing in. In this slice that is the Files page's folder (`params[:folder]`
# on files#index) and the library root everywhere else; slice 4 generalises "the folder you're in"
# to every page and moves Upload into this bar beside it.
module NewMenuHelper
  def new_menu_folder_node_id
    params[:folder].presence if controller_path == "files" && action_name == "index"
  end

  # Available tools only; an unavailable one would be a menu entry that opens an apology. NOT ASKED
  # WITHOUT A SOURCE: an unconfigured Source.current raises KeyError, which Registry rescues to []
  # with a warning — on every page, since this is the layout.
  def new_menu_tools
    @new_menu_tools ||=
      Maker::Addons::Source.configured? ? Maker::Addons::Registry.all.select(&:available?) : []
  end
end
```

In `app/views/layouts/_topbar.html.erb`, after the search form's closing `<% end %>`:

```erb
  <%# NEW ▾ (structural redesign spec §4.2): everything here creates where the maker is standing —
      NewMenuHelper#new_menu_folder_node_id. Upload joins it in slice 4 with folder destinations. %>
  <details class="menu topbar-new" data-controller="menu">
    <summary class="btn">New <span aria-hidden="true">▾</span></summary>
    <div class="menu-list">
      <%= form_with url: library_folders_path, method: :post, class: "menu-form", data: { turbo: false } do %>
        <%= hidden_field_tag :parent_node_id, new_menu_folder_node_id, id: nil %>
        <label class="menu-form-label" for="new_folder_name">New folder</label>
        <span class="menu-form-row">
          <%= text_field_tag :name, nil, id: "new_folder_name", placeholder: "Folder name",
                             required: true, autocomplete: "off" %>
          <%= submit_tag "Create", class: "small", name: nil %>
        </span>
      <% end %>
      <div class="menu-sep" role="separator"></div>
      <%= link_to "Text file", new_files_text_file_path(parent_node_id: new_menu_folder_node_id), class: "menu-item" %>
      <%= link_to "Project", new_project_path, class: "menu-item" %>
      <% if new_menu_tools.any? %>
        <div class="menu-sep" role="separator"></div>
        <% new_menu_tools.each do |addon| %>
          <%= link_to "#{addon.title}…", tools_addon_path(addon.key), class: "menu-item" %>
        <% end %>
      <% end %>
      <div class="menu-sep" role="separator"></div>
      <%= link_to "Inventory item", new_inventory_item_path, class: "menu-item" %>
    </div>
  </details>
```

In `app/controllers/library_browse_controller.rb`, replace the success line
`render json: { node_id: node.node_id, name: node.name, kind: node.kind }, status: :created` with:

```ruby
    # TWO DOORS, ONE ACTION. The file chooser posts JSON (Accept: application/json) and gets the row
    # back; the top bar's New ▸ Folder posts a browser form and lands IN the new folder. JSON is
    # listed FIRST so an ambiguous Accept (*/*) keeps getting the JSON it always got.
    respond_to do |format|
      format.json { render json: { node_id: node.node_id, name: node.name, kind: node.kind }, status: :created }
      format.html { redirect_to files_path(folder: node.node_id), notice: "Folder “#{node.name}” created." }
    end
```

Replace `folder_error`:

```ruby
  def folder_error(message)
    respond_to do |format|
      format.json { render json: { error: message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: files_path, alert: message }
    end
  end
```

In `app/assets/stylesheets/components.css`, after `.menu-sep`:

```css
  /* An inline form inside a menu (New ▸ Folder): a label, then a field and its button on one row. */
  .menu-form { display: grid; gap: var(--space-1); padding: 6px 10px 8px; margin: 0; }
  .menu-form-label { font-size: 13px; font-weight: 500; color: var(--fg); }
  .menu-form-row { display: flex; gap: var(--space-2); }
  .menu-form-row input[type="text"] { flex: 1; min-width: 0; }
```

- [ ] **Step 3: Run**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/new_menu_test.rb test/integration/chunk_remote_journey_test.rb test/integration/web/template_hygiene_test.rb test/system/file_chooser_test.rb test/system/shell_test.rb test/css_hygiene_test.rb`
Expected: PASS. The chooser and journey tests prove the JSON door is unchanged, and `shell_test`'s
375px sweep proves the New button fits the phone top bar.

- [ ] **Step 4: Mutation-check (§15)** — report actual output.

1. Swap the `respond_to` order so `format.html` comes first. Expected: "an ambiguous Accept still
   gets JSON" is red (it receives a redirect). The explicit-JSON test stays green, which is why the
   ambiguous one exists.
2. Make `new_menu_folder_node_id` return nil. Expected: "on a folder's page, New creates in that
   folder" is red.

- [ ] **Step 5: Commit**

Subject: `The top bar's New menu makes a folder, a text file, a project, a tool's output or an item`.

---

### Task 4: Record the slice

**Files:** `docs/invariants/design-system.md`, `docs/superpowers/specs/2026-10-08-structural-redesign-design.md`.

- [ ] **Step 1: design-system.md**

Replace rule 8 with:

```markdown
8. **The sidebar lights exactly one link, and `ShellHelper#sidebar_current` alone decides which.**
   `rail_section` still maps `controller_path`'s FIRST segment (a new web controller needs a
   `SECTIONS` entry or its pages light nothing), and `sidebar_current` refines it: the deepest
   pinned folder on the Files breadcrumb beats Library, a listed project's own link beats All
   projects, and an unlisted one lights All projects. The sidebar and the phone tab bar both read
   it. `shell_layout_test.rb` pins one lit link per page.
```

In rule 12's list of pinned names, add after `.current-project select`: "(until slice 4 of the
2026-10-08 redesign retires the current project)".

- [ ] **Step 2: The spec**

In §11's table, change slice 2's "delivers" cell to "places sidebar, pins (`maker_pins`), the top
bar's New ▾ menu". Change slice 4's cell to "retire the current project, Upload into the top bar,
the tool destination bar, intake-only attach". Under the table, add:

```markdown
**Amended 2026-10-08 (slice 2's plan):** the top bar's Upload moved from slice 2 to slice 4, because
its destination IS slice 4's change; moving the button first would write its destination logic
twice. The current-project card stays in the sidebar until slice 4 for the same reason.
```

- [ ] **Step 3: Commit**

Subject: `The invariants and the spec record where the sidebar's answers live`.

---

### Task 5: Close out

- [ ] Run bare `bin/ci`. All gates must be green, and `test`, `test-s3` and `test-chunk-remote` must
  report **identical run counts**.
- [ ] `/finish-branch`: push, open the PR, and state what was verified (gates, counts, mutation
  outputs, the visual check) and what was not.
- [ ] `bin/log arc --from-pr <n>` as the PR opens, and `bin/log close <n>` at merge.
