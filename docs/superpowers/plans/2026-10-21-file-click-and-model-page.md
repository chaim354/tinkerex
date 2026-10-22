# A click opens the file, and a model gets its own page — Implementation Plan

> **For agentic workers:** this repo's default is `.claude/commands/execute-plan.md` (CLAUDE.md §15):
> one implementer per task, disjoint tasks in parallel, one capped quality review each. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single click on a file opens its page, a double-click opens it in a new tab,
right-click › Details opens the Library's side panel, and every 3D model renders its own
Printables-style page (files left, a pane right).

**Architecture:** One Stimulus controller (`fileopen`) on the layout's `<main>` delays a single click
by 250 ms to tell it from a double-click, then re-issues it as a synthetic click (`detail === 0`)
that Turbo follows normally. File links opt in through one helper, `FilesHelper#file_open_data`. The
model page's pane is a Turbo Frame (`model_stage`) rendered from a viewer chain extracted out of
`files/show.html.erb` into `files/_viewer.html.erb`, fed by one maker-only concern (`FileViewer`).

**Tech Stack:** Rails 8, Hotwire (Turbo 8 via turbo-rails 2.0.23, Stimulus), Minitest, Capybara +
Selenium headless Chrome.

**Spec:** `docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md`.

**One spec amendment, made in Task 0:** the spec's "Not changed" bullet kept BOM part names, the
connections panel's names and search names as plain links. They are file ROWS, not prose, and the
owner's words were "any file anywhere", so only rendered Markdown (README, text blocks) and `.btn`
actions keep plain links. That also makes Task 3's guard a two-rule exclusion instead of a list.

---

## Ground rules for every implementer

- **Worktree:** `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/file-click-model-page`.
  Run every command from there. Never `cd` to the main checkout.
- **Do not commit.** The orchestrator commits each task's files. Leave your changes in the tree and
  list every path you touched in your report.
- **Run only the test files your task names.** Another implementer may be running tests in this
  worktree at the same moment (shared SQLite test DB). Never run `bin/ci` or the whole suite. If a
  test errors with `SQLite3::BusyException`, re-run that file once before treating it as real.
- **Bash locale:** run Ruby that edits repo files with `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8`. Prefer
  the Edit tool.
- **ERB:** never use Ruby's hash shorthand (`key:`) as the LAST argument of a `render`/helper call
  inside `<%= … %>`; it swallows the next line's expression. Spell every argument out
  (`editable: editable`). Never write `%>` inside an ERB comment (§14d).
- **Bootsnap:** after restoring a mutated file, `rm -rf tmp/cache/bootsnap*` before the green re-run.
- **Mutation checks (§15):** every guard named in a task gets broken on purpose, run red, restored
  with `git checkout -- <file>` (or the Edit tool for a file that is new), and re-run green. Report
  the actual red output, one line per mutation.
- **Docs sweep:** when your change falsifies a comment or a doc sentence, grep for every place that
  describes the same behaviour and fix all of them in your task.

**Test commands** (from the worktree):

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test <files…>          # request, helper, service tests
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/<file>  # one system test file (headless Chrome)
```

---

## Waves

| wave | tasks (parallel) | why this order |
|---|---|---|
| 1 | Task 1, Task 4 | disjoint files; Task 1's helper and Task 4's viewer are what later tasks build on |
| 2 | Task 2, Task 5 | Task 2 needs Task 1; Task 5 needs Tasks 1 and 4; they share no file |
| 3 | Task 3 | its guard sweeps every page, so it runs once every surface has landed |

Task 0 is the orchestrator's own commit (the spec amendment and this plan).

---

### Task 0 (orchestrator): amend the spec

**Files:** Modify `docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md`.

- [ ] Replace the spec's "Not changed" paragraph's first sentence (from `**Not changed:** links inside written text` through `it should keep doing so.`) with:

```markdown
**Not changed:** links inside rendered Markdown — a README, a text block — stay ordinary links, and
so do `.btn` actions (the side panel's Open, the model pane's "Open file page"). Everything else
that links a file page is a file row and takes the click rule, including BOM part names, the
connections panel's names, search results and the project repo browser's file links.
```

- [ ] In the spec's "Where" list, replace the line `- the file page's photo tiles (`files/_connections`, the `photo-cell` links);` with:

```markdown
- the file page's connections panel (`files/_connections`, every link), a BOM's part names
  (`projects/_bom_lines`), and the repo browser's file links (`lib/file_chooser.js`, browse mode);
```

- [ ] In the spec's Part 2 "How" list, replace `The `file` param is validated against that same set.`
  with: `The `file` param is validated against the model's live attachments — the tree is a subset of
  them, and the gallery can name an image outside the folder.`

- [ ] Commit the spec and this plan together.

---

### Task 1: The click controller and the two helpers it hangs on

**Files:**
- Create: `app/javascript/controllers/fileopen_controller.js`
- Modify: `app/views/layouts/application.html.erb` (the signed-in `<main>`)
- Modify: `app/helpers/files_helper.rb` (`file_menu_data` signature + `details_url`; new `file_open_data`)
- Modify (callers of `file_menu_data`): `app/views/files/_grid.html.erb`, `app/views/files/_list.html.erb`,
  `app/views/home/index.html.erb`, `app/views/projects/_file_tile.html.erb`, `app/views/projects/_file_rows.html.erb`
- Test: `test/helpers/files_helper_test.rb`

- [ ] **Step 1: Write the failing helper tests.** In `test/helpers/files_helper_test.rb`, below the
  `include Rails.application.routes.url_helpers` line, add the fixture method:

```ruby
  # An UNSAVED node is all the builders read: its id, its name and its parent.
  def menu_node(name = "widget.stl", parent: "d-1")
    Node.new(node_id: "n-1", name:, parent_node_id: parent)
  end
```

  Change every existing call `file_menu_data("n-1", "widget.stl", X)` to `file_menu_data(menu_node, X)`,
  and the one with `"Bracket v2.stl"` to `file_menu_data(menu_node("Bracket v2.stl"), nil)`. Then add:

```ruby
  # DETAILS IS THE LIBRARY WITH THIS FILE SELECTED (2026-10-21), built here like every other entry so
  # filemenu_controller.js never assembles a URL. The FOLDER is the file's parent, because
  # FilesController#index honours `selected` only for a file in the listing it renders; a file at
  # the library root has no parent, and its URL carries no folder.
  test "file_menu_data's details url opens the Library on the file's own folder with it selected" do
    assert_equal files_path(folder: "d-1", selected: "n-1"), file_menu_data(menu_node, nil)[:details_url]
    assert_equal files_path(selected: "n-1"), file_menu_data(menu_node(parent: nil), nil)[:details_url]
  end

  # APPENDED, NEVER REPLACED: the file menu's contextmenu action and the selection hooks share the
  # attribute. An absent new-tab url must render NO attribute (Rails drops a nil data value, but the
  # key must not even be there for an exact-hash caller).
  test "file_open_data appends the fileopen action and names a new-tab url only when given one" do
    data = file_open_data({ action: "contextmenu->filemenu#open", node_id: "n-1" })
    assert_equal "contextmenu->filemenu#open click->fileopen#click", data[:action]
    assert_equal "n-1", data[:node_id]
    refute data.key?(:fileopen_new_tab_url)
    assert_equal({ action: "click->fileopen#click" }, file_open_data)
    assert_equal "/files/n-1", file_open_data({}, new_tab: "/files/n-1")[:fileopen_new_tab_url]
  end
```

- [ ] **Step 2: Run them, expect red.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/helpers/files_helper_test.rb
```

  Expected: errors — `ArgumentError: wrong number of arguments (given 2, expected 3)` and
  `NoMethodError: undefined method 'file_open_data'`.

- [ ] **Step 3: Change `file_menu_data` and add `file_open_data`** in `app/helpers/files_helper.rb`.
  Replace the method body (keep its existing comment above it, and add the Details sentence shown):

```ruby
  # DETAILS (2026-10-21) is the Library with this file selected: its own folder, so the listing
  # FilesController#index renders contains it, and `selected=` its id. A root file has no parent and
  # `files_path` drops the nil. It takes the NODE, not an id and a name, because it now needs the
  # parent too, and every caller already holds the node.
  def file_menu_data(node, origin)
    { action: "contextmenu->filemenu#open",
      node_name: node.name,
      note_url: file_notes_path(node.node_id),
      download_url: blob_file_path(node.node_id, download: 1),
      delete_url: file_path(node.node_id),
      details_url: files_path(folder: node.parent_node_id, selected: node.node_id),
      addon_open_url: origin&.dig(:url),
      addon_open_label: origin&.dig(:label) }
  end
```

  Add, directly below `with_selection` (leave `with_selection` itself alone — Task 2 changes it):

```ruby
  # A FILE LINK THAT OPENS ON A CLICK AND IN A NEW TAB ON A DOUBLE-CLICK (2026-10-21,
  # fileopen_controller.js, mounted on the layout's <main>). Merged into a link's data the way
  # with_selection is: the action is APPENDED, never replaced, because the file menu and the
  # thumbnail poll share the hash. `new_tab:` is for a link whose href is NOT the file page — the
  # model page's list, whose click swaps the pane — and is omitted everywhere else, so the key is
  # absent rather than nil.
  def file_open_data(data = {}, new_tab: nil)
    opened = data.merge(action: [ data[:action], "click->fileopen#click" ].compact.join(" "))
    new_tab ? opened.merge(fileopen_new_tab_url: new_tab) : opened
  end
```

- [ ] **Step 4: Update the five callers** to the new signature (nothing else changes in them yet):
  - `app/views/files/_grid.html.erb` (two calls) and `app/views/files/_list.html.erb` (two calls) and
    `app/views/home/index.html.erb` (two calls): `file_menu_data(node.node_id, node.name, X)` →
    `file_menu_data(node, X)`.
  - `app/views/projects/_file_tile.html.erb`: `file_menu_data(row.node_id, node.name, @addon_origins[row.node_id])`
    → `file_menu_data(node, @addon_origins[row.node_id])` (`node` is `row.node`, assigned at the top).
  - `app/views/projects/_file_rows.html.erb`: `file_menu_data(row.node_id, node.name, origin)` →
    `file_menu_data(node, origin)`.
  - Then `grep -rn "file_menu_data(" app test` must show no three-argument call.

- [ ] **Step 5: Create `app/javascript/controllers/fileopen_controller.js`:**

```js
import { Controller } from "@hotwired/stimulus"

// A CLICK OPENS THE FILE, A DOUBLE-CLICK OPENS IT IN A NEW TAB (2026-10-21,
// docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md). Mounted ONCE, on the
// signed-in layout's <main>; a file link opts in through FilesHelper#file_open_data, which appends
// `click->fileopen#click` to whatever action the link already carries.
//
// A BROWSER CANNOT TELL A CLICK FROM THE FIRST HALF OF A DOUBLE-CLICK UNTIL THE SECOND ONE ARRIVES OR
// DOES NOT, so a single click waits WINDOW_MS and then re-issues itself with `link.click()`. That
// synthetic click has `detail === 0`, which the first line below lets straight through, so Turbo
// follows it with every data-turbo-* attribute the link carries — the model page's frame links
// included — and this controller never reimplements navigation. Turbo has no isTrusted check
// (LinkClickObserver#clickEventIsSignificant reads `which`, the modifiers and defaultPrevented), and
// Turbo 8 prefetches a link's page on hover, so the wait is usually spent with the response in hand.
//
// EVERYTHING ELSE IS THE LINK'S: a modifier or middle click, Enter (a click whose `detail` is 0), and
// with JavaScript off every tile is a plain link. A slow double-click — the second click after the
// timer already fired — opens the page here, once; it never opens it here AND in a new tab.
const WINDOW_MS = 250

export default class extends Controller {
  disconnect() {
    this.cancel()
  }

  click(event) {
    if (event.detail === 0 || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const link = event.currentTarget
    event.preventDefault()
    if (event.detail === 1) {
      this.cancel()
      this.pending = link
      this.timer = setTimeout(() => {
        this.timer = null
        this.pending = null
        link.click()
      }, WINDOW_MS)
    } else if (event.detail === 2 && this.timer && this.pending === link) {
      this.cancel()
      window.open(link.dataset.fileopenNewTabUrl || link.href, "_blank", "noopener")
    }
    // Anything else — a triple click, or a second click after the timer fired — is swallowed.
  }

  cancel() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.pending = null
  }
}
```

- [ ] **Step 6: Mount it.** In `app/views/layouts/application.html.erb`, the SIGNED-IN branch's
  `<main id="main" class="container <%= content_for(:container_class) %>">` becomes
  `<main id="main" class="container <%= content_for(:container_class) %>" data-controller="fileopen">`.
  Add an ERB comment above it: the controller is mounted once here so every file link on a
  signed-in page can opt in; the visitor's branch below has none, because public pages are out of
  scope (the spec). Do NOT touch the signed-out `<main>`.

- [ ] **Step 7: Run green.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/helpers/files_helper_test.rb test/stimulus_hygiene_test.rb test/integration/web/file_menu_wiring_test.rb test/integration/web/files_selection_test.rb test/integration/web/home_test.rb
```

  Expected: all pass (the selection tests are untouched until Task 2).

- [ ] **Step 8: Mutation checks.** (a) Make `file_open_data` replace the action instead of appending
  (`action: "click->fileopen#click"`): the append test goes red. (b) Drop `details_url` from
  `file_menu_data`: the details test goes red. Restore both.

---

### Task 4: One viewer chain for two maker pages

**Files:**
- Create: `app/controllers/concerns/file_viewer.rb`
- Create: `app/views/files/_viewer.html.erb`
- Modify: `app/controllers/files_controller.rb` (`include FileViewer`; `#show`; move `current_thumbnail` out)
- Modify: `app/views/files/show.html.erb` (the `.preview` block)

This is a pure refactor: no behaviour changes, so the existing file-page suites are the test.

- [ ] **Step 1: Create `app/controllers/concerns/file_viewer.rb`.** Move `current_thumbnail` here
  from `FilesController` VERBATIM, with its whole comment block, and delete it from the controller:

```ruby
# THE VIEWER ONE FILE GETS ON A MAKER'S PAGE (2026-10-21): the file page (FilesController#show) and
# the model page's pane (ModelsController#show, models/_stage) both ask `viewer_state_for` and both
# render files/_viewer from what it answers, so the two cannot disagree about which viewer a file
# gets or what that viewer is handed.
#
# MAKER-ONLY, WHICH IS WHY IT IS NOT FilePreview. This reads `current_user` (the stat, the thumbnail
# enqueue, the 3MF manifest); FilePreview is included by a VISITOR's page too and never reads the
# session (§14d). FilePreview#viewer_for stays the one answer to the KIND; this adds what a maker's
# page wraps around it.
module FileViewer
  extend ActiveSupport::Concern
  include FilePreview

  # Everything files/_viewer reads, one value per file. `info` is the port's stat; `kind`,
  # `gerber_layers` and `gerber_single` are viewer_for's three facts; `manifest` is
  # Maker::ThreeMfManifest's answer (nil for anything that is not a 3MF).
  Viewer = Data.define(:node, :info, :kind, :gerber_layers, :gerber_single, :thumbnail, :manifest)

  private

  def viewer_state_for(node)
    info = FileLayer.current.stat(current_user, node_id: node.node_id)
    kind, layers, single =
      viewer_for(user: current_user, node:, url: ->(n) { named_blob_file_path(n.node_id, filename: n.name) })
    token = info&.content_token
    Viewer.new(node:, info:, kind:, gerber_layers: layers, gerber_single: single,
               thumbnail: token && current_thumbnail(node, token),
               manifest: Maker::ThreeMfManifest.for(user: current_user, node:))
  end

  # (current_thumbnail moved here verbatim, comment and all)
end
```

- [ ] **Step 2: Rewire `FilesController`.** Add `include FileViewer` beside `include FilePreview`
  (keep `FilePreview`'s include — the constants comment there depends on it). In `#show`, replace
  the `@info = …stat…` line, the `@kind, @gerber_layers, @gerber_single = viewer_for(…)` assignment,
  the `token = …`/`@thumbnail = …` pair and the `@viewer_manifest = …` line with:

```ruby
    # ONE ANSWER FOR THE VIEWER, ASKED BY THE MODEL PAGE'S PANE TOO (FileViewer, 2026-10-21): the stat,
    # FilePreview#viewer_for's kind and board, the current thumbnail and the 3MF manifest. `@kind` is
    # final from this line, before `@editable` reads it.
    @viewer = viewer_state_for(@node)
    @info = @viewer.info
    @kind = @viewer.kind
    @thumbnail = @viewer.thumbnail
```

  Keep the long comments that explained the removed lines by folding their substance into
  `FileViewer` (the viewer_for comment, the manifest comment) — do not lose them. Then
  `grep -rn "@gerber_layers\|@gerber_single\|@viewer_manifest" app/views/files app/controllers/files_controller.rb`:
  any read left outside the chain moved in Step 3 must read `@viewer.<field>` instead.

- [ ] **Step 3: Extract the chain.** Create `app/views/files/_viewer.html.erb` from the `if
  @info.content_token.nil?` … `end` chain inside `files/show.html.erb`'s `<div class="preview">`,
  with these exact changes and nothing else:
  - first line: `<%# locals: (viewer:, editable:, save:) %>`;
  - move the "EIGHT BRANCHES, EIGHT PARTIALS" comment in, and add: it lives OUTSIDE
    `files/viewers/` on purpose — it calls private route helpers, which `architecture_invariants_test.rb`'s
    Public scan forbids inside that directory; a visitor's page keeps its own chain
    (`public/files/view.html.erb`) over the same eight partials; `editable:` and `save:` are the two
    facts about the OWNER's page the model pane switches off;
  - `@node` → `viewer.node`, `@info` → `viewer.info`, `@kind` → `viewer.kind`, `@thumbnail` →
    `viewer.thumbnail`, `@gerber_layers` → `viewer.gerber_layers`, `@gerber_single` →
    `viewer.gerber_single`, `@viewer_manifest` → `viewer.manifest`, `@editable` → `editable`, and the
    Measure branch's `save: true` → `save: save` (spelled out, never `save:`);
  - the `:text` branch loses the repo banner (Step 4 keeps it on the file page) and keeps only the
    `files/viewers/code` render.

- [ ] **Step 4: Render it from the file page.** In `files/show.html.erb`, the chain inside
  `<div class="preview">` becomes:

```erb
  <%# THE BANNER IS NOT PART OF THE VIEWER and stays on this page: it is a fact about a
      REPOSITORY and about who is looking at it (whether this box can commit, how many edits are
      pending), neither of which a visitor's page or the model pane has or should have. Rendered
      where the chain's :text branch used to render it, right before the code viewer. %>
  <% if @info.content_token && @kind == :text && @repo_root %>
    <div class="repo-banner">
      … the banner's existing markup, moved verbatim …
    </div>
  <% end %>
  <%= render "files/viewer", viewer: @viewer, editable: @editable, save: true %>
```

- [ ] **Step 5: Run green.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/files_flow_test.rb test/integration/web/template_hygiene_test.rb test/architecture_invariants_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/inspector_test.rb test/controllers/files_controller_preview_kind_test.rb
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/code_viewer_test.rb test/system/o3dv_test.rb test/system/measure_formats_test.rb
```

  Expected: all pass with the same counts as before the change (run them once on a clean checkout
  first and note the counts). The template-hygiene coverage assertion must count `files/_viewer` as
  rendered (the file-detail pages render it).

- [ ] **Step 6: Mutation check.** In `files/_viewer.html.erb`, change `editable: editable` to
  `editable: true`, then run `test/integration/web/public_file_view_test.rb` and `files_flow_test.rb`.
  The file page should stay green (it passes `@editable`), which proves nothing, so instead change
  `files/show.html.erb`'s `editable: @editable` to `editable: false` and run the repo-editor or
  code-viewer test that asserts the editor mounts (`grep -rln "data-controller='editor'\|editor-save-url" test`).
  It must go red. Restore.

---

### Task 2: The Library — click opens, Details opens the panel

**Files:**
- Modify: `app/javascript/controllers/selection_controller.js`
- Modify: `app/javascript/controllers/filemenu_controller.js`
- Modify: `app/helpers/files_helper.rb` (`with_selection` only)
- Modify: `app/views/files/_grid.html.erb`, `app/views/files/_list.html.erb`
- Modify: `docs/invariants/files-preview.md`
- Test: `test/helpers/files_helper_test.rb`, `test/integration/web/files_selection_test.rb`,
  `test/integration/web/file_menu_wiring_test.rb`, `test/system/files_selection_test.rb`

- [ ] **Step 1: Failing helper test.** In `test/helpers/files_helper_test.rb` add:

```ruby
  # A TILE IS A SELECTION ITEM FOR DETAILS ONLY (2026-10-21): the menu's Details asks the tile through
  # a `filemenu:details` event, and nothing here intercepts a click any more — fileopen does.
  test "with_selection appends the Details hook and nothing that intercepts a click" do
    data = with_selection({ action: "contextmenu->filemenu#open" }, "n-1")
    assert_equal "contextmenu->filemenu#open filemenu:details->selection#details", data[:action]
    assert_equal "item", data[:selection_target]
    assert_equal "n-1", data[:selection_id]
  end
```

- [ ] **Step 2: Change `with_selection`** in `app/helpers/files_helper.rb`:

```ruby
  # A FILE TILE IS A SELECTION ITEM FOR DETAILS (2026-10-21). A click opens the file
  # (fileopen_controller.js, through file_open_data) and a double-click opens it in a new tab; the
  # side panel opens from the file menu's Details, which dispatches `filemenu:details` on the tile and
  # is answered here by selection_controller.js#details. Merged into whatever data the tile already
  # carries — its `action` is APPENDED to, never replaced. A FOLDER IS NEVER PASSED THROUGH THIS: a
  # folder click navigates into it.
  def with_selection(data, node_id)
    data.merge(selection_target: "item", selection_id: node_id,
               action: [ data[:action], "filemenu:details->selection#details" ].compact.join(" "))
  end
```

- [ ] **Step 3: The four Library links opt in.** In `_grid.html.erb` (two file branches) and
  `_list.html.erb` (two file branches), wrap the existing `with_selection(…)` in `file_open_data(…)`:
  `data: file_open_data(with_selection(<what is there now>, node.node_id))`. Update the comments in
  both files that say a file card or row "is a selection item" / "click selects": a click opens the
  file, a double-click opens it in a new tab, right-click › Details opens the panel.

- [ ] **Step 4: Rewrite `selection_controller.js`.** Delete `click(event)` and `open(event)`. Add:

```js
  // RIGHT-CLICK › DETAILS (filemenu_controller.js) asks the tile through a cancelable
  // `filemenu:details` event. On the Library the answer is this panel, opened in place, and the cancel
  // is what tells the menu not to navigate to its details url.
  details(event) {
    event.preventDefault()
    this.select(event.currentTarget)
  }
```

  In `keydown`, after the `step` line, gate the arrows on the panel being open:

```js
    if (!this.element.classList.contains("has-inspector")) return
```

  Rewrite the header comment: DETAILS OPENS THE PANEL; A CLICK OPENS THE FILE (2026-10-21). The panel
  opens from the file menu's Details or from a page rendered with `?selected=`; everything about the
  selection once open (the ink ring, `?selected=` replaced into the URL through Turbo's history, the
  frame, arrows while open, Escape) is unchanged; a click and a double-click are
  fileopen_controller.js's; the tiles stay `<a href=file_path>` for the same reasons as before.

- [ ] **Step 5: Add Details to `filemenu_controller.js`.** Directly after the `if (href) { … "Open" … }`
  block, insert:

```js
    // DETAILS — the Library's side panel for this file (2026-10-21). The CELL is asked first, through
    // a cancelable `filemenu:details` event: on the Library the tile is a selection item and
    // selection_controller.js#details opens the panel in place and cancels it. Anywhere else nothing
    // cancels it and the entry is an ordinary link to `data-details-url` — the Library with this file
    // selected, a URL the server built (file_menu_data) like every other entry here. The document's
    // own click listener closes the menu afterwards, as it does for Open.
    const detailsUrl = cell.dataset.detailsUrl
    if (detailsUrl) {
      const details = document.createElement("a")
      details.href = detailsUrl
      details.textContent = "Details"
      details.addEventListener("click", (e) => {
        const asked = this.dispatch("details", { target: cell, cancelable: true })
        if (asked.defaultPrevented) e.preventDefault()
      })
      this.menu.appendChild(details)
    }
```

  Add "Details" to the controller's header list of entries.

- [ ] **Step 6: Request tests.** In `test/integration/web/files_selection_test.rb`, replace the two
  `assert_includes el["data-action"], "click->selection#click"` / `"dblclick->selection#open"` lines
  with:

```ruby
          assert_includes el["data-action"], "click->fileopen#click"
          assert_includes el["data-action"], "filemenu:details->selection#details"
          refute_includes el["data-action"], "selection#click", "#{view}: a click must open, not select"
```

  Rename the test to "every file tile opens on a click, keeps its link, and is a Details item;
  folders are not". Rewrite the class header comment: a click opens the file, right-click › Details
  selects it and opens the inspector, `?selected=` still restores it.

  In `test/integration/web/file_menu_wiring_test.rb` add:

```ruby
    # DETAILS REACHES EVERY MENU-BEARING FILE CELL (2026-10-21): the Library's grid and list, Recent and
    # a project's tiles all build the menu from file_menu_data, and a surface that dropped the url would
    # offer no Details entry with nothing anywhere going red. A cell's own note url names its node.
    test "every menu-bearing file cell carries a details url naming its folder and itself" do
      dir = @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-in", name: "inner.stl", kind: "file", mtime: 1, size: 5,
                          parent_node_id: dir.node_id, content_hash: "h-in", current_version_id: "v-in")
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: "n-stl", role: "model")

      [ files_path(view: "list"), files_path(view: "grid"), files_path(folder: dir.node_id, view: "grid"),
        root_path, project_path(project) ].each do |path|
        get path
        assert_response :success
        cells = css_select("[data-action*='filemenu#open'][data-note-url]")
        refute_empty cells, "#{path} rendered no file menu"
        cells.each do |cell|
          id = cell["data-note-url"][%r{/files/([^/]+)/notes}, 1]
          parent = @user.nodes.find_by!(node_id: id).parent_node_id
          assert_equal files_path(folder: parent, selected: id), cell["data-details-url"], "#{path}: #{id}"
        end
      end
    end
```

  If `root_path` renders no file menu for this fixture, Recent is filtering the token-less setup
  nodes: add `content_hash:`/`current_version_id:` to the two nodes in `setup` (as `n-in` has), never
  drop `root_path` from the list.

- [ ] **Step 7: Rewrite `test/system/files_selection_test.rb`.** Keep the setup/teardown and the
  three node helpers. Replace the header comment (a click opens the file, a double-click opens it in
  a new tab, right-click › Details opens the panel — selection_controller.js and
  fileopen_controller.js, driven in a browser because only a browser shows the click being delayed,
  the tab opening and the frame loading). Add these helpers and tests; keep the two existing tests
  that need no click ("arrow keys inside the inspector stay with the control" unchanged), and adapt
  the re-sort and phone tests as shown:

```ruby
  def details_for(selector, name)
    find(selector, text: name).right_click
    find(".file-menu a", text: "Details").click
  end

  test "a click opens the file page" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_current_path file_path(bracket.node_id)
    assert_no_console_errors
  end

  test "a click on a list row opens the file page too" do
    visit files_path(folder: legs.node_id, view: "list")
    find("table.files a", text: "plate.stl").click
    assert_current_path file_path(plate.node_id)
    assert_no_console_errors
  end

  # THE WAIT IS THE MECHANISM: a double-click must cancel the single click's pending visit. The sleep
  # outlasts fileopen's 250 ms window, so a visit that was NOT cancelled has started by the time the
  # path is asserted.
  test "a double-click opens the file page in a new tab and leaves this one where it was" do
    visit files_path(folder: legs.node_id, view: "grid")
    tab = window_opened_by { find(".grid-card", text: "plate.stl").double_click }
    within_window(tab) { assert_current_path file_path(plate.node_id) }
    sleep 0.5
    assert_current_path files_path, ignore_query: true
    assert_selector ".grid-card", text: "bracket.stl"
    tab.close
    assert_no_console_errors
  end

  test "Enter on a focused tile opens it" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").send_keys(:enter)
    assert_current_path file_path(plate.node_id)
    assert_no_console_errors
  end

  # A MODIFIER CLICK IS THE BROWSER'S, so fileopen must not cancel it. Dispatched rather than clicked,
  # because a real Cmd-click opens a tab the test cannot close cleanly; the spy on document runs after
  # the link's own listeners and cancels the navigation itself.
  test "a modifier click is left to the browser" do
    visit files_path(folder: legs.node_id, view: "grid")
    prevented = page.evaluate_script(<<~JS)
      (() => {
        const a = [...document.querySelectorAll(".grid-card")].find((el) => el.textContent.includes("bracket.stl"))
        let seen = null
        document.addEventListener("click", (ev) => { seen = ev.defaultPrevented; ev.preventDefault() }, { once: true })
        a.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true, detail: 1, button: 0 }))
        return seen
      })()
    JS
    assert_equal false, prevented, "fileopen cancelled a Cmd-click"
    assert_no_console_errors
  end

  # IN PLACE IS THE CLAIM, and the visit counter is what can tell: following the menu's details url
  # would ALSO land on this Library with the panel open (the server honours `selected=`), so every
  # other assertion here passes on a navigation too. A visit replaces the page, so the counter reads
  # nil rather than 0.
  test "right-click › Details opens the panel in place; Escape closes; reload restores" do
    visit files_path(folder: legs.node_id, view: "grid")
    page.execute_script("window.__visits = 0; addEventListener('turbo:before-visit', () => window.__visits++)")
    details_for(".grid-card", "bracket.stl")
    assert_selector ".library.has-inspector .inspector .inspector-name", text: "bracket.stl"
    assert_equal 0, page.evaluate_script("window.__visits"), "Details navigated instead of opening the panel"
    assert_includes page.current_url, "selected=#{bracket.node_id}"
    assert_selector ".grid-card.is-selected", count: 1, text: "bracket.stl"
    assert_current_path files_path, ignore_query: true

    visit page.current_url
    assert_selector ".inspector .inspector-name", text: "bracket.stl"

    find(".grid-card.is-selected").send_keys(:escape)
    assert_no_selector ".library.has-inspector"
    refute_includes page.current_url, "selected="
    assert_no_console_errors
  end

  test "Details from Recent lands in the Library with the panel open" do
    visit root_path
    details_for(".recent-grid .grid-card", "plate.stl")
    assert_current_path files_path, ignore_query: true
    assert_includes page.current_url, "folder=#{legs.node_id}"
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    assert_no_console_errors
  end

  test "arrow keys move the selection while the panel is open, and only then" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").send_keys(:arrow_right)
    assert_no_selector ".grid-card.is-selected"
    assert_no_selector ".library.has-inspector"

    visit files_path(folder: legs.node_id, view: "grid", selected: bracket.node_id)
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    find(".grid-card.is-selected").send_keys(:arrow_right)
    assert_selector ".grid-card.is-selected", count: 1, text: "plate.stl"
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    assert_includes page.current_url, "selected=#{plate.node_id}"
    assert_no_console_errors
  end
```

  The re-sort test: replace each `find("table.files a", text: X).click` with
  `details_for("table.files a", X)`, and the grid one likewise; the assertions stay. The phone test:
  replace `find(".grid-card", text: "bracket.stl").click` with `details_for(".grid-card", "bracket.stl")`.
  Delete the old "click selects …", "double-click opens …" and "arrow keys move the selection" tests
  (replaced above). The old double-click test's "THE REFERER CARRIES THE SELECTION" assertion moves
  into the Details test: after Details, `find(".inspector a", text: "Open").click`, then
  `assert_includes find_link("Back")[:href], "selected=#{bracket.node_id}"`.

- [ ] **Step 8: Docs.** In `docs/invariants/files-preview.md`:
  - "The inspector is ONE node's frame" → the "The tiles stay links" bullet: rewrite its first two
    sentences to "**The tiles stay links.** A click opens the file and a double-click opens it in a new
    tab (`fileopen_controller.js`, 2026-10-21); the panel opens from the file menu's Details
    (`filemenu:details` → `selection_controller.js#details`) or a `?selected=` page. Every tile keeps
    `href=file_path`, which a single click, the file menu's Open, a modifier click, Enter and
    no-JavaScript all rely on." Keep the rest of the bullet (the strip, Recent and the hub), and
    change "their tiles and list rows link `file_path` and open the file" to add "on a click, and in a
    new tab on a double-click".
  - The `:model3d` section's sentence "Since slice 5 the model page renders only for a model with no
    folder strip to land on; the Library's model strip carries no viewer, so in a model folder the
    manifest reaches the viewer through the file page." becomes "Every model renders its own page
    (2026-10-21); a file opened in its pane goes through `files/_viewer`, the file page's own chain, so
    the manifest reaches the viewer the same way on both."
  - `grep -rn "click selects\|selection#click\|double-click opens\|Click to select" app docs/invariants test`
    and fix every hit this task's change falsifies.

- [ ] **Step 9: Run green.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/helpers/files_helper_test.rb test/integration/web/files_selection_test.rb test/integration/web/file_menu_wiring_test.rb test/stimulus_hygiene_test.rb
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/files_selection_test.rb test/system/file_menu_test.rb
```

- [ ] **Step 10: Mutation checks.** (a) Restore the old click-to-select wiring — `"click->selection#click"`
  in `with_selection`, `click(event)` in `selection_controller.js` — AND drop `file_open_data` from
  `_grid.html.erb`: "a click opens the file page" goes red (the click selects and stays). (Either half
  alone stays green, because a plain link and a fileopen link both open the page on a click; the
  double-click test is what tells them apart.) (b) Remove the `e.preventDefault()` line in the
  Details handler: "right-click › Details opens the panel in place" goes red at the visit counter. (c) Change `WINDOW_MS` to `0`: the
  double-click test goes red (this tab navigates). (d) Delete the `metaKey` check in
  `fileopen_controller.js`: the modifier test goes red. (e) Remove the `has-inspector` gate: the first
  half of the arrows test goes red. Restore all.

---

### Task 5: The model page — files left, a pane right

**Files:**
- Modify: `app/controllers/models_controller.rb`
- Modify: `app/views/models/show.html.erb`, `app/views/models/_file_tree.html.erb`
- Create: `app/views/models/_stage.html.erb`, `app/views/models/_details.html.erb`
- Create: `app/javascript/controllers/modelstage_controller.js`
- Modify: `app/assets/stylesheets/pages/models.css`
- Modify: `app/views/files/_model_strip.html.erb` (title link)
- Modify: `app/services/maker/model_folder.rb` (delete `landing_folder_id`)
- Modify: `app/controllers/files_controller.rb` (one comment near line 267 only — Task 4 has finished)
- Modify: `docs/invariants/model-intake.md`, `docs/invariants/design-system.md` (rule 8's "model pages that survive")
- Test: `test/integration/web/models_redirects_test.rb`, `test/services/maker/model_folder_test.rb`,
  `test/integration/web/page_query_budget_test.rb`, `test/integration/web/model_strip_test.rb`
- Create tests: `test/integration/web/model_stage_test.rb`, `test/system/model_page_test.rb`

- [ ] **Step 1: Failing request tests.** Create `test/integration/web/model_stage_test.rb`:

```ruby
require "test_helper"

module Web
  # THE MODEL PAGE (2026-10-21, docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md):
  # every model renders its own page, the list on the left targets the `model_stage` frame on the
  # right, and `?file=` picks what that pane shows — one of this model's live files, `details`, or the
  # default for anything else (the first live instructions file, else Details). Never an error.
  #
  # ROWS ONLY, BOTH TOKEN COLUMNS (template_hygiene_test.rb#file!'s shape), so the stat answers on
  # every backend leg without bytes behind it.
  class ModelStageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "ms-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @user.nodes.create!(node_id: "d-bracket", name: "bracket", kind: "dir", mtime: 1, size: 0)
      file!("n-stl", "bracket.stl")
      file!("n-pdf", "assembly.pdf")
      file!("n-src", "notes.txt")
      @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      attach!("n-stl", "model", 0)
      attach!("n-pdf", "instructions", 1)
      attach!("n-src", Maker::FileAttachment.role_for("notes.txt"), 2)
    end

    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", parent_node_id: "d-bracket", mtime: 1, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
    end

    def attach!(node_id, role, position)
      @model.file_attachments.create!(user: @user, node_id:, role:, position:)
    end

    test "a folder model renders its own page, opening on its instructions" do
      get model_path(@model)
      assert_response :success
      assert_select ".page-head h1", text: "Wall Bracket"
      assert_select "turbo-frame#model_stage iframe.preview-pdf[src=?]", blob_file_path("n-pdf")
      assert_select ".model-index a[aria-current='true'][href=?]", model_path(@model, file: "n-pdf")
    end

    test "with no instructions the pane opens on Details" do
      @model.file_attachments.find_by!(node_id: "n-pdf").destroy!
      get model_path(@model)
      assert_select "turbo-frame#model_stage .model-details"
      assert_select ".model-index a.model-index-details[aria-current='true']"
    end

    test "?file=details shows Details even when the model has instructions" do
      get model_path(@model, file: "details")
      assert_select "turbo-frame#model_stage .model-details"
      assert_select "turbo-frame#model_stage iframe.preview-pdf", count: 0
    end

    test "?file= shows a listed file in the pane, with its own Download and file-page doors" do
      get model_path(@model, file: "n-stl")
      assert_select "turbo-frame#model_stage .model-viewer"
      assert_select "turbo-frame#model_stage .model-stage-head a[href=?]", file_path("n-stl"), text: "Open file page"
      assert_select "turbo-frame#model_stage .model-stage-head a[href=?]", blob_file_path("n-stl", download: 1),
                    text: "Download"
      assert_select ".model-index a[aria-current='true'][href=?]", model_path(@model, file: "n-stl")
    end

    # THE PANE VIEWS, THE FILE PAGE EDITS: a text file is the read-only code viewer here, never the
    # editor, and Measure carries no save doors (files/_viewer's `editable:`/`save:`).
    test "the pane is read-only" do
      get model_path(@model, file: "n-src")
      assert_select "turbo-frame#model_stage [data-controller='codeview']"
      assert_select "turbo-frame#model_stage [data-controller='editor']", count: 0
    end

    test "a foreign node, a tombstone, a folder, garbage and a non-string fall back to the default" do
      other = User.create!(email: "ms-o-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "n-theirs", name: "x.stl", kind: "file", mtime: 1, size: 1)
      file!("n-gone", "gone.stl").update!(deleted: true)
      attach!("n-gone", "model", 3)
      [ "n-theirs", "n-gone", "d-bracket", "no-such-node" ].each do |id|
        get model_path(@model, file: id)
        assert_response :success
        assert_select "turbo-frame#model_stage iframe.preview-pdf[src=?]", blob_file_path("n-pdf"),
                      "#{id} did not fall back to the default"
      end
      get "#{model_path(@model)}?file[]=n-stl"
      assert_response :success
      assert_select "turbo-frame#model_stage iframe.preview-pdf"
    end

    # A FRAME REQUEST IS THE PANE ALONE, so switching files costs one viewer's setup: no page head, no
    # list, no Details sections.
    test "a frame request renders the pane alone" do
      get model_path(@model, file: "n-stl"), headers: { "Turbo-Frame" => "model_stage" }
      assert_response :success
      assert_select "turbo-frame#model_stage .model-viewer"
      assert_select ".page-head", count: 0
      assert_select ".model-index", count: 0

      get model_path(@model, file: "details"), headers: { "Turbo-Frame" => "model_stage" }
      assert_select "turbo-frame#model_stage .model-details"
      assert_select ".model-index", count: 0
    end

    test "the list's file links target the pane and open the file page in a new tab" do
      get model_path(@model)
      links = css_select(".model-index .tree-fname")
      assert_equal %w[n-pdf n-src n-stl].sort, links.map { |a| a["href"][/file=([^&]+)/, 1] }.sort
      links.each do |a|
        id = a["href"][/file=([^&]+)/, 1]
        assert_equal "model_stage", a["data-turbo-frame"]
        assert_equal "advance", a["data-turbo-action"]
        assert_equal file_path(id), a["data-fileopen-new-tab-url"]
        assert_includes a["data-action"], "click->fileopen#click"
      end
    end
  end
end
```

- [ ] **Step 2: Run, expect red** (a 302 on the first test, and no `.model-index`).

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/model_stage_test.rb
```

- [ ] **Step 3: The controller.** In `app/controllers/models_controller.rb`:
  - add `include FileViewer` under `include PageNodes`, and rewrite the class header's slice-5
    paragraph: since 2026-10-21 `#show` renders every model's own page (no redirect to its folder);
  - replace `#show` with the following, keeping every existing comment by moving it beside the line
    it explains (the `A FILE DELETED FROM THE LIBRARY` block stays above `all_attachments`; the
    `@file_tree` block stays above `@file_tree`; the hero, covers and `@viewable_3d` blocks move into
    `load_details`):

```ruby
  # EVERY MODEL HAS ITS OWN PAGE (2026-10-21): its files on the left, a pane on the right
  # (models/_stage), Printables-style. Until then a model whose folder showed the Library's strip was
  # sent there with a 302 (Maker::ModelFolder.landing_folder_id, deleted); the owner asked for a model
  # with several files to open a page of its own instead.
  def show
    all_attachments = @model.file_attachments.order(:position).to_a
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + [ @model.cover_node_id ])
    @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
    @missing_attachment_count = missing.size
    @stage = stage_for(params[:file])
    @viewer = viewer_state_for(@stage) unless @stage == :details
    # A FRAME REQUEST IS THE PANE ALONE: the list sits outside the frame (its scroll survives a click),
    # so a file switch needs one viewer's setup and nothing else — not the tree walk, not the hero's
    # covers, not the print log. Details is the one pane that needs the details data.
    if turbo_frame_request_id == "model_stage"
      load_details if @stage == :details
      return render(partial: "models/stage", locals: { model: @model, stage: @stage, viewer: @viewer })
    end

    @file_tree  = file_tree_for_model
    @file_count = count_files(@file_tree)
    load_details
  end
```

  and, under `private`:

```ruby
  # WHICH PANE THE PAGE OPENS ON: `?file=details`, `?file=<one of this model's LIVE attachments>`,
  # or — for anything else, a foreign node, a tombstone, a folder, garbage, a non-string — the
  # default, never an error: the first live instructions attachment by position, else Details. The
  # tree on the left lists a subset of the live attachments (file_tree_for_model), and the gallery
  # can name an image outside the folder, so the attachments are the set to validate against.
  def stage_for(requested)
    return :details if requested == "details"

    live = @attachments.index_by(&:node_id)
    return @page_nodes[requested] if requested.is_a?(String) && live.key?(requested)

    first = @attachments.find { |a| a.role == "instructions" }
    first ? @page_nodes[first.node_id] : :details
  end

  # What the Details pane and the hero read: by-role groups, the cover, the covers map, the 3D
  # switcher's files, the print log. Everything that was #show's body below the attachments.
  def load_details
    @by_role = @attachments.group_by(&:role)
    @cover_att = @attachments.find { |a| a.node_id == @model.cover_node_id }
    # … the existing gallery/@covers lines and their comments, verbatim …
    # … the existing @viewable_3d / @viewable_3d_default lines and their comments, verbatim …
    @print_runs = @model.print_runs.reorder(printed_on: :desc, id: :desc).to_a
    @printers, @materials = Maker::PrintRun.composer_choices(current_user)
  end
```

- [ ] **Step 4: The templates.** `app/views/models/_stage.html.erb`:

```erb
<%# locals: (model:, stage:, viewer:) %>
<%# THE MODEL PAGE'S PANE (2026-10-21): Details, or one of the model's files through files/_viewer,
    the file page's own chain. A Turbo Frame the list's links target (data-turbo-frame), and
    `target="_top"` so every link and form INSIDE it — Download, Open file page, Edit, the print
    log's forms — moves the whole page rather than the pane. The gallery's links opt back into the
    frame explicitly (models/_details).

    THE PANE VIEWS; THE FILE PAGE EDITS. `editable: false` and `save: false` are the visitor's modes
    of the code and Measure viewers, already supported, so nothing here can write to the library;
    editing, notes and history are one click away through "Open file page". No thumbnail poll
    either: a render in flight shows the viewer's own "Generating preview…". %>
<%= turbo_frame_tag "model_stage", class: "model-stage", target: "_top",
                    data: { modelstage_target: "stage" } do %>
  <% if stage == :details %>
    <%= render "models/details" %>
  <% else %>
    <div class="model-stage-head">
      <h2 class="model-stage-name"><%= stage.name %></h2>
      <span class="model-stage-actions">
        <%= link_to "Download", blob_file_path(stage.node_id, download: 1), class: "btn small" %>
        <%= link_to "Open file page", file_path(stage.node_id), class: "btn small" %>
      </span>
    </div>
    <div class="preview">
      <%= render "files/viewer", viewer: viewer, editable: false, save: false %>
    </div>
  <% end %>
<% end %>
```

  `app/views/models/_details.html.erb`: a `<div class="model-details">` holding, MOVED VERBATIM from
  `models/show.html.erb` and in this order: the hero `if @viewable_3d.any? … end` (current lines
  42–100) and the gallery (102–130); the notes section (142–144); the meta `<dl class="meta">`
  (148–163) and the print-settings section (165–175); then the print log render (line 200). The
  instructions section (132–140) and the Files section (177–198) are NOT moved: the instructions are
  the default pane, and the files are the list. One change inside the gallery: its link

```erb
          <%= link_to model_path(@model, file: a.node_id),
                      data: file_open_data({ turbo_frame: "model_stage", turbo_action: "advance" },
                                           new_tab: file_path(a.node_id)) do %>
```

  Add a header comment: Details is what the main and side columns held before 2026-10-21, minus the
  file tree (the list) and the instructions iframes (the default pane); its gallery opens an image in
  the pane.

  `app/views/models/show.html.erb`: keep lines 1–36 (title, crumbs, page head) as they are. Replace
  everything from `<div class="model-layout">` to the end with:

```erb
<%# THE MODEL PAGE, PRINTABLES-STYLE (2026-10-21): the model's files on the left, a pane on the right.
    The list is OUTSIDE the frame so its scroll survives a click; modelstage_controller.js keeps its
    aria-current true across frame loads, and on a phone scrolls the pane into view. %>
<div class="model-layout" data-controller="modelstage" data-action="turbo:frame-load->modelstage#loaded">
  <nav class="model-index" aria-label="Model files">
    <%= link_to "Details", model_path(@model, file: "details"), class: "model-index-details",
                aria: { current: ("true" if @stage == :details) },
                data: { turbo_frame: "model_stage", turbo_action: "advance", modelstage_target: "entry" } %>
    <section class="model-files">
      <h2>Files <span class="muted">(<%= @file_count %>)</span></h2>
      <% if @file_tree.present? %>
        <div class="file-tree-box">
          <%= render "file_tree", nodes: @file_tree, model: @model,
                     current: (@stage == :details ? nil : @stage.node_id) %>
        </div>
      <% else %>
        <p class="muted">No files yet.</p>
      <% end %>
      <%# … the NOT SILENT comment and the missing-attachments paragraph, moved verbatim … %>
    </section>
  </nav>
  <%= render "models/stage", model: @model, stage: @stage, viewer: @viewer %>
</div>
```

  `app/views/models/_file_tree.html.erb`: first line `<%# locals: (nodes:, model:, current:) %>`;
  the header comment's "files link to the existing /files/:node_id preview page" becomes "a file
  opens in the model page's pane, and in a new tab on its file page on a double-click"; the
  recursive render becomes `render "file_tree", nodes: item[:children], model: model, current: current`;
  the file link becomes:

```erb
        <%= link_to node.name, model_path(model, file: node.node_id), title: node.name, class: "tree-fname",
                    aria: { current: ("true" if node.node_id == current) },
                    data: file_open_data({ turbo_frame: "model_stage", turbo_action: "advance",
                                           modelstage_target: "entry" },
                                         new_tab: file_path(node.node_id)) %>
```

- [ ] **Step 5: `app/javascript/controllers/modelstage_controller.js`:**

```js
import { Controller } from "@hotwired/stimulus"

// THE MODEL PAGE'S LIST AND PANE (2026-10-21). The pane is a Turbo Frame (`model_stage`) the list's
// links target, and the list sits OUTSIDE it so its scroll survives a click — which leaves the list
// to say which entry the pane now shows. The server marks it on a full render; this keeps it true
// across frame loads by reading the `file` param off the URL the frame just loaded, never off which
// link was clicked (a gallery link inside the pane loads it too). On a phone the list stacks above
// the pane (pages/models.css, below 900px), so a load there also scrolls the pane into view.
export default class extends Controller {
  static targets = ["entry", "stage"]

  loaded(event) {
    if (event.target !== this.stageTarget) return
    const shown = new URL(this.stageTarget.src, window.location.href).searchParams.get("file")
    this.entryTargets.forEach((link) => {
      if (new URL(link.href).searchParams.get("file") === shown) link.setAttribute("aria-current", "true")
      else link.removeAttribute("aria-current")
    })
    if (window.matchMedia("(max-width: 899px)").matches) this.stageTarget.scrollIntoView({ block: "start" })
  }
}
```

- [ ] **Step 6: CSS.** In `app/assets/stylesheets/pages/models.css`, replace the two `.model-layout`
  lines and their comment with:

```css
  /* THE MODEL PAGE, PRINTABLES-STYLE (2026-10-21): the model's files on the left, the pane on the
     right. One column below 900px, the list first (modelstage_controller.js scrolls the pane into
     view on a phone). Selection is ink (design-system rule 13): the shown entry is --fg on --raised. */
  .model-layout { display: grid; grid-template-columns: minmax(220px, 300px) minmax(0, 1fr); gap: 28px; align-items: start; }
  @media (max-width: 899px) { .model-layout { grid-template-columns: 1fr; } }
  .model-index-details { display: block; padding: 4px 8px; margin-bottom: 14px; border-radius: 4px; font-weight: 600; }
  .model-index a[aria-current="true"] { background: var(--raised); color: var(--fg); }
  .model-stage { display: block; min-width: 0; }
  .model-stage-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; flex-wrap: wrap; }
  .model-stage-name { font-size: 15px; margin: 0; overflow-wrap: anywhere; }
  .model-stage-actions { display: inline-flex; gap: 8px; flex-wrap: wrap; }
  .model-stage .preview-pdf { width: 100%; height: 75vh; }
```

  Delete the now-unused `.model-main .preview-pdf` rule and the `.model-instructions` selector from
  the shared `h2` rule (keep `.model-notes` and `.model-files` there). Then run
  `LIBRARY_PATH=$(mktemp -d) bin/rails test test/css_hygiene_test.rb`.

- [ ] **Step 7: The strip, the service and the dead tests.**
  - `files/_model_strip.html.erb`: `<h2><%= model.title %></h2>` → `<h2><%= link_to model.title, model_path(model) %></h2>`;
    add to its header comment that the title opens the model's own page.
  - `app/services/maker/model_folder.rb`: delete `landing_folder_id` and its comment; rewrite the
    module header so it answers ONE question ("which model does this folder show?"), noting that the
    redirect it also fed was removed on 2026-10-21 when every model got its own page.
  - `test/services/maker/model_folder_test.rb`: delete the three `landing_folder_id` tests.
  - `test/integration/web/model_strip_test.rb`: add `assert_select ".model-strip h2 a[href=?]", model_path(<the fixture's model>)`
    to the test that asserts the strip's title.
  - `test/integration/web/models_redirects_test.rb`: rewrite the header comment (the `/models` index
    still 301s to the Library view; a model page no longer redirects). Replace "a folder model's page
    redirects to its folder…" with:

```ruby
    test "a folder model renders its own page, never a redirect to its folder" do
      model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: "d-bracket")
      get model_path(model)
      assert_response :success
      assert_select ".page-head h1", text: "Wall Bracket"
    end
```

    Delete "a model whose folder is in the trash keeps the model page" and "a model whose folder a
    project claims keeps the model page" (the cases a redirect could take are gone; the first test
    covers the page). In "another user's folder model is a 404…" delete the `landing_folder_id`
    fixture assertion and its comment's redirect sentence; keep the 404 assertion.
  - `app/controllers/files_controller.rb` near line 267: the parenthetical "(the redirect from
    /models/:id reads it …)" goes; `Maker::ModelFolder` is the strip's one definition.

- [ ] **Step 8: Query budget.** In `test/integration/web/page_query_budget_test.rb`, below
  "models#show does not grow with attachments or print runs", add:

```ruby
    # THE PANE (2026-10-21): one file's viewer, whatever the model holds. The first attachment is the
    # one shown at both sizes, so the measurement is the page around one viewer, not the viewer.
    test "models#show with a file in the pane does not grow with attachments or print runs" do
      model = @user.maker_models.create!(title: "Paned", slug: "paned")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          model.file_attachments.create!(user: @user, node_id: id, role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success")
        end
      end
      assert_constant_queries(model_path(model, file: "ps0"),
                              -> { add.call("ps", SMALL) },
                              -> { add.call("pl", LARGE - SMALL) },
                              "models#show (file pane)")
    end
```

- [ ] **Step 9: System test.** Create `test/system/model_page_test.rb`:

```ruby
require "application_system_test_case"

# THE MODEL PAGE IN A BROWSER (2026-10-21): the list swaps the pane without reloading the page, the
# URL and the list's mark follow, Back walks the panes, a double-click opens the file page in a new
# tab, and at phone width the pane is scrolled into view. No instructions PDF in this fixture on
# purpose: headless Chrome's PDF handling is not what is under test, and the request suite pins the
# PDF default (model_stage_test.rb).
class ModelPageTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    dir = @root.join("Models/bracket")
    dir.mkpath
    dir.join("bracket.stl").write("solid bracket\nendsolid bracket\n")
    dir.join("notes.txt").write("print it flat\n")
    # TEN MORE PARTS so the list is taller than a phone screen: the phone test needs the pane to start
    # below the fold, or scrolling it into view is a no-op it cannot tell from a missing scroll.
    (1..10).each { |i| dir.join(format("part-%02d.stl", i)).write("solid p\nendsolid p\n") }
    @user = sign_in_as("model-page@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: node("Models/bracket").node_id)
    @user.nodes.where(parent_node_id: @model.folder_node_id, kind: "file").order(:name).each_with_index do |n, i|
      @model.file_attachments.create!(user: @user, node_id: n.node_id, role: Maker::FileAttachment.role_for(n.name),
                                      position: i)
    end
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def node(path) = @user.nodes.find_by!(storage_path: path)
  def stl = node("Models/bracket/bracket.stl")
  def notes = node("Models/bracket/notes.txt")

  test "a file in the list opens in the pane, the URL and the mark follow, and Back walks back" do
    visit model_path(@model)
    assert_selector "turbo-frame#model_stage .model-details"
    # THE LIST IS NOT RE-RENDERED: a marker on it survives the click, which a full page visit would drop.
    page.execute_script("document.querySelector('.model-index').dataset.marker = 'kept'")

    within(".model-index") { click_link "notes.txt" }
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    assert_includes page.current_url, "file=#{notes.node_id}"
    assert_selector ".model-index a[aria-current='true']", count: 1, text: "notes.txt"
    assert_equal "kept", page.evaluate_script("document.querySelector('.model-index').dataset.marker")

    within(".model-index") { click_link "bracket.stl" }
    assert_selector "turbo-frame#model_stage .model-viewer"
    assert_selector ".model-index a[aria-current='true']", count: 1, text: "bracket.stl"

    page.go_back
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    assert_includes page.current_url, "file=#{notes.node_id}"

    within(".model-index") { click_link "Details" }
    assert_selector "turbo-frame#model_stage .model-details"
    assert_selector ".model-index a.model-index-details[aria-current='true']"
    assert_no_console_errors
  end

  test "a double-click on a list entry opens its file page in a new tab" do
    visit model_path(@model)
    tab = window_opened_by { find(".model-index a", text: "bracket.stl").double_click }
    within_window(tab) { assert_current_path file_path(stl.node_id) }
    sleep 0.5 # outlasts fileopen's window: an uncancelled single click would have swapped the pane
    assert_selector "turbo-frame#model_stage .model-details"
    tab.close
    assert_no_console_errors
  end

  test "at phone width the list stacks, a click scrolls the pane into view, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 500,
                                    deviceScaleFactor: 1, mobile: false)
    visit model_path(@model)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
           "the model page scrolls sideways"
    # MEASURED AGAINST ITSELF, NOT A LITERAL: whichever element scrolls (the document or the shell),
    # a pane scrolled into view sits higher on screen than it did before the click, and one that was
    # not has not moved — a frame swap replaces the pane's contents, never its position.
    pane_top = "document.querySelector('#model_stage').getBoundingClientRect().top"
    before = page.evaluate_script(pane_top)
    within(".model-index") { click_link "notes.txt" }
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    after = page.evaluate_script(pane_top)
    assert_operator after, :<, before - 40, "the pane was not scrolled into view (#{before}px → #{after}px)"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
```

  If `before` is already near the top of the viewport (under ~150px), the page above the pane is
  shorter than measured here: add parts to the fixture until it is not, so the assertion can fail.
  Step 11's mutation (e) proves it can.

- [ ] **Step 10: Docs.**
  - `docs/invariants/model-intake.md`: rewrite the bullet "THE MODEL STRIP AND THE REDIRECTS REPLACE
    THE MODEL PAGE…" so it says every model renders its own page (2026-10-21, files left, pane right),
    the strip stays above a model folder's files and its title links the page, and `/models` still
    301s to `/files/models`; rewrite the next bullet so `Maker::ModelFolder` answers ONE question
    (`model_in`, the strip) and drop every `landing_folder_id`/"302s there"/"a 302, never a 301"
    sentence; fix the earlier "only on the page that survives slice 5" sentence about the file tree
    panel (the panel is now the page's list, on every model).
  - `docs/invariants/design-system.md` rule 8: "on the model pages that survive (`models/*`, …)" →
    "on the model pages (`models/*`, …)".
  - `grep -rn "landing_folder_id\|survives slice 5\|strip to land on\|redirects to its folder" app lib docs/invariants test`
    must return nothing when you finish (Task 3 rewrites the one in `template_hygiene_test.rb`; leave
    that one).

- [ ] **Step 11: Run green, then mutation checks.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/model_stage_test.rb test/integration/web/models_redirects_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_pages_test.rb test/integration/web/models_catalog_test.rb test/integration/web/page_nodes_test.rb test/integration/web/model_strip_test.rb test/services/maker/model_folder_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb test/integration/web/print_runs_test.rb
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/model_page_test.rb test/system/o3dv_test.rb test/system/projects_models_pages_test.rb
```

  Mutations: (a) restore the redirect at the top of `#show` (`redirect_to files_path(folder: @model.folder_node_id)` when present): "a folder model renders its own page" goes red. (b) Make `stage_for` return
  `@page_nodes[requested]` without the `live.key?` check: the fallback test goes red on `n-gone`.
  (c) Pass `editable: true` in `_stage.html.erb`: "the pane is read-only" goes red. (d) Remove the
  frame-request early return: "a frame request renders the pane alone" goes red. (e) Delete the
  `scrollIntoView` line: the phone test goes red. (f) Delete the aria-current loop: the first system
  test goes red at the second mark. Restore all.

---

### Task 3: Every other surface, and the guard that keeps it so

**Files:**
- Modify: `app/views/home/index.html.erb`, `app/views/projects/_file_tile.html.erb`,
  `app/views/projects/_file_rows.html.erb`, `app/views/projects/_photos.html.erb`,
  `app/views/projects/_schematics.html.erb`, `app/views/projects/_hero.html.erb`,
  `app/views/projects/_block_panel.html.erb`, `app/views/projects/_bom_lines.html.erb`,
  `app/views/shared/_result_group.html.erb`, `app/views/files/_connections.html.erb`
- Modify: `app/javascript/lib/file_chooser.js` (browse-mode file links)
- Test: `test/integration/web/template_hygiene_test.rb`

- [ ] **Step 1: The failing guard.** In `test/integration/web/template_hygiene_test.rb`, add two
  entries to `pages` beside the other model entries:

```ruby
        # 2026-10-21: the model page's pane with a FILE in it, the one page that renders
        # models/_stage's file arm (its head, Download and "Open file page").
        "model detail (file pane)" => model_path(@model, file: "n-stl"),
```

  rewrite the `FOLDERLESS ON PURPOSE (structural redesign slice 5)` comment above `@model`: every
  model renders its page since 2026-10-21; `@model` stays folderless so "model detail" sweeps the
  attachment-list fallback of `file_tree_for_model`. Then add the test:

```ruby
    # A CLICK OPENS A FILE AND A DOUBLE-CLICK OPENS IT IN A NEW TAB, ON EVERY FILE LINK (2026-10-21,
    # docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md). RIDES THE `pages` SWEEP
    # for the reason the .page-head test gives: a page added there is covered with no edit, so a new
    # surface that links a file page without FilesHelper#file_open_data goes red here instead of
    # opening on the first half of a double-click. Two exclusions and no list: rendered Markdown (a
    # README, a text block) is prose, and a `.btn` is an action. A file page link is `/files/<a node
    # id of this fixture>` exactly — no query, no fragment, no second segment (a blob or notes URL).
    test "every link to a file page opens through fileopen" do
      node_ids = @user.nodes.pluck(:node_id).to_set
      seen = 0
      offenders = []
      pages.each do |name, path|
        get path
        assert_response :success, "#{name} (#{path}) did not render"
        css_select("a[href]").each do |a|
          uri = URI.parse(a["href"]) rescue next
          next unless uri.host.nil? && uri.query.nil? && uri.fragment.nil?
          id = uri.path[%r{\A/files/([^/]+)\z}, 1]
          next unless id && node_ids.include?(id)
          next if a.ancestors(".markdown").any? || a.classes.include?("btn")
          seen += 1
          next if a["data-action"].to_s.include?("click->fileopen#click")
          offenders << "#{name}: #{a.to_html.first(140)}"
        end
      end
      # NON-VACUITY FIRST (§14e): a sweep that matched no file link would pass over nothing.
      assert_operator seen, :>, 20, "only #{seen} file-page links were examined across #{pages.size} pages"
      assert_empty offenders, offenders.uniq.join("\n")
    end
```

- [ ] **Step 2: Run it, expect red** naming the project hub, Recent's comment-only surfaces, search
  and the file page's connections.

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/template_hygiene_test.rb -n "/fileopen/"
```

- [ ] **Step 3: Opt every surface in** with `file_open_data`, appending to any `data:` already there
  (`data: file_open_data(<existing hash>)`) or adding `data: file_open_data` where there is none:
  - `home/index.html.erb`: both tile links (`thumb_cell_data(…).merge(file_menu_data(…))` and
    `file_menu_data(…)`); rewrite the line-11 comment ("a link to its file page, never a selection
    item") to add "a click opens it, a double-click opens it in a new tab".
  - `projects/_file_tile.html.erb`: the tile link; same comment sentence in its header.
  - `projects/_file_rows.html.erb`: the `col-name` link (the menu stays on the `<tr>`).
  - `projects/_photos.html.erb`, `projects/_schematics.html.erb`: the file links.
  - `projects/_hero.html.erb`: both `link_to file_path(@cover_node.node_id)` links.
  - `projects/_block_panel.html.erb`: the image block's two links (NOT the Markdown resolver's links,
    which render inside `.markdown`).
  - `projects/_bom_lines.html.erb`: the `:design_file` name link.
  - `shared/_result_group.html.erb`: the `:file` arm's link and the `:note` arm's file link.
  - `files/_connections.html.erb`: all four groups' links.
  - Re-run Step 2's command. If it names a link not in this list, give it `file_open_data` unless it
    renders inside `.markdown` or is a `.btn`; never widen the exclusions.

- [ ] **Step 4: The repo browser's links.** In `app/javascript/lib/file_chooser.js`, `rowEl`, inside
  the `if (this.fileUrlTemplate)` block after `setAttribute("href", …)`:

```js
      // A CLICK OPENS THE FILE, A DOUBLE-CLICK OPENS IT IN A NEW TAB (2026-10-21) — the same opt-in
      // every server-rendered file link carries (FilesHelper#file_open_data). Stimulus binds the
      // action when the row is inserted; fileopen is mounted on the layout's <main>, which holds
      // every browse-mode host (projects/_repo_browser).
      link.dataset.action = "click->fileopen#click"
```

  Then run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/repo_browser_test.rb`; a test there
  that clicks a file link and asserts the file page must still pass (Capybara waits out the 250 ms).

- [ ] **Step 5: Run green.**

```bash
LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/template_hygiene_test.rb test/integration/web/home_test.rb test/integration/web/project_attachments_test.rb test/integration/web/projects_flow_test.rb test/integration/web/file_menu_wiring_test.rb
LIBRARY_PATH=$(mktemp -d) bin/rails test test/system/home_test.rb test/system/repo_browser_test.rb test/system/projects_models_pages_test.rb
```

  Report the `seen` count from the guard's first green run, and lower the floor to roughly half of
  it if 20 is far below (the floor is a non-vacuity check, not a pin).

- [ ] **Step 6: Mutation checks.** (a) Remove `file_open_data` from `files/_connections.html.erb`'s
  first group: the guard goes red naming "file detail (3d)". (b) Change the floor to `> 10_000`: it
  goes red at the floor, proving `seen` counts. (c) Remove the `.markdown` exclusion: the guard goes
  red on a README link (if it does not, say so — then no swept page renders a Markdown file link,
  and the exclusion is unexercised; report it rather than inventing a fixture). Restore all.

---

## Close-out (orchestrator)

- [ ] `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync` and run bare
  `bin/ci` from the worktree; all three backend legs must report identical RUN counts.
- [ ] `/finish-branch`: commit, push, open the PR, then `bin/log arc --from-pr <n>`.
