# Click-through folder panels and the version-stack setting — Implementation Plan

> **For agentic workers:** in this repo the default executor is `.claude/commands/execute-plan.md`
> (CLAUDE.md §15) — batched by file, parallel where independent, one capped quality review per task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A project's folder panels show one folder at a time — subfolder tiles you click into, then
its files — and version stacking becomes a per-project setting with one master default in Settings
that also drives the Library and Search.

**Spec:** `docs/superpowers/specs/2026-11-24-project-panel-click-through-design.md` (read it first).

**Architecture:** The listing (`Maker::ProjectFolderListing`) learns which folders are on screen
(`#shown!`) before its rows load and spends the 300-tile cap on those alone. `ProjectsController#show`
resolves each panel's open folder from `?at[<panel id>]=<node id>` off the listing's walk, and answers
a Turbo Frame request for one panel with that panel alone. Each folder panel is wrapped in a
`<turbo-frame target="_top">`; only folder tiles and path-bar links opt into it. Stacking is read
from `Maker::Project#stacking?` (project column, else the user's), threaded into the layout, and the
three checkboxes (project panels, Library, Search) are deleted.

**Tech stack:** Rails 8.1, Hotwire (Turbo Frames + Stimulus), Minitest, SQLite in test.

**Ground rules for every task** (CLAUDE.md):
- All three backend legs must pass with equal RUN counts; `bin/ci` compares them.
- Mutation-check every guard: break what it guards, see it go RED, restore, clear
  `tmp/cache/bootsnap*` (memory: bootsnap masks equal-length restores).
- Run repo-editing Ruby with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8` (the Bash tool's locale is ASCII).
- Never write `<%= … %>` or a bare `%>` inside a `<%# … %>` comment (§14d).
- Assert RENDERED field names for any new form field (§14d's `scope:` lesson).
- Commit messages via `git commit -F <file>` (zsh runs backticks in `-m`).
- Test command for one file: `LIBRARY_PATH=$(mktemp -d) bin/rails test <file>`.

---

## File map

| File | Change |
|---|---|
| `db/migrate/20261124120000_add_stack_versions_settings.rb` | **new** — `users.stack_versions` (bool, default true, NOT NULL), `maker_projects.stack_versions` (bool, nullable) |
| `db/schema.rb`, `docs/reference/schema-map.html` | the two columns; regenerated map |
| `app/models/maker/project.rb` | `#stacking?`; `panel_layout` passes `stacks:` |
| `app/services/maker/project_kind.rb` | `Layout` loses `unstacked`, gains `stacks`; `layout_for(stacks:)` |
| `app/controllers/projects/panels_controller.rb` | delete `update_stack` and the `unstacked` carry; `update_view` carries `at` |
| `app/views/projects/_stack_switch.html.erb` | **delete** |
| `app/views/projects/_attachments.html.erb` | drop the stack switch render |
| `app/views/projects/_form.html.erb`, `ProjectsController#project_params` | the per-project select |
| `config/routes.rb`, `app/controllers/settings_controller.rb`, `app/views/settings/show.html.erb`, `app/assets/stylesheets/pages/settings.css` | master default row + `PATCH /settings` |
| `app/controllers/concerns/stack_switch.rb` | **delete**; Files and Search read `current_user.stack_versions` |
| `app/views/files/index.html.erb`, `app/views/search/index.html.erb`, `app/assets/stylesheets/components.css` | drop the two checkboxes and `.stack-switch` |
| `app/services/maker/project_folder_listing.rb` | `#shown!`, `#walk_path`, `#dir`; delete `#untiled!`, `#repos_beneath` |
| `app/controllers/projects_controller.rb` | panel paths, shown folders, tile union, frame render |
| `app/views/projects/panel_frame.html.erb` | **new** — one panel for a frame request |
| `app/helpers/projects_helper.rb` | `panel_frame_id`, `panel_at`, `panel_folder_link_data`; delete `folder_sections`/`FolderSection` |
| `app/views/projects/_folder_panel.html.erb` | rewritten body: frame, path bar, folder tiles, files |
| `app/views/projects/_folder_tile.html.erb`, `app/views/projects/_folder_path.html.erb` | **new** |
| `app/views/projects/_file_rows.html.erb` | optional folder rows at the top |
| `app/views/projects/_view_toggle.html.erb` | carries `at` |
| `app/views/projects/_file_tree_section.html.erb` | **delete** |
| `app/assets/stylesheets/pages/projects.css` | drop section/switch rules; add frame, folder tile, path bar |
| `app/javascript/controllers/filebrowser_controller.js` | comment only (the nested `<details>` host is gone) |
| `docs/invariants/project-intake.md` | the shown-folders cap rule |
| tests | see each task |

Tasks 1–4 (stacking) and Tasks 5–8 (click-through) touch disjoint files **except**
`projects_controller.rb` (Task 3 edits `load_version_stacks`; Task 6 edits `show`) and
`projects.css` (Task 3 deletes `.stack-panel-switch`; Task 7 edits other rules). Run Task 3 before
Task 6 and Task 7, or give each its own hunk and commit by pathspec.

---

### Task 1: The two columns and `Maker::Project#stacking?`

**Files:**
- Create: `db/migrate/20261124120000_add_stack_versions_settings.rb`
- Modify: `db/schema.rb`, `app/models/maker/project.rb`, `docs/reference/schema-map.html` (generated)
- Test: `test/models/maker/project_stacking_test.rb` (new)

- [ ] **Step 1: Write the failing test**

```ruby
# test/models/maker/project_stacking_test.rb
require "test_helper"

module Maker
  # WHETHER A PROJECT STACKS VERSIONS (2026-11-24): the project's own choice when it made one, the
  # owner's master default (Settings) when it did not. One method, so no panel reads a column.
  class ProjectStackingTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "stk-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                           omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "a new account stacks, and a project with no choice of its own follows it" do
      assert @user.stack_versions, "on is the shipped default for every account"
      assert_nil @project.stack_versions
      assert @project.stacking?

      @user.update!(stack_versions: false)
      refute @project.reload.stacking?, "the master default decides while the project has no choice"
    end

    test "a project's own choice wins over the default either way" do
      @user.update!(stack_versions: false)
      @project.update!(stack_versions: true)
      assert @project.stacking?

      @user.update!(stack_versions: true)
      @project.update!(stack_versions: false)
      refute @project.reload.stacking?
    end

    test "the layout is handed the answer" do
      @project.update!(stack_versions: false)
      refute @project.panel_layout.stacked?("attachments")
      @project.update!(stack_versions: nil)
      assert @project.reload.panel_layout.stacked?("attachments")
      refute @project.panel_layout.stacked?("tasks"), "a panel that draws no files never stacks"
    end
  end
end
```

- [ ] **Step 2: Run it — expect errors** (`NoMethodError: stack_versions`)

`LIBRARY_PATH=$(mktemp -d) bin/rails test test/models/maker/project_stacking_test.rb`

- [ ] **Step 3: Migration**

```ruby
# db/migrate/20261124120000_add_stack_versions_settings.rb
# VERSION STACKS AS A SETTING (2026-11-24; docs/superpowers/specs/2026-11-24-project-panel-click-through-design.md).
# The account's master default is ON for everyone, existing and new, so no account-creation door has
# to set it. A project's own choice is NULL until the maker makes one, and NULL means "follow mine".
class AddStackVersionsSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :stack_versions, :boolean, default: true, null: false
    add_column :maker_projects, :stack_versions, :boolean
  end
end
```

- [ ] **Step 4: schema.rb BY HAND, not by `db:migrate`'s dump.** The local dev DB re-dumps every
  table in physical column order (memory: rails-814-dumps-schema-in-physical-column-order), which
  turns a two-line change into a 40-table diff. Edit `db/schema.rb`:
  - bump the `ActiveRecord::Schema[8.1].define(version: …)` line to `2026_11_24_120000`;
  - in `create_table "users"`, add as the table's LAST column line:
    `t.boolean "stack_versions", default: true, null: false`
  - in `create_table "maker_projects"`, add as its LAST column line:
    `t.boolean "stack_versions"`

  Then load it: `bin/rails db:test:prepare`. (To migrate the dev DB as well without the re-dump:
  `bin/rails db:migrate` then `git checkout -- db/schema.rb` and re-apply the three edits.)

- [ ] **Step 5: The resolver** — in `app/models/maker/project.rb`, beside `panel_layout`:

```ruby
    # DOES THIS PROJECT DRAW ITS VERSIONS AS STACKS (2026-11-24)? Its own choice when it made one
    # (the Edit page), the owner's master default otherwise (Settings). NOT `stack_versions?` —
    # that is ActiveRecord's own query method for the column, and nil reads false there.
    def stacking? = stack_versions.nil? ? user.stack_versions : stack_versions
```

  and change `panel_layout` to pass it:

```ruby
    def panel_layout(folders: [], blocks: [], root_repo: false) =
      Maker::ProjectKind.layout_for(kind:, overrides: self[:panels], folders:, blocks:, root_repo:,
                                    stacks: stacking?)
```

  (`Layout`'s `stacks:` lands in Task 2; this test's third case stays red until then.)

- [ ] **Step 6: Regenerate the schema map:** `bin/rails schema:map`, then
  `bin/rails test test/schema_map_test.rb` — expect PASS.

- [ ] **Step 7: Commit** (after Task 2 makes the third case green) — `git add` the migration,
  schema.rb, the map, project.rb, the test.

### Task 2: The layout takes `stacks:` and forgets `unstacked`

**Files:**
- Modify: `app/services/maker/project_kind.rb:262-277` (Layout) and `:471-472` (layout_for)
- Test: `test/services/maker/project_kind_test.rb` (add one case)

- [ ] **Step 1: Failing test** — append to `ProjectKindTest`:

```ruby
    test "stacking is one answer for the layout, never per panel" do
      on = Maker::ProjectKind.layout_for(kind: "other", overrides: { "unstacked" => [ "attachments" ] })
      assert on.stacked?("attachments"), "a stored per-panel switch is ignored now"
      off = Maker::ProjectKind.layout_for(kind: "other", overrides: {}, stacks: false)
      refute off.stacked?("attachments")
      refute on.stacked?("tasks")
    end
```

- [ ] **Step 2: Run — expect FAIL** (`unknown keyword: :stacks`).

- [ ] **Step 3: Implement.** In the `Layout` definition replace the `unstacked` comment block,
  member and method:

```ruby
    # `stacks` IS WHETHER THIS PROJECT DRAWS VERSIONS AS STACKS (2026-11-24): one answer for the
    # whole page, Maker::Project#stacking? (the project's choice, else the owner's default). The
    # per-panel switch and its sparse `unstacked` list went with it; a stored `unstacked` key is
    # ignored and dropped on the next layout write.
    Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids, :block_kinds,
                         :shelf_views, :shelf_groups, :root_repo, :stacks) do
      def initialize(shelf_views: {}, shelf_groups: {}, root_repo: false, stacks: true, **rest) =
        super(shelf_views:, shelf_groups:, root_repo:, stacks:, **rest)

      # Does this panel draw its versions as stacks? Every panel that can, when the project stacks.
      def stacked?(key) = ProjectKind.stacks?(key) && stacks
```

  In `self.layout_for`, add `stacks: true` to the signature and replace the last
  `unstacked: known(...)...` argument with `stacks: stacks != false)`.

  Update the `self.stacks?` comment ("The switch renders for these…") to: "Layout#stacked? asks it."

- [ ] **Step 4: Run both tests** — `project_kind_test.rb`, `project_stacking_test.rb` — PASS.
  `grep -rn "unstacked" app/ lib/` must now list only `panels_controller.rb` (Task 3).

- [ ] **Step 5: Mutation check** — make `stacked?` return `ProjectKind.stacks?(key)`; the
  `stacks: false` case goes RED. Restore.

- [ ] **Step 6: Commit** Tasks 1+2 together.

### Task 3: Delete the project page's stack switch

**Files:**
- Delete: `app/views/projects/_stack_switch.html.erb`
- Modify: `app/views/projects/_attachments.html.erb:97-100`, `app/views/projects/_folder_panel.html.erb`
  (the `stack_switch` render and its comment), `app/controllers/projects/panels_controller.rb`,
  `app/controllers/projects_controller.rb` (`load_version_stacks`), `app/assets/stylesheets/pages/projects.css:170`
- Test: `test/integration/web/version_stacks_pages_test.rb`, `test/integration/web/project_attachments_test.rb:704`

- [ ] **Step 1: Rewrite the three project-panel tests** in `version_stacks_pages_test.rb`
  (`"a project's folder panel draws its stacks, and its own switch turns them off"`,
  `"a panel's switch is answered in place, and the editor's Save keeps it"`,
  `"a panel's stack switch is refused for a key the page cannot stack"`) as:

```ruby
    test "a project's folder panel draws its stacks, and the project's setting turns them off" do
      key = Maker::ProjectKind.folder_key(laser.node_id)
      get project_path(@project)
      assert_response :success
      panel = css_select("section[id='#{key}']").sole
      assert_equal [ "edge test", "game box", "hex tiles", "stacking card" ],
                   panel.css(".attachments-grid > .stack-item .stack-name").map { |el| el.text.strip }
      assert_select "section[id=?]", key do
        assert_select ".stack-item", text: /1 backup\s+hex tiles/
        assert_select "a[href=?]", file_path(file("laser/game box 2.lbrn2").node_id)
      end
      assert_select ".stack-panel-switch, .stack-switch", 0, "no panel carries a switch any more"
      assert_select "#attachments .attachment-group", text: /Backups/, count: 0

      @project.update!(stack_versions: false)
      get project_path(@project)
      assert_select "section[id=?] .stack-item", key, 0
      assert_select "#attachments .attachment-group summary", text: /Backups/
      assert_select "section[id=?] .stack-item", Maker::ProjectKind.folder_key(@dirs.fetch("design").node_id), 0,
                    "the setting is the whole project's, not one panel's"
    end

    test "a project with no choice of its own follows the account's default" do
      key = Maker::ProjectKind.folder_key(laser.node_id)
      @user.update!(stack_versions: false)
      get project_path(@project)
      assert_select "section[id=?] .stack-item", key, 0

      @project.update!(stack_versions: true)
      get project_path(@project)
      assert_select "section[id=?] .stack-item", key, 4
    end

    test "the panels door no longer takes a stack switch" do
      patch project_panels_path(@project), params: { stack: { Maker::ProjectKind.folder_key(laser.node_id) => "0" } }
      assert_response :bad_request
      assert_nil @project.reload.panels
    end
```

  In `project_attachments_test.rb:704` replace
  `project.update!(panels: { "unstacked" => [ "folder:d-laser" ] })` with
  `project.update!(stack_versions: false)` and re-read that test's assertions: they asserted the
  folder's backups land in Backups when its panel is unstacked — with the setting project-wide, the
  same assertions hold.

- [ ] **Step 2: Run — expect FAIL** (switch still renders; `patch stack:` still 302s).

- [ ] **Step 3: Implement.**
  - `git rm app/views/projects/_stack_switch.html.erb`.
  - `_attachments.html.erb`: delete the `<%# VERSION STACKS, THIS PANEL'S OWN SWITCH … %>` comment
    line and the `if` block that renders `projects/stack_switch` (lines 97-100).
  - `_folder_panel.html.erb`: delete the same comment and `if count > 1 && view != "browser"` block.
  - `PanelsController`: delete `return update_stack if params[:stack].present?`, the whole
    `update_stack` method and its comment, and in `replace` the four-line
    `# THE STACK SWITCHES RIDE THROUGH…` comment plus `attrs[:panels]["unstacked"] = …`.
  - `ProjectsController#load_version_stacks`: delete the `@stack_counts` lines (the last four
    statements) and the "@stack_counts is each stacking panel's…" comment paragraph; change "A panel
    stacks unless its switch is off (Layout#stacked?)" to "A panel stacks when the project does
    (Layout#stacked?, Maker::Project#stacking?)".
  - `pages/projects.css:170`: delete the `.stack-panel-switch { … }` rule.
  - `app/controllers/concerns/stack_switch.rb`'s header names `update_stack`; it is deleted in Task 5.

- [ ] **Step 4: Run** `version_stacks_pages_test.rb`, `project_attachments_test.rb`,
  `project_panels_test.rb` — PASS. `grep -rn "stack_switch\|update_stack\|stack_counts\|unstacked" app/`
  lists only `concerns/stack_switch.rb` and the Files/Search views (Task 5).

- [ ] **Step 5: Commit.**

### Task 4: The per-project choice on the Edit page

**Files:**
- Modify: `app/views/projects/_form.html.erb` (after the autofile label), `app/controllers/projects_controller.rb` (`project_params`)
- Test: `test/integration/web/projects_flow_test.rb` (add one case)

- [ ] **Step 1: Failing test** (assert the RENDERED field, then post through it):

```ruby
    test "the edit page sets the project's version stacks, defaulting to the account's" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get edit_project_path(project)
      assert_select "select[name=?]", "project[stack_versions]" do
        assert_select "option[value='']", text: "Use my default (On)"
        assert_select "option[value='true']", text: "On"
        assert_select "option[value='false']", text: "Off"
        assert_select "option[selected]", text: "Use my default (On)"
      end

      patch project_path(project), params: { project: { name: "Lamp", stack_versions: "false" } }
      assert_equal false, project.reload.stack_versions
      patch project_path(project), params: { project: { name: "Lamp", stack_versions: "" } }
      assert_nil project.reload.stack_versions, "blank goes back to following the default"

      user.update!(stack_versions: false)
      get edit_project_path(project)
      assert_select "option[value='']", text: "Use my default (Off)"
    end
```

- [ ] **Step 2: Run — FAIL** (no select).

- [ ] **Step 3: Implement.** `project_params`: add `:stack_versions` to `permit`, then after it
  `attrs[:stack_versions] = attrs[:stack_versions].presence if attrs.key?(:stack_versions)` (a
  blank select value must store NULL, not false — ActiveRecord casts `""` to nil for booleans
  already, but say so in a one-line comment rather than rely on it silently). In `_form.html.erb`,
  after the autofile `</label>`:

```erb
  <%# VERSION STACKS (2026-11-24): this project's own choice, or the account's default from Settings.
      A select, not a checkbox, because "follow my default" is a third answer a box cannot give. %>
  <label class="field">
    <span>Stack versions and backups</span>
    <%= f.select :stack_versions,
                 [ [ "Use my default (#{current_user.stack_versions ? 'On' : 'Off'})", "" ],
                   [ "On", "true" ], [ "Off", "false" ] ],
                 selected: project.stack_versions.nil? ? "" : project.stack_versions.to_s %>
    <span class="field-hint muted">Draws a file's versions and backups as one tile you open.</span>
  </label>
```

  Check the form's other `<label class="field">` blocks for the exact span markup the page uses
  for a label's text and match it.

- [ ] **Step 4: Run — PASS. Mutation:** drop `:stack_versions` from `permit` → RED. Restore.
- [ ] **Step 5: Commit.**

### Task 5: The master default in Settings; the Library and Search follow it

**Files:**
- Modify: `config/routes.rb:484` (`resource :settings, only: %i[show update], controller: "settings"`),
  `app/controllers/settings_controller.rb`, `app/views/settings/show.html.erb`,
  `app/assets/stylesheets/pages/settings.css:40`, `app/controllers/files_controller.rb:67,229-231`,
  `app/controllers/search_controller.rb:14,36`, `app/views/files/index.html.erb:155-171`,
  `app/views/search/index.html.erb:17-25`, `app/assets/stylesheets/components.css:458-460`
- Delete: `app/controllers/concerns/stack_switch.rb`
- Test: `test/integration/web/settings_version_stacks_test.rb` (new; copy `projects_flow_test.rb`'s
  `setup`/`teardown`/`sign_in` — a fresh share library and the house sign-in), `version_stacks_pages_test.rb:104-117`,
  `files_type_filter_test.rb:530`

- [ ] **Step 1: Failing tests.** Settings (inside `class SettingsVersionStacksTest < ActionDispatch::IntegrationTest`
  in `module Web`, with `projects_flow_test.rb`'s setup, teardown and `sign_in` copied in):

```ruby
    test "the settings page sets the account's version-stack default" do
      user = sign_in
      get settings_path
      assert_select ".settings-hub li", text: /Version stacks/ do
        assert_select "form[action=?] button[aria-pressed=true]", settings_path, text: "On"
        assert_select "form[action=?] button[aria-pressed=false]", settings_path, text: "Off"
        assert_select "input[name=?][value=?]", "stack_versions", "0"
      end
      patch settings_path, params: { stack_versions: "0" }
      assert_redirected_to settings_path
      refute user.reload.stack_versions
      patch settings_path, params: { stack_versions: "banana" }
      refute user.reload.stack_versions, "only 0 and 1 are answers"
      patch settings_path, params: { stack_versions: "1" }
      assert user.reload.stack_versions
    end
```

  Library (replace `"the switch turns stacks off, and the choice holds across folders"`):

```ruby
    test "the Library follows the account's default, with no switch of its own" do
      @user.update!(stack_versions: false)
      get files_path(folder: laser.node_id, view: "list", stacks: "1")
      assert_select "tr.stack-row", 0, "a ?stacks= param is inert now"
      assert_select "tbody tr", 22
      assert_select ".stack-switch", 0

      @user.update!(stack_versions: true)
      get files_path(folder: laser.node_id)
      assert_select "tr.stack-row", 4
    end
```

  (`@user` is the account this suite signs in as, in its `setup`.)
  Search: add `assert_select ".stack-switch", 0` to `"Search draws one row per stack…"`.
  `files_type_filter_test.rb:530`: replace `stacks: "0"` with setting the signed-in user's
  `stack_versions` to false before the request.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement.**
  - routes: `resource :settings, only: %i[show update], controller: "settings"`.
  - `SettingsController`:

```ruby
  # PATCH /settings — the one thing the hub itself writes (2026-11-24): the account's master default
  # for version stacks, which every project follows unless it chose (Maker::Project#stacking?) and
  # which the Library and Search read directly. Two answers; anything else writes nothing.
  def update
    value = params[:stack_versions].to_s
    current_user.update!(stack_versions: value == "1") if %w[0 1].include?(value)
    redirect_to settings_path, notice: (current_user.stack_versions ? "Versions stack by default." : "Versions no longer stack by default.")
  end
```

  Update the class comment's "writes nothing" sentence to say it writes this one preference.
  - `settings/show.html.erb`, after the Theme `<li>`:

```erb
  <%# VERSION STACKS (2026-11-24): the account's default. A project's Edit page can choose for
      itself; the Library and Search follow this. Two buttons, the Theme row's shape. %>
  <li>
    <span class="settings-name">Version stacks</span>
    <div class="settings-choice" role="group" aria-label="Stack versions and backups by default">
      <% [ [ "On", "1", true ], [ "Off", "0", false ] ].each do |label, value, on| %>
        <%= button_to label, settings_path, method: :patch, params: { stack_versions: value },
                      class: "btn small", "aria-pressed": (current_user.stack_versions == on).to_s %>
      <% end %>
    </div>
  </li>
```

  - `pages/settings.css:40`: `.theme-choice, .settings-choice { … }` (same rule, both selectors).
  - `FilesController`: delete `include StackSwitch`; `@stacking = resolve_stacks` →
    `@stacking = current_user.stack_versions`, and fix the comment above it ("remembered in a cookie
    like the dot-file switch") to name the setting.
  - `SearchController`: same two edits.
  - `files/index.html.erb`: delete the `<%# STACK VERSIONS AND BACKUPS …` comment and the
    `<form … class="stack-switch">…</form>`.
  - `search/index.html.erb`: delete its comment, the hidden `stacks` input and the
    `<label class="stack-switch muted">…</label>`.
  - `git rm app/controllers/concerns/stack_switch.rb`.
  - `components.css:458-460`: delete the three `.stack-switch` rules (no markup names it now —
    `grep -rn "stack-switch" app/` must be empty).
  - `grep -rn "files_stacks\|resolve_stacks" app/ test/` must be empty.

- [ ] **Step 4: Run** the settings test, `version_stacks_pages_test.rb`, `files_type_filter_test.rb`,
  `test/css_hygiene_test.rb` — PASS.
- [ ] **Step 5: Mutation:** make `update` write `value == "0"` → settings test RED. Restore.
- [ ] **Step 6: Commit.**

### Task 6: The listing spends the cap on the folders on screen

**Files:**
- Modify: `app/services/maker/project_folder_listing.rb`
- Test: `test/services/maker/project_folder_listing_test.rb:349-402` (replace the three #554 tests)

- [ ] **Step 1: Replace the three `untiled` tests** with:

```ruby
    # THE CAP GOES TO WHAT IS ON SCREEN (2026-11-24, click-through panels): a panel shows one folder,
    # so only that folder's OWN files draw. Everything else still loads, from a second pot.
    test "a shown folder's own files take the tiles' cap, and a folder not on screen takes none" do
      _projects, desk_lamp = desk_lamp_folder
      cad = dir("dir-cad", "cad", desk_lamp.node_id)
      out = dir("dir-out", "out", desk_lamp.node_id)
      stl = dir("dir-stl", "stl", out.node_id)
      bulk_files("cad", 5, "c%d.step", cad)
      bulk_files("out", 10, "o%02d.stl", out)
      bulk_files("stl", 4, "s%d.stl", stl)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id), file_cap: 8)
      listing.shown!([ out.node_id ])
      panels = listing.tree.index_by(&:name)

      assert_equal [ 8, 2 ], [ panels["out"].files.size, panels["out"].hidden_count ], "the open folder gets the whole cap"
      assert_equal 4, panels["cad"].files.size, "a folder not on screen still loads, from the second pot"
      assert_equal 4, panels["out"].children.first.files.size
      assert_equal listing.dir(stl.node_id), panels["out"].children.first
      assert listing.truncated?
    end

    test "a walk path runs from a panel down to a folder beneath it, and is nil for anything else" do
      _projects, desk_lamp = desk_lamp_folder
      out = dir("dir-out", "out", desk_lamp.node_id)
      itx = dir("dir-itx", "itx", out.node_id)
      stl = dir("dir-stl", "stl", itx.node_id)
      cad = dir("dir-cad", "cad", desk_lamp.node_id)
      dir("dir-dot", ".cache", out.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))
      assert_equal [ out.node_id, itx.node_id, stl.node_id ], listing.walk_path(out.node_id, stl.node_id)
      assert_equal [ out.node_id ], listing.walk_path(out.node_id, out.node_id)
      assert_nil listing.walk_path(out.node_id, cad.node_id), "a sibling panel's folder is not beneath it"
      assert_nil listing.walk_path(out.node_id, "dir-dot"), "a folder the walk skips cannot be opened"
      assert_nil listing.walk_path(out.node_id, "no-such-node")
    end

    test "shown! comes before the rows load, and the panels can be named without loading them" do
      _projects, desk_lamp = desk_lamp_folder
      cad = dir("dir-cad", "cad", desk_lamp.node_id)
      file("f-c", "c.step", cad.node_id)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id))
      assert_equal [ cad.node_id ], listing.panel_folders.map(&:first)
      assert_equal({ cad.node_id => "cad" }, listing.panel_folder_names)
      listing.shown!([ cad.node_id ])
      assert_equal [ "c.step" ], names_of(listing.tree.first.files)

      assert_raises(ArgumentError, "a listing someone already read cannot change") { listing.shown!([ cad.node_id ]) }
    end

    test "a listing nobody told what is shown splits the cap across the whole tree, as before" do
      _projects, desk_lamp = desk_lamp_folder
      cad = dir("dir-cad", "cad", desk_lamp.node_id)
      out = dir("dir-out", "out", desk_lamp.node_id)
      bulk_files("cad", 5, "c%d.step", cad)
      bulk_files("out", 10, "o%02d.stl", out)

      listing = Maker::ProjectFolderListing.new(@user, project_with_folder(desk_lamp.node_id), file_cap: 8)
      assert_equal [ 4, 4 ], listing.tree.map { |d| d.files.size }, "Maker::ReleaseSnapshot and the public page"
    end
```

  Also the query-count test (`"a cut listing costs the same queries…"`) needs no change.

- [ ] **Step 2: Run — FAIL** (`shown!`, `walk_path`, `dir` undefined).

- [ ] **Step 3: Implement** in `project_folder_listing.rb`:
  - constructor: `@untiled = Set.new` → `@shown = nil` with comment "nil until the page says which
    folders are on screen (#shown!); nil splits the cap across the whole tree, as every other caller
    wants".
  - replace `untiled!` with:

```ruby
    # THE FOLDERS THIS RENDER DRAWS FILES FOR, DECLARED BEFORE ANY ROW LOADS (2026-11-24,
    # click-through panels; spec §1 "The tile budget"). A folder panel shows ONE folder at a time,
    # so only the open folder's OWN files are tiles: they split FILE_CAP between them, and every
    # other folder in the project loads from a second FILE_CAP, because Photos, repository cards,
    # README links and Backups still read those rows. The project's own folder is always shown —
    # the Files panel draws its loose files. This generalises #554's rule (a browsed panel took 105
    # of `pc case`'s 300 tiles): a folder not on screen takes none of the cap. Called after a read,
    # it would change a listing someone already saw, so it refuses.
    def shown!(dir_ids)
      raise ArgumentError, "shown! after the rows loaded" if @rows_loaded

      @shown = dir_ids.to_set.intersection(@dir_ids_set)
      @shown << @folder_id if @folder_id
      self
    end
```

  - delete `repos_beneath` and its comment; in `panel_folders`' comment replace "(#untiled!)" with
    "(#shown!)".
  - add, public, after `panel_folder_names`:

```ruby
    # THE DIRS FROM ONE WALKED DIR DOWN TO ANOTHER BENEATH IT, both ends included — [from] when they
    # are the same, nil when `to_id` is not beneath `from_id` in the walk (a sibling, a skipped
    # dot-dir, a node outside the folder, anything at all). Off the walk, so it answers before the
    # rows load: ProjectsController#show resolves a panel's `?at=` with it, and an `at` this cannot
    # place falls back to the panel's own folder rather than a 404. The walk is a tree (its `seen`
    # set), so the recursion terminates.
    def walk_path(from_id, to_id)
      return [ from_id ] if from_id == to_id

      @walk_children[from_id].each do |child|
        rest = walk_path(child.node_id, to_id)
        return [ from_id ] + rest if rest
      end
      nil
    end

    # One Dir of the loaded tree by node id, or nil (the folder itself has none: its files are #loose).
    def dir(node_id) = (@dirs_by_id ||= flatten_dirs(tree).index_by(&:node_id))[node_id]
```

  - replace `allocate`, `subtree_counts` and `spread` with:

```ruby
    # dir node_id => how many of its OWN files to load. With nothing declared (#shown! never called —
    # Maker::ReleaseSnapshot, the public page), the folder starts with FILE_CAP and at each dir
    # `.share` splits what the dir was given between its own files and each child's whole subtree,
    # so every level is fair. `dir_ids` is the walk's breadth-first order, parents before children,
    # which is what lets one pass do it; the subtree sums run the same list backwards.
    #
    # TWO POTS ONCE THE PAGE SAID WHAT IS ON SCREEN (#shown!): the shown folders' own files split
    # the tiles' FILE_CAP between them, and every other dir shares a second FILE_CAP by the
    # tree-fair rule with the shown dirs' own files counted as none. The two never load a dir twice:
    # a shown dir gets nothing from the second pot.
    def allocate(dir_ids)
      return {} if dir_ids.empty?
      return spread(dir_ids, { dir_ids.first => @file_cap }, @counts) if @shown.nil?

      shown = dir_ids.select { |id| @shown.include?(id) }
      own = shown.zip(self.class.share(@file_cap, shown.map { |id| @counts.fetch(id, 0) })).to_h
      rest = @counts.reject { |id, _| @shown.include?(id) }
      spread(dir_ids, { dir_ids.first => @file_cap }, rest).each { |id, n| own[id] = own.fetch(id, 0) + n }
      own
    end

    # Hands each dir in `grant` its budget and passes it down the walk: a dir's own files (`counts`)
    # and each child's subtree under the same counts share what the dir was given.
    def spread(dir_ids, grant, counts)
      subtree = dir_ids.reverse_each.with_object({}) do |id, sums|
        sums[id] = counts.fetch(id, 0) + @walk_children[id].sum { |c| sums.fetch(c.node_id, 0) }
      end
      dir_ids.each_with_object({}) do |id, own|
        kids = @walk_children[id].sort_by { |c| [ c.name.to_s, c.node_id ] }
        parts = self.class.share(grant.delete(id) || 0, [ counts.fetch(id, 0), *kids.map { |c| subtree.fetch(c.node_id, 0) } ])
        own[id] = parts.first
        kids.each_with_index { |c, i| grant[c.node_id] = grant.fetch(c.node_id, 0) + parts[i + 1] }
      end
    end
```

  - `load_rows!`' comment: "(see #untiled!)" → "(see #shown!)".
  - The header comment's FILE_CAP paragraph: add one sentence — "Since 2026-11-24 the page names the
    folders on screen (#shown!) and only their own files share the cap."
  - `Dir#subtree_file_ids`' comment mentions "a nested repository" among #dirs_without_tiles' kinds:
    drop that kind (a nested repository is a folder tile now).

- [ ] **Step 4: Run** the listing test file — PASS.
- [ ] **Step 5: Mutation:** make `shown!` return `self` without setting `@shown` → the first new
  test goes RED ([4,4] split). Restore; clear bootsnap.
- [ ] **Step 6: Commit.**

### Task 7: The controller, the frame, and the panel views

**Files:**
- Modify: `app/controllers/projects_controller.rb` (show's middle, the end, private methods),
  `app/helpers/projects_helper.rb`, `app/views/projects/_folder_panel.html.erb`,
  `app/views/projects/_file_rows.html.erb`, `app/views/projects/_view_toggle.html.erb`,
  `app/controllers/projects/panels_controller.rb` (`update_view`), `app/assets/stylesheets/pages/projects.css`,
  `app/javascript/controllers/filebrowser_controller.js` (comment)
- Create: `app/views/projects/panel_frame.html.erb`, `app/views/projects/_folder_tile.html.erb`,
  `app/views/projects/_folder_path.html.erb`
- Delete: `app/views/projects/_file_tree_section.html.erb`
- Test: Task 8

- [ ] **Step 1: Helpers** — in `projects_helper.rb` delete `FolderSection` and `folder_sections`
  (with their comment) and add:

```ruby
  # A FOLDER PANEL'S TURBO FRAME (2026-11-24, click-through panels). Not the layout key itself: the
  # section inside keeps that id, because a view switch replaces it by id and anchors land on it.
  PANEL_FRAME_PREFIX = "frame-".freeze
  def panel_frame_id(key) = "#{PANEL_FRAME_PREFIX}#{key}"

  # THE `at` A LINK CARRIES (2026-11-24): every panel's open folder as this render has it
  # (@panel_at, ProjectsController#show), with one panel moved to `node_id` — or back to its own
  # folder, which is no entry at all. nil when nothing is open, so the link is the bare page.
  def panel_at(panel_id, node_id)
    at = (@panel_at || {}).merge(panel_id => node_id)
    at.reject { |pid, id| id.nil? || id == pid }.presence
  end

  # WHAT A FOLDER LINK IN A PANEL CARRIES: it opts INTO the panel's frame (which is `_top` for every
  # other link inside it) and advances the URL, so Back steps out of the folder.
  def panel_folder_link_data(key) = { turbo_frame: panel_frame_id(key), turbo_action: "advance" }
```

- [ ] **Step 2: Controller — the middle of `show`.** Replace the block from the comment
  `# THE SAME FOLDERS ARE DECLARED TO THE LISTING FIRST…` through
  `@recent_files = @listing.recent_files(skip: no_tiles)` with:

```ruby
    # EACH PANEL'S OPEN FOLDER (2026-11-24, click-through panels): `?at[<panel id>]=<node id>`,
    # placed off the listing's walk before any row loads. Then the folders ON SCREEN are declared to
    # the listing (#shown!) — each Tiles or List panel's open folder — so only their own files share
    # the 300 tiles, and the panels that draw no tiles (hidden, browsed) are what the recent row and
    # the version stacks leave out. Everything above this line reads the walk only (#shown! refuses
    # a late call).
    @panel_paths = panel_paths
    @panel_at = @panel_paths.transform_values(&:last)
    untiled = untiled_panel_ids
    @shown_dir_ids = (@listing.panel_folder_names.keys - untiled).map { |id| @panel_paths.fetch(id, [ id ]).last }
    @listing.shown!(@shown_dir_ids)
    no_tiles = dirs_without_tiles(untiled)
    @recent_files = @listing.recent_files(skip: no_tiles)
```

  Replace the tile-union lines:

```ruby
    load_version_stacks(no_tiles)
    untiled = no_tiles.flat_map(&:subtree_file_ids).to_set
    tile_ids = @listing.node_ids.reject { |id| untiled.include?(id) }
```

  with:

```ruby
    load_version_stacks(no_tiles)
    # THE TILES ARE WHAT IS ON SCREEN (2026-11-24): the Files panel's loose files and Backups, and
    # each shown folder's own files. A file in a folder nobody opened draws no tile, so it is not
    # backfilled (F-S15-1: the union is what this render paints); Photos below still paints images
    # at any depth, through its own term.
    tile_ids = (@listing.loose + @listing.backups).map(&:node_id) +
               @shown_dir_ids.flat_map { |id| @listing.dir(id)&.files&.map(&:node_id) || [] }
```

  Update the long `# THE TILES: every file the listing holds, minus every file beneath no_tiles…`
  paragraph above `load_version_stacks` to describe the new term in two sentences.

- [ ] **Step 3: Controller — the end of `show`.** Replace the final `if @panel_key … end` with:

```ruby
    if @panel_key
      render partial: "projects/panel_body", locals: { key: @panel_key, extra: {} }, layout: false
    elsif @switched_panel
      render turbo_stream: switched_panel_streams
    elsif (@frame_key = frame_panel_key)
      # ONE PANEL FOR ITS FRAME (2026-11-24): a folder tile or a path-bar link. A template, not a
      # partial, so it renders in layouts/turbo_rails/frame — that layout's real <head> is what lets
      # Turbo record the promoted visit, or Back shows the wrong folder (models/pane's lesson).
      render :panel_frame
    end
```

- [ ] **Step 4: Controller — private methods.** Delete `untiled_dir_ids`. Add:

```ruby
  # { panel folder id => [dir ids from the panel's own folder down to the open one] }, for each
  # panel whose `at` names a folder beneath it in the walk; nothing else (a stale or hand-made id
  # falls back to the panel's own folder). The editor arranges panels and opens none.
  def panel_paths
    raw = params[:at]
    return {} if @editing || !raw.is_a?(ActionController::Parameters)

    wanted = raw.to_unsafe_h
    @listing.panel_folder_names.keys.each_with_object({}) do |panel_id, out|
      target = wanted[panel_id]
      path = target.is_a?(String) && @listing.walk_path(panel_id, target)
      out[panel_id] = path if path && path.size > 1
    end
  end

  # THE DEPTH-ONE PANELS THAT DRAW NO TILES: hidden outside the editor, or in the browser view.
  # Decided per PANEL, not per open folder — the recent row and the version stacks leave these
  # out, and a subfolder nobody opened is still one of its panel's files (spec §1).
  def untiled_panel_ids
    @listing.panel_folder_names.keys.select do |id|
      key = Maker::ProjectKind.folder_key(id)
      (!@editing && !@panel_layout.visible?(key)) || @panel_layout.view_for(key) == "browser"
    end
  end

  # THE PANEL A TURBO FRAME REQUEST NAMES (2026-11-24), or nil for the whole page: a visible folder
  # panel, by its frame id (ProjectsHelper#panel_frame_id). Anything else gets the page.
  def frame_panel_key
    id = turbo_frame_request_id.to_s
    return if @editing || !id.start_with?(ProjectsHelper::PANEL_FRAME_PREFIX)

    key = id.delete_prefix(ProjectsHelper::PANEL_FRAME_PREFIX)
    @panel_layout.visible.find { |k| k == key && @panel_layout.folder?(k) }
  end
```

  Update `dirs_without_tiles`' and `load_version_stacks`' comments: the "every repository nested
  inside any other panel" kind is gone (a nested repository is a folder tile now). `stacking_dirs`
  keeps its body; its comment's "not a repository nested inside it" clause goes.

- [ ] **Step 5: The frame template** — `app/views/projects/panel_frame.html.erb`:

```erb
<%# ONE FOLDER PANEL, FOR ITS TURBO FRAME (2026-11-24, click-through panels): ProjectsController#show's
    answer when a folder tile or a path-bar link asks for `frame-folder:<id>`. In
    layouts/turbo_rails/frame, whose real head lets Turbo record the promoted visit; the title is
    the page's own, because Turbo copies the response's title into the page. %>
<% content_for :title, "#{@project.name} — Tinkerex" %>
<%= render "projects/panel_body", key: @frame_key, extra: {} %>
```

- [ ] **Step 6: `switched_panel_streams`** — a folder panel's stream must replace the FRAME (the
  partial renders frame + section; replacing the section would nest a frame in a frame):

```ruby
    keys.map do |key|
      target = @panel_layout.folder?(key) ? helpers.panel_frame_id(key) : key
      turbo_stream.replace(target, partial: "projects/panel_body", locals: { key: key, extra: {} })
    end
```

- [ ] **Step 7: `_folder_tile.html.erb`** (new):

```erb
<%# locals: (dir:, panel_id:, key:) %>
<%#
  ONE SUBFOLDER, AS A TILE YOU OPEN (2026-11-24, click-through panels): the Library's folder glyph,
  the name, and the files in its whole subtree, which the walk counts whether or not the cap loaded
  them. The link opts into the panel's frame (ProjectsHelper#panel_folder_link_data) and carries
  every other panel's open folder. In the editor it is not a link: the editor arranges panels, and
  a click that left the draft for another URL would lose it.
%>
<% count = dir.subtree_file_count + dir.subtree_hidden_count %>
<div class="folder-tile">
  <% if @editing %>
    <span class="grid-card file-cell">
      <span class="thumb folder-thumb" aria-hidden="true"><%= folder_glyph %></span>
      <span class="grid-name"><%= dir.name %></span>
    </span>
  <% else %>
    <%= link_to project_path(@project, at: panel_at(panel_id, dir.node_id)), class: "grid-card file-cell",
                data: panel_folder_link_data(key) do %>
      <span class="thumb folder-thumb" aria-hidden="true"><%= folder_glyph %></span>
      <span class="grid-name"><%= dir.name %></span>
    <% end %>
  <% end %>
  <span class="muted folder-tile-count"><%= pluralize(count, "file") %><% if dir.repo? %> <span class="badge">repo</span><% end %></span>
</div>
```

- [ ] **Step 8: `_folder_path.html.erb`** (new):

```erb
<%# locals: (path:, key:) %>
<%#
  WHERE IN THE PANEL YOU ARE (2026-11-24): the panel's own folder, then each folder opened beneath
  it. Every part but the last goes back up to that folder, in the panel's frame; the last is where
  you are. Rendered only once a subfolder is open — the panel head already names its own folder.
%>
<nav class="folder-path" aria-label="Folder in <%= path.first.name %>">
  <% path.each_with_index do |d, i| %>
    <% if i.positive? %><span class="folder-path-sep" aria-hidden="true">/</span><% end %>
    <% if i == path.size - 1 %>
      <span class="folder-path-here" aria-current="location"><%= d.name %></span>
    <% else %>
      <%= link_to d.name, project_path(@project, at: panel_at(path.first.node_id, d.node_id)),
                  data: panel_folder_link_data(key) %>
    <% end %>
  <% end %>
</nav>
```

- [ ] **Step 9: `_folder_panel.html.erb`.** Keep the head exactly as it is. Wrap the whole
  `<section …>…</section>` in
  `<%= turbo_frame_tag panel_frame_id(key), target: "_top", class: "panel-frame" do %> … <% end %>`.
  Replace the header comment's "ONLY DEPTH ONE IS A PANEL…" paragraph with one describing
  click-through (one folder at a time; `?at=`; the frame is `_top` and only folder links opt in), and
  drop the "THE COUNT IS THE WHOLE SUBTREE…" paragraph's "a panel holds its nested sections" reason
  (the count is still the whole subtree). Replace the body's `else` branch (everything from
  `<% figures = stack_figures(visible, folder_id: dir.node_id) %>` to just before the final
  `<% end %>` of the `if view == "browser"`) with:

```erb
        <%# ONE FOLDER AT A TIME (2026-11-24, click-through panels): the panel's own folder, or the
            one `?at=` opened beneath it (@panel_paths), then its subfolders as tiles you open and
            its own files. A stale `at` never reaches here: ProjectsController#panel_paths drops it. %>
        <% path = (@panel_paths&.fetch(dir.node_id, nil) || [ dir.node_id ]).map { |id| id == dir.node_id ? dir : @listing.dir(id) } %>
        <% path = [ dir ] if path.any?(&:nil?) %>
        <% here = path.last %>
        <% if path.size > 1 %>
          <%= render "projects/folder_path", path:, key: %>
          <% if here.repo? && (card = @repo_cards[here.node_id]) %>
            <%= render "projects/repo_card", card: card %>
          <% end %>
        <% end %>
        <% figures = stack_figures(here.files, folder_id: here.node_id) %>
        <% if here.children.empty? && figures.empty? && here.hidden_count.zero? %>
          <p class="muted">Empty folder.</p>
        <% elsif view == "list" %>
          <%= render "file_rows", rows: here.files, figures: figures, folders: here.children,
                     panel_id: dir.node_id, key: key %>
        <% else %>
          <div class="attachments-grid">
            <% here.children.each do |child| %>
              <%= render "projects/folder_tile", dir: child, panel_id: dir.node_id, key: key %>
            <% end %>
            <% figures.each do |figure| %>
              <% if figure.is_a?(ProjectsHelper::StackFigure) %>
                <%= render "projects/stack_tile", figure: figure %>
              <% else %>
                <%= render "file_tile", row: figure %>
              <% end %>
            <% end %>
          </div>
        <% end %>
        <% if here.hidden_count.positive? %>
          <p class="muted attachments-truncated">Showing <%= here.files.size %> of <%= here.files.size + here.hidden_count %> files in this folder. <%= link_to "Open the folder", files_path(folder: here.node_id) %></p>
        <% end %>
```

  The panel's own repo card (the existing `if dir.repo? && (card = …)` above the browser branch)
  stays where it is and renders at every depth of the panel; the block above adds the OPENED
  folder's card only when it is a different, nested repository.

- [ ] **Step 10: `_file_rows.html.erb`** — after `<% figures = local_assigns.fetch(:figures, rows) %>`
  add `<% folders = local_assigns.fetch(:folders, []) %>`, document the three new optional locals in
  the header comment (`folders`, `panel_id`, `key`: subfolders listed first as rows you open, the
  list view of a click-through panel), and as the first thing in `<tbody>`:

```erb
    <% folders.each do |dir| %>
      <% count = dir.subtree_file_count + dir.subtree_hidden_count %>
      <tr class="folder-row">
        <td class="col-name">
          <% if @editing %>
            <%= folder_glyph %> <%= dir.name %>
          <% else %>
            <%= link_to project_path(@project, at: panel_at(local_assigns[:panel_id], dir.node_id)),
                        data: panel_folder_link_data(local_assigns[:key]) do %><%= folder_glyph %> <%= dir.name %><% end %>
          <% end %>
        </td>
        <td class="muted col-section">—</td>
        <td class="num muted col-size"><%= pluralize(count, "file") %></td>
        <td class="muted col-modified">—</td>
        <td class="muted col-origin"><% if dir.repo? %><span class="badge">repo</span><% else %>—<% end %></td>
      </tr>
    <% end %>
```

- [ ] **Step 11: The view toggle carries `at`.** In `_view_toggle.html.erb`, `params:` becomes
  `{ view: { key => value }, in_place: ("1" unless @editing), at: @panel_at.presence }.compact`.
  In `PanelsController#update_view`, the redirect keeps it — after `key, view = view_pair`:

```ruby
      # THE OPEN FOLDERS RIDE ALONG (2026-11-24): a view switch keeps every panel where it was.
      # Strings only; ProjectsController#panel_paths re-validates each against the walk.
      at = params[:at].is_a?(ActionController::Parameters) ? params[:at].to_unsafe_h.select { |_k, v| v.is_a?(String) } : {}
      back = project_path(@project, **in_place(key, view), at: at.presence, anchor: key)
```

  (replacing the existing `back = …` line; keep its "BEFORE THE WRITE" comment.)

- [ ] **Step 12: Delete** `app/views/projects/_file_tree_section.html.erb` (`git rm`).
  `grep -rn "file_tree_section\|folder_sections\|FolderSection\|untiled_dir_ids\|repos_beneath" app/`
  must list only `Maker::PublicProject` and `public/projects/_folder_panel` (the visitor's page,
  which has its own `folder_sections`).

- [ ] **Step 13: CSS** (`pages/projects.css`): delete the four rules from #554
  (`.file-tree-section …` ×3, `.section-more`). Add:

```css
  /* CLICK-THROUGH PANELS (2026-11-24): the frame is a box like the section it holds; a folder tile is
     a file tile's shape with the Library's folder glyph; the path bar sits above the contents. */
  .panel-frame { display: block; }
  .folder-tile { position: relative; display: flex; flex-direction: column; gap: 4px; }
  .folder-tile .thumb { width: 100%; height: 96px; }
  .folder-tile .grid-name { font-size: 12px; }
  .folder-tile-count { font-size: 11px; }
  .folder-path { display: flex; flex-wrap: wrap; align-items: center; gap: 4px 6px; margin: 0 0 var(--space-3); font-size: 13px; }
  .folder-path-sep { color: var(--fg-muted); }
  .folder-path-here { font-weight: 600; }
```

  Check `docs/invariants/design-system.md` before adding: these are page selectors (not component
  ones), qualified by nothing else on the page, so `pages/projects.css` is their place; run
  `test/css_hygiene_test.rb`.

- [ ] **Step 14: `filebrowser_controller.js`** — its header describes a nested repository as "a
  closed <details> inside its parent panel (projects/_file_tree_section)". Rewrite that paragraph:
  the browser mounts on connect in a folder panel (its only host on the project page now); the
  `<details>` branch stays for any future host and costs nothing. Code unchanged.

- [ ] **Step 15: Commit** (Task 8's tests go in the same commit if run together).

### Task 8: Page tests for click-through

**Files:**
- Modify: `test/integration/web/project_attachments_test.rb`, `test/integration/web/project_page_test.rb`,
  `test/integration/web/project_repo_card_test.rb:254` (check only), `test/integration/web/page_query_budget_test.rb`
- Delete one system test: `test/system/repo_browser_test.rb` "a nested repository still waits for its section to be opened"

- [ ] **Step 1: Rework the section-shaped tests** in `project_attachments_test.rb`:
  - `"loose files stay in Files, each subfolder is a panel, and a nested one is a section inside it"`:
    the `docs` block becomes a folder tile, not a section:

```ruby
      assert_select "section.folder-panel[id=?]", "folder:d-docs" do
        assert_select ".folder-tile .grid-name", text: "wiring"
        assert_select ".folder-tile .folder-tile-count", text: "1 file"
        assert_select ".attachment-tile .grid-name", text: "manual.pdf"
        assert_select ".attachment-tile .grid-name", text: "pinout.pdf", count: 0, "a subfolder's files wait for it to be opened"
      end
```

    (rename the test: "…and a nested one is a folder tile inside it").
  - `"a nested repository is a section, badged, closed by default, browsed rather than unrolled"`
    → `"a nested repository is a folder tile, badged, and opening it shows its card and its files"`:
    assert the `code` panel has `.folder-tile` for `firmware` with `.badge` "repo" and count "2 files";
    then `get project_path(project, at: { "d-code" => "d-firmware" })` and assert inside the panel:
    `nav.folder-path`, the repo card (`.repo-card` — check `_repo_card`'s root class), a folder tile
    for `src`, a file tile `main.c`, and no `.repo-browser`.
  - `"a nested subfolder's section is a collapsible details, open by default"` → delete (no sections).
  - `"a panel's folders are flat sections in disk order…"` (#554) → replace with the path-bar test:

```ruby
    test "opening folders in a panel shows a path back up, and every other panel stays where it was" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      itx = subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      four = subfolder!(user, project, name: "four-piece", node_id: "d-four", parent: itx.node_id)
      docs = subfolder!(user, project, name: "docs", node_id: "d-docs")
      old = subfolder!(user, project, name: "old", node_id: "d-old", parent: docs.node_id)
      folder_file!(user, project, name: "foot.stl", node_id: "n-foot", parent: four.node_id)
      folder_file!(user, project, name: "summary.json", node_id: "n-summary", parent: itx.node_id)
      folder_file!(user, project, name: "v1.pdf", node_id: "n-v1", parent: old.node_id)

      get project_path(project)
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select "nav.folder-path", 0, "a panel at its own folder needs no path"
        assert_select ".folder-tile a[href=?][data-turbo-frame=?][data-turbo-action=advance]",
                      project_path(project, at: { "d-out" => "d-itx" }), "frame-folder:d-out"
      end
      assert_select "turbo-frame[id=?][target=_top] > section.folder-panel[id=?]", "frame-folder:d-out", "folder:d-out"

      get project_path(project, at: { "d-out" => "d-four", "d-docs" => "d-old" })
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select "nav.folder-path a", 2
        assert_select "nav.folder-path a[href=?]", project_path(project, at: { "d-docs" => "d-old" }), text: "out"
        assert_select "nav.folder-path a[href=?]", project_path(project, at: { "d-out" => "d-itx", "d-docs" => "d-old" }), text: "itx"
        assert_select "nav.folder-path .folder-path-here", text: "four-piece"
        assert_select ".attachment-tile .grid-name", text: "foot.stl"
        assert_select ".attachment-tile .grid-name", text: "summary.json", count: 0
      end
      assert_select "section.folder-panel[id=?] .attachment-tile .grid-name", "folder:d-docs", text: "v1.pdf"
    end

    test "an at the walk cannot place leaves the panel at its own folder" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      docs = subfolder!(user, project, name: "docs", node_id: "d-docs")
      folder_file!(user, project, name: "top.stl", node_id: "n-top", parent: out.node_id)

      [ "no-such-node", docs.node_id, "n-top" ].each do |target|
        get project_path(project, at: { "d-out" => target })
        assert_response :success
        assert_select "section.folder-panel[id=?]", "folder:d-out" do
          assert_select "nav.folder-path", 0, "#{target} is not a folder beneath out"
          assert_select ".attachment-tile .grid-name", text: "top.stl"
        end
      end
    end

    test "a frame request answers the one panel, with the folder it opened" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      itx = subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      subfolder!(user, project, name: "docs", node_id: "d-docs")
      folder_file!(user, project, name: "summary.json", node_id: "n-summary", parent: itx.node_id)

      get project_path(project, at: { "d-out" => "d-itx" }), headers: { "Turbo-Frame" => "frame-folder:d-out" }
      assert_response :success
      assert_select "turbo-frame[id=?]", "frame-folder:d-out"
      assert_select "section.folder-panel", 1, "only the panel the frame names"
      assert_select "section.attachments-panel", 0
      assert_select ".attachment-tile .grid-name", text: "summary.json"
      assert_select "title", text: "Case — Tinkerex"

      get project_path(project), headers: { "Turbo-Frame" => "frame-folder:no-such" }
      assert_select "section.attachments-panel", 1, "a frame id that names no panel gets the page"
    end

    test "a list panel opens folders the same way" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)
      folder_file!(user, project, name: "top.stl", node_id: "n-top", parent: out.node_id)
      project.update!(panels: { "views" => { "folder:d-out" => "list" } })

      get project_path(project)
      assert_select "section.folder-panel[id=?] table.project-files tbody", "folder:d-out" do
        assert_select "tr.folder-row:first-child a[href=?][data-turbo-frame=?]",
                      project_path(project, at: { "d-out" => "d-itx" }), "frame-folder:d-out", text: /itx/
        assert_select "tr a", text: "top.stl"
      end
    end

    test "the editor draws folder tiles that open nothing" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)

      get edit_layout_project_path(project, at: { "d-out" => "d-itx" })
      assert_response :success
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select ".folder-tile .grid-name", text: "itx"
        assert_select ".folder-tile a", 0
        assert_select "nav.folder-path", 0, "the editor opens no folder"
      end
    end

    test "a view switch keeps the panels where they were" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      subfolder!(user, project, name: "itx", node_id: "d-itx", parent: out.node_id)

      get project_path(project, at: { "d-out" => "d-itx" })
      assert_select "section.folder-panel[id=?] .view-toggle form input[name=?][value=?]", "folder:d-out", "at[d-out]", "d-itx"
      patch project_panels_path(project), params: { view: { "folder:d-out" => "list" }, in_place: "1", at: { "d-out" => "d-itx" } }
      assert_redirected_to project_path(project, panel: "folder:d-out", at: { "d-out" => "d-itx" }, anchor: "folder:d-out")
    end
```

  - `"a folder in the browser view takes none of the tiles from a tiles panel beside it"` (#554):
    keep as is — it still holds (a browsed panel is not shown). Add the subfolder case beside it:

```ruby
    test "a subfolder's files take none of the tiles until it is opened" do
      user = sign_in
      project = user.maker_projects.create!(name: "Case")
      out = subfolder!(user, project, name: "out", node_id: "d-out")
      deep = subfolder!(user, project, name: "deep", node_id: "d-deep", parent: out.node_id)
      now = Time.current
      Node.insert_all([ [ "out", out, 280 ], [ "deep", deep, 200 ] ].flat_map do |prefix, parent, n|
        n.times.map do |i|
          { node_id: "#{prefix}-#{i}", name: format("#{prefix}%03d.stl", i), kind: "file", user_id: user.id,
            parent_node_id: parent.node_id, deleted: false, created_at: now, updated_at: now }
        end
      end)

      get project_path(project)
      assert_select "section.folder-panel[id=?]", "folder:d-out" do
        assert_select ".panel-head .mono.muted", text: "480 files"
        assert_select ".attachment-tile", 280, "the open folder's own files, all of them"
        assert_select ".folder-tile .folder-tile-count", text: "200 files"
        assert_select ".attachments-truncated", 0
      end
    end
```

    Mutation: make `ProjectsController`'s `@listing.shown!(…)` line a no-op → this test RED
    (150 tiles). Restore.
  - The cap test (`"the panel caps at FILE_CAP and points at the folder"`) and
    `"a folder cut by the cap counts its real files and says so…"`: re-read each; any assertion on
    `.file-tree-section`, "See all … in the Library" or `.section-more` becomes the panel's
    `.attachments-truncated` line ("Showing X of Y files in this folder"). A test whose fixture
    relies on several panels being cut keeps its arithmetic: shown folders split the cap by `.share`.
  - Line ~704 (stacks) was done in Task 3.
- [ ] **Step 2: `project_page_test.rb`:**
  - `:779` `"a repository nested in a tiles-view repository panel backfills nothing; the panel's own
    tiles do"` — the nested repo is now a folder tile, and a folder nobody opened is not backfilled
    either; rename to "…a folder nobody opened backfills nothing…" and replace the
    `.file-tree-section .repo-browser` assertion with `.folder-tile .grid-name` "lib".
  - `:879` `"a nested folder is a section inside its parent's panel, never a panel"` → assert a
    `.folder-tile` named `old` inside the `models` panel and no panel for `old`.
  - `:895` `"the Files panel keeps the root and renders no subfolder section"` → its
    `.file-tree-section` counts become `.folder-tile` counts (Files has none; models has one).
- [ ] **Step 3: `page_query_budget_test.rb`** — the project page's constancy-in-N case: add a second
  measured render with one panel opened (`at: { <a depth-one folder> => <its child> }`) and assert
  the same constancy. Read the test's seed to pick the ids.
- [ ] **Step 4: `test/system/repo_browser_test.rb:172`** — delete
  `"a nested repository still waits for its section to be opened"` (the host it tested is gone);
  keep the depth-one browser tests.
- [ ] **Step 5: Run** the five files, then `test/integration/web/template_hygiene_test.rb`,
  `test/stimulus_hygiene_test.rb`, `test/css_hygiene_test.rb` — PASS.
- [ ] **Step 6: Commit.**

### Task 9: System test — click in, go up, go Back

**Files:**
- Create: `test/system/project_panel_navigation_test.rb`

- [ ] **Step 1: Write it** (follow `test/system/model_page_test.rb` for sign-in and fixture shape;
  read it first and copy its setup helpers rather than inventing):

```ruby
require "application_system_test_case"

class ProjectPanelNavigationTest < ApplicationSystemTestCase
  # Copy model_page_test.rb's library + sign-in setup here.

  test "a folder tile opens inside its panel, the path goes back up, and Back steps out" do
    # project "Case": out/itx/foot.stl, out/top.stl, docs/manual.pdf
    visit project_path(@project)
    other = find("section.folder-panel[id='folder:d-docs']")
    within("section.folder-panel[id='folder:d-out']") { click_on "itx" }

    within("section.folder-panel[id='folder:d-out']") do
      assert_selector ".folder-path-here", text: "itx"
      assert_selector ".grid-name", text: "foot.stl"
    end
    assert_current_path project_path(@project, at: { "d-out" => "d-itx" })
    assert_equal other, find("section.folder-panel[id='folder:d-docs']"), "the other panel was not redrawn"

    within("section.folder-panel[id='folder:d-out']") { click_on "out" }
    assert_no_selector "section.folder-panel[id='folder:d-out'] .folder-path"
    assert_current_path project_path(@project)

    page.go_back
    within("section.folder-panel[id='folder:d-out']") { assert_selector ".folder-path-here", text: "itx" }
  end
end
```

  `find(...) == find(...)` compares Selenium element identity; if the suite has a house way to
  assert "not redrawn" (a data attribute set by JS before the click), use it instead.
- [ ] **Step 2:** `bin/rails test test/system/project_panel_navigation_test.rb` — PASS (needs the
  Chrome 158 fix from PR #555 merged, or run on the Linux CI runners).
- [ ] **Step 3: Commit.**

### Task 10: Docs, then the gates

- [ ] **Step 1:** `docs/invariants/project-intake.md` — replace the paragraph starting
  `**A FOLDER THAT DRAWS NO TILES TAKES NONE OF THE CAP (2026-11-23).**` with:

  > **ONLY WHAT IS ON SCREEN TAKES THE CAP (2026-11-23, then 2026-11-24).** A folder panel shows one
  > folder at a time (`?at[<panel id>]=<node id>`), so `ProjectsController#show` names each Tiles or
  > List panel's open folder with `#shown!` BEFORE the rows load (the listing loads on first read and
  > refuses a late call), and only those folders' OWN files split `FILE_CAP`. Every other folder —
  > a subfolder nobody opened, a browsed or hidden panel — loads from a SECOND `FILE_CAP`, because
  > Photos, repository cards, README links and Backups read those rows. Read the layout's folders and
  > resolve `at` off the walk (`panel_folders`, `panel_folder_names`, `walk_path`), never `tree`,
  > above that call. An `at` the walk cannot place is dropped, never a 404.

- [x] **Step 2:** The spec already records the Library/Search answer and the `#stacking?` name
  (updated while planning).
- [ ] **Step 3:** `bin/ci` from this worktree with `TINKEREX_SYNC_DIR` set (memory:
  bin-ci-from-a-worktree). If `system` errors in `reset!` with "* is not a valid URL", PR #555 has not
  merged: run `bin/ci style scan test test-s3 test-chunk-remote` and let CI's `system-test` job be
  the check, saying so in the PR. If `setup` re-dumps `db/schema.rb` in column order, discard that
  diff (`git checkout -- db/schema.rb`) and keep only Task 1's lines.
- [ ] **Step 4:** Browser check against a local share library shaped like `pc case` (memory:
  dev-server-for-screenshots-recipe): open `out`, click `itx`, click `out` in the path, press Back,
  switch to List, open `itx` there; set Settings → Version stacks Off and see the Library and a
  project un-stack; set the project to On and see it stack again. Screenshot for the PR.
- [ ] **Step 5:** Commit, push, `gh pr create`, `bin/log arc --from-pr <n>` (CLAUDE.md §15).
