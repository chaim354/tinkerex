# The Page Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: this repo's `.claude/commands/execute-plan.md`
> (batched by file, disjoint tasks in parallel, one capped full-depth review per task) overrides
> any generic subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-place edit mode on the project page — drag to reorder, hide, view, Full/Half
width, title and intro per panel, draft until Save — with a YAML drawer beside the page whose
text is the shareable form of the layout and whose Apply merges pasted YAML into the draft.

**Architecture:** The `panels` JSON column gains `widths`, `titles` and `intros` beside `order`,
`hidden` and `views`; `Maker::ProjectKind::Layout` answers them and default widths move out of
the stylesheet into the layout. `Maker::LayoutDocument` is the one grammar: the browser's draft,
the YAML text, the merge rules, the column shape. The edit page IS `ProjectsController#show`
with an `editing` flag, so it loads what the page loads; two read-only conversions live on
`Projects::LayoutsController`; Save is a document branch on the existing panels door. One
Stimulus controller, `layout_editor`, owns the draft (read off the slots' data attributes),
SortableJS for dragging, the drawer and Save. Both pages render every panel inside a
`.panel-slot` wrapper that carries the width class.

**Tech Stack:** Rails 8, Hotwire/Stimulus, Psych (`YAML.safe_load`), SortableJS 1.15.7 (MIT,
vendored through the importmap), Minitest, Capybara + headless Chrome.

**Spec:** `docs/superpowers/specs/2026-09-09-page-editor-design.md`. Three details this plan
settles differently from the spec's wording, each recorded in Task E's docs step: the control
strip sits along the TOP EDGE of each panel card rather than inside its head (ten partials own
their heads; a strip in the slot wrapper touches none of them); a Save that fails validation
redirects back to the edit page with the errors as an alert (the draft is not retained — the
only reachable cause, a folder renamed mid-edit, is handled by dropping the entry with a notice);
and a failed panel preview keeps the CHOSEN view in the draft and says the preview did not load,
rather than reverting the switch.

---

## Shared interface (every task codes against this; nothing here is optional)

**`Maker::ProjectKind`** (Task A)
```ruby
WIDTHS = %w[full half].freeze
TITLE_MAX = 60
INTRO_MAX = 200
FULL_BY_DEFAULT = %w[attachments photos].freeze
Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids)
  # existing: visible, visible?(key), hidden?(key), folder?(key), folder_id(key), view_for(key)
  # new:
  def width_for(key)            # "full" | "half"; stored else ProjectKind.default_width(key)
  def title_for(key, default)   # stored title else `default` (the caller knows the label)
  def intro_for(key)            # stored intro or nil
def self.default_width(key)     # "full" for FULL_BY_DEFAULT and every folder key, else "half"
```
`layout_for(kind:, overrides:, folders: [])` filters `widths` to `WIDTHS`, `titles`/`intros` to
non-empty one-line strings capped at the max — total on the way out like every other map.

**`Maker::LayoutDocument`** (Task B) — `app/services/maker/layout_document.rb`
```ruby
Maker::LayoutDocument.new(layout, folder_names)   # folder_names: { node_id => name } for the depth-one folders
VERSION = 1; MAX_BYTES = 16 * 1024
Result = Data.define(:draft, :notes, :errors) { def ok? = errors.empty? }
#draft                       -> the current layout as a draft Hash (below)
#to_yaml(draft = self.draft, project_name:) -> String
#parse(text)                 -> Result (YAML text, names -> keys, merge rules)
#from_draft(hash)            -> Result (the browser's draft, keys; same rules)
#column(draft)               -> { "order"=>[], "hidden"=>[], "views"=>{}, "widths"=>{}, "titles"=>{}, "intros"=>{} }
```
A **draft** is `{ "layout" => 1, "panels" => [ entry, … ] }`, an entry is
`{ "key" => "attachments", "hidden" => false, "width" => "full", "view" => "tiles", "title" => "…", "intro" => "…" }`
with `view` present only for a panel that offers views and `title`/`intro` only when set.

**Routes** (Task C)
```ruby
get :layout,         on: :member, to: "projects#show", defaults: { editing: "1" }, as: :edit_layout   # edit_layout_project_path
get "layout/panel",  on: :member, to: "projects#show", defaults: { editing: "1" }, as: :layout_panel  # layout_panel_project_path(p, panel:, view:)
resource :layout, only: [], module: :projects do post :yaml; post :parse end                        # yaml_project_layout_path, parse_project_layout_path
```
`PATCH /projects/:id/panels` with `layout=<draft JSON>` saves; `view[<key>]=<view>` stays; `DELETE` resets.

**Markup contract** (Task C renders, Task D drives)
```
div.layout-editor[data-controller=layout-editor]
  [data-layout-editor-yaml-url-value] [data-layout-editor-parse-url-value] [data-layout-editor-panel-url-value]
  div.layout-bar
    button[data-action="layout-editor#toggleDrawer"]        Edit as YAML
    form.layout-save[data-layout-editor-target=form][data-action="submit->layout-editor#save"]
      input[name=layout][data-layout-editor-target=draft]
  div.project-panels.layout-editing[data-layout-editor-target=grid]
    div.panel-slot.panel--full|half[.panel-slot--hidden][.panel-slot--pinned]
        [data-layout-editor-target=slot] [data-key] [data-hidden=true|false] [data-width] [data-view] [data-title] [data-intro] [data-always]
      div.panel-strip
        span.panel-strip-handle
        b[data-layout-editor-target=name]
        button[data-action="layout-editor#up"] / #down / #toggleHidden ([data-layout-editor-target=eye])
        span.view-toggle > button.toggle[data-action="layout-editor#width"][data-width=full|half]
        span.view-toggle > button.toggle[data-action="layout-editor#view"][data-view=tiles|list|browser]
        details.panel-strip-edit > summary, div.panel-strip-popover > input[data-action="input->layout-editor#title"], input[data-action="input->layout-editor#intro"]
      div.panel-slot-body[data-layout-editor-target=body]
  aside.layout-drawer[hidden][data-layout-editor-target=drawer]
    button[data-controller=copy][data-layout-editor-target=copy]   textarea[data-layout-editor-target=yaml]
    button[data-action="layout-editor#apply"]                        div.layout-drawer-notes[data-layout-editor-target=notes]
```
On the normal page and the public page a panel renders as `div.panel-slot.panel--full|half > section.panel…`
and a panel whose partial renders nothing renders NO slot.

**`ProjectsHelper`** (Task E): `panel_title(layout, key, default = nil)` and `panel_intro(layout, key)`.
Shared `projects/_wiring` gains a `layout:` local; Task C passes `layout: @panel_layout` from
`projects/show.html.erb`, Task E passes `layout: pub.layout` from the public page.

**Order:** A → B → C → then D and E in parallel → close-out. C, D and E touch disjoint files
(listed per task). The fixture rules from CLAUDE.md apply throughout: folders are ROWS
(`project_folder_rows!`), never the port; every guard is mutation-checked; `bin/ci` from a
worktree needs `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`.

**Test environment for every command below:**
```bash
export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)
```

---

### Task A: widths, titles and intros in the layout

**Files:**
- Modify: `app/services/maker/project_kind.rb`
- Test: `test/services/maker/project_kind_test.rb`

- [ ] **Step 1: Write the failing tests** — append inside the class, after the `offered_views` test:

```ruby
    # --- widths, titles, intros (2026-09-09, the page editor; spec §3) -------------------------

    test "default_width: Files, Photos and every folder are full, the rest half — today's CSS rule as data" do
      assert_equal "full", Maker::ProjectKind.default_width("attachments")
      assert_equal "full", Maker::ProjectKind.default_width("photos")
      assert_equal "full", Maker::ProjectKind.default_width(key(MODELS))
      %w[schematics build_log tasks bom wiring releases sheets publish].each do |k|
        assert_equal "half", Maker::ProjectKind.default_width(k), k
      end
    end

    test "width_for answers the stored width, else the default, and filters junk" do
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "widths" => { "tasks" => "full", "photos" => "half", key(MODELS) => "wide",
                                   "nope" => "full", :bom => :full } },
        folders: FOLDERS
      )

      assert_equal "full", layout.width_for("tasks")
      assert_equal "half", layout.width_for("photos")
      assert_equal "full", layout.width_for(:bom), "symbol keys and values are stringified"
      assert_equal "full", layout.width_for(key(MODELS)), "a value outside WIDTHS falls back to the default"
      refute layout.widths.key?("nope"), "a key outside the vocabulary is dropped"
      assert_equal "half", layout.width_for("wiring")
    end

    test "titles and intros are plain one-line text, capped, and blank means absent" do
      long = "x" * 100
      layout = Maker::ProjectKind.layout_for(
        kind: "other",
        overrides: { "titles" => { key(MODELS) => "  Prints ", "tasks" => "", "nope" => "Gone", "bom" => long },
                     "intros" => { key(MODELS) => "Line one\nline two", "photos" => "   " } },
        folders: FOLDERS
      )

      assert_equal "Prints", layout.title_for(key(MODELS), "models")
      assert_equal "Tasks", layout.title_for("tasks", "Tasks"), "an empty title is no title"
      assert_equal "Prints", layout.titles[key(MODELS)]
      refute layout.titles.key?("nope")
      assert_equal Maker::ProjectKind::TITLE_MAX, layout.title_for("bom", "BOM").length
      assert_equal "Line one line two", layout.intro_for(key(MODELS)), "newlines collapse to one line"
      assert_nil layout.intro_for("photos")
      assert_nil layout.intro_for("tasks")
    end

    test "junk in widths, titles and intros is filtered rather than raised on" do
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "widths" => "full", "titles" => [ 1 ], "intros" => 7 },
                                             folders: FOLDERS)
      assert_equal({}, layout.widths)
      assert_equal({}, layout.titles)
      assert_equal({}, layout.intros)
    end

    test "a stored key for a folder that is gone drops out of widths, titles and intros too" do
      gone = key("d-vanished")
      layout = Maker::ProjectKind.layout_for(kind: "other",
                                             overrides: { "widths" => { gone => "full" }, "titles" => { gone => "X" },
                                                          "intros" => { gone => "Y" } },
                                             folders: FOLDERS)
      refute layout.widths.key?(gone)
      refute layout.titles.key?(gone)
      refute layout.intros.key?(gone)
      assert_equal "full", layout.width_for(gone), "the stale key still answers a default, never raises"
    end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/services/maker/project_kind_test.rb -n "/default_width|width_for|titles and intros|junk in widths|widths, titles and intros too/"
```
Expected: 5 failures/errors (`NoMethodError: undefined method 'default_width'`, `unknown keyword: :widths` …).

- [ ] **Step 3: Implement** — in `app/services/maker/project_kind.rb`:

Replace the `Layout = Data.define(:order, :hidden, :views, :repo_ids) do … end` block (lines 201–220) with:

```ruby
    # One project page's panel list. `order` is a permutation of the vocabulary (Maker::Project::
    # PANELS plus the current folder keys); `hidden` is a subset of it with ALWAYS removed; `views`
    # holds only vocabulary keys with values in Maker::Project::VIEWS; `widths` only vocabulary keys
    # with values in WIDTHS; `titles` and `intros` only vocabulary keys with non-empty one-line text
    # under their caps (2026-09-09, the page editor; spec §3); `repo_ids` are the node ids of the
    # folders that are working trees, which is all #view_for needs to pick a default. `visible` is
    # what the loop renders.
    Layout = Data.define(:order, :hidden, :views, :widths, :titles, :intros, :repo_ids) do
      def visible = order - hidden
      # `to_s` like `folder?` and `view_for` below, so a Symbol asks the same question a String does.
      def visible?(key) = order.include?(key.to_s) && !hidden.include?(key.to_s)
      def hidden?(key) = hidden.include?(key.to_s)
      def folder?(key) = key.to_s.start_with?(FOLDER_PREFIX)
      def folder_id(key) = key.to_s.delete_prefix(FOLDER_PREFIX)

      # The maker's choice, else the default for what this panel IS. The `folder?` guard is not
      # decoration: without it a fixed key is asked whether `repo_ids` holds the string
      # "attachments", which is a question about node ids that only has a right answer by luck.
      def view_for(key)
        views[key.to_s] || ProjectKind.default_view(key.to_s, repo: folder?(key) && repo_ids.include?(folder_id(key)))
      end

      # THE WIDTH IS DATA, NOT A STYLESHEET RULE (2026-09-09): pages/projects.css used to name
      # `.attachments-panel, .photos-panel, .folder-panel` as the panels that span both columns.
      # Both pages now render `panel--<width>` from this answer, so a layout can carry a width and
      # be shared as YAML, and every existing project renders exactly as it did.
      def width_for(key) = widths[key.to_s] || ProjectKind.default_width(key)

      # THE CALLER SUPPLIES THE DEFAULT because only the caller knows it: PANEL_LABELS for a fixed
      # key, the folder's own name for a folder key — this struct holds node ids, never names.
      def title_for(key, default) = titles[key.to_s] || default

      def intro_for(key) = intros[key.to_s]
    end
```

After `def self.default_view(_key, repo:) = repo ? "browser" : "tiles"` add:

```ruby
    WIDTHS = %w[full half].freeze
    TITLE_MAX = 60
    INTRO_MAX = 200
    # Today's page, written down: Files and Photos spanned both columns by a stylesheet rule that
    # also named `.folder-panel`; a folder panel holds a tile grid, nested sections or the browser,
    # and half a column is where the browser stops being usable.
    FULL_BY_DEFAULT = %w[attachments photos].freeze

    def self.default_width(key)
      k = key.to_s
      k.start_with?(FOLDER_PREFIX) || FULL_BY_DEFAULT.include?(k) ? "full" : "half"
    end
```

Replace the `Layout.new(...)` line inside `layout_for` with:

```ruby
      Layout.new(order: order & vocabulary, hidden:, views: stored_views(over["views"], vocabulary),
                 widths: stored_widths(over["widths"], vocabulary),
                 titles: stored_text(over["titles"], vocabulary, TITLE_MAX),
                 intros: stored_text(over["intros"], vocabulary, INTRO_MAX),
                 repo_ids:)
```

After `stored_views` add, and extend the `private_class_method` line:

```ruby
    def self.stored_widths(raw, vocabulary)
      return {} unless raw.is_a?(Hash)

      raw.to_h { |key, width| [ key.to_s, width.to_s ] }
         .select { |key, width| vocabulary.include?(key) && WIDTHS.include?(width) }
    end

    # PLAIN TEXT, ONE LINE, CAPPED — and total on the way out like every other map here: a console
    # write of five thousand characters renders as the first sixty, never as an error on the page.
    # Whitespace collapses so an intro pasted with a newline still reads as the one line it renders
    # as, and a blank string is ABSENT rather than an empty heading.
    def self.stored_text(raw, vocabulary, max)
      return {} unless raw.is_a?(Hash)

      raw.filter_map do |key, text|
        k = key.to_s
        t = text.to_s.gsub(/\s+/, " ").strip
        [ k, t[0, max] ] if vocabulary.include?(k) && !t.empty?
      end.to_h
    end
    private_class_method :known, :stored_order, :preset_order, :stored_views, :stored_widths, :stored_text
```

Update the module header's fourth bullet (`* `views` IS PER PANEL…`) by appending one bullet after it:

```ruby
  #   * `widths`, `titles` AND `intros` ARE PER PANEL TOO (2026-09-09, the page editor): a width in
  #     WIDTHS, else the default that used to be a stylesheet rule (#default_width); plain one-line
  #     text under TITLE_MAX / INTRO_MAX, else dropped. Same totality, same reason.
```

- [ ] **Step 4: Run the file, then the two suites that construct layouts**

```bash
bin/rails test test/services/maker/project_kind_test.rb
bin/rails test test/models/maker/project_test.rb test/services/maker/public_project_test.rb
```
Expected: all green. If anything constructs `Layout.new` positionally it fails here — `grep -rn "Layout.new" app test` should show only `project_kind.rb`.

- [ ] **Step 5: Mutation-check** — three, each restored with the Edit tool (never git), then clear `tmp/cache/bootsnap*`:
  1. In `default_width`, swap `"full" : "half"` → the first test goes red.
  2. In `stored_text`, delete `.gsub(/\s+/, " ")` → the intros test goes red on "newlines collapse".
  3. In `stored_widths`, delete `&& WIDTHS.include?(width)` → the width_for test goes red on "wide".
  After each restore: `rm -rf tmp/cache/bootsnap*` and re-run the file green.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/project_kind.rb test/services/maker/project_kind_test.rb
git commit -F- <<'MSG'
The layout carries a width, a title and an intro per panel, and default widths are data

Three maps beside order, hidden and views in the panels column, filtered on the way out like the
rest (spec 2026-09-09-page-editor §3). default_width writes down the stylesheet rule that made
Files, Photos and folder panels span both columns, so a page can render `panel--<width>` from the
layout and a layout can be shared as text. No page changes yet; every existing project answers
exactly what the CSS said.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task B: `Maker::LayoutDocument` — the draft, the YAML, the merge rules, the column

**Files:**
- Create: `app/services/maker/layout_document.rb`
- Test: `test/services/maker/layout_document_test.rb`

- [ ] **Step 1: Write the failing tests** — create `test/services/maker/layout_document_test.rb`:

```ruby
require "test_helper"

module Maker
  # THE ONE GRAMMAR (2026-09-09, the page editor; spec §4). Pure arithmetic over a Layout and a
  # folder-name map — no rows, no port — so every rule here runs identically on the three legs.
  class LayoutDocumentTest < ActiveSupport::TestCase
    MODELS = "d-models".freeze
    FIRMWARE = "d-firmware".freeze
    FOLDERS = [ [ FIRMWARE, true ], [ MODELS, false ] ].freeze
    NAMES = { FIRMWARE => "firmware", MODELS => "models" }.freeze

    def key(id) = Maker::ProjectKind.folder_key(id)

    def layout(overrides = nil, kind: "other")
      Maker::ProjectKind.layout_for(kind:, overrides:, folders: FOLDERS)
    end

    def doc(overrides = nil, kind: "other") = Maker::LayoutDocument.new(layout(overrides, kind:), NAMES)

    def entry(result, key) = result.draft["panels"].find { |e| e["key"] == key }

    # --- the draft -----------------------------------------------------------------------------

    test "the draft lists every panel in order with hidden, width, and a view only where offered" do
      d = doc({ "hidden" => %w[tasks], "views" => { key(MODELS) => "list" },
                "widths" => { "photos" => "half" }, "titles" => { key(MODELS) => "Prints" } }).draft

      assert_equal 1, d["layout"]
      assert_equal layout.order, d["panels"].map { |e| e["key"] }
      files = d["panels"].find { |e| e["key"] == "attachments" }
      assert_equal({ "key" => "attachments", "hidden" => false, "width" => "full", "view" => "tiles" }, files)
      models = d["panels"].find { |e| e["key"] == key(MODELS) }
      assert_equal "list", models["view"]
      assert_equal "Prints", models["title"]
      refute models.key?("intro"), "an unset intro is absent, not nil"
      tasks = d["panels"].find { |e| e["key"] == "tasks" }
      assert tasks["hidden"]
      refute tasks.key?("view"), "Tasks offers no view, so the draft carries none"
      assert_equal "half", d["panels"].find { |e| e["key"] == "photos" }["width"]
    end

    # --- export ----------------------------------------------------------------------------------

    test "to_yaml names folders by name, writes width always, view where offered, title/intro/hidden when set" do
      text = doc({ "hidden" => %w[wiring], "views" => { key(MODELS) => "list" },
                   "titles" => { key(MODELS) => "Prints" },
                   "intros" => { key(MODELS) => "Everything you need to print: sliced." } }).to_yaml(project_name: "Desk Lamp")

      assert text.start_with?("# Desk Lamp, page layout."), text.lines.first
      assert_includes text, "layout: 1\n"
      assert_includes text, "- panel: attachments\n  width: full\n  view: tiles\n"
      assert_includes text, "- folder: models\n  title: Prints\n  intro: 'Everything you need to print: sliced.'\n  width: full\n  view: list\n"
      assert_includes text, "- panel: wiring\n  width: half\n  hidden: true\n"
      assert_includes text, "- panel: tasks\n  width: half\n"
      refute_includes text, "d-models", "a node id never appears in the shareable form"
      refute_includes text, "hidden: false"
    end

    test "export then parse is the identity on a layout with every attribute set" do
      d = doc({ "order" => [ "attachments", key(MODELS), "photos", "tasks", "build_log", key(FIRMWARE) ] + %w[schematics bom wiring releases sheets publish],
                "hidden" => %w[wiring sheets], "views" => { key(MODELS) => "list", "attachments" => "list" },
                "widths" => { "tasks" => "full", "photos" => "half" },
                "titles" => { key(MODELS) => "Prints", "tasks" => "To do" },
                "intros" => { key(MODELS) => "Sliced for 0.2 mm." } })

      result = d.parse(d.to_yaml(project_name: "Lamp"))

      assert result.ok?, result.errors.inspect
      assert_equal [], result.notes
      assert_equal d.draft, result.draft
    end

    # --- parse: the grammar -----------------------------------------------------------------------

    test "parse: a folder is looked up by name and becomes its key" do
      result = doc.parse("layout: 1\npanels:\n  - folder: models\n    title: Prints\n")

      assert result.ok?, result.errors.inspect
      assert_equal key(MODELS), result.draft["panels"].first["key"]
      assert_equal "Prints", entry(result, key(MODELS))["title"]
    end

    test "parse: listed entries take the order given, unlisted panels follow in their current relative order" do
      result = doc.parse("layout: 1\npanels:\n  - panel: tasks\n  - panel: bom\n")

      assert result.ok?
      order = result.draft["panels"].map { |e| e["key"] }
      assert_equal %w[tasks bom], order.first(2)
      rest = layout.order - %w[tasks bom]
      assert_equal rest, order[2..], "the unmentioned keep their relative order"
    end

    test "parse: an attribute not given keeps the draft's current value; a given one replaces it" do
      result = doc({ "titles" => { "tasks" => "To do" }, "widths" => { "tasks" => "full" } })
                 .parse("layout: 1\npanels:\n  - panel: tasks\n    width: half\n")

      assert result.ok?
      assert_equal "To do", entry(result, "tasks")["title"]
      assert_equal "half", entry(result, "tasks")["width"]
    end

    test "parse: a folder this project lacks is skipped with a note, and the rest applies" do
      result = doc.parse("layout: 1\npanels:\n  - folder: enclosure\n    width: half\n  - panel: tasks\n    width: full\n")

      assert result.ok?
      assert_equal [ "This project has no folder named “enclosure”; that entry was skipped." ], result.notes
      assert_equal "full", entry(result, "tasks")["width"]
      assert_equal layout.order.size, result.draft["panels"].size
    end

    test "parse: hidden on an always-shown panel is ignored with a note" do
      result = doc.parse("layout: 1\npanels:\n  - panel: attachments\n    hidden: true\n")

      assert result.ok?
      refute entry(result, "attachments")["hidden"]
      assert_equal [ "Files is always shown; `hidden` was ignored." ], result.notes
    end

    test "parse: publish listed anywhere but last is moved to the end with a note" do
      result = doc.parse("layout: 1\npanels:\n  - panel: publish\n  - panel: tasks\n")

      assert result.ok?
      assert_equal "publish", result.draft["panels"].last["key"]
      assert_equal "tasks", result.draft["panels"].first["key"]
      assert_equal [ "Publish is always last; it was moved to the end." ], result.notes
    end

    test "parse: each error names its entry and blocks Apply" do
      cases = {
        "layout: 1\npanels:\n  - panel: tsaks\n"                          => /Entry 1: unknown panel “tsaks”/,
        "layout: 1\npanels:\n  - panel: tasks\n    hiden: true\n"         => /Entry 1: unknown attribute “hiden”/,
        "layout: 1\npanels:\n  - panel: tasks\n    folder: models\n"      => /Entry 1 names both `panel` and `folder`/,
        "layout: 1\npanels:\n  - panel: photos\n    view: list\n"         => /Entry 1: Photos has no view/,
        "layout: 1\npanels:\n  - panel: attachments\n    view: browser\n" => /Entry 1: Files does not offer the browser view/,
        "layout: 1\npanels:\n  - panel: tasks\n    width: wide\n"         => /Entry 1: width must be full or half/,
        "layout: 1\npanels:\n  - panel: tasks\n    title: #{'x' * 61}\n"  => /Entry 1: the title is over 60 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    intro: #{'x' * 201}\n" => /Entry 1: the intro is over 200 characters/,
        "layout: 1\npanels:\n  - panel: tasks\n    hidden: yes please\n"  => /Entry 1: hidden must be true or false/,
        "layout: 1\npanels:\n  - tasks\n"                                 => /Entry 1 is not a mapping/,
        "layout: 1\npanels:\n  - width: full\n"                           => /Entry 1 names neither `panel` nor `folder`/,
        "layout: 1\npanels:\n  - panel: tasks\n  - panel: tasks\n"        => /Entry 2 names Tasks a second time/,
        "layout: 2\npanels: []\n"                                         => /newer than this server/,
        "panels: []\n"                                                    => /`layout: 1` is required/,
        "layout: 1\npanels: {}\n"                                         => /`panels` must be a list/,
        "layout: 1\npanels: []\nlook: dark\n"                             => /Unknown key “look” at the top level/,
        "- just\n- a list\n"                                              => /must be a mapping/,
        "layout: 1\npanels:\n  - panel: tasks\n   width: [\n"             => /Line \d+, column \d+/,
        "x" * (16 * 1024 + 1)                                             => /over 16 KB/
      }
      cases.each do |text, message|
        result = doc.parse(text)
        refute result.ok?, "expected an error for #{text.inspect[0, 60]}"
        assert_match message, result.errors.join(" "), text.inspect[0, 60]
      end
    end

    test "parse: safe_load refuses tags and aliases rather than instantiating anything" do
      refute doc.parse("layout: 1\npanels: !ruby/object:Object {}\n").ok?
      refute doc.parse("a: &x 1\nlayout: 1\npanels: *x\n").ok?
    end

    # --- from_draft: the browser's document ------------------------------------------------------

    test "from_draft validates like parse and drops a folder key that is no longer in the vocabulary, with a note" do
      result = doc.from_draft("layout" => 1, "panels" => [
        { "key" => "tasks", "hidden" => true, "width" => "full" },
        { "key" => key("d-vanished"), "hidden" => false, "width" => "full" },
        { "key" => "attachments", "hidden" => true, "width" => "full", "view" => "list", "title" => "Stuff" }
      ])

      assert result.ok?, result.errors.inspect
      assert_equal %w[tasks attachments], result.draft["panels"].map { |e| e["key"] }.first(2)
      assert entry(result, "tasks")["hidden"]
      refute entry(result, "attachments")["hidden"]
      assert_equal "list", entry(result, "attachments")["view"]
      assert_includes result.notes, "A folder changed on disk while you were editing; its panel keeps its defaults."
      assert_includes result.notes, "Files is always shown; `hidden` was ignored."
    end

    test "from_draft refuses a fixed key it does not know and anything that is not a draft" do
      refute doc.from_draft("layout" => 1, "panels" => [ { "key" => "../../etc" } ]).ok?
      refute doc.from_draft("nope").ok?
      refute doc.from_draft("layout" => 1, "panels" => "x").ok?
    end

    # --- the column ----------------------------------------------------------------------------

    test "column writes the six maps the layout reads back, and only the set values" do
      result = doc.parse(<<~YAML)
        layout: 1
        panels:
          - folder: models
            title: Prints
            intro: Sliced.
            view: list
          - panel: tasks
            hidden: true
      YAML
      column = doc.column(result.draft)

      assert_equal layout.order.size, column["order"].size
      assert_equal [ key(MODELS), "tasks" ], column["order"].first(2)
      assert_equal %w[tasks], column["hidden"]
      assert_equal "list", column["views"][key(MODELS)]
      assert_equal({ key(MODELS) => "Prints" }, column["titles"])
      assert_equal({ key(MODELS) => "Sliced." }, column["intros"])
      assert_equal "full", column["widths"][key(MODELS)]
      assert_equal "half", column["widths"]["tasks"]

      round = Maker::ProjectKind.layout_for(kind: "other", overrides: column, folders: FOLDERS)
      assert_equal result.draft, Maker::LayoutDocument.new(round, NAMES).draft, "the column reads back as the same draft"
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/services/maker/layout_document_test.rb
```
Expected: `NameError: uninitialized constant Maker::LayoutDocument`.

- [ ] **Step 3: Implement** — create `app/services/maker/layout_document.rb`:

```ruby
module Maker
  # THE ONE GRAMMAR OF A PAGE LAYOUT (2026-09-09, the page editor; spec §4 and decision 2). Three
  # forms of one thing meet here and nowhere else: the DRAFT the browser holds (keys), the YAML a
  # maker copies and pastes (folder NAMES, never node ids), and the six-map COLUMN the layout
  # reads back. The browser never parses or emits YAML; it posts a draft and receives text, or
  # posts text and receives a draft with notes and errors.
  #
  # APPLY MERGES, IT DOES NOT REPLACE (spec decision 3): listed entries take the order and the
  # attributes given, an attribute not given keeps the draft's current value, and the panels of
  # this project the text does not mention keep their settings and follow in their current
  # relative order — so a layout shared from a smaller project hides nothing here.
  #
  # ERRORS BLOCK, NOTES INFORM, AND A MISSPELLING IS AN ERROR (decision 5): the format is typed by
  # hand, and a silently ignored `hiden: true` is how a hand-typed line does nothing for a week.
  #
  # PURE: takes a Layout and a { node_id => name } map, touches no row and no port, so every rule
  # runs identically on the three backend legs. Psych's `safe_load` with no permitted classes and
  # a 16 KB cap is the whole of the parsing surface.
  class LayoutDocument
    VERSION = 1
    MAX_BYTES = 16 * 1024
    ATTRIBUTES = %w[title intro width view hidden].freeze

    Result = Data.define(:draft, :notes, :errors) do
      def ok? = errors.empty?
    end

    def initialize(layout, folder_names)
      @layout = layout
      @names = folder_names.to_h { |id, name| [ id.to_s, name.to_s ] }
    end

    # --- the draft ---------------------------------------------------------------------------

    def draft
      { "layout" => VERSION, "panels" => @layout.order.map { |key| entry(key) } }
    end

    # --- export ------------------------------------------------------------------------------

    def to_yaml(draft = self.draft, project_name:)
      panels = draft["panels"].map do |e|
        out = {}
        if @layout.folder?(e["key"])
          out["folder"] = @names.fetch(@layout.folder_id(e["key"]))
        else
          out["panel"] = e["key"]
        end
        out["title"] = e["title"] if e["title"]
        out["intro"] = e["intro"] if e["intro"]
        out["width"] = e["width"]
        out["view"] = e["view"] if e["view"]
        out["hidden"] = true if e["hidden"]
        out
      end
      body = Psych.dump({ "layout" => VERSION, "panels" => panels }, line_width: -1).delete_prefix("---\n")
      "# #{project_name.to_s.gsub(/\s+/, ' ').strip}, page layout. Paste into another project's editor to reuse it.\n#{body}"
    end

    # --- parse: YAML text in ---------------------------------------------------------------------

    def parse(text)
      text = text.to_s
      return failure("The layout is over #{MAX_BYTES / 1024} KB.") if text.bytesize > MAX_BYTES

      data = begin
        Psych.safe_load(text, permitted_classes: [], aliases: false)
      rescue Psych::Exception, Psych::SyntaxError => e
        line = e.respond_to?(:line) ? e.line : nil
        column = e.respond_to?(:column) ? e.column : nil
        problem = e.respond_to?(:problem) ? e.problem : e.message
        return failure(line ? "Line #{line}, column #{column}: #{problem}." : "The YAML did not parse: #{problem}.")
      end
      return failure("The layout must be a mapping with `layout` and `panels`.") unless data.is_a?(Hash)

      version = data["layout"]
      if version.is_a?(Integer) && version > VERSION
        return failure("`layout: #{version}` is newer than this server, which reads version #{VERSION}.")
      end
      return failure("`layout: #{VERSION}` is required at the top.") unless version == VERSION

      unknown = data.keys.map(&:to_s) - %w[layout panels]
      return failure("Unknown key “#{unknown.first}” at the top level.") if unknown.any?
      return failure("`panels` must be a list.") unless data["panels"].is_a?(Array)

      merge(data["panels"], :yaml)
    end

    # --- from_draft: the browser's JSON in ----------------------------------------------------------

    def from_draft(hash)
      return failure("Not a layout draft.") unless hash.is_a?(Hash) && hash["panels"].is_a?(Array)

      merge(hash["panels"], :draft)
    end

    # --- the column -------------------------------------------------------------------------------

    def column(draft)
      panels = draft["panels"]
      { "order" => panels.map { |e| e["key"] },
        "hidden" => panels.select { |e| e["hidden"] }.map { |e| e["key"] },
        "views" => panels.filter_map { |e| [ e["key"], e["view"] ] if e["view"] }.to_h,
        "widths" => panels.to_h { |e| [ e["key"], e["width"] ] },
        "titles" => panels.filter_map { |e| [ e["key"], e["title"] ] if e["title"] }.to_h,
        "intros" => panels.filter_map { |e| [ e["key"], e["intro"] ] if e["intro"] }.to_h }
    end

    private

    def entry(key)
      e = { "key" => key, "hidden" => @layout.hidden?(key), "width" => @layout.width_for(key) }
      e["view"] = @layout.view_for(key) if Maker::ProjectKind.offered_views(key).any?
      e["title"] = @layout.titles[key] if @layout.titles[key]
      e["intro"] = @layout.intros[key] if @layout.intros[key]
      e
    end

    def failure(message) = Result.new(draft: draft, notes: [], errors: [ message ])

    # The merge, shared by both doors. `source` says how an entry names its panel: `:yaml` by
    # `panel:`/`folder:` (names), `:draft` by `key`. Everything after the key is one code path.
    def merge(raw_entries, source)
      notes, errors = [], []
      current = draft["panels"].to_h { |e| [ e["key"], e ] }
      listed = []

      raw_entries.each_with_index do |raw, i|
        n = i + 1
        unless raw.is_a?(Hash)
          errors << "Entry #{n} is not a mapping."
          next
        end
        raw = raw.to_h { |k, v| [ k.to_s, v ] }
        key = source == :yaml ? key_from_yaml(raw, n, notes, errors) : key_from_draft(raw, n, notes, errors)
        next unless key

        unknown = raw.keys - (source == :yaml ? %w[panel folder] : %w[key]) - ATTRIBUTES
        errors << "Entry #{n}: unknown attribute “#{unknown.first}”." if unknown.any?
        if listed.any? { |k, _| k == key }
          errors << "Entry #{n} names #{label(key)} a second time."
          next
        end
        listed << [ key, apply(current.fetch(key), raw, key, n, notes, errors) ]
      end
      return Result.new(draft: draft, notes: notes, errors: errors) if errors.any?

      ordered = listed.map(&:last) + (current.keys - listed.map(&:first)).map { |k| current[k] }
      if listed.any? { |k, _| k == "publish" } && ordered.last["key"] != "publish"
        publish = ordered.find { |e| e["key"] == "publish" }
        ordered = (ordered - [ publish ]) + [ publish ]
        notes << "Publish is always last; it was moved to the end."
      end
      Result.new(draft: { "layout" => VERSION, "panels" => ordered }, notes: notes, errors: errors)
    end

    def key_from_yaml(raw, n, notes, errors)
      if raw.key?("panel") && raw.key?("folder")
        errors << "Entry #{n} names both `panel` and `folder`; use one."
        return nil
      end
      if raw.key?("panel")
        key = raw["panel"].to_s
        return key if Maker::Project::PANELS.include?(key)

        errors << "Entry #{n}: unknown panel “#{key}”."
        return nil
      end
      if raw.key?("folder")
        name = raw["folder"].to_s
        id = @names.key(name)
        return Maker::ProjectKind.folder_key(id) if id && @layout.order.include?(Maker::ProjectKind.folder_key(id))

        notes << "This project has no folder named “#{name}”; that entry was skipped."
        return nil
      end
      errors << "Entry #{n} names neither `panel` nor `folder`."
      nil
    end

    def key_from_draft(raw, n, notes, errors)
      key = raw["key"].to_s
      return key if @layout.order.include?(key)

      if @layout.folder?(key)
        # A FOLDER RENAMED ON DISK MID-EDIT (share/s3 mint a new dir id on rename — the layout's
        # own header): the key left the vocabulary between the page render and this Save.
        notes << "A folder changed on disk while you were editing; its panel keeps its defaults."
      else
        errors << "Entry #{n}: unknown panel “#{key}”."
      end
      nil
    end

    # An attribute GIVEN replaces; one absent keeps `base`'s value. A given blank title or intro
    # clears it. `hidden: true` on an always-shown panel is a note, never an error, because a
    # shared layout may reasonably carry it.
    def apply(base, raw, key, n, notes, errors)
      e = base.dup
      if raw.key?("title")
        title = text(raw["title"])
        errors << "Entry #{n}: the title is over #{Maker::ProjectKind::TITLE_MAX} characters." if title.length > Maker::ProjectKind::TITLE_MAX
        if title.empty?
          e.delete("title")
        else
          e["title"] = title
        end
      end
      if raw.key?("intro")
        intro = text(raw["intro"])
        errors << "Entry #{n}: the intro is over #{Maker::ProjectKind::INTRO_MAX} characters." if intro.length > Maker::ProjectKind::INTRO_MAX
        if intro.empty?
          e.delete("intro")
        else
          e["intro"] = intro
        end
      end
      if raw.key?("width")
        width = raw["width"].to_s
        if Maker::ProjectKind::WIDTHS.include?(width)
          e["width"] = width
        else
          errors << "Entry #{n}: width must be full or half."
        end
      end
      if raw.key?("view") && !raw["view"].nil?
        view = raw["view"].to_s
        offered = Maker::ProjectKind.offered_views(key)
        if offered.empty?
          errors << "Entry #{n}: #{label(key)} has no view."
        elsif offered.include?(view)
          e["view"] = view
        else
          errors << "Entry #{n}: #{label(key)} does not offer the #{view} view."
        end
      end
      if raw.key?("hidden")
        hidden = raw["hidden"]
        if [ true, false ].include?(hidden)
          if hidden && Maker::ProjectKind::ALWAYS.include?(key)
            notes << "#{label(key)} is always shown; `hidden` was ignored."
            e["hidden"] = false
          else
            e["hidden"] = hidden
          end
        else
          errors << "Entry #{n}: hidden must be true or false."
        end
      end
      e
    end

    def text(value) = value.to_s.gsub(/\s+/, " ").strip

    def label(key)
      @layout.folder?(key) ? @names.fetch(@layout.folder_id(key), key) : Maker::Project::PANEL_LABELS.fetch(key, key)
    end
  end
end
```

- [ ] **Step 4: Run it green**

```bash
bin/rails test test/services/maker/layout_document_test.rb
```
Expected: all green. Two things most likely to need a touch, and how to read them: the `to_yaml`
assertions pin Psych's exact output (`- panel:` at column 0 under `panels:`, single quotes around a
scalar with a colon) — if Psych on this Ruby differs, change the TEST's expected strings to what
`Psych.dump` produces and keep the round-trip test as the real guard; and the `Line 4, column`
assertion depends on `Psych::SyntaxError#line` — if the message has no line, assert `/did not parse/`.

- [ ] **Step 5: Mutation-check** — five, each restored with Edit, `rm -rf tmp/cache/bootsnap*` after:
  1. In `merge`, replace `(current.keys - listed.map(&:first))` with `[]` → "unlisted panels follow" red.
  2. In `key_from_yaml`, change the unknown-panel `errors <<` to `notes <<` → the error-cases test red on `tsaks`.
  3. In `apply`, delete the `ALWAYS` branch → "hidden on an always-shown panel" red.
  4. In `parse`, delete the `MAX_BYTES` check → error-cases red on "over 16 KB".
  5. In `column`, change `"widths" => panels.to_h …` to `{}` → the column test red.

- [ ] **Step 6: Commit**

```bash
git add app/services/maker/layout_document.rb test/services/maker/layout_document_test.rb
git commit -F- <<'MSG'
Maker::LayoutDocument: one grammar for the draft, the YAML and the column

Folders by name in the text and by node id everywhere else; Apply merges rather than replaces;
unknown panels, attributes and values are errors, a missing folder or a hidden always-shown panel a
note; safe_load, no classes, 16 KB. Nothing renders it yet (spec 2026-09-09-page-editor §4).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task C: the edit page, the three doors, the slot wrapper, the chooser retired

**Files:**
- Modify: `config/routes.rb` (the `resources :projects` block)
- Modify: `app/controllers/projects_controller.rb` (`show`)
- Create: `app/controllers/concerns/projects/layout_scoped.rb`
- Modify: `app/controllers/projects/panels_controller.rb`
- Create: `app/controllers/projects/layouts_controller.rb`
- Modify: `app/views/projects/show.html.erb`
- Create: `app/views/projects/_panel_slot.html.erb`, `_panel_body.html.erb`, `_panel_strip.html.erb`, `_layout_bar.html.erb`, `_layout_drawer.html.erb`
- Delete: `app/views/projects/_panel_chooser.html.erb`
- Modify: `app/assets/stylesheets/pages/projects.css` (the grid rule and the chooser rules)
- Modify: `app/models/maker/project.rb` (one comment line)
- Test: `test/integration/web/project_panels_test.rb` (rewrite), create `test/integration/web/project_layout_editor_test.rb`, modify `test/integration/web/page_query_budget_test.rb`

- [ ] **Step 1: Write the failing editor tests** — create `test/integration/web/project_layout_editor_test.rb`:

```ruby
require "test_helper"

module Web
  # THE PAGE EDITOR'S SERVER HALF (2026-09-09; spec §5): the edit page, its three doors and the
  # document write. What the BROWSER does with them — dragging, the drawer, Save — is
  # test/system/page_editor_test.rb; everything here is markup the server writes and the row that
  # comes back.
  class ProjectLayoutEditorTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "editor-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
      @models = dir!("models", @folder.node_id)
      file!("base.stl", @models.node_id)
    end

    def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
    def models_key = Maker::ProjectKind.folder_key(@models.node_id)
    def order = @project.panel_layout(folders: [ [ @models.node_id, false ] ]).order

    # --- the edit page ---------------------------------------------------------------------------

    test "the edit page is the project page with the chrome on, one slot per panel, hidden ones included" do
      @project.update!(panels: { "hidden" => %w[tasks] })

      get edit_layout_project_path(@project)

      assert_response :success
      assert_select "div.layout-editor[data-controller=layout-editor]" do
        assert_select "[data-layout-editor-yaml-url-value=?]", yaml_project_layout_path(@project)
        assert_select "[data-layout-editor-parse-url-value=?]", parse_project_layout_path(@project)
        assert_select "[data-layout-editor-panel-url-value=?]", layout_panel_project_path(@project)
        assert_select "div.layout-bar form.layout-save[action=?] input[name=layout]", project_panels_path(@project)
        assert_select "div.project-panels.layout-editing div.panel-slot", order.size
        assert_select "div.panel-slot[data-key=tasks].panel-slot--hidden[data-hidden=true]", 1
        assert_select "div.panel-slot[data-key=publish].panel-slot--pinned", 1
        assert_select "div.panel-slot[data-key=?][data-width=full]", models_key, 1
        assert_select "div.panel-slot[data-key=tasks][data-width=half]", 1
        assert_select "aside.layout-drawer[hidden] textarea[data-layout-editor-target=yaml]", 1
      end
      assert_select "section.tasks-panel", 1, "a hidden panel is rendered, ghosted, in edit mode"
    end

    test "the strip offers what the panel offers: a view switch for Files and folders only, no eye on always-shown" do
      get edit_layout_project_path(@project)

      assert_select "div.panel-slot[data-key=attachments] .panel-strip" do
        assert_select "button[data-action='layout-editor#view'][data-view=tiles]", 1
        assert_select "button[data-action='layout-editor#view'][data-view=list]", 1
        assert_select "button[data-action='layout-editor#view'][data-view=browser]", count: 0
        assert_select "button[data-action='layout-editor#toggleHidden']", count: 0
        assert_select ".panel-strip-always", 1
      end
      assert_select "div.panel-slot[data-key=?] .panel-strip button[data-view=browser]", models_key, 1
      assert_select "div.panel-slot[data-key=tasks] .panel-strip" do
        assert_select "button[data-action='layout-editor#view']", count: 0
        assert_select "button[data-action='layout-editor#toggleHidden']", 1
        assert_select "button[data-action='layout-editor#width'][data-width=half].active", 1
        assert_select "details.panel-strip-edit input[maxlength=?]", Maker::ProjectKind::TITLE_MAX.to_s
      end
      assert_select "div.panel-slot[data-key=publish] .panel-strip button[data-action='layout-editor#up']", count: 0
    end

    test "a panel that renders nothing gets a placeholder in edit mode and no slot on the page" do
      get edit_layout_project_path(@project)
      assert_select "div.panel-slot[data-key=photos] section.panel--placeholder h2", text: "Photos"

      get project_path(@project)
      assert_select "div.panel-slot[data-key=photos]", count: 0
      assert_select "section.photos-panel", count: 0
    end

    test "the normal page wraps every visible panel in a slot with its width, and carries no chrome" do
      get project_path(@project)

      assert_select "div.project-panels > div.panel-slot.panel--full > section.attachments-panel", 1
      assert_select "div.project-panels > div.panel-slot.panel--half > section.tasks-panel", 1
      assert_select "div.project-panels > div.panel-slot.panel--full > section.folder-panel", 1
      assert_select ".panel-strip", count: 0
      assert_select ".layout-bar", count: 0
      assert_select "details.panel-chooser", count: 0
      assert_select "#panel-visibility", count: 0
      assert_select "a.customise-link[href=?]", edit_layout_project_path(@project), text: "Customise page"
    end

    test "the edit page and the doors are the owner's alone" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      get edit_layout_project_path(theirs)
      assert_response :not_found
      post yaml_project_layout_path(theirs), params: { draft: "{}" }
      assert_response :not_found
      post parse_project_layout_path(theirs), params: { yaml: "layout: 1\npanels: []\n" }
      assert_response :not_found
      get layout_panel_project_path(theirs, panel: "attachments", view: "list")
      assert_response :not_found
    end

    # --- one panel's body ---------------------------------------------------------------------------

    test "layout/panel renders one panel's body for a view the draft chose, and nothing else" do
      get layout_panel_project_path(@project, panel: models_key, view: "list")

      assert_response :success
      assert_select "section.folder-panel", 1
      assert_includes response.body, "base.stl", "the folder's file is listed"
      assert_select ".layout-bar", count: 0
      assert_select ".panel-strip", count: 0
      assert_select "div.panel-slot", count: 0, "the body alone, never the slot around it"
      assert_select "div.attachments-grid", count: 0, "the list view, not the tiles the row is saved with"
    end

    test "layout/panel refuses a view the panel does not offer and a key that is not a panel" do
      get layout_panel_project_path(@project, panel: "attachments", view: "browser")
      assert_response :not_found
      get layout_panel_project_path(@project, panel: "tasks", view: "list")
      assert_response :not_found
      get layout_panel_project_path(@project, panel: "folder:nope", view: "list")
      assert_response :not_found
    end

    # --- the drawer's two conversions -------------------------------------------------------------

    test "yaml answers text/plain YAML for the posted draft, and the current layout for a broken one" do
      draft = { layout: 1, panels: [ { key: "tasks", hidden: true, width: "full" } ] }
      post yaml_project_layout_path(@project), params: { draft: draft.to_json }

      assert_response :success
      assert_equal "text/plain", response.media_type
      assert_includes response.body, "# Desk Lamp, page layout."
      assert_includes response.body, "- panel: tasks\n  width: full\n  hidden: true\n"
      assert_includes response.body, "- folder: models\n"

      post yaml_project_layout_path(@project), params: { draft: "not json" }
      assert_response :success
      assert_includes response.body, "- panel: attachments\n  width: full\n  view: tiles\n"
    end

    test "parse answers the draft with notes and errors as JSON, 200 either way" do
      post parse_project_layout_path(@project), params: { yaml: "layout: 1\npanels:\n  - folder: models\n    view: list\n  - folder: enclosure\n" }, as: :json

      assert_response :success
      body = response.parsed_body
      assert_equal [], body["errors"]
      assert_equal [ "This project has no folder named “enclosure”; that entry was skipped." ], body["notes"]
      assert_equal "list", body["draft"]["panels"].find { |e| e["key"] == models_key }["view"]

      post parse_project_layout_path(@project), params: { yaml: "layout: 1\npanels:\n  - panel: tsaks\n" }, as: :json
      assert_response :success
      assert_match(/unknown panel/, response.parsed_body["errors"].first)
    end

    # --- Save --------------------------------------------------------------------------------------

    test "Save writes the whole document as six maps and lands on the page" do
      draft = { layout: 1, panels: [
        { key: models_key, hidden: false, width: "half", view: "list", title: "Prints", intro: "Sliced." },
        { key: "tasks", hidden: true, width: "full" },
        { key: "attachments", hidden: false, width: "full", view: "tiles" }
      ] }

      patch project_panels_path(@project), params: { layout: draft.to_json }

      assert_redirected_to project_path(@project)
      assert_equal "Page layout saved.", flash[:notice]
      panels = @project.reload.panels
      assert_equal [ models_key, "tasks", "attachments" ], panels["order"].first(3)
      assert_equal %w[tasks], panels["hidden"]
      assert_equal "list", panels["views"][models_key]
      assert_equal "half", panels["widths"][models_key]
      assert_equal "full", panels["widths"]["tasks"]
      assert_equal({ models_key => "Prints" }, panels["titles"])
      assert_equal({ models_key => "Sliced." }, panels["intros"])
      assert_equal "publish", panels["order"].last
    end

    test "Save drops a folder key that left the vocabulary, with a notice, and refuses a bad document" do
      draft = { layout: 1, panels: [ { key: "folder:gone", hidden: false, width: "full" }, { key: "tasks", hidden: true, width: "half" } ] }
      patch project_panels_path(@project), params: { layout: draft.to_json }

      assert_redirected_to project_path(@project)
      assert_match(/changed on disk/, flash[:notice])
      assert_equal %w[tasks], @project.reload.panels["hidden"]

      patch project_panels_path(@project), params: { layout: { layout: 1, panels: [ { key: "../etc" } ] }.to_json }
      assert_redirected_to edit_layout_project_path(@project)
      assert_match(/not saved/, flash[:alert])
      assert_equal %w[tasks], @project.reload.panels["hidden"], "a refused document writes nothing"

      patch project_panels_path(@project), params: { layout: "not json" }
      assert_redirected_to edit_layout_project_path(@project)
    end

    test "a bare PATCH with neither a view nor a document is a 400, and Reset clears every map" do
      patch project_panels_path(@project)
      assert_response :bad_request

      @project.update!(panels: { "hidden" => %w[tasks], "widths" => { "tasks" => "full" }, "titles" => { "tasks" => "X" } })
      delete project_panels_path(@project)
      assert_redirected_to project_path(@project)
      assert_nil @project.reload[:panels]
    end
  end
end
```

- [ ] **Step 2: Rewrite `test/integration/web/project_panels_test.rb`** — keep the header, the setup,
and ONLY these tests from the old file: "the door writes only known keys" family for the VIEW
branch and every `view[...]` test (lines from `# THE DOOR WRITES ONLY KNOWN KEYS` onward that post
`view:`); delete every test that renders `details.panel-chooser`, posts `move:` or `panels: { order:, visible: }`.
Replace the file's header comment with:

```ruby
  # STAGE 4, S4-7 (story 6.5), narrowed on 2026-09-09: the panels door's VIEW branch — the inline
  # tiles/list/browser toggle that still saves at once. The chooser and its move/visible branches
  # retired with the page editor (spec 2026-09-09-page-editor §2); the document write is tested
  # in project_layout_editor_test.rb.
```
Then run `bin/rails test test/integration/web/project_panels_test.rb` — the kept view tests must
still be green before you touch the controller (they exercise a branch this task keeps).

- [ ] **Step 3: Run the new file to see it fail**

```bash
bin/rails test test/integration/web/project_layout_editor_test.rb
```
Expected: errors — `NoMethodError: undefined method 'edit_layout_project_path'`.

- [ ] **Step 4: Routes** — in `config/routes.rb`, replace the `resource :panels, only: %i[update destroy], module: :projects` line and its comment with:

```ruby
    # THE PAGE'S LAYOUT (stage 4, S4-7; story 6.5; the page editor 2026-09-09, spec
    # docs/superpowers/specs/2026-09-09-page-editor-design.md). SINGULAR: one layout per project.
    # PATCH writes it — `view[<key>]` is the inline toggle, `layout=<draft JSON>` is the editor's
    # Save — and DELETE resets it by REMOVING the override, never by writing the current preset
    # into the row. `controller_path` is "projects/panels", so ShellHelper::SECTIONS needs no entry.
    resource :panels, only: %i[update destroy], module: :projects
    # THE EDITOR IS THE PAGE. `layout` renders projects#show in EDIT MODE — the same action, the
    # same loads, one flag from these defaults — so page_query_budget_test.rb pins both renders with
    # one budget. `layout/panel` renders ONE panel's body for a view the draft has chosen but not
    # saved, through the same action for the same reason: the Files panel reads a dozen ivars
    # #show loads, and nothing else can render it honestly.
    get :layout, on: :member, to: "projects#show", defaults: { editing: "1" }, as: :edit_layout
    get "layout/panel", on: :member, to: "projects#show", defaults: { editing: "1" }, as: :layout_panel
    # THE DRAWER'S TWO CONVERSIONS, read-only and owner-scoped: draft in, YAML out; YAML in, draft
    # with notes and errors out. Neither writes; Save is the panels door above.
    resource :layout, only: [], module: :projects do
      post :yaml
      post :parse
    end
```
Verify: `bin/rails routes -g layout` lists `edit_layout_project GET /projects/:id/layout`,
`layout_panel_project GET /projects/:id/layout/panel`, `yaml_project_layout POST /projects/:project_id/layout/yaml`,
`parse_project_layout POST /projects/:project_id/layout/parse`.

- [ ] **Step 5: The shared scope** — create `app/controllers/concerns/projects/layout_scoped.rb`:

```ruby
module Projects
  # WHAT THE PANELS DOOR AND THE DRAWER'S CONVERSIONS SHARE (2026-09-09, the page editor): the
  # owner's project by slug, a DIRS-ONLY listing for the vocabulary, and the one document over
  # them. Extracted rather than copied because two controllers building the same document from two
  # different listings is exactly how a folder key would exist for one door and not the other.
  #
  # NOT MEMOIZED PAST ONE REQUEST, for Maker::Project#panel_layout's own reason: the panels door
  # writes the column and could read the layout back in the same request.
  module LayoutScoped
    extend ActiveSupport::Concern

    included do
      before_action :set_project
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
      @listing = Maker::ProjectFolderListing.new(current_user, @project, load_files: false)
    end

    def layout = @project.panel_layout(folders: @listing.panel_folders)

    def document = Maker::LayoutDocument.new(layout, @listing.tree.to_h { |dir| [ dir.node_id, dir.name ] })

    def kind_label = Maker::ProjectKind.label(@project.kind)
  end
end
```

- [ ] **Step 6: The panels door** — rewrite `app/controllers/projects/panels_controller.rb`:

```ruby
module Projects
  # The project page's own panel layout: the inline view toggle, the editor's Save, reset (stage
  # 4, S4-7; story 6.5; folder panels 2026-09-08; the page editor 2026-09-09).
  #
  # IT WRITES ONLY KEYS FROM THE PROJECT'S OWN VOCABULARY, and that is structural rather than a
  # validation someone can loosen: a view pair is checked against this project's vocabulary and
  # against what THAT panel offers, and a document goes through Maker::LayoutDocument, which merges
  # into the CURRENT layout and so can only ever name keys the layout already holds. A crafted
  # request cannot put `../../etc/passwd` in the stored order and projects/show.html.erb's
  # `render "projects/#{key}"` can never be handed a partial name that does not exist.
  # Maker::ProjectKind.layout_for filters again on the way OUT, for the rows this door did not
  # write (the v1 API, a console, a later migration) — two filters, one at each end.
  #
  # ONE PATCH, TWO SHAPES. `view[<key>]=<view>` is the toggle in a panel's head and saves at once;
  # `layout=<draft JSON>` is the editor's Save and writes the whole arrangement in one update. The
  # chooser's `move` and `panels[order][]` shapes retired with the chooser itself (spec §2).
  class PanelsController < ApplicationController
    include LayoutScoped

    def update
      return update_view if params[:view].present?
      return replace if params[:layout].present?

      head :bad_request
    end

    # RESET MEANS REMOVE THE OVERRIDE, not "write the current preset into the column": the second
    # would freeze this release's defaults onto the row and stop the project following its own kind
    # — including after the maker changes that kind on the edit form. Views, widths, titles and
    # intros go with it, by the same argument: they are the arrangement, not a separate setting.
    def destroy
      @project.update!(panels: nil)
      redirect_to project_path(@project), notice: "Page layout reset to the #{kind_label} defaults."
    end

    private

    # THE EDITOR'S SAVE. The document is what the browser holds; LayoutDocument validates it against
    # the layout AS IT IS NOW, so a folder renamed on disk mid-edit (share/s3 mint a new dir id)
    # drops out with a note rather than refusing the whole save, and anything a browser of ours
    # would never send — an unknown fixed key, a view Files does not offer — refuses the write and
    # returns to the editor with the reasons. Nothing is written on a refusal.
    def replace
      result = document.from_draft(parsed_layout)
      if result.ok?
        @project.update!(panels: document.column(result.draft))
        redirect_to project_path(@project), notice: [ "Page layout saved.", *result.notes ].join(" ")
      else
        redirect_to edit_layout_project_path(@project), alert: "The layout was not saved: #{result.errors.join(' ')}"
      end
    end

    def parsed_layout
      JSON.parse(params[:layout].to_s)
    rescue JSON::ParserError
      nil
    end

    # ONE PANEL'S VIEW (2026-09-08, folder panels; spec decision 6). The pair is validated on BOTH
    # sides — the key against this project's vocabulary, the value against what that panel offers —
    # and an invalid pair writes NOTHING rather than raising. It MERGES into the stored views: one
    # click is about one panel, and the layout's other choices are none of its business.
    def update_view
      key, view = view_pair
      @project.update!(panels: stored.merge("views" => stored_views.merge(key => view))) if key
      # A refused pair redirects to the page with no anchor: `key` is the only thing that could
      # name one, and echoing an unvalidated key into the url is what this branch exists to refuse.
      redirect_to key ? project_path(@project, anchor: key) : project_path(@project)
    end

    def view_pair
      raw = params[:view]
      return [ nil, nil ] unless raw.is_a?(ActionController::Parameters)

      pairs = raw.to_unsafe_h
      return [ nil, nil ] unless pairs.size == 1

      key, view = pairs.first
      return [ nil, nil ] unless layout.order.include?(key.to_s) && Maker::ProjectKind.offered_views(key).include?(view.to_s)

      [ key.to_s, view.to_s ]
    end

    def stored = @project.panels.is_a?(Hash) ? @project.panels : {}

    def stored_views = stored["views"].is_a?(Hash) ? stored["views"] : {}
  end
end
```
Note `layout.order.include?` replaces the old `vocabulary.include?` — the layout's order IS the
vocabulary (total), so the door and the document read one list.

- [ ] **Step 7: The conversions** — create `app/controllers/projects/layouts_controller.rb`:

```ruby
module Projects
  # THE DRAWER'S TWO CONVERSIONS (2026-09-09, the page editor; spec §5). Both are READ-ONLY: a draft
  # in, YAML out; YAML in, a draft plus notes and errors out. Neither touches the column — Save is
  # PanelsController#update's document branch — and Maker::LayoutDocument is the one grammar the
  # three share, which is why the browser never parses or emits YAML itself (spec decision 2).
  #
  # `parse` ANSWERS 200 WITH ERRORS, deliberately: the browser shows them beside the text, and a
  # 4xx would read as the endpoint failing rather than the text. `yaml` for a draft that does not
  # validate answers the CURRENT layout's text rather than an error, because the only way to send
  # one is by hand, and the honest answer to "show me the YAML" is still some YAML.
  class LayoutsController < ApplicationController
    include LayoutScoped

    def yaml
      result = document.from_draft(parsed_draft)
      text = document.to_yaml(result.ok? ? result.draft : document.draft, project_name: @project.name)
      render plain: text, content_type: "text/plain"
    end

    def parse
      result = document.parse(params[:yaml].to_s)
      render json: { draft: result.draft, notes: result.notes, errors: result.errors }
    end

    private

    def parsed_draft
      raw = params[:draft]
      raw.is_a?(String) ? JSON.parse(raw) : raw.to_unsafe_h
    rescue JSON::ParserError
      nil
    end
  end
end
```
(`params[:draft]` is a String when posted as a form field and `ActionController::Parameters` when
posted as JSON; the editor posts JSON, the test posts a form field — both must work.)

- [ ] **Step 8: `ProjectsController#show`** — after the `@panel_labels = …` statement add:

```ruby
    # EDIT MODE (2026-09-09, the page editor; spec §5). `editing` arrives only as the DEFAULT of the
    # two `layout` routes; it turns on the chrome and nothing else — every load below is the same,
    # which is what lets page_query_budget_test.rb pin the edit page with the page's own budget.
    @editing = params[:editing] == "1"
    # ONE PANEL FOR A VIEW THE DRAFT CHOSE BUT HAS NOT SAVED (`layout/panel`). The layout is
    # overridden IN MEMORY for this render alone — Data#with, never a write — and only for a panel
    # that offers views and a view it offers; anything else is a 404, because the only client is
    # our own controller and a wrong pair from it is a bug to surface, not a page to render.
    if @editing && params[:panel].present?
      @panel_key = params[:panel].to_s
      wanted = params[:view].to_s
      offered = Maker::ProjectKind.offered_views(@panel_key)
      raise ActiveRecord::RecordNotFound unless @panel_layout.order.include?(@panel_key) && offered.include?(wanted)

      @panel_layout = @panel_layout.with(views: @panel_layout.views.merge(@panel_key => wanted))
    end
```
Delete the `@panels_open = params[:panels] == "open"` statement and its comment. At the END of
`show` (after `@scan_started = …`) add:

```ruby
    # `layout/panel` renders the one body and stops; the whole page is the default render.
    render partial: "projects/panel_body", locals: { key: @panel_key, extra: {} }, layout: false if @panel_key
```
Check that `ActiveRecord::RecordNotFound` renders a 404 in the test env the way `find_by!` does
elsewhere in this controller (`config.action_dispatch.show_exceptions` is `:rescuable` in test) —
the owner test in Step 1 pins it.

- [ ] **Step 9: The views** — in `app/views/projects/show.html.erb`:

Replace the `<%= link_to (@project.published? ? "Publishing" : "Publish"), "#publish", … %>` line's
neighbourhood: after the `head-actions` `Edit` link add
```erb
    <%# THE PAGE EDITOR (2026-09-09): the same page with the chrome on. A link, because entering
        edit mode changes nothing until Save. %>
    <%= link_to "Customise page", edit_layout_project_path(@project), class: "btn small customise-link" %>
```
Replace everything from `<% panel_locals = {` to the end of the file with:

```erb
<% panel_locals = {
     "wiring"   => { project: @project, connections: @connections, editable: true, layout: @panel_layout },
     "releases" => { project: @project, releases: @releases, current_tokens: @release_tokens,
                     repos: @release_repos, editable: true },
     "publish"  => { project: @project, folder_path: (@listing.path if @listing&.available?) }
   } %>
<%#
  EVERY PANEL RENDERS INSIDE A SLOT (2026-09-09, the page editor; spec §3 and §5): projects/
  _panel_slot wraps the panel in `div.panel-slot.panel--<width>` on the normal page, and in edit
  mode adds the strip and the data attributes the layout_editor controller reads its draft from.
  The width used to be a stylesheet rule naming three panel classes; it is the layout's answer now.

  IN EDIT MODE THE LOOP IS `order`, NOT `visible`: a hidden panel renders ghosted in its place so
  it can be dragged and shown again. Its data was not loaded (the controller skips a hidden
  panel's queries), so it renders quiet — which is the honest ghost.
%>
<% if @editing %>
  <div class="layout-editor" data-controller="layout-editor"
       data-layout-editor-yaml-url-value="<%= yaml_project_layout_path(@project) %>"
       data-layout-editor-parse-url-value="<%= parse_project_layout_path(@project) %>"
       data-layout-editor-panel-url-value="<%= layout_panel_project_path(@project) %>">
    <%= render "projects/layout_bar" %>
    <div class="project-panels layout-editing" data-layout-editor-target="grid">
      <% @panel_layout.order.each do |key| %>
        <%= render "projects/panel_slot", key:, extra: panel_locals.fetch(key, {}) %>
      <% end %>
    </div>
    <%= render "projects/layout_drawer" %>
  </div>
<% else %>
  <div class="project-panels">
    <% @panel_layout.visible.each do |key| %>
      <%= render "projects/panel_slot", key:, extra: panel_locals.fetch(key, {}) %>
    <% end %>
  </div>
<% end %>
```
(The old `<%# THE PANELS, AS DATA … %>` header comment above `panel_locals` stays; append one line
to it: `THE SLOT (2026-09-09): see projects/_panel_slot.html.erb.`)

Create `app/views/projects/_panel_body.html.erb`:
```erb
<%#
  THE PANEL ITSELF, BY KEY (2026-09-09, the page editor). The fixed branch is the interpolated
  render projects/show.html.erb has always done, reached only for keys in Maker::Project::PANELS;
  a folder key renders projects/_folder_panel with the Dir it names. Also what `layout/panel`
  renders alone, for a view the draft has chosen — ProjectsController#show overrides
  @panel_layout's view for that one key before rendering this.

  Locals: key; extra (the locals map for wiring/releases/publish, `{}` for every other key).
%>
<% if @panel_layout.folder?(key) %>
  <%= render "projects/folder_panel", key:, view: @panel_layout.view_for(key),
             dir: @listing.tree.find { |d| d.node_id == @panel_layout.folder_id(key) } %>
<% else %>
  <%= render "projects/#{key}", **extra %>
<% end %>
```

Create `app/views/projects/_panel_slot.html.erb`:
```erb
<%#
  ONE PANEL'S SLOT (2026-09-09, the page editor; spec §3, §5). The grid item is this div, not the
  panel's own section, so the width class comes from the layout without ten partials learning
  about widths, and so edit mode can hang a control strip and a ghost state on any panel without
  touching what the panel renders.

  THE BODY IS CAPTURED FIRST. Photos and Schematics render NOTHING when they have nothing to show;
  on the normal page an empty slot would still occupy a grid cell, so a blank body renders no slot
  at all — exactly the page before slots existed. In edit mode the same blank body renders a
  PLACEHOLDER instead, because a panel that cannot be seen cannot be arranged.

  THE DATA ATTRIBUTES ARE THE DRAFT. layout_editor_controller.js reads its state off these slots
  and writes changes back to them; there is no second copy of the layout in the page.
  `data-view` is present only for a panel that offers views (Maker::ProjectKind.offered_views).

  Locals: key; extra (passed through to projects/_panel_body).
%>
<% body = render "projects/panel_body", key:, extra: %>
<% width = @panel_layout.width_for(key) %>
<% if @editing %>
  <% hidden = @panel_layout.hidden?(key) %>
  <% offered = Maker::ProjectKind.offered_views(key) %>
  <div class="panel-slot panel--<%= width %><%= " panel-slot--hidden" if hidden %><%= " panel-slot--pinned" if key == "publish" %>"
       data-layout-editor-target="slot" data-key="<%= key %>" data-hidden="<%= hidden %>" data-width="<%= width %>"
       data-view="<%= @panel_layout.view_for(key) if offered.any? %>"
       data-title="<%= @panel_layout.titles[key] %>" data-intro="<%= @panel_layout.intros[key] %>"
       data-always="<%= Maker::ProjectKind::ALWAYS.include?(key) %>">
    <%= render "projects/panel_strip", key:, hidden:, width:, offered: %>
    <div class="panel-slot-body" data-layout-editor-target="body">
      <% if body.blank? %>
        <section class="panel panel--placeholder">
          <h2><%= @panel_layout.title_for(key, @panel_labels.fetch(key)) %></h2>
          <p class="muted">Nothing here yet. This panel appears on the page once it has something to show.</p>
        </section>
      <% else %>
        <%= body %>
      <% end %>
    </div>
  </div>
<% elsif body.present? %>
  <div class="panel-slot panel--<%= width %>"><%= body %></div>
<% end %>
```

Create `app/views/projects/_panel_strip.html.erb`:
```erb
<%#
  THE CONTROL STRIP ALONG A PANEL'S TOP EDGE, IN EDIT MODE (2026-09-09; spec §2). Every control is
  a plain <button> the layout_editor controller handles — no forms, because nothing here writes:
  the draft lives in the slot's data attributes until Save. Up/Down are always present, quiet, so
  ordering is never mouse-only. An always-shown panel says so where the eye would be; Publish has
  no Up/Down because it is always last (spec decision 11). The view switch renders only the views
  THIS panel offers, from the same list the door validates against.

  Locals: key, hidden, width, offered (Maker::ProjectKind.offered_views(key)).
%>
<% label = @panel_labels.fetch(key) %>
<% always = Maker::ProjectKind::ALWAYS.include?(key) %>
<div class="panel-strip">
  <span class="panel-strip-handle" title="Drag to move" aria-hidden="true">⋮⋮</span>
  <span class="panel-strip-name">
    <b data-layout-editor-target="name"><%= @panel_layout.title_for(key, label) %></b>
    <% if @panel_layout.folder?(key) %><span class="mono muted"><%= label %>/</span><% end %>
  </span>
  <span class="panel-strip-controls">
    <% unless key == "publish" %>
      <button type="button" class="linkbtn small" data-action="layout-editor#up" aria-label="Move <%= label %> up">▲</button>
      <button type="button" class="linkbtn small" data-action="layout-editor#down" aria-label="Move <%= label %> down">▼</button>
    <% end %>
    <% if always %>
      <span class="muted panel-strip-always">always shown</span>
    <% else %>
      <button type="button" class="linkbtn small" data-action="layout-editor#toggleHidden"
              data-layout-editor-target="eye"><%= hidden ? "Show" : "Hide" %></button>
    <% end %>
    <span class="view-toggle" role="group" aria-label="Width of <%= label %>">
      <% Maker::ProjectKind::WIDTHS.each do |w| %>
        <button type="button" class="toggle<%= " active" if width == w %>" data-action="layout-editor#width" data-width="<%= w %>"><%= w.capitalize %></button>
      <% end %>
    </span>
    <%# Below the two-column breakpoint every panel stacks, so the switch still WORKS but shows
        nothing until the window is wide — said here rather than left to be discovered (spec §2).
        Hidden at >= 900px by components.css. %>
    <span class="muted panel-strip-narrow">on wide screens</span>
    <% if offered.any? %>
      <span class="view-toggle" role="group" aria-label="View of <%= label %>">
        <% offered.each do |v| %>
          <button type="button" class="toggle<%= " active" if @panel_layout.view_for(key) == v %>" data-action="layout-editor#view" data-view="<%= v %>"><%= v.capitalize %></button>
        <% end %>
      </span>
    <% end %>
    <details class="panel-strip-edit">
      <summary class="linkbtn small" aria-label="Rename <%= label %>">✎</summary>
      <div class="panel-strip-popover">
        <label class="field"><span>Title</span>
          <input type="text" maxlength="<%= Maker::ProjectKind::TITLE_MAX %>" value="<%= @panel_layout.titles[key] %>"
                 placeholder="<%= label %>" data-action="input->layout-editor#title"></label>
        <label class="field"><span>Intro</span>
          <input type="text" maxlength="<%= Maker::ProjectKind::INTRO_MAX %>" value="<%= @panel_layout.intros[key] %>"
                 placeholder="One line under the heading" data-action="input->layout-editor#intro"></label>
      </div>
    </details>
  </span>
</div>
```

Create `app/views/projects/_layout_bar.html.erb`:
```erb
<%#
  THE EDIT MODE'S TOP BAR (2026-09-09; spec §2). Save is the ONE write: a real form to the panels
  door whose hidden `layout` field the controller fills with the draft on submit. Cancel is a link
  (nothing to undo server-side). Reset is the existing DELETE, after a confirm, because it removes
  the override rather than editing the draft. The noscript line is the whole of the no-JavaScript
  story (spec decision 8).
%>
<div class="layout-bar">
  <div class="layout-bar-text">
    <b>Editing page layout</b>
    <span class="muted">Drag panels by their handle. Half-width panels pair up on wide screens. Nothing is saved until you click Save.</span>
    <noscript><span class="layout-bar-noscript">The page editor needs JavaScript.</span></noscript>
  </div>
  <div class="layout-bar-actions">
    <button type="button" class="btn small" data-action="layout-editor#toggleDrawer" aria-expanded="false">Edit as YAML</button>
    <%= button_to "Reset to #{Maker::ProjectKind.label(@project.kind)} defaults", project_panels_path(@project),
                  method: :delete, class: "linkbtn small",
                  form: { data: { turbo_confirm: "Reset the page to its type's defaults? Order, hidden panels, views, widths, titles and intros all go back." } } %>
    <%= link_to "Cancel", project_path(@project), class: "btn small" %>
    <%= form_with url: project_panels_path(@project), method: :patch, class: "layout-save",
                  data: { layout_editor_target: "form", action: "submit->layout-editor#save" } do %>
      <%= hidden_field_tag :layout, "", data: { layout_editor_target: "draft" }, id: "layout-draft" %>
      <%= submit_tag "Save", class: "btn small primary" %>
    <% end %>
  </div>
</div>
```

Create `app/views/projects/_layout_drawer.html.erb`:
```erb
<%#
  THE YAML DRAWER (2026-09-09; spec §2, §4). Hidden until "Edit as YAML"; beside the page, never
  over it, so a drag on the left is watched on the right. The text is whatever the server rendered
  for the current draft (Projects::LayoutsController#yaml); Apply posts it back (#parse) and the
  controller adopts the draft that returns. Copy is the shared copy controller with its text
  value kept current by the editor.
%>
<aside class="layout-drawer" hidden data-layout-editor-target="drawer" aria-label="Layout as YAML">
  <div class="layout-drawer-head">
    <b>Layout as YAML</b>
    <span>
      <button type="button" class="btn small" data-controller="copy" data-copy-text-value=""
              data-action="copy#copy" data-layout-editor-target="copy">Copy</button>
      <button type="button" class="btn small primary" data-action="layout-editor#apply">Apply</button>
    </span>
  </div>
  <textarea class="layout-yaml" rows="24" spellcheck="false" aria-label="Layout YAML"
            data-layout-editor-target="yaml"></textarea>
  <div class="layout-drawer-notes" data-layout-editor-target="notes" aria-live="polite"></div>
  <p class="muted">Apply updates the page behind this drawer; nothing is saved until Save. A layout naming a folder this project lacks is applied without that entry, and says so here.</p>
</aside>
```

Delete `app/views/projects/_panel_chooser.html.erb` (`git rm`).

- [ ] **Step 10: The stylesheet's grid rule and the chooser's rules** — in `app/assets/stylesheets/pages/projects.css`:

Replace lines 51–53 (`.project-panels { display: grid; …}` through the `@media` line) with:
```css
  .project-panels { display: grid; grid-template-columns: 1fr; gap: 16px; }
  /* THE GRID ITEM IS THE SLOT (2026-09-09, the page editor): projects/_panel_slot wraps every panel
     in `div.panel-slot.panel--<width>`, and the width is the LAYOUT's answer (Maker::ProjectKind
     ::Layout#width_for) rather than this sheet naming three panel classes. `.panel` stays in the
     rule for the public page's repo cards, which render outside a slot. */
  .project-panels > .panel, .project-panels > .panel-slot { min-width: 0; }
  @media (min-width: 900px) { .project-panels { grid-template-columns: 1fr 1fr; } .project-panels > .panel-slot.panel--full { grid-column: 1 / -1; } }
```
Delete the `.panel-chooser`, `.panel-chooser > summary`, `.panel-chooser-note`, `.panel-choices`,
`.panel-choice`, `.panel-choice:last-child`, `.panel-choice-name`, `.panel-choice-always`,
`.panel-choice-moves` and `.panel-chooser-actions` rules (around lines 310–320) and any comment
block that introduces them. In the comment above `.folder-panel .panel-path` (the "Folder panels"
block) delete the sentence "FULL WIDTH, with Files and Photos, because …usable." and replace with
"Full width by default — Maker::ProjectKind.default_width, since the page editor."

In `app/models/maker/project.rb` line 210 change `projects/_panel_chooser` to `projects/_panel_slot`.

- [ ] **Step 11: Run the two integration files and the page's own suite**

```bash
bin/rails test test/integration/web/project_layout_editor_test.rb test/integration/web/project_panels_test.rb \
               test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb \
               test/integration/web/publishing_test.rb
```
Expected: green. If `project_page_test.rb` asserts `section.folder-panel` as a DIRECT child of
`.project-panels`, loosen it to a descendant — the slot is between them now, by design.
`test/system/shell_test.rb`'s phone sweep still opens the retired chooser and goes red from this
commit until Task D rewrites that block; that is expected and named here so a reviewer does not
chase it.

- [ ] **Step 12: The query budget** — in `test/integration/web/page_query_budget_test.rb`, after the
"hiding bom, wiring and releases skips their controller loads" test add:

```ruby
    # THE EDIT PAGE COSTS WHAT THE PAGE COSTS (2026-09-09, the page editor): the same action, one
    # flag, and a strip that reads only what the page already loaded. Measured as a difference with
    # the page rather than as a literal, so the three legs' differing baselines cannot pin one.
    test "projects#show in edit mode costs no more queries than the page, and stays constant in folders" do
      project = @user.maker_projects.create!(name: "Edit budget")
      folder = project_folder_rows!(@user, project)
      seed = lambda do |n|
        n.times do |i|
          dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "part-#{i}", kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
          @user.nodes.create!(node_id: SecureRandom.uuid, name: "f-#{i}.stl", kind: "file", parent_node_id: dir.node_id, mtime: 1, size: 3)
        end
      end

      seed.call(1)
      get edit_layout_project_path(project) # warm-up
      get project_path(project)
      page = count_queries { get project_path(project) }
      small = count_queries { get edit_layout_project_path(project) }
      seed.call(3)
      get edit_layout_project_path(project)
      large = count_queries { get edit_layout_project_path(project) }

      assert_operator small, :<=, page + 1, "edit mode: #{small} vs page: #{page}"
      assert_equal small, large, "the edit page must not grow with folders (#{small} → #{large})"
    end
```
Run: `bin/rails test test/integration/web/page_query_budget_test.rb` — green. If `small` exceeds
`page + 1`, find the strip's query (it should read `@panel_labels`, the layout and nothing else).

- [ ] **Step 13: Mutation-check** — five, restore each with Edit, clear bootsnap:
  1. In `_panel_slot`, change `<% elsif body.present? %>` to `<% else %>` → "no slot on the page" red.
  2. In `show`, delete `raise ActiveRecord::RecordNotFound unless …` → the refuses-a-view test red.
  3. In `replace`, change `if result.ok?` to `if true` → "refuses a bad document" red.
  4. In `_panel_slot`, drop `<%= " panel-slot--pinned" if key == "publish" %>` → the first edit-page test red.
  5. In `LayoutScoped#set_project`, change `current_user.maker_projects` to `Maker::Project` → the owner test red.

- [ ] **Step 14: Commit**

```bash
git add -A config/routes.rb app/controllers app/views/projects app/assets/stylesheets/pages/projects.css app/models/maker/project.rb test/integration/web
git commit -F- <<'MSG'
The project page has an edit mode, a slot per panel with its width, and the chooser is retired

/projects/<slug>/layout is projects#show with the chrome on: a strip along each panel's top edge,
the Save form, the YAML drawer, and every panel — hidden ones ghosted — rendered inside a
div.panel-slot that carries the layout's width. The same slot wraps the normal page, so the grid
rule keys on `panel--full` instead of naming three panel classes. Two read-only conversions
(Projects::LayoutsController#yaml, #parse) and one write (the panels door's `layout` document
branch) sit behind Maker::LayoutDocument; the chooser's checkbox form and its move/visible door
branches go. No JavaScript yet: the strip's buttons do nothing until layout_editor lands.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task D: the client — SortableJS, `layout_editor_controller.js`, the editor's styles, the browser suite

**Files:**
- Modify: `config/importmap.rb`
- Create: `vendor/javascript/sortablejs.js` (downloaded), `vendor/javascript/LICENSE-sortablejs.md`
- Create: `app/javascript/controllers/layout_editor_controller.js`
- Modify: `app/assets/stylesheets/components.css`
- Modify: `test/css_hygiene_test.rb` (the component list), `test/system/shell_test.rb` (the chooser sweep)
- Create: `test/system/page_editor_test.rb`

- [ ] **Step 1: Vendor SortableJS**

```bash
bin/importmap pin sortablejs@1.15.7 --download
grep -c "export default" vendor/javascript/sortablejs.js
grep -c "^import " vendor/javascript/sortablejs.js
```
Expected: the pin line `pin "sortablejs" # @1.15.7` appears in `config/importmap.rb`; the first
grep prints ≥ 1 and the second prints 0. If the downloaded file has no default export, run
`bin/importmap unpin sortablejs` and pin the ESM build instead:
`bin/importmap pin sortablejs@1.15.7/modular/sortable.esm.js --download`, then rename the pin's
specifier to `sortablejs` and the file to `vendor/javascript/sortablejs.js` (the jszip pin in the
same file records the identical manoeuvre). Move the pin line beside the jszip pin and comment it:

```ruby
# SortableJS 1.15.7 — MIT — https://github.com/SortableJS/Sortable. Drag-to-reorder for the page
# editor (layout_editor_controller.js). Vendored via `bin/importmap pin sortablejs@1.15.7 --download`;
# licence in vendor/javascript/LICENSE-sortablejs.md. Hand-rolled pointer dragging was rejected for
# touch, auto-scroll and drop placement in a two-column grid (spec 2026-09-09-page-editor §5).
pin "sortablejs" # @1.15.7
```
Create `vendor/javascript/LICENSE-sortablejs.md` with the MIT text from
https://github.com/SortableJS/Sortable/blob/master/LICENSE (copyright Lebedev Konstantin), headed
`SortableJS 1.15.7 (MIT), vendored as vendor/javascript/sortablejs.js.` Run `bin/ci scan` — the
importmap audit must pass.

- [ ] **Step 2: The controller** — create `app/javascript/controllers/layout_editor_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"
import Sortable from "sortablejs"

// THE PAGE EDITOR (2026-09-09; spec docs/superpowers/specs/2026-09-09-page-editor-design.md §5).
//
// THE DRAFT LIVES IN THE SLOTS. Every `.panel-slot` carries data-key/-hidden/-width/-view/-title/
// -intro (projects/_panel_slot.html.erb); this controller reads the draft off them and writes each
// change back to them, so there is no second copy of the layout to fall out of step, and the DOM
// order of the slots IS the draft's order. Save serialises the slots into the form's hidden field;
// the drawer's text is whatever the server rendered for that same serialisation.
//
// THE BROWSER NEVER PARSES OR EMITS YAML (spec decision 2): the drawer refreshes by posting the
// draft to `yamlUrl` and Apply posts the text to `parseUrl`; both answer from the one grammar,
// Maker::LayoutDocument. A view change fetches that panel's body from `panelUrl` so the preview is
// the real tiles, list or browser.
//
// SORTABLE RUNS IN FALLBACK MODE (`forceFallback: true`): native HTML5 drag events cannot be driven
// by Selenium, so the browser suite could not prove dragging at all with them, and the fallback is
// also what makes touch work the same on every platform. The pinned Publish slot is filtered out
// of dragging and refused as a drop target (spec decision 11).
const YAML_DEBOUNCE_MS = 200
const TOAST_MS = 6000

export default class extends Controller {
  static targets = ["grid", "slot", "form", "draft", "drawer", "yaml", "notes", "copy"]
  static values = { yamlUrl: String, parseUrl: String, panelUrl: String }

  connect() {
    this.sortable = Sortable.create(this.gridTarget, {
      handle: ".panel-strip-handle",
      draggable: ".panel-slot",
      filter: ".panel-slot--pinned",
      ghostClass: "panel-slot--ghost",
      forceFallback: true,
      fallbackTolerance: 3,
      animation: 120,
      onMove: (evt) => !evt.related.classList.contains("panel-slot--pinned"),
      onEnd: () => this.changed()
    })
  }

  disconnect() {
    this.sortable?.destroy()
    clearTimeout(this.yamlTimer)
  }

  // --- the draft, read off the slots ---------------------------------------------------------

  draft() {
    return { layout: 1, panels: this.slotTargets.map((slot) => this.entry(slot)) }
  }

  entry(slot) {
    const d = slot.dataset
    const e = { key: d.key, hidden: d.hidden === "true", width: d.width }
    if (d.view) e.view = d.view
    if (d.title) e.title = d.title
    if (d.intro) e.intro = d.intro
    return e
  }

  slotOf(event) {
    return event.currentTarget.closest(".panel-slot")
  }

  changed() {
    this.refreshYaml()
  }

  // --- order -----------------------------------------------------------------------------------

  up(event) { this.step(this.slotOf(event), -1) }
  down(event) { this.step(this.slotOf(event), 1) }

  step(slot, delta) {
    const movable = this.slotTargets.filter((s) => !s.classList.contains("panel-slot--pinned"))
    const i = movable.indexOf(slot)
    const j = i + delta
    if (i < 0 || j < 0 || j >= movable.length) return
    if (delta < 0) movable[j].before(slot)
    else movable[j].after(slot)
    slot.querySelector(delta < 0 ? "[data-action='layout-editor#up']" : "[data-action='layout-editor#down']")?.focus()
    this.changed()
  }

  // --- hidden ------------------------------------------------------------------------------------

  toggleHidden(event) {
    const slot = this.slotOf(event)
    this.setHidden(slot, slot.dataset.hidden !== "true")
    this.changed()
  }

  setHidden(slot, hidden) {
    slot.dataset.hidden = String(hidden)
    slot.classList.toggle("panel-slot--hidden", hidden)
    const eye = slot.querySelector("[data-layout-editor-target=eye]")
    if (eye) eye.textContent = hidden ? "Show" : "Hide"
  }

  // --- width -------------------------------------------------------------------------------------

  width(event) {
    this.setWidth(this.slotOf(event), event.currentTarget.dataset.width)
    this.changed()
  }

  setWidth(slot, width) {
    slot.dataset.width = width
    slot.classList.toggle("panel--full", width === "full")
    slot.classList.toggle("panel--half", width === "half")
    this.activate(slot, "[data-width]", (b) => b.dataset.width === width)
  }

  // --- view --------------------------------------------------------------------------------------

  async view(event) {
    await this.setView(this.slotOf(event), event.currentTarget.dataset.view)
    this.changed()
  }

  // THE DRAFT KEEPS THE CHOSEN VIEW WHATEVER THE PREVIEW DOES: a failed fetch leaves the old body
  // on screen and says so, and Save still writes the view the maker asked for (spec §6).
  async setView(slot, view) {
    if (slot.dataset.view === view) return
    slot.dataset.view = view
    this.activate(slot, "[data-view]", (b) => b.dataset.view === view)
    const url = new URL(this.panelUrlValue, window.location.origin)
    url.searchParams.set("panel", slot.dataset.key)
    url.searchParams.set("view", view)
    try {
      const res = await fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      slot.querySelector("[data-layout-editor-target=body]").innerHTML = await res.text()
      this.applyTitle(slot, slot.dataset.title || "")
      this.applyIntro(slot, slot.dataset.intro || "")
    } catch (_e) {
      this.toast("The preview for that view did not load. The view is kept and applies on Save.")
    }
  }

  // --- title and intro -------------------------------------------------------------------------

  title(event) {
    const slot = this.slotOf(event)
    slot.dataset.title = event.currentTarget.value.trim()
    this.applyTitle(slot, slot.dataset.title)
    this.changed()
  }

  intro(event) {
    const slot = this.slotOf(event)
    slot.dataset.intro = event.currentTarget.value.trim()
    this.applyIntro(slot, slot.dataset.intro)
    this.changed()
  }

  applyTitle(slot, title) {
    const input = slot.querySelector(".panel-strip-popover input[data-action='input->layout-editor#title']")
    if (input && input.value.trim() !== title) input.value = title
    const name = title || input?.placeholder || slot.dataset.key
    const label = slot.querySelector("[data-layout-editor-target=name]")
    if (label) label.textContent = name
    const h2 = slot.querySelector(".panel-slot-body .panel h2")
    if (h2) h2.textContent = name
  }

  applyIntro(slot, intro) {
    const input = slot.querySelector(".panel-strip-popover input[data-action='input->layout-editor#intro']")
    if (input && input.value.trim() !== intro) input.value = intro
    const body = slot.querySelector(".panel-slot-body")
    let p = body?.querySelector(".panel-intro")
    if (!p && intro && body) {
      p = document.createElement("p")
      p.className = "panel-intro muted"
      const head = body.querySelector(".panel-head") || body.querySelector(".panel h2")
      head?.after(p)
    }
    if (p) {
      p.textContent = intro
      p.hidden = !intro
    }
  }

  // --- the drawer --------------------------------------------------------------------------------

  toggleDrawer(event) {
    const open = this.drawerTarget.hidden
    this.drawerTarget.hidden = !open
    event.currentTarget.setAttribute("aria-expanded", String(open))
    this.element.classList.toggle("layout-editor--drawer", open)
    if (open) this.refreshYaml(true)
  }

  refreshYaml(now = false) {
    clearTimeout(this.yamlTimer)
    if (this.drawerTarget.hidden) return
    this.yamlTimer = setTimeout(() => this.fetchYaml(), now ? 0 : YAML_DEBOUNCE_MS)
  }

  async fetchYaml() {
    try {
      const res = await this.post(this.yamlUrlValue, { draft: this.draft() })
      const text = await res.text()
      this.yamlTarget.value = text
      this.copyTarget.dataset.copyTextValue = text
    } catch (_e) {
      this.note(["The YAML view could not be refreshed."], [])
    }
  }

  async apply() {
    let data
    try {
      const res = await this.post(this.parseUrlValue, { yaml: this.yamlTarget.value })
      data = await res.json()
    } catch (_e) {
      this.note(["Apply failed: the server did not answer."], [])
      return
    }
    this.note(data.errors, data.notes)
    if (data.errors.length) return
    await this.adopt(data.draft)
  }

  // Re-append the slots in the draft's order (a slot the draft does not name — none, the merge is
  // total — would stay where it is), then apply every attribute, fetching bodies for changed views.
  async adopt(draft) {
    const byKey = new Map(this.slotTargets.map((s) => [s.dataset.key, s]))
    for (const e of draft.panels) {
      const slot = byKey.get(e.key)
      if (!slot) continue
      this.gridTarget.appendChild(slot)
      this.setHidden(slot, Boolean(e.hidden))
      this.setWidth(slot, e.width)
      slot.dataset.title = e.title || ""
      slot.dataset.intro = e.intro || ""
      this.applyTitle(slot, slot.dataset.title)
      this.applyIntro(slot, slot.dataset.intro)
      if (e.view) await this.setView(slot, e.view)
    }
    this.refreshYaml(true)
  }

  note(errors, notes) {
    this.notesTarget.replaceChildren()
    const add = (text, cls) => {
      const p = document.createElement("p")
      p.className = cls
      p.textContent = text
      this.notesTarget.appendChild(p)
    }
    errors.forEach((e) => add(e, "layout-note layout-note--error"))
    notes.forEach((n) => add(n, "layout-note"))
    if (!errors.length && !notes.length) add("Valid.", "layout-note layout-note--ok")
  }

  // --- Save ----------------------------------------------------------------------------------------

  save(_event) {
    this.draftTarget.value = JSON.stringify(this.draft())
  }

  // --- helpers -------------------------------------------------------------------------------------

  post(url, body) {
    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/plain",
        "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
      },
      body: JSON.stringify(body)
    }).then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      return res
    })
  }

  activate(slot, selector, chosen) {
    slot.querySelectorAll(`.panel-strip button${selector}`).forEach((b) => b.classList.toggle("active", chosen(b)))
  }

  // The flash stack is always in the layout (layouts/_flash.html.erb); a notice removes itself.
  toast(text) {
    const stack = document.querySelector(".flash-stack")
    if (!stack) return
    const item = document.createElement("div")
    item.className = "flash flash-notice"
    item.setAttribute("role", "status")
    const span = document.createElement("span")
    span.className = "flash-text"
    span.textContent = text
    item.appendChild(span)
    stack.appendChild(item)
    setTimeout(() => item.remove(), TOAST_MS)
  }
}
```

- [ ] **Step 3: The styles** — in `app/assets/stylesheets/components.css`, after the `.panel-actions` rule (line 116) add:

```css
  /* --- The page editor (2026-09-09, spec 2026-09-09-page-editor §5): the slot, the strip along
     a panel's top edge, the ghost state, the top bar and the YAML drawer. Components, so they hold
     in both themes and the page sheet keeps only the grid rule (design-system rules 2 and 3). --- */
  .panel-slot { min-width: 0; }
  .panel-intro { margin: -4px 0 10px; font-size: 13px; }
  .panel-slot-body > .panel { border-top-left-radius: 0; border-top-right-radius: 0; }
  .panel--placeholder p { margin: 0; }
  .panel-strip { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; padding: 4px 8px;
                 border: 1px dashed var(--line-strong); border-bottom: 0;
                 border-radius: var(--radius-panel) var(--radius-panel) 0 0; background: var(--raised); font-size: 12px; }
  .panel-strip-handle { cursor: grab; color: var(--fg-muted); font-size: 14px; letter-spacing: -2px; user-select: none; }
  .panel-strip-name { display: flex; align-items: baseline; gap: 6px; min-width: 0; }
  .panel-strip-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 8px; margin-left: auto; }
  .panel-strip .view-toggle .toggle { padding: 2px 8px; }
  .panel-strip-narrow { font-size: 11px; }
  @media (min-width: 900px) { .panel-strip-narrow { display: none; } }
  .panel-strip-edit { position: relative; }
  .panel-strip-edit > summary { list-style: none; cursor: pointer; }
  .panel-strip-edit > summary::-webkit-details-marker { display: none; }
  .panel-strip-popover { position: absolute; right: 0; top: calc(100% + 4px); z-index: 5; width: min(320px, 80vw); display: grid; gap: 8px;
                         padding: 10px; background: var(--surface); border: 1px solid var(--line-strong);
                         border-radius: var(--radius-panel); box-shadow: var(--shadow-float); }
  .panel-slot--hidden .panel-slot-body { opacity: .45; }
  .panel-slot--hidden .panel-strip { border-style: dotted; }
  .panel-slot--ghost { opacity: .35; }
  .layout-bar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 8px 16px;
                padding: 10px 12px; margin: 0 0 12px; border: 1px solid var(--accent); border-radius: var(--radius-panel); background: var(--accent-soft); }
  .layout-bar-text { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; font-size: 13px; }
  .layout-bar-noscript { color: var(--danger); }
  .layout-bar-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
  .layout-bar-actions form { display: contents; }
  .layout-editor--drawer { display: grid; grid-template-columns: minmax(0, 1fr) 380px; gap: 16px; align-items: start; }
  .layout-editor--drawer .layout-bar { grid-column: 1 / -1; }
  .layout-drawer { position: sticky; top: 12px; display: flex; flex-direction: column; gap: 8px; padding: 12px;
                   border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); }
  .layout-drawer-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
  .layout-yaml { width: 100%; min-height: 320px; resize: vertical; font: 12px/1.45 var(--font-mono); color: var(--fg);
                 background: var(--bg); border: 1px solid var(--line); border-radius: var(--radius-control); padding: 8px; }
  .layout-note { margin: 0; font-size: 12px; }
  .layout-note--error { color: var(--danger); }
  .layout-note--ok { color: var(--ok); }
  @media (max-width: 899px) { .layout-editor--drawer { grid-template-columns: 1fr; } .layout-drawer { position: static; } }
```
In `test/css_hygiene_test.rb` add `.panel-slot .panel-strip .layout-bar .layout-drawer` to
`COMPONENT_SELECTORS`. Run `bin/rails test test/css_hygiene_test.rb` — green (projects.css qualifies
`.panel-slot` as `.project-panels > .panel-slot`, which is allowed; a bare `.panel-slot {}` there would fail).

- [ ] **Step 4: The browser suite** — create `test/system/page_editor_test.rb`:

```ruby
require "application_system_test_case"

# THE PAGE EDITOR, DRIVEN (2026-09-09; spec §7). The server tests prove what the page and the doors
# write; only a browser can prove that a drag reorders, that Apply re-renders, that the pencil
# changes the heading in place, and that Save posts what the maker sees.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!): the editor reads `nodes` and fetches no bytes.
class PageEditorTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("page-editor@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
    @folder = project_folder_rows!(@user, @project)
    @models = dir!("models", @folder.node_id)
    file!("base.stl", @models.node_id)
    file!("arm.stl", @models.node_id)
    @firmware = dir!("firmware", @folder.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, @firmware.node_id)
    file!("main.c", @firmware.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
  def key(dir) = Maker::ProjectKind.folder_key(dir.node_id)
  def slot(k) = "div.panel-slot[data-key='#{k}']"
  def order_on_page = all("div.panel-slot").map { |s| s["data-key"] }

  def open_editor
    visit edit_layout_project_path(@project)
    assert_selector ".layout-bar", text: "Editing page layout"
    assert_selector "div.panel-slot", minimum: 5
  end

  test "Down then Save persists the order, and the keyboard alone can do it" do
    open_editor
    within(slot("tasks")) { find("button[aria-label='Move Tasks down']").click }
    moved = order_on_page
    assert_equal moved.index("tasks"), moved.index("bom") + 1, "Tasks moved below BOM"

    click_on "Save"
    assert_current_path project_path(@project)
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_equal moved, @project.reload.panels["order"]
    assert_no_console_errors
  end

  test "dragging a panel by its handle reorders it" do
    open_editor
    handle = find("#{slot(key(@models))} .panel-strip-handle")
    target = find(slot("tasks"))
    handle.drag_to(target, delay: 0.05)

    assert_operator order_on_page.index(key(@models)), :>, order_on_page.index("photos"),
                    "models dropped after Photos: #{order_on_page.inspect}"
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_operator @project.reload.panels["order"].index(key(@models)), :>, @project.panels["order"].index("photos")
  end

  test "Half width, Hide, and a view change apply in place and persist" do
    open_editor
    within(slot("attachments")) { click_on "Half" }
    assert_selector "#{slot('attachments')}.panel--half"
    within(slot("tasks")) { click_on "Hide" }
    assert_selector "#{slot('tasks')}.panel-slot--hidden"
    assert_selector "#{slot('tasks')} button", text: "Show"
    within(slot(key(@models))) { click_on "List" }
    assert_no_selector "#{slot(key(@models))} .attachments-grid"
    within("#{slot(key(@models))} .panel-slot-body") { assert_text "base.stl" }
    assert_selector "#{slot(key(@models))} .panel-strip button.toggle.active", text: "List"

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    panels = @project.reload.panels
    assert_equal "half", panels["widths"]["attachments"]
    assert_includes panels["hidden"], "tasks"
    assert_equal "list", panels["views"][key(@models)]
    assert_no_selector "section.tasks-panel"
    assert_no_console_errors
  end

  test "the pencil renames a folder panel and adds an intro, live and on the saved page" do
    open_editor
    within(slot(key(@models))) do
      find("details.panel-strip-edit > summary").click
      fill_in "Title", with: "Prints"
      fill_in "Intro", with: "Sliced for 0.2 mm."
    end
    assert_selector "#{slot(key(@models))} .panel-slot-body h2", text: "Prints"
    assert_selector "#{slot(key(@models))} .panel-slot-body .panel-intro", text: "Sliced for 0.2 mm."
    assert_selector "#{slot(key(@models))} .panel-strip .mono", text: "models/"

    click_on "Save"
    assert_selector "section.folder-panel h2", text: "Prints"
    assert_selector "section.folder-panel .panel-intro", text: "Sliced for 0.2 mm."
    assert_equal "models", @models.reload.name, "a title never renames the folder"
  end

  test "the drawer shows the draft as YAML, follows a change, and Apply re-renders the page" do
    open_editor
    click_on "Edit as YAML"
    assert_selector "aside.layout-drawer:not([hidden])"
    yaml = find("textarea.layout-yaml")
    assert_includes yaml.value, "layout: 1"
    assert_includes yaml.value, "- folder: models"
    refute_includes yaml.value, @models.node_id

    within(slot("tasks")) { click_on "Hide" }
    # A textarea's VALUE is not its text node, so Capybara's `text:` cannot see a refresh; poll the
    # value with the suite's own helper (test/system/support/web_helpers.rb#wait_until).
    wait_until(message: "the drawer did not follow the change") do
      find("textarea.layout-yaml").value.include?("- panel: tasks\n  width: half\n  hidden: true")
    end

    yaml.set(<<~YAML)
      layout: 1
      panels:
        - folder: models
          title: Prints
          width: half
        - folder: enclosure
          hidden: true
        - panel: bom
          hidden: true
    YAML
    click_on "Apply"
    assert_selector ".layout-drawer-notes .layout-note", text: "no folder named “enclosure”"
    assert_no_selector ".layout-note--error"
    assert_equal key(@models), order_on_page.first
    assert_selector "#{slot(key(@models))}.panel--half .panel-slot-body h2", text: "Prints"
    assert_selector "#{slot('bom')}.panel-slot--hidden"
    assert_selector "#{slot('tasks')}.panel-slot--hidden", "a panel the text did not mention keeps its state"

    yaml.set("layout: 1\npanels:\n  - panel: tsaks\n")
    click_on "Apply"
    assert_selector ".layout-note--error", text: "unknown panel “tsaks”"
    assert_no_console_errors
  end

  test "Cancel changes nothing and Reset clears the override" do
    @project.update!(panels: { "hidden" => %w[tasks], "widths" => { "bom" => "full" } })
    open_editor
    within(slot("bom")) { click_on "Half" }
    click_on "Cancel"
    assert_current_path project_path(@project)
    assert_equal "full", @project.reload.panels["widths"]["bom"]

    visit edit_layout_project_path(@project)
    accept_confirm { click_on "Reset to Other defaults" }
    assert_selector ".flash-notice", text: "reset"
    assert_nil @project.reload[:panels]
  end
end
```
If `handle.drag_to` does not reorder under Selenium, replace it with a pointer sequence on the
handle: `page.driver.browser.action.click_and_hold(handle.native).move_by(0, 40).move_to(target.native).release.perform`
— fallback mode responds to real mouse events, which that sequence is.

- [ ] **Step 5: The phone sweep** — in `test/system/shell_test.rb`, replace the block from
`find("details.panel-chooser > summary").click` through `opened_panels = true` (and its comment
block above, from `# STAGE 4, S4-7: THE PANEL CHOOSER, OPENED.`) with:

```ruby
          # THE PAGE EDITOR, AT PHONE WIDTH (2026-09-09): the strip is the widest thing a project
          # page asks a 375px viewport to lay out — a handle, two arrows, an eye, two segmented
          # controls and the pencil, all on one wrapping flex row per panel. `count:` is derived
          # from PANELS plus this project's folders, because edit mode renders the WHOLE order.
          visit edit_layout_project_path(project)
          folder_rows = @user.nodes.where(parent_node_id: folder.node_id, kind: "dir").count
          assert_operator folder_rows, :>=, 2, "the strips need folder panels to list"
          assert_selector "div.panel-slot .panel-strip", count: Maker::Project::PANELS.size + folder_rows
          assert_selector ".layout-bar input[type=submit][value='Save']"
          opened_panels = true
          visit path
```
Read the surrounding loop first: `path` is the page under sweep and the overflow assertion runs on
the CURRENT page after this block, so the `visit path` at the end returns the sweep to it. If the
block's structure differs from this description, keep its shape and only swap the chooser lines.

- [ ] **Step 6: Run the browser suites**

```bash
bin/rails test test/system/page_editor_test.rb test/system/shell_test.rb test/system/repo_browser_test.rb
```
Expected: green. Also `bin/rails test test/stimulus_hygiene_test.rb test/css_hygiene_test.rb`.

- [ ] **Step 7: Mutation-check** — three in the controller, each restored with Edit:
  1. Delete the `filter: ".panel-slot--pinned"` and `onMove` lines → the drag test must still pass
     (Publish is not the target) but add `assert_equal "publish", order_on_page.last` after the drag
     in the drag test first, then a drag of models onto the Publish slot goes red without the filter.
  2. In `save`, delete the assignment → "Down then Save" red (the door 400s).
  3. In `applyTitle`, delete the `h2` lines → the pencil test red on the live heading.

- [ ] **Step 8: Commit**

```bash
git add config/importmap.rb vendor/javascript/sortablejs.js vendor/javascript/LICENSE-sortablejs.md \
        app/javascript/controllers/layout_editor_controller.js app/assets/stylesheets/components.css \
        test/css_hygiene_test.rb test/system/shell_test.rb test/system/page_editor_test.rb
git commit -F- <<'MSG'
The page editor drags, hides, resizes, renames and previews in the browser, and the drawer follows

layout_editor_controller.js keeps the draft in the slots' data attributes, drives SortableJS in
fallback mode over the grid with Publish pinned last, fetches a panel's body for a view the draft
chose, keeps the YAML drawer's text current through the server and adopts what Apply returns, and
fills the Save form on submit. SortableJS 1.15.7 (MIT) is vendored through the importmap. Styles are
components on the tokens; the grid rule stays the page sheet's.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task E: titles, intros and widths on both pages; the public slot; the sweeps; the docs

**Files:**
- Create: `app/helpers/projects_helper.rb`
- Modify: `app/views/projects/_attachments.html.erb`, `_photos.html.erb`, `_schematics.html.erb`, `_build_log.html.erb`, `_tasks.html.erb`, `_bom.html.erb`, `_wiring.html.erb`, `_releases.html.erb`, `_sheets.html.erb`, `_publish.html.erb`, `_folder_panel.html.erb`
- Modify: `app/views/public/projects/_page.html.erb`, `_files.html.erb`, `_photos.html.erb`, `_schematics.html.erb`, `_build_log.html.erb`, `_bom.html.erb`, `_releases.html.erb`, `_folder_panel.html.erb`
- Modify: `test/integration/web/public_project_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/integration/web/project_page_test.rb`
- Modify: `docs/superpowers/specs/2026-09-09-page-editor-design.md`, `docs/user-stories.md`

- [ ] **Step 1: Write the failing tests**

Append to `test/integration/web/project_page_test.rb` (inside the class; it already signs in and
seeds a project with folders — reuse its fixture names, reading its setup first):

```ruby
    # --- titles and intros (2026-09-09, the page editor; spec §3) -----------------------------

    test "a custom title replaces the heading and an intro renders under it, on fixed and folder panels" do
      models_key = Maker::ProjectKind.folder_key(@models.node_id)
      @project.update!(panels: { "titles" => { "tasks" => "To do", models_key => "Prints" },
                                 "intros" => { models_key => "Sliced for 0.2 mm." } })

      get project_path(@project)

      assert_select "section.tasks-panel h2", text: "To do"
      assert_select "section.folder-panel h2", text: "Prints"
      assert_select "section.folder-panel p.panel-intro", text: "Sliced for 0.2 mm."
      assert_select "section.tasks-panel p.panel-intro", count: 0
      assert_select "section.folder-panel a.panel-path", text: /models/, minimum: 1
    end

    test "a title is escaped, never markup" do
      @project.update!(panels: { "titles" => { "tasks" => "<b>x</b>" } })
      get project_path(@project)
      assert_select "section.tasks-panel h2 b", count: 0
      assert_select "section.tasks-panel h2", text: "<b>x</b>"
    end
```
(If the file's setup names its folder differently from `@models`, use its name.)

Append to `test/integration/web/public_project_test.rb` (reuse its `PublicFixture` helpers and an
existing public project fixture; read its setup first):

```ruby
    # --- the arrangement travels (2026-09-09, the page editor; spec §2) ---------------------------

    test "a visitor sees the maker's titles, intros and widths, inside slots, and no slot for an empty panel" do
      folder_key = Maker::ProjectKind.folder_key(@models.node_id)
      @project.update!(panels: { "titles" => { folder_key => "Prints", "build_log" => "Diary" },
                                 "intros" => { folder_key => "Sliced." },
                                 "widths" => { folder_key => "half", "build_log" => "full" } })

      get public_project_path(@user.handle, @project.slug)

      assert_select "div.project-panels > div.panel-slot.panel--half > section.folder-panel h2", text: "Prints"
      assert_select "section.folder-panel p.panel-intro", text: "Sliced."
      assert_select "div.panel-slot.panel--full > section.build-log-panel h2", text: "Diary"
      assert_select "div.panel-slot > section.photos-panel", count: 0, "no photos, no slot"
      assert_select "div.panel-slot:empty", count: 0
    end
```
(This test needs the public fixture to hold a folder with a file and at least one build-log entry
and no images; the file's existing seed helper does that — check which instance variables it sets
and adapt the names.)

In `test/integration/web/template_hygiene_test.rb`, in `pages`, beside the project detail entry add
`"project detail (edit mode)" => edit_layout_project_path(@project),` and update the comment at
line 314 that names `projects/_panel_chooser` to name `projects/_panel_slot` and `_panel_strip`.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/project_page_test.rb -n "/custom title|escaped/" test/integration/web/public_project_test.rb -n "/travels/"
```
Expected: failures on the headings.

- [ ] **Step 3: The helper** — create `app/helpers/projects_helper.rb`:

```ruby
# The project page's panel headings (2026-09-09, the page editor; spec §3). Two helpers rather
# than each partial reaching into the layout, so a title's fallback and an intro's markup are
# written once for the maker's page and the visitor's. The LAYOUT IS AN ARGUMENT: the maker's page
# holds @panel_layout, the public page holds `pub.layout`, and the shared projects/_wiring partial
# is handed whichever it is rendering for as a local.
module ProjectsHelper
  # The maker's title, else the default label — Maker::Project::PANEL_LABELS for a fixed key, the
  # folder's own name for a folder key, which only the caller knows.
  def panel_title(layout, key, default = nil)
    layout.title_for(key, default || Maker::Project::PANEL_LABELS.fetch(key.to_s))
  end

  # One muted line under the heading, or nothing. Escaped by `content_tag`; an intro is text.
  def panel_intro(layout, key)
    intro = layout.intro_for(key)
    content_tag(:p, intro, class: "panel-intro muted") if intro
  end
end
```

- [ ] **Step 4: The maker's partials** — in each, replace the heading and add the intro line right
after the head. The exact edits:

- `_attachments.html.erb`: `<h2>Files</h2>` → `<h2><%= panel_title(@panel_layout, "attachments") %></h2>`; after the `</div>` that closes `panel-head` (the line after the `upload_control` render's closing `%>` and its `</div>`) insert `<%= panel_intro(@panel_layout, "attachments") %>`.
- `_photos.html.erb`: `<h2>Photos</h2>` → `panel_title(@panel_layout, "photos")`; intro after the head's `</div>`.
- `_schematics.html.erb`: `<h2>Schematics</h2>` → `<h2><%= panel_title(@panel_layout, "schematics") %></h2><%= panel_intro(@panel_layout, "schematics") %>`.
- `_build_log.html.erb`: same shape with `"build_log"`.
- `_tasks.html.erb`: same shape with `"tasks"`.
- `_bom.html.erb`: `<h2>Bill of materials</h2>` → `panel_title(@panel_layout, "bom")`; intro after the head.
- `_wiring.html.erb`: `<h2>Wiring</h2>` → `<h2><%= panel_title(layout, "wiring") %></h2>`; intro `<%= panel_intro(layout, "wiring") %>` after the head; add `layout -- the Maker::ProjectKind::Layout the page renders from (titles, intros)` to the Locals list in its header.
- `_releases.html.erb`, `_sheets.html.erb`, `_publish.html.erb`: same shape with their keys (publish's intro after the head).
- `_folder_panel.html.erb`: `<h2><%= dir.name %></h2>` → `<h2><%= panel_title(@panel_layout, key, dir.name) %></h2>`; intro `<%= panel_intro(@panel_layout, key) %>` after the head's `</div>`; in the header comment change "the chooser can hide it and move it (projects/_panel_chooser)" to "the page editor can hide it, move it, size it and retitle it (projects/_panel_slot)".

- [ ] **Step 5: The public page** — in `app/views/public/projects/_page.html.erb` replace the
`<div class="project-panels">…</div>` block (from `<div class="project-panels">` to the line after
the repo cards loop's `<% end %>`) with:

```erb
<%#
  EVERY PANEL IN A SLOT WITH ITS WIDTH (2026-09-09, the page editor; spec §3): the same
  `div.panel-slot.panel--<width>` the maker's page renders, from the same layout, so the visitor
  sees the arrangement the maker made. The body is CAPTURED first because every partial below
  omits itself when it has nothing to show, and an empty slot would still hold a grid cell.
%>
<div class="project-panels">
  <% pub.visible_panels.each do |key| %>
    <% body = capture do %>
      <% if key == "wiring" %>
        <% if pub.connections.any? %>
          <%= render "projects/wiring", project: project, connections: pub.connections, editable: false, layout: pub.layout %>
        <% end %>
      <% elsif pub.layout.folder?(key) %>
        <%= render "public/projects/folder_panel", pub: pub, key: key, dir: pub.folder_dir(key),
                   view: pub.layout.view_for(key) %>
      <% elsif (partial = public_panels[key]) %>
        <%= render partial, pub: pub %>
      <% end %>
    <% end %>
    <% if body.present? %>
      <div class="panel-slot panel--<%= pub.layout.width_for(key) %>"><%= body %></div>
    <% end %>
  <% end %>
  <% pub.repo_cards.each_value do |card| %>
    <%= render "public/projects/repo_card", card: card %>
  <% end %>
</div>
```
Then the public partials: `_files.html.erb` `<h2>Files</h2>` → `<h2><%= panel_title(pub.layout, "attachments") %></h2>` and `<%= panel_intro(pub.layout, "attachments") %>` after the head; `_photos`, `_schematics`, `_build_log`, `_bom`, `_releases` the same with their keys; `_folder_panel.html.erb` `<h2><%= dir.name %></h2>` → `<h2><%= panel_title(pub.layout, key, dir.name) %></h2>` and the intro after the head.

The seam guard (`test/architecture_invariants_test.rb`) forbids certain calls in public templates;
`panel_title`/`panel_intro` build no URLs, so they pass — run it to be sure.

- [ ] **Step 6: Run everything these files touch**

```bash
bin/rails test test/integration/web/project_page_test.rb test/integration/web/public_project_test.rb \
               test/integration/web/public_bundle_test.rb test/integration/web/template_hygiene_test.rb \
               test/integration/web/page_query_budget_test.rb test/architecture_invariants_test.rb \
               test/integration/web/project_preview_test.rb
```
Expected: green.

- [ ] **Step 7: Mutation-check** — three:
  1. In `panel_title`, return `default || …` ignoring the layout → the titles test red.
  2. In `_page.html.erb`, change `<% if body.present? %>` to `<% if true %>` → "no slot for an empty panel" red.
  3. In `_folder_panel.html.erb` (public), revert the h2 to `dir.name` → the visitor test red on "Prints".

- [ ] **Step 8: The docs** — in `docs/superpowers/specs/2026-09-09-page-editor-design.md` add, after decision 12 in §8:

```markdown
13. **Settled in execution (2026-09-09):** the strip sits along the TOP EDGE of the panel card, in the
    slot wrapper, not inside the panel head — ten partials own their heads and the wrapper touches
    none of them. A Save that fails validation returns to the editor with the errors as an alert
    and does not retain the draft; the only reachable cause, a folder renamed mid-edit, is handled
    by dropping the entry with a notice. A failed panel preview keeps the CHOSEN view in the draft
    and says the preview did not load. Export quotes strings where YAML needs it, in Psych's own
    style. The draft is read off the slots' data attributes rather than an embedded JSON blob.
```
Also change §6's "the strip's view switch returns to the previous value" sentence to "the strip
keeps the chosen view, the old body stays on screen, a toast says the preview did not load, and
Save writes the view the maker chose" and §4's "Strings that need it are double-quoted" to
"Strings are quoted where YAML needs it."

In `docs/user-stories.md`, after the "Re-measured after folder panels" line add:
`Re-measured after the page editor (2026-09-09): 6.5 stays `works` — an in-place edit mode on the project page (drag to reorder, hide, view, Full/Half width, title and intro per panel, draft until Save) with a YAML drawer whose text is the shareable layout; the visitor's page mirrors all of it.`

- [ ] **Step 9: Commit**

```bash
git add app/helpers/projects_helper.rb app/views/projects app/views/public/projects test/integration/web docs/superpowers/specs/2026-09-09-page-editor-design.md docs/user-stories.md
git commit -F- <<'MSG'
Titles and intros render on both pages, the visitor's panels sit in slots with the maker's widths

ProjectsHelper#panel_title/#panel_intro read the layout the page renders from — @panel_layout on
the maker's page, pub.layout on the visitor's, a local for the shared wiring partial. The public
page wraps every panel in the same div.panel-slot.panel--<width>, captured first so an empty panel
still renders no slot. Spec §8 records what execution settled; story 6.5 re-measured.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Close-out (after A–E)

- [ ] `rm -rf tmp/cache/bootsnap*; TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` — every gate green, the three legs at identical run counts (the +7 / +~160 assertion and 32/33/8 skip deltas are the normal shape).
- [ ] Push, `gh pr create --base main` with a body that carries: what this adds, the decisions (spec §8 items 1–13), review findings per task, the verification table, scope (slices 2–6). Then `bin/log arc --from-pr <n>`, watch CI, and stop: **merging needs the owner's go-ahead.**
