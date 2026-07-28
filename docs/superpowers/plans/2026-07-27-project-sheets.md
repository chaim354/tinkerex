# Project Sheets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every project any number of named, free-form spreadsheets — cut lists, cost math, measurements — each on its own full-width page, with formulas, autosave, and CSV export.

**Architecture:** `Maker::Sheet` is ordinary maker data in the app DB (like tasks and build-log entries) holding the whole workbook as one JSON blob. Nothing touches the FileLayer port, so all three `LIBRARY_BACKEND` legs behave identically and the §10 tripwire is not approached. The grid is Jspreadsheet CE v5 + jsuites, both MIT, vendored as UMD browser builds and loaded only on the sheet page — chosen over a jspm ESM build specifically to avoid the shared-chunk patching documented at length in `config/importmap.rb`.

**Tech Stack:** Rails 8.1, Stimulus, propshaft, Jspreadsheet CE v5 (MIT), jsuites (MIT), Minitest.

**Spec:** `docs/superpowers/specs/2026-07-27-project-page-overhaul-design.md` §6.

---

## File Structure

| File | Change | Responsibility after this plan |
|---|---|---|
| `db/migrate/*_create_maker_sheets.rb` | Create | Schema. |
| `app/models/maker/sheet.rb` | Create | Validations, user scoping, blank-workbook shape, CSV rendering. |
| `config/routes.rb` | Modify | `resources :sheets` shallow under `projects`. |
| `app/controllers/projects/sheets_controller.rb` | Create | create / show / update (autosave + rename) / destroy / CSV. |
| `app/views/projects/_sheets.html.erb` | Create | The Sheets panel on the project page. |
| `app/views/projects/sheets/show.html.erb` | Create | Full-width grid page. |
| `app/javascript/controllers/sheet_controller.js` | Create | Instantiates the grid, debounces the autosave, drives the status indicator. |
| `vendor/javascript/jspreadsheet.js`, `vendor/javascript/jsuites.js` | Create | Vendored MIT browser builds. |
| `app/assets/stylesheets/jspreadsheet.css`, `app/assets/stylesheets/jsuites.css` | Create | Vendored MIT stylesheets. |
| `app/assets/stylesheets/projects.css` | Modify | Sheet panel + page styles. |
| `app/controllers/projects_controller.rb` | Modify | Loads `@sheets` for the panel. |
| `app/views/projects/show.html.erb` | Modify | Renders the Sheets panel. |
| `test/models/maker/sheet_test.rb` | Create | Model coverage. |
| `test/integration/web/project_sheets_test.rb` | Create | CRUD, autosave, CSV, cross-user isolation. |

---

## Task 1: The `Maker::Sheet` model

**Files:**
- Create: `db/migrate/<timestamp>_create_maker_sheets.rb`
- Create: `app/models/maker/sheet.rb`
- Create: `test/models/maker/sheet_test.rb`
- Modify: `app/models/maker/project.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/maker/sheet_test.rb`:

```ruby
require "test_helper"

module Maker
  class SheetTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "sheet@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid belonging to a project" do
      sheet = @project.sheets.build(user: @user, name: "Cut list")
      assert sheet.valid?
    end

    test "name is required" do
      sheet = @project.sheets.build(user: @user, name: "")
      assert_not sheet.valid?
    end

    test "a sheet cannot be built on another user's project" do
      other = User.create!(email: "other@example.com")
      theirs = other.maker_projects.create!(name: "Theirs")
      sheet = theirs.sheets.build(user: @user, name: "Sneaky")
      assert_not sheet.valid?
    end

    test "blank_data is a rectangular grid with titled columns" do
      data = Maker::Sheet.blank_data(rows: 3, columns: 2)
      assert_equal 2, data["columns"].size
      assert_equal %w[A B], data["columns"].map { |c| c["title"] }
      assert_equal 3, data["cells"].size
      assert_equal [ "", "" ], data["cells"].first
    end

    test "cells and columns read defensively from a malformed blob" do
      sheet = @project.sheets.create!(user: @user, name: "Odd", data: "not a hash")
      assert_equal [], sheet.cells
      assert_equal [], sheet.columns

      # A Hash whose inner keys are the wrong shape — Array("x") would make this one garbage row.
      sheet.update!(data: { "cells" => "not an array", "columns" => 42 })
      assert_equal [], sheet.cells
      assert_equal [], sheet.columns
    end

    test "column titles continue past Z the way a spreadsheet does" do
      assert_equal "A",  Maker::Sheet.column_title(0)
      assert_equal "Z",  Maker::Sheet.column_title(25)
      assert_equal "AA", Maker::Sheet.column_title(26)
      assert_equal "AB", Maker::Sheet.column_title(27)
      assert_equal "BA", Maker::Sheet.column_title(52)
    end

    # `("A".."Z").first(30)` returns 26 titles without complaining, while Array.new(30) does not —
    # so the naive version yields 26 headers over 30-wide rows, silently non-rectangular.
    test "blank_data stays rectangular past 26 columns" do
      data = Maker::Sheet.blank_data(rows: 2, columns: 30)
      assert_equal 30, data["columns"].size
      assert_equal 30, data["cells"].first.size
      assert_equal "AD", data["columns"].last["title"]
    end

    test "to_csv writes the column titles then the cells" do
      sheet = @project.sheets.create!(user: @user, name: "Costs", data: {
        "columns" => [ { "title" => "Part" }, { "title" => "Qty" } ],
        "cells"   => [ [ "M3 bolt", "12" ], [ "Insert", "8" ] ]
      })
      assert_equal "Part,Qty\nM3 bolt,12\nInsert,8\n", sheet.to_csv
    end

    test "to_csv quotes a cell containing a comma" do
      sheet = @project.sheets.create!(user: @user, name: "Costs", data: {
        "columns" => [ { "title" => "Part" } ],
        "cells"   => [ [ "bolt, hex" ] ]
      })
      assert_equal "Part\n\"bolt, hex\"\n", sheet.to_csv
    end

    test "destroying the project destroys its sheets" do
      @project.sheets.create!(user: @user, name: "Cut list")
      assert_difference -> { Maker::Sheet.count }, -1 do
        @project.destroy!
      end
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/models/maker/sheet_test.rb
```

Expected: FAIL with `NameError: uninitialized constant Maker::Sheet`.

- [ ] **Step 2b: Declare the `csv` gem — the model's `require "csv"` will not resolve without it**

On Ruby 3.4, `csv` moved from a *default* gem to a *bundled* gem: it still ships with Ruby, but
Bundler no longer auto-activates it, so `require "csv"` raises `LoadError: cannot load such file --
csv` under `Bundler.setup`. That surfaces as the whole test file erroring out, not as a test failure,
which reads like something much worse than it is.

Add to the `Gemfile`:

```ruby
# Ruby 3.4 demoted csv from a default gem to a bundled one — it still ships with Ruby, but Bundler
# no longer auto-activates it, so Maker::Sheet's `require "csv"` raises LoadError without this line.
gem "csv"
```

Then `bundle install`. Licence is **Ruby / BSD-2-Clause** — permissive, CLAUDE.md §9 satisfied
(verify from `gem specification csv` rather than taking this on trust).

- [ ] **Step 3: Generate and write the migration**

```bash
bin/rails generate migration CreateMakerSheets
```

Replace the generated file's contents with:

```ruby
class CreateMakerSheets < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_sheets do |t|
      t.integer :user_id, null: false
      t.integer :project_id, null: false
      t.string  :name, null: false
      t.integer :position, null: false, default: 0
      # The whole workbook as one blob: {"columns" => [...], "cells" => [[...], ...]}. `t.json`
      # is real JSON on Postgres and text on SQLite, matching maker_previews.metadata.
      t.json    :data
      t.timestamps
    end

    add_index :maker_sheets, [ :user_id, :project_id, :position ],
              name: "index_maker_sheets_on_project_position"
  end
end
```

```bash
bin/rails db:migrate
```

- [ ] **Step 4: Write the model**

Create `app/models/maker/sheet.rb`:

```ruby
require "csv"

module Maker
  # A free-form spreadsheet on a project — cut lists, cost math, measurements. The whole workbook
  # lives in one JSON blob rather than a normalized cells table: a sheet is read and written whole
  # by the grid, nothing queries across cells, and the single-user scale this targets never makes
  # the blob the bottleneck. If it ever does, a cells table slots in behind the same controller.
  class Sheet < ApplicationRecord
    self.table_name = "maker_sheets"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    DEFAULT_ROWS    = 20
    DEFAULT_COLUMNS = 6

    validates :name, presence: true
    validate  :project_belongs_to_user

    # A…Z, then AA, AB, … — spreadsheet convention. NOT `("A".."Z").first(columns)`: Range#first
    # silently returns fewer than asked past Z, which yields 26 headers over N-wide rows and breaks
    # the rectangular-grid invariant (and to_csv's header alignment) with no error.
    def self.column_title(index)
      title = +""
      n = index
      loop do
        title.prepend((("A".ord + (n % 26))).chr)
        n = n / 26 - 1
        break if n.negative?
      end
      title
    end

    # A blank workbook.
    def self.blank_data(rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS)
      {
        "columns" => Array.new(columns) { |i| { "title" => column_title(i), "width" => 120 } },
        "cells"   => Array.new(rows) { Array.new(columns, "") }
      }
    end

    # Defensive readers: `data` is written by the browser, so a malformed or half-written blob must
    # render an empty grid rather than 500 the page. The INNER shape is checked too — Array("x")
    # wraps a bare String into a one-element array, so a "cells" key holding a scalar would
    # otherwise become one garbage row rather than nothing.
    def cells   = data.is_a?(Hash) && data["cells"].is_a?(Array) ? data["cells"] : []
    def columns = data.is_a?(Hash) && data["columns"].is_a?(Array) ? data["columns"] : []

    # Exports what is STORED, which means a formula exports as `=A1*B1`, not as its result. That is
    # the intent: the export is the sheet, not a snapshot of its output.
    def to_csv
      CSV.generate do |csv|
        csv << columns.map { |c| c["title"].to_s }
        cells.each { |row| csv << Array(row).map(&:to_s) }
      end
    end

    private

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end
  end
end
```

- [ ] **Step 5: Add the association**

In `app/models/maker/project.rb`, below the `has_many :boms` line:

```ruby
    has_many :sheets, -> { order(:position, :id) },
             class_name: "Maker::Sheet", foreign_key: :project_id, dependent: :destroy
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
bin/rails test test/models/maker/sheet_test.rb
```

Expected: PASS, 10 tests.

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/maker/sheet.rb app/models/maker/project.rb \
        test/models/maker/sheet_test.rb
git commit -m "feat(sheets): Maker::Sheet model with CSV rendering"
```

---

## Task 2: Routes and controller

**Files:**
- Modify: `config/routes.rb:61`
- Create: `app/controllers/projects/sheets_controller.rb`
- Create: `test/integration/web/project_sheets_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/project_sheets_test.rb`:

```ruby
require "test_helper"

module Web
  class ProjectSheetsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The project detail view reads file metadata + capabilities through FileLayer.current; pin a
    # real backend so the share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
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
      user = User.create!(email: "x@example.com", password: PASSWORD, confirmed_at: Time.current)
      project = user.maker_projects.create!(name: "Lamp")
      post project_sheets_path(project)
      assert_redirected_to new_user_session_path
    end

    test "create makes a blank sheet and redirects to it" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")

      assert_difference "project.sheets.count", 1 do
        post project_sheets_path(project), params: { sheet: { name: "Cut list" } }
      end
      sheet = project.sheets.last
      assert_equal "Cut list", sheet.name
      assert_equal Maker::Sheet::DEFAULT_ROWS, sheet.cells.size
      assert_redirected_to sheet_path(sheet)
    end

    test "create falls back to a default name" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      post project_sheets_path(project), params: { sheet: { name: "" } }
      assert_equal "Sheet 1", project.sheets.last.name
    end

    test "show renders the grid page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      get sheet_path(sheet)
      assert_response :success
      assert_select "h1", "Cut list"
      assert_select "[data-controller=?]", "sheet"
    end

    test "update autosaves the data and answers JSON" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      patch sheet_path(sheet), as: :json, params: { sheet: { data: {
        "columns" => [ { "title" => "Part" } ], "cells" => [ [ "M3 bolt" ] ]
      } } }

      assert_response :success
      assert_equal "ok", JSON.parse(response.body)["status"]
      assert_equal [ [ "M3 bolt" ] ], sheet.reload.cells
    end

    test "update renames and redirects for an HTML request" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      patch sheet_path(sheet), params: { sheet: { name: "Costs" } }
      assert_redirected_to sheet_path(sheet)
      assert_equal "Costs", sheet.reload.name
    end

    test "csv export writes the column titles and cells" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Costs", data: {
        "columns" => [ { "title" => "Part" }, { "title" => "Qty" } ],
        "cells"   => [ [ "M3 bolt", "12" ] ]
      })

      get sheet_path(sheet, format: :csv)
      assert_response :success
      assert_equal "text/csv", response.media_type
      assert_equal "Part,Qty\nM3 bolt,12\n", response.body
    end

    test "destroy returns to the project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list")

      assert_difference "project.sheets.count", -1 do
        delete sheet_path(sheet)
      end
      assert_redirected_to project_path(project)
    end

    # `config.action_dispatch.show_exceptions = :rescuable` in the test env, so the RecordNotFound
    # from current_user scoping arrives as a 404 RESPONSE rather than a raised exception — which is
    # why every cross-user test in this suite asserts the status, not an exception.
    test "another user's sheet is not reachable" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs").sheets.create!(user: other, name: "Secret")

      get sheet_path(theirs)
      assert_response :not_found

      patch sheet_path(theirs), params: { sheet: { name: "x" } }
      assert_response :not_found

      delete sheet_path(theirs)
      assert_response :not_found
      assert_equal "Secret", theirs.reload.name
    end

    test "create cannot target another user's project" do
      sign_in("a@example.com")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      assert_no_difference "Maker::Sheet.count" do
        post project_sheets_path(theirs), params: { sheet: { name: "Sneaky" } }
      end
      assert_response :not_found
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/integration/web/project_sheets_test.rb
```

Expected: FAIL with `NameError: undefined local variable or method 'project_sheets_path'`.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, inside `resources :projects do`, after the `tasks` line (line 61):

```ruby
    # Free-form spreadsheets. Shallow like tasks and build-log entries: create is nested under the
    # project, the grid page and its autosave/CSV live at /sheets/:id.
    resources :sheets, only: %i[create show update destroy], module: :projects, shallow: true
```

- [ ] **Step 4: Write the controller**

Create `app/controllers/projects/sheets_controller.rb`:

```ruby
module Projects
  # Free-form project spreadsheets. Backend-neutral: sheets are app-DB maker rows, so this
  # controller never touches FileLayer, Sync::* or the port — nothing here is capability-gated and
  # every action behaves identically on chunk, share and s3.
  class SheetsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_sheet, only: %i[show update destroy]

    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      next_pos = (project.sheets.maximum(:position) || -1) + 1
      sheet = project.sheets.create!(
        user: current_user,
        name: params.dig(:sheet, :name).presence || "Sheet #{project.sheets.count + 1}",
        position: next_pos,
        data: Maker::Sheet.blank_data
      )
      redirect_to sheet_path(sheet)
    end

    def show
      respond_to do |format|
        format.html
        format.csv do
          send_data @sheet.to_csv, type: "text/csv",
                    filename: "#{@sheet.name.parameterize.presence || 'sheet'}.csv",
                    disposition: "attachment"
        end
      end
    end

    # Two callers, one action: the grid's debounced JSON autosave (sends `data`) and the rename
    # form (sends `name`). Answering by format keeps them from needing separate routes.
    def update
      @sheet.update!(sheet_params)
      respond_to do |format|
        format.json { render json: { status: "ok", updated_at: @sheet.updated_at } }
        format.html { redirect_to sheet_path(@sheet) }
      end
    end

    def destroy
      project = @sheet.project
      @sheet.destroy!
      redirect_to project_path(project), notice: "Sheet deleted."
    end

    private

    def set_sheet
      @sheet = current_user.maker_sheets.find(params[:id])
    end

    # `data` is an arbitrary nested structure the grid round-trips, so it is permitted whole rather
    # than shape-checked here — Maker::Sheet's readers are what defend the render against a
    # malformed blob.
    def sheet_params
      params.require(:sheet).permit(:name, :position, data: {})
    end
  end
end
```

- [ ] **Step 5: Add the user association**

`User` declares one `has_many` per maker model (lines 11-29) and does **not** yet have one for
sheets — `set_sheet` above scopes through it, so without this the controller raises. Add it after
the `maker_notes` line:

```ruby
  has_many :maker_sheets, class_name: "Maker::Sheet", dependent: :destroy
```

- [ ] **Step 6: Create the show view placeholder so the routing tests can run**

Create `app/views/projects/sheets/show.html.erb`:

```erb
<% content_for :title, "#{@sheet.name} — Tinkerex" %>

<h1><%= @sheet.name %></h1>
<div data-controller="sheet"></div>
```

Task 3 replaces this with the real page. It exists now so Task 2's routing and JSON tests can go
green on their own.

- [ ] **Step 7: Run the tests to verify they pass**

```bash
bin/rails test test/integration/web/project_sheets_test.rb
```

Expected: PASS, 10 tests.

- [ ] **Step 8: Commit**

```bash
git add config/routes.rb app/controllers/projects/sheets_controller.rb \
        app/views/projects/sheets/show.html.erb app/models/user.rb \
        test/integration/web/project_sheets_test.rb
git commit -m "feat(sheets): routes and controller for project spreadsheets"
```

---

## Task 3: Vendor the grid library

**Files:**
- Create: `vendor/javascript/jspreadsheet.js`, `vendor/javascript/jsuites.js`
- Create: `app/assets/stylesheets/jspreadsheet.css`, `app/assets/stylesheets/jsuites.css`
- Create: `vendor/javascript/JSPREADSHEET-LICENSES.md`

- [ ] **Step 1: Download the four files**

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/index.min.js -o vendor/javascript/jspreadsheet.js
```

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/jspreadsheet.min.css -o app/assets/stylesheets/jspreadsheet.css
```

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.js -o vendor/javascript/jsuites.js
```

```bash
curl -fsSL https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.css -o app/assets/stylesheets/jsuites.css
```

- [ ] **Step 2: Verify what actually landed**

```bash
ls -l vendor/javascript/jspreadsheet.js vendor/javascript/jsuites.js \
      app/assets/stylesheets/jspreadsheet.css app/assets/stylesheets/jsuites.css
head -c 400 vendor/javascript/jspreadsheet.js
```

Expected: four non-empty files; the JS head shows a UMD preamble (a `typeof exports`/`typeof
define` factory) and sets a global. **If it is an ES module (`export default`) instead**, stop and
switch to the importmap route: `pin "jspreadsheet", to: "jspreadsheet.js"` plus a matching `import`
in the Stimulus controller. Both routes are supported by this plan; only Step 5 of Task 4 differs.

- [ ] **Step 3: Record the licences (CLAUDE.md §9)**

Create `vendor/javascript/JSPREADSHEET-LICENSES.md`:

```markdown
# Vendored grid libraries

Both MIT — permissive, per CLAUDE.md §9. Vendored as prebuilt browser bundles from jsDelivr rather
than pinned through jspm: these are UMD, so they carry no bare-specifier imports and cannot
reintroduce the shared-chunk problem documented in `config/importmap.rb` (the hand-patched
`buffer.js` that jszip and Maker.js share).

| File | Package | Version | Licence | Source |
|---|---|---|---|---|
| `vendor/javascript/jspreadsheet.js` | `jspreadsheet-ce` | 5.0.4 | MIT | `https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/index.min.js` |
| `app/assets/stylesheets/jspreadsheet.css` | `jspreadsheet-ce` | 5.0.4 | MIT | `https://cdn.jsdelivr.net/npm/jspreadsheet-ce@5/dist/jspreadsheet.min.css` |
| `vendor/javascript/jsuites.js` | `jsuites` | 5.13.5 | MIT | `https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.js` |
| `app/assets/stylesheets/jsuites.css` | `jsuites` | 5.13.5 | MIT | `https://cdn.jsdelivr.net/npm/jsuites@5/dist/jsuites.min.css` |

**`@5` is a floating range — those are what it resolved to on 2026-07-28.** Record whatever you
actually get, from the jsDelivr `Original file:` banner and the package's `package.json`, not from
this table. Note the bundles also carry an *internal* version string used only for a diagnostic
printout (`5.0.0` and `5.13.3`) which lags the real patch release — that string is not authoritative.

**Both are UMD**, confirmed by the wrapper
`!function(e,t){"object"==typeof exports&&…?…:e.jspreadsheet=t()}`. Loaded by a classic `<script>`
they fall to the global branch and set:

- `window.jspreadsheet` (all lowercase)
- **`window.jSuites`** — capital S in the middle, *not* `window.jsuites`

**Licence provenance differs between the two, and the second one matters.** jspreadsheet-ce
self-identifies inside the bundle (`license:"MIT"`, alongside `"Jspreadsheet CE"` — so the bundle
itself confirms it is CE and not Pro). **jsuites carries no licence string at all** — grepping it for
`licen[sc]e` returns nothing — so its MIT comes from `package.json`'s `licenses` array and the npm
`LICENSE` file. Do not report "verified from the banner" for jsuites; there is no banner.

`jsuites` is jspreadsheet's peer dependency and MUST load first — and this is demonstrable, not
folklore: jspreadsheet's bundle calls `jSuites.ajax(`, `.calendar(`, `.color(`, `.contextmenu(`,
`.dropdown(`, `.editor(`, `.image(`, `.picker(`, `.setDictionary(` and `.tabs(` directly. Load it
second and `window.jSuites` is `undefined` at those call sites, giving a `TypeError`.

**Community Edition only.** Jspreadsheet *Pro* is a paid commercial licence; do not upgrade the
package to Pro or copy Pro-only code in. Formulas, which are what this is here for, are in CE.
```

Then confirm the licences are what this file claims:

```bash
grep -io "MIT" vendor/javascript/jspreadsheet.js | head -1
grep -io "MIT" vendor/javascript/jsuites.js | head -1
```

Expected: `MIT` from each bundle's banner comment. If a bundle carries no licence banner, fetch and
read the package's `LICENSE` from npm before proceeding — §9 is a hard constraint, not a formality.

- [ ] **Step 4: Confirm propshaft serves them**

```bash
bin/rails runner 'puts %w[jspreadsheet.js jsuites.js jspreadsheet.css jsuites.css].map { |f| "#{f}: #{Rails.application.assets.load_path.find(f)&.path.inspect}" }'
```

Expected: a real path for all four. A `nil` for the JS files means `vendor/javascript` is not on
the load path — fix that before continuing.

- [ ] **Step 5: Commit**

```bash
git add vendor/javascript/jspreadsheet.js vendor/javascript/jsuites.js \
        vendor/javascript/JSPREADSHEET-LICENSES.md \
        app/assets/stylesheets/jspreadsheet.css app/assets/stylesheets/jsuites.css
git commit -m "chore(sheets): vendor Jspreadsheet CE v5 and jsuites (both MIT)"
```

---

## Task 4: The grid page

**Files:**
- Modify: `app/views/projects/sheets/show.html.erb`
- Create: `app/javascript/controllers/sheet_controller.js`
- Modify: `app/assets/stylesheets/projects.css`
- Test: `test/integration/web/project_sheets_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/project_sheets_test.rb`:

```ruby
    test "the grid page carries the data, the save URL and a breadcrumb back to the project" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: {
        "columns" => [ { "title" => "Part" } ], "cells" => [ [ "M3 bolt" ] ]
      })

      get sheet_path(sheet)
      assert_response :success
      assert_select ".breadcrumb a", text: "Lamp"
      assert_select "[data-sheet-url-value=?]", sheet_path(sheet)
      assert_select "[data-sheet-data-value*=?]", "M3 bolt"
      assert_select "a[href=?]", sheet_path(sheet, format: :csv)

      # Both targets must be INSIDE the controller element — Stimulus only resolves targets in its
      # own subtree, and a status span left outside would leave the indicator stuck on "Saved"
      # while every save failed. Asserting the nesting, not just the presence, is what catches it.
      assert_select "[data-controller=sheet] [data-sheet-target=status]"
      assert_select "[data-controller=sheet] [data-sheet-target=grid]"
    end

    test "the grid page loads the vendored library only on this page" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      sheet = project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)

      get sheet_path(sheet)
      assert_select "script[src*=?]", "jspreadsheet"

      get project_path(project)
      assert_select "script[src*=?]", "jspreadsheet", count: 0
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/project_sheets_test.rb -n "/grid page/"
```

Expected: FAIL — the placeholder view has no breadcrumb, no values, no script tag.

- [ ] **Step 3: Write the grid page**

Replace `app/views/projects/sheets/show.html.erb` in full:

```erb
<% content_for :title, "#{@sheet.name} — Tinkerex" %>

<%# The grid library loads HERE ONLY, not in the global layout — it is a large bundle and no other
    page needs it. jsuites must precede jspreadsheet (see vendor/javascript/JSPREADSHEET-LICENSES.md).
    Classic script tags rather than importmap: these are UMD bundles that publish globals. The
    importmap's module scripts are deferred, so these have always executed by the time the Stimulus
    controller connects. %>
<% content_for :head do %>
  <%= stylesheet_link_tag "jsuites", "jspreadsheet" %>
  <%= javascript_include_tag "jsuites", "jspreadsheet" %>
<% end %>

<nav class="breadcrumb" aria-label="Sheet path">
  <%= link_to "Projects", projects_path %>
  <span class="sep" aria-hidden="true">/</span>
  <%= link_to @sheet.project.name, project_path(@sheet.project) %>
  <span class="sep" aria-hidden="true">/</span>
  <span aria-current="page"><%= @sheet.name %></span>
</nav>

<%# The controller element wraps the HEAD AS WELL AS the grid: Stimulus resolves targets only
    within its own element's subtree, so a status span left up in the page head outside this div
    would never be found and the indicator would sit on "Saved" forever while saves failed. %>
<div class="sheet-page"
     data-controller="sheet"
     data-sheet-url-value="<%= sheet_path(@sheet) %>"
     data-sheet-data-value="<%= @sheet.data.to_json %>">

  <div class="page-head sheet-head">
    <div>
      <h1><%= @sheet.name %></h1>
      <span class="sheet-status muted" data-sheet-target="status">Saved</span>
    </div>
    <div class="head-actions">
      <%= form_with model: @sheet, scope: :sheet, url: sheet_path(@sheet), method: :patch,
                    class: "sheet-rename" do |f| %>
        <%= f.text_field :name, "aria-label": "Sheet name" %>
        <%= f.submit "Rename", class: "btn small" %>
      <% end %>
      <%= link_to "Export CSV", sheet_path(@sheet, format: :csv), class: "linkbtn" %>
      <%= button_to "Delete", sheet_path(@sheet), method: :delete, class: "linkbtn danger",
                    form: { data: { turbo_confirm: "Delete #{@sheet.name}?" } } %>
    </div>
  </div>

  <div class="sheet-grid" data-sheet-target="grid"></div>
</div>
```

`data-sheet-data-value` uses `to_json` into an HTML attribute — ERB escapes the quotes, and the
Stimulus `Object` value type parses it back. No `html_safe` anywhere: the blob is user input.

`scope: :sheet` on the rename form is load-bearing for the same reason it is on the project form:
`Maker::Sheet` is namespaced, so `form_with model:` alone derives `maker_sheet[...]` and
`params.require(:sheet)` would raise.

- [ ] **Step 4: Write the Stimulus controller**

Create `app/javascript/controllers/sheet_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Drives the Jspreadsheet grid on a sheet page and debounces its autosave.
//
// The library is a UMD bundle loaded by a classic <script> in the page head (see
// projects/sheets/show.html.erb), so it arrives as a global rather than an import.
export default class extends Controller {
  static targets = ["grid", "status"]
  static values = { url: String, data: Object }

  // Long enough that typing across a row is one save, short enough that a browser closed right
  // after an edit has already persisted it.
  static DEBOUNCE_MS = 1000

  connect() {
    const jss = window.jspreadsheet
    if (!jss) {
      this.setStatus("Grid failed to load", true)
      return
    }

    const columns = this.dataValue?.columns || []
    const cells = this.dataValue?.cells || []

    this.instance = jss(this.gridTarget, {
      data: cells,
      columns: columns.map((c) => ({ title: c.title, width: c.width || 120 })),
      allowInsertRow: true,
      allowInsertColumn: true,
      allowDeleteRow: true,
      allowDeleteColumn: true,
      onchange: () => this.scheduleSave(),
      oninsertrow: () => this.scheduleSave(),
      ondeleterow: () => this.scheduleSave(),
      oninsertcolumn: () => this.scheduleSave(),
      ondeletecolumn: () => this.scheduleSave()
    })
  }

  disconnect() {
    clearTimeout(this.timer)
    if (this.instance?.destroy) this.instance.destroy()
  }

  scheduleSave() {
    clearTimeout(this.timer)
    this.setStatus("Saving…")
    this.timer = setTimeout(() => this.save(), this.constructor.DEBOUNCE_MS)
  }

  async save() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content

    // getData(false) asks for the RAW values, so a cell holding =A1*B1 persists as that formula
    // rather than as the number it currently evaluates to. Saving the computed value would
    // silently destroy every formula on the next page load.
    const payload = {
      columns: this.instance.getHeaders
        ? this.instance.getHeaders(true).map((title, i) => ({ title, width: this.instance.getWidth(i) }))
        : this.dataValue.columns,
      cells: this.instance.getData(false)
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": token
        },
        body: JSON.stringify({ sheet: { data: payload } })
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.setStatus("Saved")
    } catch (error) {
      // An autosave that fails silently is indistinguishable from one that worked, which is the
      // whole risk of choosing autosave over a Save button.
      this.setStatus("Not saved — check your connection", true)
    }
  }

  setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("sheet-status-error", isError)
  }
}
```

- [ ] **Step 5: Add the styles**

Append to `app/assets/stylesheets/projects.css`:

```css
.sheet-head { align-items: flex-start; }
.sheet-head h1 { margin: 0 0 6px; }
.sheet-rename { display: inline-flex; gap: 6px; }
/* The GRID scrolls sideways, not the whole page container — the page head sits in the same
   element (it holds the Stimulus targets) and must stay put. */
.sheet-grid { overflow-x: auto; }
.sheet-status { font-size: 12px; }
.sheet-status-error { color: var(--danger); }

.sheets-panel .sheet-row { display: flex; align-items: center; justify-content: space-between;
                           padding: 6px 0; border-bottom: 1px solid var(--line); }
.sheets-panel .sheet-row:last-child { border-bottom: 0; }
```

- [ ] **Step 6: Run the tests to verify they pass**

```bash
bin/rails test test/integration/web/project_sheets_test.rb
```

Expected: PASS, whole file.

- [ ] **Step 7: Commit**

```bash
git add app/views/projects/sheets/show.html.erb app/javascript/controllers/sheet_controller.js \
        app/assets/stylesheets/projects.css test/integration/web/project_sheets_test.rb
git commit -m "feat(sheets): the grid page with debounced autosave"
```

---

## Task 5: The Sheets panel on the project page

**Files:**
- Modify: `app/controllers/projects_controller.rb` (`show`)
- Create: `app/views/projects/_sheets.html.erb`
- Modify: `app/views/projects/show.html.erb:34-38`
- Test: `test/integration/web/project_sheets_test.rb`

- [ ] **Step 1: Write the failing test**

Append to `test/integration/web/project_sheets_test.rb`:

```ruby
    test "the project page lists its sheets and offers a new-sheet form" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.sheets.create!(user:, name: "Cut list", data: Maker::Sheet.blank_data)
      project.sheets.create!(user:, name: "Costs", data: Maker::Sheet.blank_data)

      get project_path(project)
      assert_response :success
      assert_select ".sheets-panel .sheet-row", count: 2
      assert_select ".sheets-panel a", text: "Cut list"
      assert_select ".sheets-panel form[action=?]", project_sheets_path(project)
    end

    test "the project page shows an empty state with no sheets" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      get project_path(project)
      assert_select ".sheets-panel .sheet-row", count: 0
      assert_select ".sheets-panel .muted", text: /No sheets yet/
    end

    test "another user's sheets never appear on a project page" do
      user = sign_in("a@example.com")
      project = user.maker_projects.create!(name: "Mine")
      other = User.create!(email: "b@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs").sheets.create!(user: other, name: "Secret")

      get project_path(project)
      assert_select ".sheets-panel a", text: "Secret", count: 0
    end
```

- [ ] **Step 2: Run them to verify they fail**

```bash
bin/rails test test/integration/web/project_sheets_test.rb -n "/project page/"
```

Expected: FAIL — there is no `.sheets-panel`.

- [ ] **Step 3: Load the sheets in the controller**

In `app/controllers/projects_controller.rb`, in `show`, after the `@tasks` line:

```ruby
    @sheets = @project.sheets.to_a
```

- [ ] **Step 4: Write the panel**

Create `app/views/projects/_sheets.html.erb`:

```erb
<%#
  Named spreadsheets on this project. The grid itself lives on its own full-width page — a real
  grid inside a panel this size is unusable — so this panel is a list plus a create form.
%>
<section class="panel sheets-panel">
  <div class="panel-head">
    <h2>Sheets</h2>
    <%# text_field_tag, not f.text_field: this form has no model object, and the controller reads
        params.dig(:sheet, :name), so the field needs that exact nested name. %>
    <%= form_with url: project_sheets_path(@project), method: :post, class: "sheet-new-form" do %>
      <%= text_field_tag "sheet[name]", nil, placeholder: "New sheet…" %>
      <%= submit_tag "Add", class: "btn small" %>
    <% end %>
  </div>

  <% if @sheets.empty? %>
    <p class="muted">No sheets yet. Cut lists, cost math, measurements.</p>
  <% else %>
    <% @sheets.each do |sheet| %>
      <div class="sheet-row">
        <%= link_to sheet.name, sheet_path(sheet) %>
        <span class="muted"><%= sheet.cells.size %> rows</span>
      </div>
    <% end %>
  <% end %>
</section>
```

- [ ] **Step 5: Render it on the project page**

In `app/views/projects/show.html.erb`, add the panel inside `.project-panels`:

```erb
<div class="project-panels">
  <%= render "attachments" %>
  <%= render "build_log" %>
  <%= render "tasks" %>
  <%= render "sheets" %>
</div>
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/integration/web/project_sheets_test.rb
```

Expected: PASS, whole file.

- [ ] **Step 7: Commit**

```bash
git add app/controllers/projects_controller.rb app/views/projects/_sheets.html.erb \
        app/views/projects/show.html.erb test/integration/web/project_sheets_test.rb
git commit -m "feat(sheets): sheets panel on the project page"
```

---

## Task 6: Full verification

**Files:** none — verification only.

- [ ] **Step 1: All three backend legs**

```bash
bin/rails test
```

```bash
LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails test
```

```bash
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library \
  bin/rails test
```

> **The env vars are required, not decoration.** `LIBRARY_BACKEND=share` without `LIBRARY_PATH`
> aborts at boot (`LibraryBackendCheck::Error`) and fails ~195 tests for that one reason, which
> reads exactly like a catastrophic regression. `s3` needs the five `LIBRARY_S3_*` vars for the
> same reason. Both sets are lifted from `.github/workflows/ci.yml`'s `test-share-backend` /
> `test-s3-backend` jobs; the s3 values are deliberate stubs — the guard checks config *presence*,
> never the network, so no bucket is contacted and none needs to exist.

Expected: 0 failures, 0 errors, **identical counts on all three**. Sheets never touch the port, so
any divergence here means the controller reached somewhere it shouldn't.

- [ ] **Step 2: Confirm the §10 tripwire was not crossed**

```bash
grep -rn "FileLayer\|Sync::\|ChunkStore" app/models/maker/sheet.rb app/controllers/projects/sheets_controller.rb \
  | grep -v ':[0-9]*: *#'
```

Expected: **empty output.**

> **The `grep -v` is load-bearing, not noise — this exact trap has now bitten three times in this
> repo.** A comment that explains *why* a file doesn't touch the file layer necessarily contains the
> words `FileLayer`, `Sync::` and `ChunkStore`, so the bare grep reports the very comment written to
> document the absence. CLAUDE.md §12 records two earlier instances (the maker-layer proof and the
> `rescue NotImplementedError` proof) and the same rule: **a proof that cries wolf gets ignored.**
> Filtering comments lets the code say what it means and keeps the check honest. Do not "simplify"
> the filter away, and do not instead contort the comments to avoid the words.

- [ ] **Step 3: Browser-verify the grid**

```bash
bin/rails server -p 3001
```

By hand, on a real sheet:

1. Type values, wait a second, confirm the indicator goes Saving… → Saved. Reload: values persist.
2. **Type `=A1+B1` with numbers in A1 and B1. Confirm it computes. Reload the page and confirm the
   cell still holds the FORMULA, not the number it evaluated to.** If the formula was replaced by
   its result, `getData(false)` is not the raw accessor on this version — find the one that is
   (the library's own docs) and fix `save()` in `sheet_controller.js`. This is the single most
   important check in this plan: silently converting formulas to constants destroys the feature
   the library was chosen for.
3. Insert and delete a row and a column; confirm each triggers a save.
4. Rename the sheet; confirm the heading and the breadcrumb follow.
5. Export CSV; confirm the header row is the column titles and a formula cell exports as its
   formula text.
6. Stop the server mid-edit and confirm the indicator turns red rather than staying on "Saving…".
7. Open a project page and confirm the grid bundle is **not** requested there (Network tab).

- [ ] **Step 4: Commit any fixes**

```bash
git add -A && git commit -m "fix(sheets): follow-ups from browser verification"
```
