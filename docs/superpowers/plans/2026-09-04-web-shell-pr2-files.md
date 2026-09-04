# Web Shell PR 2: The Files Pages — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file (each task below is one coherent unit), dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver step 2 of the spec's delivery order (`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md` §8 "Files index" and "File show"): one toolbar row on the Files page with Upload as the primary action and the rest in an overflow menu, the dashed upload panel gone, richer grid tiles, and a file page whose notes composer opens on demand — without renaming a single class or label the tests pin.

**Architecture:** Template-level restructuring of `files/index.html.erb`, `files/_grid.html.erb` and `files/show.html.erb` on top of the PR 1 design system; one new component (`details.menu`, an overflow menu that a ten-line Stimulus controller closes on outside click) and a handful of page rules in `pages/files.css`. Both upload flows, the type filter, the sort form, the pager and every data attribute the JS controllers read keep their exact markup.

**Tech Stack:** Rails 8, Propshaft, Stimulus, Minitest request tests under `test/integration/web/`, Capybara/Selenium system tests under `test/system/`.

---

## Before you start

- Branch: `claude/ui-rework-pr2-files`, in the worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests need `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`. `bin/ci style` is rubocop (rails-omakase: double quotes, `[ a, b ]` with inner spaces). The full gate is `bin/ci` with `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`; only ONE full-suite run at a time in this worktree (the test database is shared).
- Read `docs/invariants/files-preview.md` (you touch `app/views/files/`) and `docs/invariants/design-system.md` (§14m) first. Never write the ERB close delimiter inside an ERB comment; every `data-controller` value is a literal.
- **The contract this PR must not break** — a full sweep of the 52 tests that drive these two pages (2026-09-04) pins these; keep each exactly:
  - Index: `h1` "Files"; `.view-toggle .toggle(.active)` with hrefs from `files_query_base`; `.ext-filter`, `.ext-picker` (`select#ext-add[name=add_ext]`, `optgroup[label]`, `option[value]`, the hidden `ext`/`q` inputs, the `disabled` + `title` state, `.muted` "no files yet"), `.ext-active a.chip.active[aria-current=true] .chip-x`, `a.clear-filter`; `p.hidden-toggle.muted a` with `href*="hidden=1"`/`"hidden=0"` and texts "Show dot-files"/"Hide dot-files"; `p.truncated` text `/first N of M/i`; `nav.pager` with `.pager-status`, `.pager-prev[rel=prev]`, `.pager-next[rel=next]`; `form.sort-form` with `select[name=sort]`, `select[name=dir]` and hidden `folder`/`ext`/`q` inputs; `form.uploader[action=?]` / `section.uploader[data-controller=uploader]`, `label.upload-btn` containing `span` "Upload a file", the hidden `redirect_url` input, `.upload-status`; `a.upload-alt[href=?]` with texts "Upload to library root instead" / "Upload to project “X” instead"; `form[action=rescan_files_path] button` matching `/rescan/i`, absent on a non-scannable backend; `p.empty.muted` with the four sentences; `.files-grid[data-controller="thumbs filemenu"][data-thumbs-url-value]`, `.grid-card`, `.grid-folder`, `.grid-card.file-cell` (with `img` once ready), `.grid-name`, `.generic-thumb`, `.note-badge`; `table.files` and every `col-*` cell in its current order (tests read cells by position); every `data-*` attribute `thumb_cell_data`/`file_menu_data` emit.
  - Show: `.page-head h1`; `.page-actions` holding `a.btn` "Download", the `button_to` "Delete" `.btn.danger`, the addon-origin `a[href]` "Edit in …", and **the Back link as the only `a.btn.ghost`** (`back_link_test` reads `.page-actions a.btn.ghost` first); `dl.meta dt/dd` ("Saved item", "· vN"); `.attach-to-project` with `.project-chip`, `.chip-x`, `form.attach-form`, `label[for=attach_project_id]`, `select#attach_project_id[name=project_id]`; `.preview-row(.has-settings)`, `.preview`, `img.preview-image`, `iframe.preview-pdf`, `.preview-code[data-controller=editor|codeview]` and their values, `pre.preview-text`, `.repo-banner`, `.model-viewer` and its parts, `.measure-view` and its parts, `.lbrn-settings` and its parts, `.history-panel[data-controller=history]`, `.notes-panel` with `h2`, `form.note-form` containing `lexxy-editor[attachments='false']` and posting `note[body]`, `article.note .note-body`, `.note-meta`, "No notes yet."; `dialog.move-conflict`.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/views/files/index.html.erb` | the page: head with Upload + overflow menu, one toolbar row, caption, truncation, pager, content | 1 |
| `app/views/files/_grid.html.erb` | tiles gain a mono sub-line (size · type) | 1 |
| `app/javascript/controllers/menu_controller.js` | closes an open `details.menu` on outside click / Escape | 1 |
| `app/assets/stylesheets/components.css` | `details.menu` (summary, list, item) | 1 |
| `app/assets/stylesheets/pages/files.css` | `.files-toolbar`, `.toolbar-count`, `.upload-caption`, `.grid-sub`, `.file-badge`, the notes composer row | 1 |
| `test/css_hygiene_test.rb` | `details.menu` joins `COMPONENT_SELECTORS` | 1 |
| `test/integration/web/files_toolbar_test.rb` | the toolbar, the menu, the caption, the count, the tiles | 1 |
| `app/views/files/show.html.erb` | the format badge; the notes composer | 2 |
| `test/integration/web/file_page_test.rb` | the badge; the composer keeps the form | 2 |
| `test/system/files_pages_test.rb` | the menu opens/closes; a note is written through the composer (Lexxy inside a closed `<details>`) | 3 |

**Dependencies:** Tasks 1 and 2 touch disjoint files (Task 1 owns every stylesheet; Task 2 only the show template and its test) and run in parallel. Task 3 needs both. Task 4 is the close-out.

---

### Task 1: The Files index — one toolbar row, Upload up front, the rest in a menu

**Files:**
- Modify: `app/views/files/index.html.erb`, `app/views/files/_grid.html.erb`, `app/assets/stylesheets/components.css`, `app/assets/stylesheets/pages/files.css`, `test/css_hygiene_test.rb`
- Create: `app/javascript/controllers/menu_controller.js`, `test/integration/web/files_toolbar_test.rb`

- [ ] **Step 1: Write the failing request tests**

`test/integration/web/files_toolbar_test.rb`:

```ruby
require "test_helper"

module Web
  # The Files page's controls (spec §8, PR 2): Upload is the primary action in the page head,
  # rescan and the upload-destination switch live in an overflow menu, and everything else —
  # the type filter, the dot-file switch, the count, the view toggle and the sort — sits on ONE
  # toolbar row in both views. Nodes are created directly, as files_type_filter_test.rb does.
  class FilesToolbarTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      file("root.stl", nil)
      file("plate.dxf", nil)
      file("firmware.bin", nil)   # no preview renderer: the generic card
      file("notes.pdf", "dir-cad")
    end

    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 2_400)
    end

    test "upload is the primary action in the page head and the dashed panel is gone" do
      get files_path
      assert_response :success
      assert_select ".page-head .page-actions label.upload-btn span", text: "Upload a file"
      assert_select ".page-head .page-actions form.uploader[action=?]", files_path
      assert_select "main .uploader", count: 1
    end

    test "rescan lives in the overflow menu on a scannable backend" do
      get files_path
      if FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu[data-controller='menu'] summary.btn"
        assert_select ".page-actions details.menu form[action=?] button.menu-item", rescan_files_path, text: /rescan/i
      else
        assert_select "form[action=?]", rescan_files_path, count: 0
      end
    end

    test "the toolbar carries the filter, the dot-file switch, the count, the view toggle and the sort, in both views" do
      %w[list grid].each do |view|
        get files_path(view:)
        assert_select ".toolbar.files-toolbar", count: 1
        assert_select ".files-toolbar .ext-picker select#ext-add"
        assert_select ".files-toolbar p.hidden-toggle a.chip[href*=?]", "hidden=1", text: "Show dot-files"
        assert_select ".files-toolbar .toolbar-count", text: "4 items"
        assert_select ".files-toolbar .view-toggle a.toggle.active", text: view.capitalize
        assert_select ".files-toolbar form.sort-form select[name='sort']"
        assert_select ".files-toolbar form.sort-form select[name='dir']"
      end
    end

    test "the count says matches when the view is flat, and keeps the truncation sentence" do
      get files_path(ext: "stl")
      assert_select ".files-toolbar .toolbar-count", text: "1 match"
      get files_path(q: "e")
      assert_select ".files-toolbar .toolbar-count", text: "3 matches"
    end

    test "a current project turns the head's upload into the project's, with a caption and a menu switch" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      get files_path
      assert_select ".page-actions label.upload-btn span", text: /Upload/
      assert_select ".page-actions form.uploader[action=?]", project_uploads_path(project)
      assert_select ".upload-to-project.upload-caption", text: /Uploads go to Desk Lamp/
      assert_select ".page-actions details.menu a.menu-item.upload-alt[href=?]",
                    files_path(upload: "library"), text: "Upload to library root instead"

      get files_path(upload: "library")
      assert_select ".page-actions form.uploader[action=?]", files_path
      assert_select ".upload-caption", count: 0
      assert_select ".page-actions details.menu a.menu-item.upload-alt[href=?]", files_path,
                    text: "Upload to project “Desk Lamp” instead"
    end

    test "no menu renders when it would be empty" do
      get files_path
      unless FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu", count: 0
      end
    end

    test "grid tiles carry a size-and-type line" do
      get files_path(view: "grid")
      assert_select ".files-grid .grid-card.file-cell .grid-sub", text: "2.34 KB · STL"
      assert_select ".files-grid .grid-card:not(.file-cell):not(.grid-folder) .grid-sub", text: "2.34 KB · BIN"
      assert_select ".files-grid .grid-folder .grid-sub", count: 0
    end
  end
end
```

Note on the last test: `firmware.bin` has no preview renderer in `Maker::Previews::Registry`, so it takes the generic-card branch (no `.file-cell`); a `.pdf` would NOT do — the registry lists pdf whether or not this box has pdfium. The test covers both card kinds and the folder.

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/files_toolbar_test.rb
```

Expected: every test fails (`.page-actions` has no uploader; there is no `.files-toolbar`).

- [ ] **Step 3: The menu component and its controller**

`app/javascript/controllers/menu_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// A <details class="menu"> is a menu the browser opens and closes for us, with no JavaScript
// and no positioning maths. The one thing native <details> will not do is close when the user
// clicks somewhere else or presses Escape — that is all this controller adds.
export default class extends Controller {
  connect() {
    this.onClick = (event) => { if (!this.element.contains(event.target)) this.element.removeAttribute("open") }
    this.onKeydown = (event) => { if (event.key === "Escape") this.element.removeAttribute("open") }
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
  }
}
```

In `app/assets/stylesheets/components.css`, after the `details.composer` rules inside `@layer components`:

```css
  /* --- Overflow menu: a <details> the browser opens; menu_controller.js closes it on an
     outside click. The summary is a .btn (the caller adds .icon for the ⋯ form). --- */
  details.menu { position: relative; display: inline-block; }
  details.menu > summary { list-style: none; }
  details.menu > summary::-webkit-details-marker { display: none; }
  details.menu[open] > summary { border-color: var(--line-strong); }
  .menu-list {
    position: absolute; right: 0; top: calc(100% + 4px); z-index: 50; min-width: 220px; padding: 4px;
    background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius-panel); box-shadow: var(--shadow-float);
  }
  .menu-list form { margin: 0; }
  .menu-item {
    display: block; width: 100%; text-align: left; padding: 7px 10px; background: none; border: 0;
    color: var(--fg); font: 13px/1.4 var(--font-ui); border-radius: var(--radius-control); cursor: pointer;
    text-decoration: none; white-space: nowrap;
  }
  .menu-item:hover { background: var(--raised); text-decoration: none; }
```

In `test/css_hygiene_test.rb` add `details.menu` to `COMPONENT_SELECTORS` (it is defined once, here).

- [ ] **Step 4: The page rules**

Append inside the `@layer pages { … }` block of `app/assets/stylesheets/pages/files.css`:

```css
  /* --- The one toolbar row (spec §8). .toolbar is the component; these are its Files tenants. */
  .files-toolbar { margin-bottom: 14px; }
  .files-toolbar .ext-filter { margin: 0; }
  .files-toolbar .hidden-toggle { margin: 0; }
  .files-toolbar .sort-form { margin: 0; }
  .toolbar-count { font: 12px/1.4 var(--font-mono); color: var(--fg-muted); white-space: nowrap; }
  .upload-caption { margin: -6px 0 12px; font-size: 12px; }
  .upload-caption strong { color: var(--fg); }
  /* The grid tile's second line: size and type, in mono, under the name. */
  .grid-sub { display: block; font: 11px/1.4 var(--font-mono); color: var(--fg-muted); text-align: center; }
  /* The file page's title row and format badge (Task 2's markup). */
  .page-head .page-title { display: flex; align-items: center; gap: 10px; min-width: 0; }
  .page-head .file-badge { font-family: var(--font-mono); text-transform: none; letter-spacing: .04em; }
  /* The notes composer (Task 2): the summary reads as a small button under the heading. */
  .notes-panel details.composer { margin: 0 0 12px; }
  .notes-panel details.composer > summary { min-height: 24px; padding: 0 8px; font-size: 12px; }
```

- [ ] **Step 5: The index template**

Replace `app/views/files/index.html.erb` with the version below. Everything inside the crumbs block, the pager, the empty states, the grid/list branches and the two upload flows is character-identical to today's; only the arrangement changes. Keep every existing ERB comment that explains a control next to its control (the ones on the hidden-file toggle, the pager, the two upload flows, the rescan gate, the sort form) — they are elided here for length, marked `[keep comment]`.

```erb
<% content_for :title, "Files — Tinkerex" %>

<% content_for :crumbs do %>
  <nav class="breadcrumb" aria-label="Folder path">
    <%= link_to "Files", files_path %>
    <% @crumbs.each_with_index do |crumb, i| %>
      <span class="sep" aria-hidden="true">/</span>
      <% if i == @crumbs.length - 1 %>
        <%= link_to crumb.name, files_path(folder: crumb.node_id), "aria-current": "page" %>
      <% else %>
        <%= link_to crumb.name, files_path(folder: crumb.node_id) %>
      <% end %>
    <% end %>
    <% if @q %>
      <span class="sep" aria-hidden="true">/</span>
      <span aria-current="page">Search “<%= @q %>”</span>
    <% end %>
  </nav>
<% end %>

<%# THE PAGE HEAD HOLDS THE ONE PRIMARY ACTION (spec §8): Upload, in whichever of its two flows
    this deployment has, or the current project's upload-and-attach control. The rest of what used
    to stack above the list — rescan, the destination switch — is an overflow menu, rendered only
    when it would have an item. %>
<% project_upload = current_project && params[:upload] != "library" %>
<% menu_items = capabilities.scannable? || current_project.present? %>
<div class="page-head">
  <h1>Files</h1>
  <div class="page-actions">
    <% if project_upload %>
      <%= render "projects/upload_control",
                 upload_url: project_uploads_path(current_project),
                 attach_url: project_attachments_path(current_project),
                 redirect_url: files_path(folder: @current_project_folder_node_id),
                 parent_node_id: @current_project_folder_node_id %>
    <% elsif capabilities.port_writable? %>
      [keep comment]
      <%= form_with url: files_path, method: :post, class: "uploader",
                    data: { turbo: false }, html: { multipart: true } do |f| %>
        <label class="upload-btn">
          <%= f.file_field :file, onchange: "this.form.requestSubmit()", hidden: true %>
          <span>Upload a file</span>
        </label>
      <% end %>
    <% else %>
      [keep comment]
      <section class="uploader"
               data-controller="uploader"
               data-uploader-begin-url-value="<%= begin_upload_files_path %>"
               data-uploader-finalize-url-value="<%= finalize_upload_files_path %>">
        <label class="upload-btn">
          <input type="file" data-uploader-target="input" data-action="uploader#upload" hidden>
          <span>Upload a file</span>
        </label>
        <span class="upload-status" data-uploader-target="status"></span>
      </section>
    <% end %>
    <% if menu_items %>
      <details class="menu" data-controller="menu">
        <summary class="btn icon" aria-label="More actions" title="More actions">⋯</summary>
        <div class="menu-list">
          <% if capabilities.scannable? %>
            [keep comment]
            <%= button_to "Rescan library", rescan_files_path(files_query_base),
                          class: "menu-item", data: { turbo: false } %>
          <% end %>
          <% if current_project %>
            <% if project_upload %>
              <%= link_to "Upload to library root instead",
                          files_path(files_query_base.merge(upload: "library")), class: "menu-item upload-alt" %>
            <% else %>
              <%= link_to "Upload to project “#{current_project.name}” instead",
                          files_path(files_query_base), class: "menu-item upload-alt" %>
            <% end %>
          <% end %>
        </div>
      </details>
    <% end %>
  </div>
</div>

<% if project_upload %>
  <p class="upload-to-project upload-caption muted">Uploads go to <strong><%= current_project.name %></strong> and are attached to it.</p>
<% end %>

<%# ONE TOOLBAR ROW: the type filter and its chips, the dot-file switch, the count, the view
    toggle and the sort — in both views (the list keeps its sortable headers as well). %>
<div class="toolbar files-toolbar">
  <%= render "ext_filter" %>
  [keep comment]
  <p class="hidden-toggle muted">
    <% if @show_hidden %>
      <%= link_to "Hide dot-files", files_path(files_query_base.merge(hidden: "0")), class: "chip active" %>
    <% else %>
      <%= link_to "Show dot-files", files_path(files_query_base.merge(hidden: "1")), class: "chip" %>
    <% end %>
  </p>
  <span class="toolbar-spacer"></span>
  <span class="toolbar-count">
    <% if @flat %>
      <%= pluralize(number_with_delimiter(@match_count), "match", "matches") %>
    <% else %>
      <%= pluralize(number_with_delimiter(@paged ? @child_count : @nodes.size), "item") %>
    <% end %>
  </span>
  <div class="view-toggle" role="group" aria-label="View">
    <%= link_to "Grid", files_path(files_query_base.merge(view: "grid")),
                class: "toggle#{' active' if @view == 'grid'}" %>
    <%= link_to "List", files_path(files_query_base.merge(view: "list")),
                class: "toggle#{' active' if @view == 'list'}" %>
  </div>
  [keep comment]
  <form method="get" action="<%= files_path %>" class="sort-form">
    <% files_query_base.each do |k, v| %>
      <input type="hidden" name="<%= k %>" value="<%= v %>">
    <% end %>
    <label class="muted" for="sort-key">Sort</label>
    <select name="sort" id="sort-key" onchange="this.form.requestSubmit()">
      <% { "name" => "Name", "type" => "Type", "modified" => "Modified" }.each do |value, label| %>
        <option value="<%= value %>" <%= "selected" if @sort == value %>><%= label %></option>
      <% end %>
    </select>
    <select name="dir" aria-label="Sort direction" onchange="this.form.requestSubmit()">
      <option value="asc"  <%= "selected" if @dir == "asc" %>>Ascending</option>
      <option value="desc" <%= "selected" if @dir == "desc" %>>Descending</option>
    </select>
  </form>
</div>

<% if @truncated %>
  <p class="truncated">
    Showing the first <%= number_with_delimiter(@nodes.size) %> of
    <%= number_with_delimiter(@match_count) %> matching files — narrow the filter to see the rest.
  </p>
<% end %>

[keep comment]
<% if @paged && @pages > 1 %>
  <nav class="pager" aria-label="Folder pages">
    … identical to today …
  </nav>
<% end %>

<% if @nodes.empty? %>
  … the four empty sentences, identical to today …
<% elsif @view == "grid" %>
  <%= render "grid" %>
<% else %>
  <%= render "list" %>
<% end %>
```

Two things the test pins that this preserves: `a.upload-alt[href=?]` (now inside the menu, same hrefs), and `form[action=rescan_files_path] button` (a `button_to` renders `<form class="button_to"><button class="menu-item">`).

`pluralize(number_with_delimiter(1), "match", "matches")` renders "1 match"; check `pluralize`'s signature takes the plural as the third positional argument in this Rails (it does since 4.x).

- [ ] **Step 6: The grid tile's sub-line**

In `app/views/files/_grid.html.erb`, after each `<span class="grid-name">…</span>` on the two FILE branches (not the folder branch), add:

```erb
        <span class="grid-sub"><%= [ (info.content_token ? number_to_human_size(info.size) : nil), ext_label.presence ].compact.join(" · ") %></span>
```

so a file with content and an extension reads `2.34 KB · STL`, one with neither renders an empty line-free span (the `compact.join` is empty and the span collapses).

- [ ] **Step 7: Run the tests and the guards**

```bash
bin/rails test test/integration/web/files_toolbar_test.rb test/integration/web/files_type_filter_test.rb \
  test/integration/web/files_sort_test.rb test/integration/web/files_pagination_test.rb test/integration/web/files_search_test.rb \
  test/integration/web/files_flow_test.rb test/integration/web/current_project_files_upload_test.rb test/integration/web/rescan_test.rb \
  test/integration/web/files_git_marker_test.rb test/integration/web/file_menu_wiring_test.rb test/integration/web/file_cell_payload_test.rb \
  test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/integration/web/template_hygiene_test.rb
bin/ci style
```

Expected: all green. If `files_sort_test` asserts the sort form only in grid view and fails on the list run, read the assertion — it will be about the hidden `folder` input's value or the selected option, both of which the moved form still emits.

- [ ] **Step 8: Mutation-check, reporting output**

```bash
# The menu's non-emptiness rule: render it always → "no menu renders when it would be empty" fails on chunk_remote-shaped runs.
sed -i '' 's/<% menu_items = capabilities.scannable? || current_project.present? %>/<% menu_items = true %>/' app/views/files/index.html.erb
LIBRARY_BACKEND=share bin/rails test test/integration/web/files_toolbar_test.rb -n /empty/   # share IS scannable, so expected: still green here — report it, and note the chunk_remote leg is where this test bites
git checkout -- app/views/files/index.html.erb
# The count: drop the flat branch → "matches" test fails.
sed -i '' 's/pluralize(number_with_delimiter(@match_count), "match", "matches")/pluralize(number_with_delimiter(@nodes.size), "item")/' app/views/files/index.html.erb
bin/rails test test/integration/web/files_toolbar_test.rb -n /matches/    # expected: 1 failure
git checkout -- app/views/files/index.html.erb
git status --porcelain
```

- [ ] **Step 9: Commit**

```bash
git add app/views/files/index.html.erb app/views/files/_grid.html.erb app/javascript/controllers/menu_controller.js \
        app/assets/stylesheets/components.css app/assets/stylesheets/pages/files.css test/css_hygiene_test.rb \
        test/integration/web/files_toolbar_test.rb
git commit -m "The Files page: Upload up front, one toolbar row, and the rest in an overflow menu"
```

---

### Task 2: The file page — a format badge, and a notes composer that opens on demand

**Files:**
- Modify: `app/views/files/show.html.erb`
- Create: `test/integration/web/file_page_test.rb`

- [ ] **Step 1: Write the failing test**

`test/integration/web/file_page_test.rb`:

```ruby
require "test_helper"

module Web
  # The file page's head and notes (spec §8, PR 2): the format sits beside the name as a badge,
  # and the notes composer is closed until asked for — the same form, the same Lexxy editor, the
  # same field, inside a <details>. The page's actions keep Back as the only ghost button
  # (back_link_test reads it by that selector).
  class FilePageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "fp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @node = @user.nodes.create!(node_id: "n-coaster", name: "coaster.lbrn2", kind: "file",
                                  mtime: 1_000_000_000, size: 2_400)
    end

    test "the head shows the format as a badge beside the name" do
      get file_path(@node.node_id)
      assert_response :success
      assert_select ".page-head h1", text: "coaster.lbrn2"
      assert_select ".page-head .badge.file-badge", text: "LBRN2"
      assert_select ".page-actions a.btn.ghost", count: 1, text: "Back"
    end

    test "the notes composer is a closed details that still holds the whole form" do
      get file_path(@node.node_id)
      assert_select ".notes-panel details.composer:not([open]) > summary", text: "Add a note"
      assert_select ".notes-panel details.composer form.note-form[action=?] lexxy-editor[attachments='false']",
                    file_notes_path(@node.node_id)
      assert_select ".notes-panel details.composer form.note-form input[type='submit'][value='Add note']"
      assert_select ".notes-panel", text: /No notes yet\./
    end

    test "a file with no extension gets no badge" do
      bare = @user.nodes.create!(node_id: "n-license", name: "LICENSE", kind: "file", mtime: 1_000_000_000, size: 10)
      get file_path(bare.node_id)
      assert_select ".page-head .file-badge", count: 0
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
bin/rails test test/integration/web/file_page_test.rb
```

Expected: the badge and composer assertions fail.

- [ ] **Step 3: The template**

In `app/views/files/show.html.erb`:

Replace `<h1><%= @node.name %></h1>` with

```erb
  <div class="page-title">
    <h1><%= @node.name %></h1>
    <% ext = File.extname(@node.name).delete(".").upcase %>
    <% if ext.present? %><span class="badge file-badge"><%= ext %></span><% end %>
  </div>
```

and replace the notes panel's form block —

```erb
  <%= form_with model: @new_note, scope: :note, url: file_notes_path(@node.node_id),
                method: :post, class: "note-form" do |f| %>
    <%= f.rich_text_area :body, placeholder: "Add a note…", attachments: "false" %>
    <%= f.submit "Add note", class: "btn small" %>
  <% end %>
```

— with the same form inside a composer:

```erb
  <%# CLOSED UNTIL ASKED FOR (spec §8): the editor's whole toolbar used to sit open on every file
      page with nothing to write. The form, its scope, its field and the Lexxy element are
      unchanged; only a <details> wraps them. Lexxy mounts inside a closed details and lays itself
      out when it opens — verified by test/system/files_pages_test.rb, which types a note through
      it. Keep the ERB comment above the form that explains `scope: :note`. %>
  <details class="composer">
    <summary class="btn small">Add a note</summary>
    <%= form_with model: @new_note, scope: :note, url: file_notes_path(@node.node_id),
                  method: :post, class: "note-form" do |f| %>
      <%= f.rich_text_area :body, placeholder: "Add a note…", attachments: "false" %>
      <%= f.submit "Add note", class: "btn small" %>
    <% end %>
  </details>
```

Task 1 owns the stylesheets and writes `.page-head .page-title`, `.page-head .file-badge` and the composer rules in `pages/files.css`; if Task 1 has not landed when you run, the page renders unstyled and every assertion here is structural, so nothing here depends on it.

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/integration/web/file_page_test.rb test/integration/web/files_flow_test.rb test/integration/web/notes_test.rb \
  test/integration/web/back_link_test.rb test/integration/web/addon_origin_surfaces_test.rb test/integration/web/attach_from_files_test.rb \
  test/integration/web/template_hygiene_test.rb
bin/ci style
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
git add app/views/files/show.html.erb test/integration/web/file_page_test.rb
git commit -m "The file page: the format beside the name, and a notes composer that opens on demand"
```

---

### Task 3: In a browser — the menu closes, and a note goes through the closed composer

**Files:**
- Create: `test/system/files_pages_test.rb`

- [ ] **Step 1: Write the tests**

```ruby
require "application_system_test_case"

# What only a browser can show about PR 2's Files pages: the overflow menu opens and closes the
# way a menu should, and the notes composer — Lexxy inside a <details> that starts closed —
# actually takes a note. The second is the risk the spec (§13) named; this is the verification.
class FilesPagesTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("files-pages@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the overflow menu opens on its button and closes on an outside click or Escape" do
    visit files_path
    assert_selector ".page-actions details.menu"
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open] .menu-item", text: /rescan/i
    find("h1", text: "Files").click
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open]"
    find("body").send_keys(:escape)
    assert_no_selector ".page-actions details.menu[open]"
    assert_no_console_errors
  end

  test "a note written through the closed composer lands on the page" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.dxf", kind: "file")
    visit file_path(node.node_id)
    assert_selector ".notes-panel details.composer"
    assert_no_selector ".notes-panel details.composer[open]"
    find(".notes-panel details.composer > summary", text: "Add a note").click
    assert_selector ".notes-panel details.composer[open] lexxy-editor", visible: true
    find(".notes-panel lexxy-editor [contenteditable='true']").click
    find(".notes-panel lexxy-editor [contenteditable='true']").send_keys("Print upside down, 4 walls.")
    click_on "Add note"
    assert_selector ".notes-panel article.note .note-body", text: "Print upside down, 4 walls."
    assert_no_console_errors
  end
end
```

The share library is scannable, so the rescan item exists; the test guards on the menu, which renders whenever the backend is scannable or a project is current.

- [ ] **Step 2: Run them**

```bash
bin/rails test test/system/files_pages_test.rb
```

Expected: green. If Lexxy's editable surface is not `[contenteditable='true']` inside `lexxy-editor`, inspect the rendered element (`page.html[/<lexxy-editor.*?<\/lexxy-editor>/m]`) and use the selector it actually renders — the claim is that a note goes through, not the selector. If the editor does not lay out inside the closed details (the note never lands), report BLOCKED with what you saw: the fallback the spec allows is rendering the composer `open` on the file page, and that is the orchestrator's call.

- [ ] **Step 3: Mutation-check the composer guard**

```bash
sed -i '' 's/<details class="composer">/<details class="composer" open>/' app/views/files/show.html.erb
bin/rails test test/system/files_pages_test.rb -n /closed_composer/    # expected: 1 failure (the details is open before the click)
git checkout -- app/views/files/show.html.erb
git status --porcelain
```

- [ ] **Step 4: Commit**

```bash
git add test/system/files_pages_test.rb
git commit -m "Pin the Files pages in a browser: the menu closes itself, a note goes through the closed composer"
```

---

### Task 4: Close-out

- [ ] `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync; bin/ci` — every gate green; the three backend legs' run counts identical.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>` the moment the PR exists.
