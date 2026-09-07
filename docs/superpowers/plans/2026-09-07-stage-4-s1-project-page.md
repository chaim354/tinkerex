# Stage 4, S4-1: the project page shows what matters — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-1 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§6). The project page gets a **hero** from `cover_node_id`; a **Photos** gallery reusing the public page's own definition; a **README card at the top of Files** for every project — the full repository card, with Commits/History in the panel head and an honest caption, when the project's own folder is a working tree; the six secondary panels **quiet when empty**; and list-view rows that carry the tile's context menu. Zero schema. Every page's query count stays constant in N.

**Architecture:** `Maker::ProjectFolderListing#root_repo?` asks the root the question the walk already asks every child. A synthetic root `Dir` feeds `Maker::RepoCard.for`, whose root node joins the batched `repo_roots` query `ProjectsController#show` already makes; a plain folder's README goes through `Maker::Readme.for` over the loose rows. `Maker::ProjectPhotos.rows` is extracted from `Maker::PublicProject#photo_rows` and both pages call it. The cover joins the page's one `PageNodes` union and one `ThumbnailMap`. Quiet is a class the six partials set on themselves when their collection is empty, styled in `pages/projects.css`.

**Tech Stack:** Rails 8, Hotwire (the existing `thumbs` and `filemenu` Stimulus controllers — no new controller), Minitest, `page_query_budget_test.rb`, `template_hygiene_test.rb`.

---

## Before you start

- Branch from `main` after the stage 4 docs PR merges (or from `claude/user-stories-ux-c52143` if it has not). Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend legs must report identical run counts.
- **Read first:** `docs/invariants/design-system.md` (a component selector is defined in `components.css` only — `.panel--quiet` is a page modifier in `pages/projects.css`, and it must not redeclare `.panel`), `docs/invariants/files-preview.md` (the seven-key `thumb_cell_data`/`file_menu_data` wire contract), and the header comments of `app/views/projects/_attachments.html.erb` and `app/controllers/projects_controller.rb#show` (the one union, the one thumbnail map, why liveness reads `nodes.present`).
- Fixtures: a project folder in a request test is `project_folder_rows!(user, project)` — never `ensure_library_folder!` (a real mkdir; red on s3 and chunk_remote). A real README or git repository needs `use_fresh_share_library!` plus `Library::ScanJob`, the idiom `test/integration/web/project_repo_card_test.rb` already carries. Nodes are `@user.nodes.create!(node_id:, name:, kind:, parent_node_id:, size:, mtime:)`.
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; `git status --porcelain` before the next run.
- Helpers you will call: `thumb_cell_data(node_id, ext_label)` and `file_menu_data(node_id, origin)` in `app/helpers/files_helper.rb`; `blob_file_path(node_id)`; `Maker::FileAttachment.role_for(name)`; `Maker::RepoCard::DEFAULT_LINK`.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/services/maker/project_folder_listing.rb` (`root_repo?`), `test/services/maker/project_folder_listing_test.rb` | is the folder itself a working tree | A |
| new `app/services/maker/project_photos.rb`, `app/services/maker/public_project.rb` (`photo_rows` delegates), new `test/services/maker/project_photos_test.rb` | the one definition of a project's photos | A |
| `app/views/projects/_build_log.html.erb`, `_tasks.html.erb`, `_bom.html.erb`, `_wiring.html.erb`, `_releases.html.erb`, `_sheets.html.erb`; `app/assets/stylesheets/pages/projects.css` (the quiet block, appended); `test/integration/web/project_page_test.rb` (two quiet tests), `project_wiring_test.rb:60`, `project_releases_test.rb:86`, `project_sheets_test.rb:245`, `project_bom_test.rb:378` | quiet empty panels | C |
| `app/controllers/projects_controller.rb#show`, `app/views/projects/show.html.erb`, new `_hero.html.erb`, new `_photos.html.erb`, new `_readme_card.html.erb`, `_attachments.html.erb`, `_file_rows.html.erb`, `app/assets/stylesheets/pages/projects.css` (hero/photos block, after `.project-stats b`); `test/integration/web/project_page_test.rb` (hero, photos), `project_attachments_test.rb` (list menu), `project_repo_card_test.rb` (root repo, plain README), `page_query_budget_test.rb` (cover + photos in the seed), `template_hygiene_test.rb` (the fixture renders the new partials) | the page | B |
| `docs/user-stories.md` (re-tag 1.4, 2.9, 5.3, 6.1, 6.2, 6.3, 6.6, 6.8), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-1 row → landed) | close-out | D |

**Dependencies:** A and C are disjoint — dispatch them in parallel. B needs A (`root_repo?`, `Maker::ProjectPhotos`) and edits `projects.css` after C has appended its block, so B starts when both have committed. D closes out.

---

### Task A: `root_repo?` and `Maker::ProjectPhotos`

**Files:**
- Modify: `app/services/maker/project_folder_listing.rb` (`initialize` after `dir_ids = …`; a reader beside `available?`)
- Create: `app/services/maker/project_photos.rb`
- Modify: `app/services/maker/public_project.rb` (`#photo_rows`)
- Test: `test/services/maker/project_folder_listing_test.rb`, `test/services/maker/project_photos_test.rb` (new)

- [ ] **Step 1: the failing listing test.** Append inside the existing test class (it already has a signed-in `@user` in `setup`; keep that):

```ruby
    test "root_repo? is true when the folder itself holds a .git marker, and false for a repo nested inside" do
      project = @user.maker_projects.create!(name: "Root Repo")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "root-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: folder.node_id, size: 0, mtime: 1_700_000_000_000_000_000)

      assert Maker::ProjectFolderListing.new(@user, project).root_repo?

      other = @user.maker_projects.create!(name: "Nested Repo")
      other_folder = project_folder_rows!(@user, other)
      firmware = @user.nodes.create!(node_id: "fw-dir", name: "firmware", kind: "dir",
                                     parent_node_id: other_folder.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "fw-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: firmware.node_id, size: 0, mtime: 1_700_000_000_000_000_000)

      listing = Maker::ProjectFolderListing.new(@user, other)
      refute listing.root_repo?, "a repository INSIDE the folder is not the root"
      assert listing.tree.first.repo?, "…but it is still flagged as a section"
    end

    test "root_repo? is false when the project has no live folder" do
      project = @user.maker_projects.create!(name: "Folderless")
      refute Maker::ProjectFolderListing.new(@user, project).root_repo?
    end
```

- [ ] **Step 2: run it, expect NoMethodError.** `bin/rails test test/services/maker/project_folder_listing_test.rb -n /root_repo/` → FAIL, `undefined method 'root_repo?'`.

- [ ] **Step 3: implement.** In `initialize`, directly after `dir_ids = @folder_id ? collect_dirs(@folder_id) : []`:

```ruby
      # THE ROOT ITSELF (stage 4, S4-1). collect_dirs ENTERS the folder but flags only its
      # children, so a project whose folder IS the working tree — every real repository on the
      # share deployment, measured 2026-09-07 — answered repo? nowhere on its page: no card, no
      # Commits, no History. Asked once here, in memory, of the same tree the walk reads.
      @root_repo = @folder_id ? working_tree?(@folder_id) : false
```

Beside `def available?`:

```ruby
    # Is the project's folder ITSELF a working tree (a `.git` marker child of folder_node_id)?
    # False when the folder is not available. S4-4's README editor and S4-6's adoption read this.
    def root_repo? = @root_repo
```

- [ ] **Step 4: run, expect PASS.** Same command → 2 runs, 0 failures.

- [ ] **Step 5: mutation check.** Change `working_tree?(@folder_id)` to `false`; run → the first test FAILS on `assert … root_repo?`. Restore with `git checkout -- app/services/maker/project_folder_listing.rb`; run → PASS. Report both outputs.

- [ ] **Step 6: the failing photos test.** Create `test/services/maker/project_photos_test.rb`:

```ruby
require "test_helper"

module Maker
  # Stage 4, S4-1: the ONE definition of a project's photos — folder images plus live entry photos,
  # deduped, name-ordered — shared by the private and the public project page.
  class ProjectPhotosTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "photos@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @project = @user.maker_projects.create!(name: "Lamp")
      @folder = project_folder_rows!(@user, @project)
    end

    def node!(id, name, parent: @folder.node_id)
      @user.nodes.create!(node_id: id, name:, kind: "file", parent_node_id: parent, size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "folder images and live entry photos, once each, by name; a model is not a photo" do
      node!("b", "b.png")
      a = node!("a", "a.jpg")
      node!("m", "part.stl")
      outside = node!("z", "z.png", parent: nil)
      entry = @project.build_log_entries.create!(user: @user, body: "step", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: "z", role: "image")
      entry.file_attachments.create!(user: @user, node_id: "a", role: "image")    # also in the folder: once
      entry.file_attachments.create!(user: @user, node_id: "gone", role: "image") # not live: dropped

      listing = Maker::ProjectFolderListing.new(@user, @project)
      entries = @project.build_log_entries.includes(:file_attachments).to_a
      page_nodes = { "z" => outside, "a" => a }

      rows = Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:)

      assert_equal %w[a.jpg b.png z.png], rows.map { |r| r.node.name }
      assert rows.last.linked?, "an entry photo outside the folder is a linked row"
      refute rows.first.linked?, "a folder image is a folder row"
    end

    test "nothing to show is an empty array, never nil" do
      listing = Maker::ProjectFolderListing.new(@user, @project)
      assert_equal [], Maker::ProjectPhotos.rows(listing:, entries: [], page_nodes: {})
    end
  end
end
```

- [ ] **Step 7: run it, expect NameError.** `bin/rails test test/services/maker/project_photos_test.rb` → FAIL, `uninitialized constant Maker::ProjectPhotos`.

- [ ] **Step 8: create the service** `app/services/maker/project_photos.rb`:

```ruby
module Maker
  # Every photo a project page shows (stage 4, S4-1): the folder's image-role rows plus every LIVE
  # build-log entry photo, deduped, in name order. THE ONE DEFINITION — Maker::PublicProject
  # #photo_rows delegated here the day the private page grew the same gallery, so the two pages
  # cannot drift about what counts as a photo.
  #
  # An entry photo usually lives OUTSIDE the folder (the upload door puts it wherever the maker
  # pointed it), which is why it is read from `page_nodes` — the page's one live-node union —
  # rather than from the listing. In memory over inputs the page already loaded: no query, and
  # page_query_budget_test.rb's seed grows entry photos with N to keep it that way.
  module ProjectPhotos
    def self.rows(listing:, entries:, page_nodes:)
      folder_rows = listing.all_rows.select { |r| r.role == "image" }
      entry_rows = entries.flat_map(&:file_attachments)
                          .filter_map { |a| page_nodes[a.node_id] }
                          .map { |node| Maker::ProjectFolderListing::Row.new(node:, attachment: nil, linked: true, section: nil) }
      (folder_rows + entry_rows).uniq(&:node_id).sort_by { |r| r.node.name }
    end
  end
end
```

Then in `app/services/maker/public_project.rb`, replace the body of `photo_rows` (keep its comment, add one line to it saying the definition moved to `Maker::ProjectPhotos` for the private page's sake):

```ruby
    def photo_rows
      @photo_rows ||= Maker::ProjectPhotos.rows(listing:, entries:, page_nodes:)
    end
```

- [ ] **Step 9: run, expect PASS.** `bin/rails test test/services/maker/project_photos_test.rb test/integration/web/public_project_test.rb` (the public page's photo assertions must stay green).

- [ ] **Step 10: mutation check.** Remove `.uniq(&:node_id)`; run the photos test → FAILS with `a.jpg` twice. Restore; run → PASS. Report both.

- [ ] **Step 11: commit.**

```bash
git add app/services/maker/project_folder_listing.rb app/services/maker/project_photos.rb app/services/maker/public_project.rb test/services/maker/project_folder_listing_test.rb test/services/maker/project_photos_test.rb
git commit -m "A listing knows when its own folder is the repository, and a project's photos have one definition"
```

---

### Task C: quiet empty panels

**Files:**
- Modify: `app/views/projects/_build_log.html.erb`, `_tasks.html.erb`, `_bom.html.erb`, `_wiring.html.erb`, `_releases.html.erb`, `_sheets.html.erb`
- Modify: `app/assets/stylesheets/pages/projects.css` (append a block at the end, inside `@layer pages`)
- Test: `test/integration/web/project_page_test.rb`; edit `project_wiring_test.rb:60`, `project_releases_test.rb:86`, `project_sheets_test.rb:245`, `project_bom_test.rb:378`

- [ ] **Step 1: the failing tests.** Append to `project_page_test.rb` (its `setup` signs `@user` in):

```ruby
    test "an empty secondary panel is quiet: its heading and one add control, no zero-count groups, no empty sentences" do
      project = @user.maker_projects.create!(name: "Blank")

      get project_path(project)

      assert_response :success
      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert_select "section.panel.#{name}-panel.panel--quiet", 1, "#{name} should be quiet"
      end
      assert_select "#project-tasks .tasks-group", count: 0
      assert_select ".build-log-panel details.composer > summary", text: "Add entry"
      assert_select "#project-tasks form.task-form input[name='task[title]']"
      assert_select "p.muted", text: /No (entries|connections|releases|sheets) yet/, count: 0
    end

    test "a populated panel is not quiet" do
      project = @user.maker_projects.create!(name: "Busy")
      project.tasks.create!(user: @user, title: "cut")
      project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)

      get project_path(project)

      assert_select "section.tasks-panel.panel--quiet", count: 0
      assert_select "section.build-log-panel.panel--quiet", count: 0
      assert_select "#project-tasks .tasks-group", count: 3
    end
```

- [ ] **Step 2: run, expect FAIL** on the first `panel--quiet` selector. `bin/rails test test/integration/web/project_page_test.rb -n /quiet/`.

- [ ] **Step 3: the six partials.** Each sets the class on itself and drops its empty sentence; a populated panel renders exactly as today.

`_build_log.html.erb` — line 1 and the `if`:

```erb
<section class="panel build-log-panel<%= " panel--quiet" if @entries.empty? %>">
```
and replace lines 16–24 with
```erb
  <% if @entries.any? %>
    <ol class="log-timeline">
      <% @entries.each do |entry| %>
        <%= render "log_entry", entry: %>
      <% end %>
    </ol>
  <% end %>
```

`_tasks.html.erb` — line 13, and wrap the groups loop:

```erb
<section class="panel tasks-panel<%= " panel--quiet" if @tasks.empty? %>" id="project-tasks">
  <h2>Tasks</h2>

  <%# QUIET AT ZERO (stage 4, S4-1): three headed groups reading "(0)" is not information. The
      turbo-stream target, the error line and the add form below are unchanged, so an Add that
      creates the first task replaces this element with the three groups as before. %>
  <% if @tasks.any? %>
    <% Maker::Task::STATUSES.each do |status| %>
      … the existing group markup, unchanged …
    <% end %>
  <% end %>
```

`_bom.html.erb` — line 8:

```erb
<section class="panel bom-panel<%= " panel--quiet" if @bom_lines.empty? %>">
```
and wrap the `render "projects/bom_lines"` in `<% if @bom_lines.any? %> … <% end %>`. The quiet BOM panel is its heading and the **Open** button — the composer lives on the BOM page, one click away, and `projects/_bom_lines` is shared with that page, whose "No lines yet." sentence stays.

`_wiring.html.erb` — line 21, the count and the empty branch:

```erb
<section class="panel wiring-panel<%= " panel--quiet" if connections.empty? %>">
  <div class="panel-head">
    <h2>Wiring</h2>
    <% if connections.any? %><span class="mono muted"><%= pluralize(connections.size, "connection") %></span><% end %>
  </div>

  <% if connections.any? %>
    … the existing forms and table, unchanged …
  <% end %>
```
(delete the `<p class="muted">No connections yet.</p>` branch; the `if editable` composer below stays.)

`_releases.html.erb` — line 27 and the same two edits: the count span only when `releases.any?`, the `if releases.empty?` sentence removed, the `each_with_index` loop kept under `if releases.any?`.

`_sheets.html.erb` — line 5 and the empty branch:

```erb
<section class="panel sheets-panel<%= " panel--quiet" if @sheets.empty? %>">
```
and replace lines 16–25 with a plain `<% @sheets.each do |sheet| %> … <% end %>` (no empty sentence).

- [ ] **Step 4: the CSS.** Append at the end of `app/assets/stylesheets/pages/projects.css`, inside the `@layer pages { … }` block:

```css
  /* --- Quiet panels (stage 4, S4-1): a secondary panel with nothing in it is its heading and one
     add control on a single line, not a box saying "No entries yet." over an open composer. The
     partial sets the class when its collection is empty; a populated panel is exactly what it was.
     A composer that opens takes the whole row. The panel-head counts are hidden — a zero is not
     information. A page modifier, not a redeclaration of `.panel` (design-system rule 3). --- */
  .panel--quiet { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 14px; padding: 8px 14px; }
  .panel--quiet > h2, .panel--quiet > .panel-head { margin: 0; flex: 1 1 auto; }
  .panel--quiet > .panel-head { display: flex; align-items: center; gap: 10px; }
  .panel--quiet > .panel-head h2 { margin: 0; }
  .panel--quiet > h2 { font-size: 13px; }
  .panel--quiet details.composer { margin: 0; }
  .panel--quiet details.composer[open] { flex-basis: 100%; }
  .panel--quiet > form { margin: 0; display: flex; gap: 6px; }
  .panel--quiet .panel-head .mono.muted { display: none; }
```

- [ ] **Step 5: the four pinned assertions.** Each pinned an empty sentence that no longer renders on the project page:
  - `project_wiring_test.rb:60`: replace `assert_select "section.panel.wiring-panel p.muted", text: "No connections yet."` with `assert_select "section.panel.wiring-panel.panel--quiet"` and `assert_select "section.wiring-panel table.wiring", count: 0`.
  - `project_releases_test.rb:86`: replace the "No releases yet." assertion with `assert_select "section.releases-panel.panel--quiet"` and `assert_select "section.releases-panel details.release", count: 0`.
  - `project_sheets_test.rb:245`: replace the "No sheets yet" assertion with `assert_select "section.sheets-panel.panel--quiet"` and `assert_select ".sheets-panel .sheet-row", count: 0`.
  - `project_bom_test.rb:378`: read the test. If it requests the **project page**, replace with `assert_select "section.bom-panel.panel--quiet"` and `assert_select "section.bom-panel table", count: 0`; if it requests the **BOM page** (`project_bom_path`), leave it — that page still renders `projects/_bom_lines` and its sentence.

- [ ] **Step 6: run the panel suites, expect PASS.**
`bin/rails test test/integration/web/project_page_test.rb test/integration/web/project_wiring_test.rb test/integration/web/project_releases_test.rb test/integration/web/project_sheets_test.rb test/integration/web/project_bom_test.rb test/integration/web/project_tasks_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/system/projects_models_pages_test.rb`

- [ ] **Step 7: mutation check.** In `_tasks.html.erb` change `if @tasks.empty?` to `if false`; run the quiet test → FAILS on `tasks should be quiet`. Restore; PASS. Report both.

- [ ] **Step 8: commit.**

```bash
git add app/views/projects/_build_log.html.erb app/views/projects/_tasks.html.erb app/views/projects/_bom.html.erb app/views/projects/_wiring.html.erb app/views/projects/_releases.html.erb app/views/projects/_sheets.html.erb app/assets/stylesheets/pages/projects.css test/integration/web/project_page_test.rb test/integration/web/project_wiring_test.rb test/integration/web/project_releases_test.rb test/integration/web/project_sheets_test.rb test/integration/web/project_bom_test.rb
git commit -m "An empty secondary panel is quiet: its heading and one add control, no zero-count groups"
```

---

### Task B: the hero, the photos, the README card, the list-view menu

Starts after A and C have committed.

**Files:**
- Modify: `app/controllers/projects_controller.rb#show`
- Modify: `app/views/projects/show.html.erb`, `_attachments.html.erb`, `_file_rows.html.erb`
- Create: `app/views/projects/_hero.html.erb`, `_photos.html.erb`, `_readme_card.html.erb`
- Modify: `app/assets/stylesheets/pages/projects.css` (insert after `.project-stats b`, and the `@media` line)
- Test: `project_page_test.rb`, `project_attachments_test.rb`, `project_repo_card_test.rb`, `page_query_budget_test.rb`, `template_hygiene_test.rb`

- [ ] **Step 1: the failing page tests.** Append to `project_page_test.rb`:

```ruby
    test "the hero shows an image cover inline, a model cover as a thumbnail cell, and nothing for a dead or absent cover" do
      project = @user.maker_projects.create!(name: "Hero")
      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "cover-png", name: "lid.png", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "cover-stl", name: "part.stl", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)

      project.update!(cover_node_id: "cover-png")
      get project_path(project)
      assert_select ".project-hero img.project-hero-img[src=?]", blob_file_path("cover-png")
      assert_select ".project-hero a[href=?]", file_path("cover-png")

      project.update!(cover_node_id: "cover-stl")
      get project_path(project)
      assert_select ".project-hero .project-hero-thumb[data-node-id=?]", "cover-stl"
      assert_select ".project-hero img.project-hero-img", count: 0

      project.update!(cover_node_id: "gone")
      get project_path(project)
      assert_select ".project-hero", count: 0
    end

    test "the photos panel shows folder images and entry photos once each, and is absent with none" do
      project = @user.maker_projects.create!(name: "Shots")
      get project_path(project)
      assert_select "section.photos-panel", count: 0

      folder = project_folder_rows!(@user, project)
      @user.nodes.create!(node_id: "p-b", name: "b.png", kind: "file", parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "p-a", name: "a.jpg", kind: "file", parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "p-z", name: "z.png", kind: "file", size: 1, mtime: 1_700_000_000_000_000_000)
      entry = project.build_log_entries.create!(user: @user, body: "glued", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: "p-z", role: "image")
      entry.file_attachments.create!(user: @user, node_id: "p-a", role: "image")

      get project_path(project)
      assert_select "section.photos-panel .photo-cell", count: 3
      assert_select "section.photos-panel .photo-cell[href=?]", file_path("p-z")
      assert_select "section.photos-panel .panel-head .mono", text: "3 photos"
    end
```

Append to `project_attachments_test.rb`, beside the list-view test at line 496 (use that test's fixture idiom for a project with one folder file `f1`):

```ruby
    test "list rows carry the same context-menu data as tiles" do
      user, project, folder = signed_in_project_with_folder!   # the helper the list-view test above uses; if it inlines its fixture, inline the same lines here
      @user.nodes.create!(node_id: "f1", name: "plate.svg", kind: "file", parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000)

      get project_path(project, view: "list")

      assert_select "table.project-files tr[data-action='contextmenu->filemenu#open'][data-note-url=?][data-download-url=?]",
                    file_notes_path("f1"), blob_file_path("f1", download: 1)
    end
```

Append to `project_repo_card_test.rb` (after `make_project_repo!`):

```ruby
    # THE PROJECT'S OWN FOLDER AS THE REPOSITORY (stage 4, S4-1): `git init` at Projects/<slug>
    # itself — the shape every real repository on the share deployment has.
    def make_root_repo!(user, project, files: { "README.md" => "# Lamp\n\nA lamp.\n" })
      folder = project.ensure_library_folder!(user)
      dir = File.join(library_root, "Projects", project.slug)
      repo = Rugged::Repository.init_at(dir)
      files.each do |rel, body|
        FileUtils.mkdir_p(File.dirname(File.join(dir, rel)))
        File.write(File.join(dir, rel), body)
      end
      index = repo.index
      files.each_key { |rel| index.add(path: rel, oid: Rugged::Blob.from_workdir(repo, rel), mode: 0o100644) }
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "First cut",
                            parents: [], update_ref: "HEAD", author: who, committer: who)
      Library::ScanJob.new.perform(user_id: user.id)
      user.nodes.present.find_by!(node_id: folder.node_id)
    end

    test "a project whose own folder is the repository gets the card, Commits and History, and an honest caption" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      root = make_root_repo!(user, project)

      get project_path(project)

      assert_response :success
      assert_select ".attachments-panel .repo-card .repo-summary", text: "First cut"
      assert_select ".attachments-panel .repo-card .markdown h1", text: "Lamp"
      assert_select ".attachments-panel .panel-head a[href=?]", repo_commit_path(root.node_id), text: "Commits"
      assert_select ".attachments-panel .panel-head a[href=?]", repo_history_path(root.node_id), text: "History"
      assert_select "p.loose-note", text: /This folder is a git repository/
      assert_select "p.loose-note", text: /filed on the next sweep/, count: 0
    end

    test "a plain folder's README renders on the private page, with no git facts and no Commits link" do
      user = sign_in
      project = user.maker_projects.create!(name: "Tray")
      project.ensure_library_folder!(user)
      File.write(File.join(library_root, "Projects", project.slug, "README.md"), "# Tray\n\nWalnut.\n")
      Library::ScanJob.new.perform(user_id: user.id)

      get project_path(project)

      assert_select ".attachments-panel .readme-card .markdown h1", text: "Tray"
      assert_select ".attachments-panel .readme-card .repo-facts", count: 0
      assert_select ".attachments-panel .panel-head a", text: "Commits", count: 0
      assert_select "p.loose-note", text: /filed on the next sweep/
    end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb test/integration/web/project_repo_card_test.rb` — the new tests fail on missing selectors.

- [ ] **Step 3: the controller.** In `ProjectsController#show`:

(a) The cover joins the union. Replace
```ruby
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + entry_photo_ids + @bom_lines.filter_map(&:node_id))
```
with
```ruby
    # THE COVER JOINS THE UNION (stage 4, S4-1): the hero renders it, and liveness is answered by
    # nodes.present like every other tile — a chosen cover is a raw column nothing validates (see
    # project_params), so a tombstoned cover renders NOTHING, not a poll cell that spins forever.
    # Maker::Project#cover_node_id derives one from the attachments when none is chosen: a constant
    # handful of queries regardless of N.
    cover_id = @project.cover_node_id
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + entry_photo_ids +
                                 @bom_lines.filter_map(&:node_id) + [ cover_id ].compact)
    @cover_node = cover_id && @page_nodes[cover_id]
```

(b) The root joins the batched query, and the card or the README is built. Replace
```ruby
    repo_roots = current_user.nodes.present.where(node_id: repo_dirs.map(&:node_id), kind: "dir")
                             .index_by(&:node_id)
```
with
```ruby
    # THE FOLDER'S OWN NODE RIDES THE SAME BATCHED QUERY (stage 4, S4-1) — the root's card needs
    # it exactly as a nested repo's card does, and a second `find_by` here would be the O(repos)
    # shape the comment above forbids, one row bigger.
    repo_roots = current_user.nodes.present
                             .where(node_id: repo_dirs.map(&:node_id) + [ @listing.folder_id ].compact, kind: "dir")
                             .index_by(&:node_id)
```
and, directly after the `@repo_cards = …` block:
```ruby
    # THE ROOT'S OWN CARD (stage 4, S4-1). A project whose folder IS the working tree had no card
    # and no Commits/History anywhere on its page — every real repository on the share deployment
    # is one (measured 2026-09-07). The root is a synthetic Dir: its files are the loose rows, its
    # children the tree, its path the folder's — exactly what Maker::RepoCard reads to find a README
    # and resolve its relative links. A plain folder's README renders through the same reader with
    # no git facts. Neither costs a query: the node came out of the batch above, and the README is a
    # bounded PORT read (Maker::Readme's own caps), never SQL.
    @root_card = nil
    @readme = nil
    if @listing.available?
      if @listing.root_repo?
        root_dir = Maker::ProjectFolderListing::Dir.new(node_id: @listing.folder_id, name: @project.name,
                                                         path: @listing.path, repo?: true,
                                                         children: @listing.tree, files: @listing.loose)
        @root_card = Maker::RepoCard.for(user: current_user, dir: root_dir, root_node: repo_roots[@listing.folder_id],
                                         listing: @listing, capabilities:)
      else
        @readme = Maker::Readme.for(user: current_user, rows: @listing.loose, base_path: @listing.path,
                                    listing: @listing, link: Maker::RepoCard::DEFAULT_LINK)
      end
    end
```

(c) The cover's thumbnail and the photos. Replace
```ruby
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, tile_ids + entry_photo_ids.select { |id| @page_nodes.key?(id) }
    )
```
with
```ruby
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, tile_ids + entry_photo_ids.select { |id| @page_nodes.key?(id) } + (@cover_node ? [ cover_id ] : [])
    )
    # PHOTOS (stage 4, S4-1): the public page's own definition, on the maker's page too. In memory
    # over @listing, @entries and @page_nodes — all already loaded above — so nothing here queries,
    # and every row's thumbnail is already in @page_thumbs (folder rows through tile_ids, entry
    # photos through entry_photo_ids).
    @photo_rows = Maker::ProjectPhotos.rows(listing: @listing, entries: @entries, page_nodes: @page_nodes)
```

- [ ] **Step 4: the three new partials.**

`app/views/projects/_hero.html.erb`:
```erb
<%#
  THE HERO (stage 4, S4-1): the cover on the project's own page — until now `cover_node_id`
  reached only the index card and Home. Reads @cover_node (a LIVE node from the page's one
  PageNodes union; nil when the cover is unset or tombstoned) and @page_thumbs. An image-role
  cover is the picture itself through the blob route; any other cover is its server thumbnail in
  a poll cell, the model page's hero-poster rule; no cover renders NOTHING — a project page is not
  a card, and an empty box under the title would read as a broken image.
%>
<% if @cover_node %>
  <% ext = File.extname(@cover_node.name).delete(".").upcase.first(4) %>
  <div class="project-hero" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <% if Maker::FileAttachment.role_for(@cover_node.name) == "image" %>
      <%= link_to file_path(@cover_node.node_id) do %>
        <%= image_tag blob_file_path(@cover_node.node_id), class: "project-hero-img", alt: @cover_node.name %>
      <% end %>
    <% else %>
      <%= link_to file_path(@cover_node.node_id), class: "file-cell project-hero-thumb",
                  data: thumb_cell_data(@cover_node.node_id, ext) do %>
        <%= render "files/thumb", thumb: @page_thumbs.thumb(@cover_node.node_id), ext_label: ext %>
      <% end %>
    <% end %>
    <span class="project-hero-name mono muted"><%= @cover_node.name %></span>
  </div>
<% end %>
```

`app/views/projects/_photos.html.erb`:
```erb
<%#
  PHOTOS (stage 4, S4-1): the gallery the public page has had since S3-4, on the maker's own page.
  Rows come from Maker::ProjectPhotos (ProjectsController#show → @photo_rows): the folder's image
  rows plus every live entry photo, deduped, name-ordered. Omitted entirely when there are none — a
  gallery with no pictures is not a quiet panel, it is no panel.

  Its own `thumbs` controller: this section sits OUTSIDE the Files panel's polling wrapper, the same
  reason projects/_log_entry carries one. Every row's thumbnail is already in @page_thumbs, so this
  polls the pending ones and never builds a second ThumbnailMap.
%>
<% if @photo_rows.any? %>
  <section class="panel photos-panel">
    <div class="panel-head">
      <h2>Photos</h2>
      <span class="mono muted"><%= pluralize(@photo_rows.size, "photo") %></span>
    </div>
    <div class="project-photos" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% @photo_rows.each do |row| %>
        <%= link_to file_path(row.node_id), class: "photo-cell file-cell", title: row.node.name,
                    data: thumb_cell_data(row.node_id, "IMG") do %>
          <%= render "files/thumb", thumb: @page_thumbs.thumb(row.node_id), ext_label: "IMG" %>
        <% end %>
      <% end %>
    </div>
  </section>
<% end %>
```

`app/views/projects/_readme_card.html.erb`:
```erb
<%#
  THE README CARD FOR A PLAIN FOLDER (stage 4, S4-1): the project's root README rendered on the
  maker's own page. Until now a README was rendered only inside a repository's card
  (projects/_repo_card) and on the PUBLIC page — a maker with a plain folder saw their own
  documentation only by publishing it. Same reader (Maker::Readme), same `.markdown` rendering,
  same `.readme` details S4-4 mounts its editor on; no git facts, because there is no git. Shares
  `.repo-card`'s frame on purpose — one card look for "what this folder says about itself".

  Locals: readme (Maker::Readme — html and/or note; the caller passes nothing when the folder has no
  README, so this partial never renders empty), editable (false until S4-4).
%>
<div class="repo-card readme-card">
  <% if readme.html.present? %>
    <details class="readme" open>
      <summary>README</summary>
      <div class="markdown"><%= readme.html %></div>
      <% if readme.note %>
        <p class="muted readme-note"><%= readme.note %></p>
      <% end %>
    </details>
  <% elsif readme.note %>
    <p class="muted readme-note"><%= readme.note %></p>
  <% end %>
</div>
```

- [ ] **Step 5: `show.html.erb`.** After the `</p>` that closes `.project-stats` and before `<div class="project-panels">`, add `<%= render "hero" %>`. Inside `.project-panels`, directly after `<%= render "attachments" %>`, add `<%= render "photos" %>`.

- [ ] **Step 6: `_attachments.html.erb`.** Three edits.

(a) The panel head — after the `panel-path` link (line 43) add the badge, and inside `.panel-actions` before the Scan folder button add the links:
```erb
    <% if @listing.root_repo? %><span class="badge">repo</span><% end %>
```
```erb
      <% if @listing.root_repo? %>
        <%= link_to "Commits", repo_commit_path(@listing.folder_id), class: "linkbtn" %>
        <%= link_to "History", repo_history_path(@listing.folder_id), class: "linkbtn" %>
      <% end %>
```

(b) The card slot — directly before the `<% backups = … %>` line (line 84):
```erb
  <%# THE ROOT'S CARD (stage 4, S4-1), above the groups, for every project that has one: the
      repository card when the folder itself is a working tree (README, latest commit, tag), the
      README alone otherwise. Outside the empty check below on purpose — a README is content. %>
  <% if @root_card %>
    <%= render "projects/repo_card", card: @root_card %>
  <% elsif @readme %>
    <%= render "projects/readme_card", readme: @readme, editable: false %>
  <% end %>
```

(c) The caption — replace line 95 with:
```erb
        <% if @listing.root_repo? %>
          <p class="muted loose-note">This folder is a git repository, so its files stay where they are.</p>
        <% else %>
          <p class="muted loose-note">Loose files are filed on the next sweep; a README stays here.</p>
        <% end %>
```
Add one sentence to the partial's header comment naming the card slot and the working-tree caption.

- [ ] **Step 7: `_file_rows.html.erb`.** Replace the `<tr>` … `</tr>` with a builder call so the row carries the menu data (nil values are dropped by the tag helper, exactly as on the tiles):
```erb
      <%= tag.tr(data: file_menu_data(row.node_id, origin)) do %>
        <td class="col-name"><%= link_to node.name, file_path(row.node_id) %></td>
        <td class="muted col-section"><%= row.section.presence || "Loose" %></td>
        <td class="num muted col-size"><%= node.size ? number_to_human_size(node.size) : "—" %></td>
        <td class="muted col-modified">
          <%= node.mtime ? Time.at(node.mtime / 1_000_000_000).strftime("%Y-%m-%d %H:%M") : "—" %>
        </td>
        <td class="muted col-origin"><%= origin ? origin[:title] : "—" %></td>
      <% end %>
```
`filemenu_controller.js#open` reads `href` off the cell or its first `<a>`, so a row's Open goes to the file page with no controller change.

- [ ] **Step 8: the CSS.** In `pages/projects.css`, after the `.project-stats b` line insert:
```css
  /* --- The hero (stage 4, S4-1): the cover on the project's own page. An image cover is the
     picture, capped like the model page's; any other cover is its thumbnail in a poll cell. --- */
  .project-hero { display: flex; flex-direction: column; gap: 6px; margin: 0 0 20px; }
  .project-hero-img { display: block; width: 100%; max-height: 50vh; object-fit: contain;
                      border: 1px solid var(--line); border-radius: var(--radius-panel); background: var(--thumb-stage); }
  .project-hero-thumb { display: block; width: min(100%, 480px); }
  .project-hero-thumb .thumb { width: 100%; height: 240px; }
  .project-hero-name { font-size: 12px; }
  /* --- Photos (stage 4, S4-1): the public gallery's grid, on the private page, full width. --- */
  .project-photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 10px; }
  .project-photos .thumb { width: 100%; height: 110px; }
```
and change the `@media (min-width: 900px)` line so Photos spans the grid like Files:
```css
  @media (min-width: 900px) { .project-panels { grid-template-columns: 1fr 1fr; } .attachments-panel, .photos-panel { grid-column: 1 / -1; } }
```

- [ ] **Step 9: run the three suites, expect PASS.** `bin/rails test test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb test/integration/web/project_repo_card_test.rb`.

- [ ] **Step 10: the query budget grows with the new things.** In `page_query_budget_test.rb`'s `projects#show` test:
  - after the `firmware-readme` node, add an image at the folder root and make it the cover:
    ```ruby
      @user.nodes.create!(node_id: "cover-img", name: "cover.png", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)
      project.update_column(:cover_node_id, "cover-img")
    ```
  - inside `add`, replace the `project.build_log_entries.create!(…)` line with an entry that carries a photo, and add a folder image per iteration:
    ```ruby
          entry = project.build_log_entries.create!(user: @user, body: "entry #{id}", logged_at: Time.current)
          node!("#{id}-photo", "#{id}.png")
          entry.file_attachments.create!(user: @user, node_id: "#{id}-photo", role: "image")
          @user.nodes.create!(node_id: "#{id}-img", name: "#{id}.jpg", kind: "file", parent_node_id: sub.node_id,
                              size: 1, mtime: 1_700_000_000_000_000_000)
    ```
  Run `bin/rails test test/integration/web/page_query_budget_test.rb -n /projects#show/` → PASS. **Mutation:** in `Maker::ProjectPhotos.rows` replace `page_nodes[a.node_id]` with `@user_nodes_lookup = a.user.nodes.present.find_by(node_id: a.node_id)` (a per-photo query); run → FAILS (grows with N). Restore; PASS. Report both.

- [ ] **Step 11: the template sweep renders the new partials' populated branches.** In `template_hygiene_test.rb`'s fixture, after the `firmware` repo seed: an image at the folder root attached as an image (becomes the derived cover → `_hero`'s image branch, and a `_photos` row), and a loose `README.md` node (no bytes → `Maker::Readme` fails closed to a note → `_readme_card`'s note branch):
    ```ruby
      file!("n-photo", "lid.png", parent_node_id: folder.node_id)
      @project.file_attachments.create!(user: @user, node_id: "n-photo", role: "image", position: 3)
      file!("n-readme", "README.md", parent_node_id: folder.node_id)
    ```
  Run `bin/rails test test/integration/web/template_hygiene_test.rb` → PASS, with `projects/_hero`, `projects/_photos` and `projects/_readme_card` rendered. If the coverage assertion names one of them as unrendered, the fixture above did not reach its branch — fix the fixture, never the assertion.

- [ ] **Step 12: mutation checks for the page.** (i) In `_hero.html.erb` change `if @cover_node` to `if false` → the hero test FAILS on the `img` selector. (ii) In `_attachments.html.erb` remove the `@listing.root_repo?` caption branch → the root-repo test FAILS on `/This folder is a git repository/`. (iii) In `_file_rows.html.erb` revert to a plain `<tr>` → the list-menu test FAILS. Restore each; PASS. Report all six outputs.

- [ ] **Step 13: the phone sweep and the full suites.** `bin/rails test test/system/shell_test.rb test/system/projects_models_pages_test.rb test/integration/web/public_project_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb` → PASS (no page scrolls sideways at 375px with the hero; the public gallery unchanged).

- [ ] **Step 14: commit.**

```bash
git add app/controllers/projects_controller.rb app/views/projects/show.html.erb app/views/projects/_hero.html.erb app/views/projects/_photos.html.erb app/views/projects/_readme_card.html.erb app/views/projects/_attachments.html.erb app/views/projects/_file_rows.html.erb app/assets/stylesheets/pages/projects.css test/integration/web/project_page_test.rb test/integration/web/project_attachments_test.rb test/integration/web/project_repo_card_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb
git commit -m "The project page shows what matters: a hero, its photos, the root README and repository card, and rows that carry the tile's menu"
```

---

### Task D: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, with the new evidence in the last column:
  - 1.4 stays `rough` — the card and Commits/History now render for a root repo (S4-1); the "New" feedback and build output remain (S4-6, S4-2).
  - 2.9 stays `rough` — the README renders on the project page (S4-1); the file page still shows source; PDF unchanged.
  - 5.3 stays `missing` — rendering landed (S4-1); the editor, template and preview are S4-4.
  - 6.1 → `rough` with new evidence: empty panels are quiet (S4-1); the fixed order and the hero choice remain (S4-7).
  - 6.2 stays `rough` — the root repository card renders (S4-1); no board on the page; schematics KiCad-only.
  - 6.3 → `rough` with new evidence: the cover is the hero (S4-1); print history still lives on Models.
  - 6.6 → `works` (S4-1, `projects/_photos`).
  - 6.8 → `works` (S4-1, `_file_rows.html.erb` carries `file_menu_data`).
  Update the Coverage table's counts.
- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-1 row as landed with the PR number.
- [ ] **Step 3: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` green; the three legs' run counts identical (a ±2 assertion flap is `tinkerex#131`; anything structural is a bug).
- [ ] **Step 4: commit, push, PR, record.** `git commit -m "S4-1 close-out: the stories re-tagged, the overview updated"`; `/finish-branch`; then `bin/log arc --from-pr <n>`.

---

## Self-review against the spec (§6)

| spec §6 item | task |
|---|---|
| hero: image inline, else thumbnail poll cell, else nothing; derived cover joins the union | B steps 3(a), 3(c), 4 |
| photos: `Maker::ProjectPhotos` extracted, both pages call it, omitted when none | A step 8, B step 4 |
| README card for every project; root working tree gets the full card, head links, honest caption; root node in the batched query | A steps 1–5, B steps 3(b), 4, 6 |
| quiet panels for the six, populated panels unchanged, Files never quiet | C |
| list view carries `file_menu_data` | B step 7 |
| query budget constant in N, seeds grow | B step 10 |
| template sweep renders the new partials | B step 11 |
| stories re-tagged in the same PR | D |
