# Web Shell PR 3: Projects, Models, Sheets — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file (each task below is one coherent unit), dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver step 3 of the spec's delivery order (`docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md` §8 "Projects index", "Project show", "Models index/show/new/edit, Shelves", and the sheet page): a project page with a stats line and real buttons, smaller tiles with Detach revealed on hover, task rows with a state mark and the composer below the list, a build-log composer that opens on demand and a timeline with the date on the left, a Files-style toolbar on Models, badges over model covers, a "Log a print" composer, a drop-zone import field, and the shelves and sheet pages themed — without renaming a class, label, field or Turbo Stream target the tests pin.

**Architecture:** Template-level tidying on top of the PR 1 design system and PR 2's `details.composer` / `details.menu` components; one new button variant (`.btn.outline`); the page rules rewritten in `pages/projects.css` and `pages/models.css`. Every form keeps its `scope:`/`model:` and field names; `#project-tasks` stays the Turbo Stream target; the `_upload_control` partial and its hidden `redirect_url` are untouched.

**Tech Stack:** Rails 8, Propshaft, Turbo Streams, Stimulus, Lexxy, Minitest request tests under `test/integration/web/`, Capybara/Selenium system tests under `test/system/`.

---

## Before you start

- Branch: `claude/ui-rework-pr3-projects-models`, in the worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests need `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`. `bin/ci style` is rubocop (rails-omakase: double quotes, `[ a, b ]` with inner spaces). The full gate is `bin/ci` with `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`; only ONE full-suite run at a time in this worktree.
- Read `docs/invariants/design-system.md` (§14m), `docs/invariants/project-intake.md` (you touch `projects/_attachments` / the scan button's neighbourhood; change no behaviour there) and `docs/invariants/model-intake.md` (you touch `models/`). Never write the ERB close delimiter inside an ERB comment; every `data-controller` value is a literal; every `form_with` keeps its `scope:`/`model:`.
- **`git checkout -- <file>` restores to HEAD, not to your uncommitted edit.** Before a mutation check, `git add` your work so the staged copy is what `checkout` restores.
- **The contract this PR must not break** — a full sweep of the tests that drive these pages (2026-09-04) pins these; keep each exactly:
  - Projects index: `h1` "Projects" / "Archived projects"; `.projects-empty` and its sentence; `.projects-grid` whose DIRECT children are only `.project-tile` (never a bare `a.project-card` or `form`); `.project-card .project-name`, `.project-card .file-cell[data-node-id]`, **no `.project-card .badge` for a live project**; `form[action=unarchive_project_path] button` "Unarchive"; `.archived-note a` "N archived project(s)" and `.archived-note` absent when none.
  - Project show: `h1`; `.badge.status-archived` "Archived"; `.current-project-badge`; `.head-actions form[action=current_project_path] button` matching `/set as current/i` or `/clear/i`; `form[action=project_path]` (Archive) vs `form[action=unarchive_project_path]`; `.project-description`; `dialog.move-conflict`; `.attachments-panel .attachment-tile a[href=file_path]`, `.attachment-tile .grid-name`, no `.attachment-tile .badge`, no `.attachment-tile.unavailable`; `.attachments-missing` sentence + `a[href=trash_index_path]`; `p.muted` exactly "No files attached yet."; `.attachment-group`, `details[open] > summary.attachment-group-head` with "Label (N)" texts (Models, Images, Vector, Laser, Documents, Other, Backups closed); `[data-controller~=scanreload][data-scanreload-url-value]` only when `?scanning=1`; `form[action=project_scan_path] button` `/scan folder/i`; **`<section id="project-tasks">` is the Turbo Stream target and stays the root of `_tasks`**; `form.task-form input[type=text][name="task[title]"]`; `.tasks-group.status-todo .task-title`, `.tasks-group.status-done .task-title`; `.task-error`; `lexxy-editor[attachments=false]` on the build-log form posting `build_log_entry[body]` (never a `textarea`); `.log-entry .entry-body` (with rich HTML inside), `.log-entry .entry-photo[data-node-id]`; `.sheets-panel .sheet-row`, `.sheets-panel a` (sheet name, a Turbo-visitable link), `.sheets-panel form[action=project_sheets_path]` posting `sheet[name]`, `.sheets-panel .muted` "No sheets yet…"; every `[data-download-url]` cell also carries `data-note-url`, every `[data-thumbs-target=cell]` carries `data-node-id`, tiles carry `[data-addon-open-url]`/`[data-addon-open-label]` when an addon made the file.
  - Project form / picker: `project[name]`, `project[description]`, `project[cover_node_id]`, `project[cover_clear]`; `.folder-field[data-filechooser-mode-value=file]`, `.folder-field-btn`, `.ff-path` ("Choose automatically" / the file name); `form.picker-search input[name=entry_id]`, `.picker-result`, `.picker-result form[action=entry_photos_path]`, "Attach", "Search".
  - Sheet page: `h1` (the name); `[data-controller=sheet][data-sheet-url-value][data-sheet-data-value]`, `[data-sheet-target=status]` exact "Saved", `[data-sheet-target=grid]`; `a[href=sheet_path(format: :csv)]` "Export CSV"; "Rename"; "Delete"; `script[src*=jspreadsheet]` on this page only; the breadcrumb.
  - Models: `h1` "Models"; `.models-empty` and its sentence; `.model-card .model-name`, `.model-card .badge.mstatus-*`; `.models-toolbar`, `.filter`; model show `h1`, `.head-actions`, "Edit", "Open in Files", "Remove from catalog" (auto) vs "Delete" (manual), `.model-hero`, `.model-hero.model-viewer[data-modelviewer-lazy-value=true]` with `select.model-viewer-source option[data-url][data-format]` or the single-file `data-modelviewer-url-value`/`-format-value`, `.mv-launch [data-action~=modelviewer#load]`, `.model-hero-empty` / `.model-hero-thumb` / `.model-hero-img`, `.image-gallery img`, `.model-instructions iframe.preview-pdf`, `.model-notes`, `.model-side dl.meta` (with `a[href=source_url]`), `.model-print-settings dt/dd`, `.model-files h2` "Files (N)", `.file-tree-box .tree-folder`, `.tree-fname`, `.attachments-missing`; `.print-log`, `form.print-form` posting `print_run[...]`, `.print-run`, "Log a print"; new: `[data-controller=importer]`, `input[type=file][data-importer-target=input][data-action=importer#choose]`, `[data-importer-target=summary|title|sourceUrl|submit|status]`, `fill_in "Title"`, "Create model"; edit: `model[title|designer|license|source_url|tag_list|print_status|notes]`, "Save changes".
  - Shelves: `form.shelf-add input[type=hidden][name=node_id]`, `li` text (the label), `.shelf-status` ("N folders matched", exactly "no folder at this path", "in your library"), "Remove", "Add shelf", "Back to models".

## File structure

| path | responsibility | task |
|---|---|---|
| `app/views/projects/show.html.erb` | title block, stats line, actions as buttons | 1 |
| `app/views/projects/_attachment_group.html.erb` | Detach as a corner control | 1 |
| `app/views/projects/_tasks.html.erb`, `_task.html.erb` | state mark per row, composer below the list | 1 |
| `app/views/projects/_build_log.html.erb`, `_log_entry.html.erb` | composer on demand; date-left timeline | 1 |
| `app/assets/stylesheets/components.css` | `.btn.outline` | 1 |
| `app/assets/stylesheets/pages/projects.css` | rewritten page rules (index, show, panels, tasks, timeline, sheets, picker, sheet page) | 1 |
| `test/integration/web/project_page_test.rb` | stats, buttons, tiles, tasks order and marks, composer, timeline shape | 1 |
| `app/views/models/index.html.erb`, `_card.html.erb`, `show.html.erb`, `_print_log.html.erb`, `new.html.erb` | toolbar, badge over cover, button actions, print composer, drop zone | 2 |
| `app/views/shelves/index.html.erb` | button classes | 2 |
| `app/assets/stylesheets/pages/models.css` | rewritten page rules | 2 |
| `test/integration/web/models_pages_test.rb` | toolbar, badge placement, actions, composer, drop zone, shelves | 2 |
| `test/system/projects_models_pages_test.rb` | build-log entry through the closed composer; Detach revealed on hover; a task moved to Done; a print logged through its composer | 3 |

**Dependencies:** Tasks 1 and 2 are disjoint (Task 1 owns `components.css` and `pages/projects.css`; Task 2 owns `pages/models.css`) and run in parallel. Task 3 needs both. Task 4 is the close-out.

---

### Task 1: The project page and its panels

**Files:**
- Modify: `app/views/projects/show.html.erb`, `app/views/projects/_attachment_group.html.erb`, `app/views/projects/_tasks.html.erb`, `app/views/projects/_task.html.erb`, `app/views/projects/_build_log.html.erb`, `app/views/projects/_log_entry.html.erb`, `app/assets/stylesheets/components.css`, `app/assets/stylesheets/pages/projects.css`
- Create: `test/integration/web/project_page_test.rb`

Read every file above in full before editing; each carries ERB comments that explain a constraint (the `scope:` traps, the Turbo Stream target, the `_task` partial's path), and every one of those comments stays.

- [ ] **Step 1: Write the failing request tests**

`test/integration/web/project_page_test.rb`:

```ruby
require "test_helper"

module Web
  # The project page after PR 3 (spec §8): a stats line from what the page already loads, real
  # buttons in the head, Detach as a corner control on smaller tiles, task rows with a state mark
  # and the composer BELOW the list, a build-log composer that opens on demand, and a timeline with
  # the date in its own column. Nothing here adds a query: page_query_budget_test.rb still holds.
  class ProjectPageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "pp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp", description: "An articulated lamp.")
      %w[base.stl shade.3mf].each_with_index do |name, i|
        @user.nodes.create!(node_id: "n-#{i}", name:, kind: "file", mtime: 1_000_000_000, size: 10)
        @project.file_attachments.create!(user: @user, node_id: "n-#{i}", role: "model")
      end
      @project.tasks.create!(user: @user, title: "Print the base", status: "done", position: 0)
      @project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 1)
      @project.tasks.create!(user: @user, title: "Design the clip", status: "todo", position: 2)
      @project.build_log_entries.create!(user: @user, entry_type: "note", logged_at: 2.days.ago,
                                         body: "<div>First print came out clean.</div>")
      @project.sheets.create!(user: @user, name: "Bill of materials")
    end

    test "the head shows a stats line built from what the page already loaded" do
      get project_path(@project)
      assert_response :success
      assert_select ".project-head .page-title h1", text: "Desk Lamp"
      assert_select ".project-stats", text: /2 files/
      assert_select ".project-stats", text: /1 of 3 tasks done/
      assert_select ".project-stats", text: /1 log entry\b/
      assert_select ".project-stats", text: /1 sheet\b/
    end

    test "the head's actions are buttons, with Archive quiet and Set as current outlined" do
      get project_path(@project)
      assert_select ".head-actions form[action=?] button.btn.outline", current_project_path, text: /set as current/i
      assert_select ".head-actions a.btn[href=?]", edit_project_path(@project), text: "Edit"
      assert_select ".head-actions form[action=?] button.btn.danger", project_path(@project), text: "Archive"
    end

    test "attachment tiles carry Detach as a corner control that keeps its text" do
      get project_path(@project)
      assert_select ".attachments-panel .attachment-tile .tile-meta form[action=?] button.tile-detach",
                    attachment_path(@project.file_attachments.first), text: "Detach"
    end

    test "task rows carry a state mark and the composer sits below the list" do
      get project_path(@project)
      assert_select "#project-tasks .tasks-group.status-done .task-row .task-state.task-state--done", count: 1
      assert_select "#project-tasks .tasks-group.status-todo .task-row .task-state.task-state--todo", count: 2
      children = css_select("#project-tasks > *").map { |el| el["class"].to_s }
      last_group = children.rindex { |c| c.include?("tasks-group") }
      form = children.index { |c| c.include?("task-form") }
      assert form && last_group && form > last_group, "the task form must come after the task groups, got #{children.inspect}"
      assert_select "#project-tasks form.task-form input[type='text'][name='task[title]']"
    end

    test "the build-log composer is a closed details holding the same form" do
      get project_path(@project)
      assert_select ".build-log-panel details.composer:not([open]) > summary", text: "Add entry"
      assert_select ".build-log-panel details.composer form[action=?] lexxy-editor[attachments='false']",
                    project_build_log_entries_path(@project)
      assert_select ".build-log-panel details.composer form input[type='submit'][value='Add entry']"
    end

    test "a log entry puts its date in the first column and its body in the second" do
      get project_path(@project)
      assert_select ".log-timeline .log-entry > time.entry-time", count: 1
      assert_select ".log-timeline .log-entry > .entry-main .entry-body", text: /First print came out clean/
      assert_select ".log-timeline .log-entry > .entry-main .entry-head form button", text: "Delete"
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/project_page_test.rb
```

Expected: every test fails except none — the stats line, the button classes, `.tile-detach`, `.task-state`, the composer and `.entry-main` do not exist yet.

- [ ] **Step 3: The button variant**

In `app/assets/stylesheets/components.css`, after the `.btn.ghost:hover` rule inside `@layer components`:

```css
  /* Outlined in the accent: the one secondary action on a page that deserves the colour without
     the fill (Set as current on a project). */
  .btn.outline { background: transparent; border-color: var(--accent); color: var(--accent); }
  .btn.outline:hover { background: var(--accent-soft); border-color: var(--accent); }
```

- [ ] **Step 4: `projects/show.html.erb`**

Replace the `.page-head` block and the description with:

```erb
<div class="page-head project-head">
  <div class="page-title">
    <h1><%= @project.name %></h1>
    <% if @project.status == "archived" %>
      <span class="badge status-archived">Archived</span>
    <% end %>
  </div>
  <div class="head-actions">
    <% if current_project == @project %>
      <span class="badge current-project-badge">★ Current project</span>
      <%= button_to "Clear", current_project_path, method: :delete, class: "btn small ghost" %>
    <% elsif @project.status != "archived" %>
      [keep the ERB comment about archived projects and CurrentProject's scope]
      <%= button_to "Set as current", current_project_path, method: :patch,
                    params: { project_id: @project.id }, class: "btn small outline" %>
    <% end %>
    <%= link_to "Edit", edit_project_path(@project), class: "btn small" %>
    <% if @project.status == "archived" %>
      <%= button_to "Unarchive", unarchive_project_path(@project), method: :patch, class: "btn small" %>
    <% else %>
      <%= button_to "Archive", project_path(@project), method: :delete, class: "btn small danger",
                    form: { data: { turbo_confirm: "Archive #{@project.name}?" } } %>
    <% end %>
  </div>
</div>

<%= render "projects/move_conflict" %>

<% if @project.description.present? %>
  <p class="project-description"><%= @project.description %></p>
<% end %>

<%# THE STATS LINE reads collections ProjectsController#show already loaded — @attachments,
    @tasks, @entries, @sheets — and nothing else, so page_query_budget_test.rb's "does not grow
    with attachments, tasks or build-log entries" holds without a counter cache. %>
<% done = @tasks.count { |t| t.status == "done" } %>
<p class="project-stats">
  <span><b><%= @attachments.size %></b> <%= "file".pluralize(@attachments.size) %></span>
  <span><b><%= done %> of <%= @tasks.size %></b> <%= "task".pluralize(@tasks.size) %> done</span>
  <span><b><%= @entries.size %></b> log <%= "entry".pluralize(@entries.size) %></span>
  <span><b><%= @sheets.size %></b> <%= "sheet".pluralize(@sheets.size) %></span>
</p>
```

Everything below (`.project-panels` and its four renders) is unchanged.

- [ ] **Step 5: `_attachment_group.html.erb`**

Change only the Detach button's class: `class: "linkbtn danger"` becomes `class: "btn small danger tile-detach"`. The `.tile-meta` wrapper, the `button_to`, the confirm text and the tile markup stay.

- [ ] **Step 6: `_tasks.html.erb` and `_task.html.erb`**

In `_tasks.html.erb`, move the `form_with … class: "task-form"` block and the `@task_error` paragraph to AFTER the `Maker::Task::STATUSES.each` loop (the form is now the last child of the section). Keep `id="project-tasks"` on the section, keep the `h2`, keep every comment (the one explaining `scope: :task` moves with the form).

Replace `_task.html.erb` with:

```erb
<%# One task row. The state mark is CSS-drawn from the status (todo hollow, doing half, done
    filled with a tick); the buttons are the same status transitions as before, plus delete. %>
<div class="task-row">
  <span class="task-state task-state--<%= task.status %>" aria-hidden="true"></span>
  <span class="task-title"><%= task.title %></span>
  <div class="task-actions">
    <% (Maker::Task::STATUSES - [ task.status ]).each do |to| %>
      <%= button_to to.capitalize, task_path(task), method: :patch,
                    params: { task: { status: to } }, class: "task-move" %>
    <% end %>
    <%= button_to "✕", task_path(task), method: :delete, class: "task-delete",
                  "aria-label": "Delete task", form: { data: { turbo_confirm: "Delete task?" } } %>
  </div>
</div>
```

(The old file had no comment; this one's comment contains no close delimiter.)

- [ ] **Step 7: `_build_log.html.erb` and `_log_entry.html.erb`**

In `_build_log.html.erb`, wrap the form (keep it and its comment verbatim) in a composer:

```erb
<section class="panel build-log-panel">
  <h2>Build log</h2>
  <details class="composer">
    <summary class="btn small">Add entry</summary>
    [keep the comment about maker_build_log_entry[...] and params.require]
    <%= form_with model: @new_entry, scope: :build_log_entry,
                  url: project_build_log_entries_path(@project), class: "log-form" do |f| %>
      <%= f.rich_text_area :body, placeholder: "What did you do?", attachments: "false" %>
      <%= f.submit "Add entry", class: "btn small" %>
    <% end %>
  </details>
  … the empty sentence and the timeline, unchanged …
</section>
```

In `_log_entry.html.erb`, move the `<time>` out of `.entry-head` into the row's first column and wrap the rest in `.entry-main`; the body line, the photos block and `.photo-attach` are unchanged:

```erb
<li class="log-entry">
  <time class="entry-time muted"><%= entry.logged_at.strftime("%Y-%m-%d %H:%M") %></time>
  <div class="entry-main">
    <div class="entry-head">
      <%= button_to "Delete", build_log_entry_path(entry), method: :delete, class: "linkbtn danger small entry-delete",
                    form: { data: { turbo_confirm: "Delete this entry?" } } %>
    </div>
    [the existing .entry-body line and its comment, verbatim]
    [the existing photos block and .photo-attach block, verbatim]
  </div>
</li>
```

- [ ] **Step 8: `pages/projects.css`**

Replace the rules named below inside the existing `@layer pages { … }` block (the migrated comments above each old rule may go; the two that explain measurements — the `.project-tile` flex note and the `.entry-body` white-space note — stay):

```css
  /* --- Index --- */
  .projects-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 16px; }
  .project-tile { display: flex; flex-direction: column; gap: 6px; }
  .project-tile form { text-align: center; }
  .project-card { display: flex; flex-direction: column; gap: 8px; align-items: center; color: var(--fg); }
  .project-card:hover { text-decoration: none; }
  .project-card:hover .thumb { border-color: var(--accent); }
  .project-card .thumb { width: 100%; height: 120px; }
  .project-thumb-empty { font-size: 36px; }
  .project-name { font-size: 13px; font-weight: 600; text-align: center; overflow-wrap: anywhere; }
  .archived-note { margin: 24px 0 0; padding-top: 12px; border-top: 1px solid var(--line); font-size: 12px; }
  .projects-empty { padding: 40px 16px; text-align: center; border: 1px dashed var(--line); border-radius: var(--radius-panel); }

  /* --- Show: head, stats, panels --- */
  .project-head { align-items: flex-start; }
  .project-head .page-title { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; min-width: 0; }
  .project-description { white-space: pre-wrap; margin: 0 0 12px; max-width: 72ch; font-size: 14px; line-height: 1.55; }
  .project-stats { display: flex; flex-wrap: wrap; gap: 6px 18px; margin: 0 0 20px; font: 12px/1.5 var(--font-mono); color: var(--fg-muted); }
  .project-stats b { color: var(--fg); font-weight: 500; }
  .project-panels { display: grid; grid-template-columns: 1fr; gap: 16px; }
  @media (min-width: 900px) { .project-panels { grid-template-columns: 1fr 1fr; } .attachments-panel { grid-column: 1 / -1; } }

  /* --- Files panel: 96px tiles, Detach in the corner on hover --- */
  .attachments-grid, .entry-photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 12px; }
  .attachment-tile { position: relative; display: flex; flex-direction: column; gap: 4px; }
  .attachment-tile .thumb { width: 100%; height: 96px; }
  .attachment-tile .grid-name { font-size: 12px; }
  .tile-meta { position: absolute; top: 4px; right: 4px; opacity: 0; transition: opacity .12s; }
  .attachment-tile:hover .tile-meta, .attachment-tile:focus-within .tile-meta { opacity: 1; }
  @media (hover: none) { .tile-meta { opacity: 1; } }
  .tile-meta form { margin: 0; }
  .tile-detach { min-height: 22px; padding: 0 6px; font-size: 11px; background: var(--surface); }
  .entry-photo .thumb { width: 100%; height: 80px; }
  .attachment-group { margin-bottom: 16px; }
  .attachment-group:last-child { margin-bottom: 0; }
  .attachment-group details[open] > .attachment-group-head { margin-bottom: 8px; }
  .attachments-missing { font-size: 12px; margin: 4px 0 0; }
  .photo-attach { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-top: 6px; font-size: 12px; }

  /* --- Tasks: a state mark, the transitions as tiny buttons, the composer last --- */
  .tasks-group { margin-top: 10px; }
  .task-row { display: flex; align-items: center; gap: 10px; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .task-title { flex: 1; min-width: 0; overflow-wrap: anywhere; }
  .status-done .task-title { text-decoration: line-through; color: var(--fg-muted); }
  .task-state { width: 14px; height: 14px; flex: 0 0 auto; border-radius: 50%; border: 1.5px solid var(--fg-muted); position: relative; }
  .task-state--doing { background: linear-gradient(90deg, var(--accent) 50%, transparent 50%); border-color: var(--accent); }
  .task-state--done { background: var(--ok); border-color: var(--ok); }
  .task-state--done::after { content: ""; position: absolute; left: 4px; top: 1px; width: 3px; height: 7px; border: solid var(--bg); border-width: 0 2px 2px 0; transform: rotate(45deg); }
  .task-actions { display: flex; gap: 4px; align-items: center; }
  .task-actions form { margin: 0; }
  .task-move { min-height: 22px; padding: 0 7px; border: 1px solid var(--line); border-radius: var(--radius-control); background: var(--surface); color: var(--fg-muted); font: 500 11px/1 var(--font-ui); cursor: pointer; }
  .task-move:hover { color: var(--fg); border-color: var(--line-strong); }
  .task-delete { min-height: 22px; padding: 0 6px; border: 0; background: none; color: var(--fg-muted); font: 12px/1 var(--font-ui); cursor: pointer; }
  .task-delete:hover { color: var(--danger); }
  .task-form { display: flex; gap: 8px; align-items: center; margin-top: 12px; }
  .task-form input[type="text"] { flex: 1; max-width: none; margin: 0; }
  .task-error { margin: 8px 0 0; }

  /* --- Build log: composer, then the timeline with its dates in a column --- */
  .build-log-panel details.composer { margin: 0 0 8px; }
  .log-timeline { list-style: none; padding: 0; margin: 8px 0 0; }
  .log-entry { display: grid; grid-template-columns: 96px minmax(0, 1fr); gap: 4px 14px; padding: 10px 0; border-top: 1px solid var(--line); }
  .entry-time { font: 11px/1.6 var(--font-mono); white-space: nowrap; padding-top: 1px; }
  .entry-main { min-width: 0; }
  .entry-head { display: flex; justify-content: flex-end; }
  .entry-delete { font-size: 11px; }
  .entry-body { margin: 0 0 6px; font-size: 14px; line-height: 1.55; max-width: 72ch; }

  /* --- Sheets panel, picker, sheet page (unchanged shapes, tokens) --- */
  .sheets-panel .sheet-row { display: flex; align-items: center; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid var(--line); }
  .sheets-panel .sheet-row:last-child { border-bottom: 0; }
  .sheets-panel .sheet-row .muted { font: 11px/1.4 var(--font-mono); }
  .sheet-new-form { display: flex; gap: 6px; align-items: center; }
  .picker-search { display: flex; gap: 8px; margin-bottom: 16px; }
  .picker-search input { flex: 1; max-width: 480px; }
  .picker-results { display: flex; flex-direction: column; gap: 6px; }
  .picker-result { display: flex; justify-content: space-between; align-items: center; padding: 8px 10px; border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--surface); }
  .sheet-head { align-items: flex-start; }
  .sheet-head h1 { margin: 0 0 4px; }
  .sheet-rename { display: inline-flex; gap: 6px; }
  .sheet-grid { overflow-x: auto; }
  .sheet-status { font: 11px/1.4 var(--font-mono); }
  .sheet-status-error { color: var(--danger); }
```

Remove the old `.task-form input` rule (the new `.task-form input[type="text"]` replaces it) and the old `.entry-head { … space-between … }` rule; keep the `.entry-body` comment about `white-space` and place it above the new `.entry-body` rule.

- [ ] **Step 9: Run the tests**

```bash
bin/rails test test/integration/web/project_page_test.rb test/integration/web/projects_flow_test.rb \
  test/integration/web/project_tasks_test.rb test/integration/web/project_build_log_test.rb test/integration/web/project_attachments_test.rb \
  test/integration/web/project_sheets_test.rb test/integration/web/project_scan_button_test.rb test/integration/web/current_project_set_from_project_test.rb \
  test/integration/web/page_nodes_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/attach_auto_move_test.rb \
  test/integration/web/file_cell_payload_test.rb test/integration/web/addon_origin_surfaces_test.rb \
  test/css_hygiene_test.rb test/integration/web/template_hygiene_test.rb
bin/ci style
```

Expected: green. `project_tasks_test` renders `_tasks` inside a Turbo Stream: the section's `id` and the `_task` partial path are what it checks.

- [ ] **Step 10: Mutation-check, reporting output** (stage your work first: `git add` the eight files)

```bash
sed -i '' 's/<% done = @tasks.count { |t| t.status == "done" } %>/<% done = 0 %>/' app/views/projects/show.html.erb
bin/rails test test/integration/web/project_page_test.rb -n /stats/     # expected: 1 failure ("1 of 3" not found)
git checkout -- app/views/projects/show.html.erb
sed -i '' 's/<details class="composer">/<details class="composer" open>/' app/views/projects/_build_log.html.erb
bin/rails test test/integration/web/project_page_test.rb -n /composer/  # expected: 1 failure
git checkout -- app/views/projects/_build_log.html.erb
git status --porcelain
```

- [ ] **Step 11: Commit**

```bash
git add app/views/projects/show.html.erb app/views/projects/_attachment_group.html.erb app/views/projects/_tasks.html.erb \
        app/views/projects/_task.html.erb app/views/projects/_build_log.html.erb app/views/projects/_log_entry.html.erb \
        app/assets/stylesheets/components.css app/assets/stylesheets/pages/projects.css test/integration/web/project_page_test.rb
git commit -m "The project page: a stats line, real buttons, Detach in the corner, task marks, a composer, a dated timeline"
```

---

### Task 2: Models, shelves, the import form

**Files:**
- Modify: `app/views/models/index.html.erb`, `app/views/models/_card.html.erb` (no markup change; listed because its CSS moves), `app/views/models/show.html.erb`, `app/views/models/_print_log.html.erb`, `app/views/models/new.html.erb`, `app/views/shelves/index.html.erb`, `app/assets/stylesheets/pages/models.css`
- Create: `test/integration/web/models_pages_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/integration/web/models_pages_test.rb`:

```ruby
require "test_helper"

module Web
  # The model catalog after PR 3 (spec §8): a Files-style toolbar on the index with the status
  # filters as chips, the status badge over the cover, button actions on the model page, a print
  # composer that opens on demand, a drop-zone import field, and the shelves page's buttons.
  class ModelsPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "n-benchy", name: "benchy.stl", kind: "file", mtime: 1_000_000_000, size: 10)
      @model = @user.maker_models.create!(title: "Benchy", print_status: "printed")
      @model.file_attachments.create!(user: @user, node_id: "n-benchy", role: "model")
    end

    test "the index carries a toolbar with the search, the status chips, the tag and sort selects" do
      get models_path
      assert_response :success
      assert_select "form.toolbar.models-toolbar input[type='search'][name='q']"
      assert_select "form.toolbar.models-toolbar a.filter.chip.active", text: "All"
      assert_select "form.toolbar.models-toolbar a.filter.chip", text: "Printed"
      assert_select "form.toolbar.models-toolbar select[name='sort']"
      assert_select ".page-head a.btn.primary[href=?]", new_model_path, text: "Import model"
      assert_select ".page-head a.btn[href=?]", shelves_path, text: "Shelves"
    end

    test "a model card keeps its badge, which the stylesheet places over the cover" do
      get models_path
      assert_select ".model-card .badge.mstatus-printed", text: /printed/i
      assert_select ".model-card .model-name", text: "Benchy"
    end

    test "the model page's actions are buttons and its print log is a closed composer" do
      get model_path(@model)
      assert_select ".head-actions a.btn[href=?]", edit_model_path(@model), text: "Edit"
      assert_select ".head-actions form[action=?] button.btn.danger", model_path(@model), text: "Delete"
      assert_select ".print-log details.composer:not([open]) > summary", text: "Log a print"
      assert_select ".print-log details.composer form.print-form[action=?] input[type='submit'][value='Log a print']",
                    model_print_runs_path(@model)
    end

    test "the import form's file field is a drop zone that keeps the importer's wiring" do
      get new_model_path
      assert_select "[data-controller='importer'] label.dropzone input[type='file'][multiple][data-importer-target='input'][data-action='importer#choose']"
      assert_select "[data-controller='importer'] [data-importer-target='summary']", text: "No files selected."
    end

    test "the shelves page uses buttons for its actions" do
      get shelves_path
      assert_select ".page-head a.btn.ghost[href=?]", models_path, text: "Back to models"
      assert_select "form.shelf-add button.btn.primary", text: "Add shelf"
    end
  end
end
```

- [ ] **Step 2: Run them to see them fail**

```bash
bin/rails test test/integration/web/models_pages_test.rb
```

Expected: the toolbar, composer, dropzone and shelves-button assertions fail.

- [ ] **Step 3: The templates**

`models/index.html.erb` — replace the page head's Shelves link class with `"btn"` and the toolbar form with:

```erb
<form class="toolbar models-toolbar" method="get" action="<%= models_path %>">
  <input type="search" name="q" value="<%= params[:q] %>" placeholder="Search models…" aria-label="Search models">
  <span class="chips">
    <% [["", "All"], %w[want_to_print Wanted], %w[printed Printed], %w[failed Failed]].each do |val, label| %>
      <%= link_to label, models_path(status: val.presence, q: params[:q], tag: params[:tag], sort: params[:sort]),
                  class: "filter chip#{' active' if @status.to_s == val}" %>
    <% end %>
  </span>
  <span class="toolbar-spacer"></span>
  <% if @all_tags.any? %>
    <select name="tag" aria-label="Tag" onchange="this.form.requestSubmit()">
      <option value="">All tags</option>
      <% @all_tags.each do |t| %><option value="<%= t %>" <%= "selected" if params[:tag] == t %>><%= t %></option><% end %>
    </select>
  <% end %>
  <select name="sort" aria-label="Sort" onchange="this.form.requestSubmit()">
    <% [%w[recent Recent], %w[title Title], %w[status Status]].each do |val, label| %>
      <option value="<%= val %>" <%= "selected" if params[:sort] == val %>><%= label %></option>
    <% end %>
  </select>
</form>
```

`models/show.html.erb` — the head actions: `"Edit"` gets `class: "btn small"`, `"Open in Files"` `class: "btn small"`, both destructive `button_to`s get `class: "btn small danger"`. Nothing else on the page changes.

`models/_print_log.html.erb` — wrap the form in a composer, keeping the form verbatim:

```erb
<section class="print-log">
  <h2>Print log <span class="muted">(<%= @print_runs.size %>)</span></h2>
  <details class="composer">
    <summary class="btn small">Log a print</summary>
    <%= form_with scope: :print_run, url: model_print_runs_path(@model), class: "print-form" do |f| %>
      … identical …
    <% end %>
  </details>
  … the runs, identical …
</section>
```

`models/new.html.erb` — give the file field's label the drop-zone class, keeping the input exactly:

```erb
  <label class="field dropzone">
    <span>Select the Printables .zip (drop extra image / PDF too if they weren't bundled)</span>
    <input type="file" multiple data-importer-target="input" data-action="importer#choose">
  </label>
```

`shelves/index.html.erb` — `"Back to models"` gets `class: "btn ghost small"`; the per-shelf `"Remove"` gets `class: "linkbtn danger small"`; the Add-shelf button already has `btn primary`.

- [ ] **Step 4: `pages/models.css`**

Replace the `.models-toolbar` rules and append the rest, inside `@layer pages`:

```css
  .models-toolbar { margin-bottom: 14px; }
  .models-toolbar input[type="search"] { flex: 0 1 260px; min-width: 160px; }
  .models-toolbar .chips { display: inline-flex; flex-wrap: wrap; gap: 6px; }
  .model-card { position: relative; }
  .model-card .badge { position: absolute; top: 6px; left: 6px; }
  .models-empty { padding: 40px 16px; text-align: center; border: 1px dashed var(--line); border-radius: var(--radius-panel); }
  .print-log details.composer { margin: 0 0 10px; }
  .print-form { display: grid; gap: 8px; max-width: 480px; }
  .print-form .row { display: flex; gap: 10px; }
  .print-form .field { margin: 0; }
  .print-log .print-run { padding: 8px 0; border-top: 1px solid var(--line); font-size: 13px; }
  .print-log .print-run strong { font-family: var(--font-mono); font-weight: 500; }
  .dropzone { display: block; padding: 18px; border: 1px dashed var(--line-strong); border-radius: var(--radius-panel); background: var(--surface); text-align: center; cursor: pointer; }
  .dropzone:hover { border-color: var(--accent); }
  .dropzone input[type="file"] { display: block; margin: 10px auto 0; }
  .shelf-list li { display: flex; align-items: center; gap: 10px; padding: 8px 0; border-bottom: 1px solid var(--line); }
  .shelf-status { margin-left: auto; font: 11px/1.4 var(--font-mono); }
```

(The old `.print-form`, `.print-run`, `.shelf-list li` and `.shelf-status` rules are replaced by these; every other rule stays.)

- [ ] **Step 5: Run the tests**

```bash
bin/rails test test/integration/web/models_pages_test.rb test/integration/web/models_flow_test.rb test/integration/web/models_catalog_test.rb \
  test/integration/web/print_runs_test.rb test/integration/web/shelves_test.rb test/integration/web/page_nodes_test.rb \
  test/integration/web/maker_page_thumbnails_test.rb test/integration/web/page_query_budget_test.rb \
  test/css_hygiene_test.rb test/integration/web/template_hygiene_test.rb
bin/ci style
```

Expected: green.

- [ ] **Step 6: Mutation-check** (stage first)

```bash
sed -i '' 's/<details class="composer">/<details class="composer" open>/' app/views/models/_print_log.html.erb
bin/rails test test/integration/web/models_pages_test.rb -n /composer/   # expected: 1 failure
git checkout -- app/views/models/_print_log.html.erb
git status --porcelain
```

- [ ] **Step 7: Commit**

```bash
git add app/views/models/index.html.erb app/views/models/show.html.erb app/views/models/_print_log.html.erb app/views/models/new.html.erb \
        app/views/shelves/index.html.erb app/assets/stylesheets/pages/models.css test/integration/web/models_pages_test.rb
git commit -m "Models and shelves: a Files-style toolbar, the badge over the cover, button actions, a print composer, a drop zone"
```

---

### Task 3: In a browser — the composers take input, Detach appears on hover, a task moves

**Files:**
- Create: `test/system/projects_models_pages_test.rb`

- [ ] **Step 1: Write the tests**

```ruby
require "application_system_test_case"

# PR 3's behaviour only a browser shows: the build-log composer (Lexxy inside a closed details)
# takes an entry; Detach is invisible until the tile is hovered and then works; a task moved to
# Done gets the filled mark through the Turbo Stream replace; the print composer logs a print.
class ProjectsModelsPagesTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("pmp@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "a build-log entry goes through the closed composer" do
    visit project_path(@project)
    assert_no_selector ".build-log-panel details.composer[open]"
    find(".build-log-panel details.composer > summary", text: "Add entry").click
    assert_selector ".build-log-panel details.composer[open] lexxy-editor", visible: true
    find(".build-log-panel lexxy-editor [contenteditable='true']").click
    find(".build-log-panel lexxy-editor [contenteditable='true']").send_keys("Shade printed in PETG.")
    click_on "Add entry"
    assert_selector ".log-timeline .log-entry .entry-body", text: "Shade printed in PETG."
    assert_no_console_errors
  end

  test "Detach is hidden until the tile is hovered, then detaches" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "base.stl", kind: "file")
    @project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
    visit project_path(@project)
    tile = find(".attachments-panel .attachment-tile", text: "base.stl")
    assert_no_selector ".attachment-tile .tile-detach", visible: true
    tile.hover
    assert_selector ".attachment-tile .tile-detach", visible: true
    accept_confirm { tile.find(".tile-detach").click }
    assert_no_selector ".attachments-panel .attachment-tile", text: "base.stl"
    assert_no_console_errors
  end

  test "moving a task to Done fills its mark" do
    @project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 0)
    visit project_path(@project)
    within("#project-tasks .tasks-group.status-todo") { click_on "Done" }
    assert_selector "#project-tasks .tasks-group.status-done .task-row .task-state--done"
    assert_no_selector "#project-tasks .tasks-group.status-todo .task-row"
    assert_no_console_errors
  end

  test "a print is logged through the closed composer" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "benchy.stl", kind: "file")
    model = @user.maker_models.create!(title: "Benchy", print_status: "want_to_print")
    model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
    visit model_path(model)
    find(".print-log details.composer > summary", text: "Log a print").click
    fill_in "print_run[printer]", with: "Prusa MK4"
    click_on "Log a print"
    assert_selector ".print-log .print-run", text: "Prusa MK4"
    assert_no_console_errors
  end
end
```

- [ ] **Step 2: Run them**

```bash
bin/rails test test/system/projects_models_pages_test.rb
```

Expected: green. If `tile.hover` does not reveal the button (Selenium's `hover` moves the pointer; `opacity` transitions settle within 120 ms), add `sleep 0.2` before the visibility assertion and say so. If `accept_confirm` does not fire because the confirm is Turbo's own dialog, use `click_on "Detach"` then `find("dialog")`/`click_on "Confirm"` — read app/javascript for how `turbo_confirm` is handled in this app before choosing.

- [ ] **Step 3: Commit**

```bash
git add test/system/projects_models_pages_test.rb
git commit -m "Pin PR 3 in a browser: composers take input, Detach appears on hover, a task moves to Done"
```

---

### Task 4: Close-out

- [ ] `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync; bin/ci` — every gate green; the three backend legs' run counts identical.
- [ ] `/finish-branch`; `bin/log arc --from-pr <n>` the moment the PR exists.
