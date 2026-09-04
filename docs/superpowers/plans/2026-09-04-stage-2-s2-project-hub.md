# Stage 2, S2-2: the project as the hub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S2-2 of `docs/superpowers/specs/2026-09-04-stage-2-structure-design.md` (§5): the project page's Files panel lists **the project's folder** — `Projects/<slug>/` recursively — grouped by role from each filename; attachment rows whose file lives *outside* the folder show in a "Linked from elsewhere" group; a git working tree inside the folder shows as **one** "Repositories" entry and is not descended; the stats line counts the folder; Home's hero uses the same count. **The page reads and never files or mints a folder.** No new tables; the query count stays constant in N.

**Architecture:** One read-only service, `Maker::ProjectFolderListing`, built on `Maker::LibraryTree` (one pluck of the user's live dirs, now with a `children_of` index): it resolves the folder from `folder_node_id` alone, walks the subtree in memory (skipping dot-dirs, stopping at working trees), and issues **one** capped files query plus **one** count. `ProjectsController#show` merges that listing with the existing `@attachments` (which stay the file→project relation: detach, cover, addon origin, missing-count) into uniform `Row`s the two panel partials render. `HomeController` asks the same service for the count only.

**Tech Stack:** Rails 8, Hotwire, Minitest request tests, the existing `page_query_budget_test.rb` harness.

---

## Before you start

- Branch `claude/stage-2-project-hub` from `main` at `dad1532` (PR #311 merged). Worktree `/Users/charlesschwartz/Desktop/repos/tinkerex/.claude/worktrees/auto-model-folder-files-bug-112353`. Never push to `main`.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; full gate `bin/ci` with `export TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync`; one full-suite run at a time.
- **Read `docs/invariants/project-intake.md` first** (§14f). Two of its rules bind this slice directly: *never call `ensure_library_folder!` from a reader* (looking must not mkdir — the `#relocate` bug), and *the page reads, it never files* (only `Library::ScanJob` / the eager nudge move bytes). The one writer on `projects#show` is the pre-existing best-effort `ensure_library_folder!` that feeds the **upload control**; it stays, and it runs BEFORE the listing so the listing sees the folder it (re)created.
- Read `docs/invariants/design-system.md` (§14m) and `docs/invariants/files-preview.md` before touching the partials: the tile markup (`grid-card file-cell` + `thumb_cell_data` + `file_menu_data` + `files/_thumb`) is a wire contract with `thumbs_controller.js` and `filemenu_controller.js`.
- **Role comes from the filename, never from the stored `role` column** (`Maker::FileAttachment.role_for(name)`) — `Maker::ProjectFolders`' rule; a folder file may have no attachment row at all, and a row's role is a snapshot.
- `.git` keeps its node on purpose (§14b): a dir is a working tree iff it has a child dir named `Library::RepoMetadata::DIR_NAME`. Hidden (dot-prefixed) dirs are skipped the way `Node.visible_entries` hides dot entries — a display rule, never a scan skip.
- `git checkout -- <file>` restores to HEAD and cannot restore a new file: `git add` before a mutation check.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/services/maker/library_tree.rb` | `children_of(node_id)` — a lazily built parent→children index over the rows already plucked | A |
| `app/services/maker/project_folder_listing.rb` | the read-only listing: folder resolution, the walk, the capped files query, `Row`/`Repo` | A |
| `test/services/maker/library_tree_test.rb`, `test/services/maker/project_folder_listing_test.rb` | their tests | A |
| `app/controllers/projects_controller.rb` (`#show`), `app/controllers/home_controller.rb` (hero `files:`) | merge listing + attachments; the hero's count | B |
| `app/views/projects/_attachments.html.erb`, `_attachment_group.html.erb`, new `_repo_group.html.erb`, `show.html.erb` (stats) | the panel | B |
| `app/assets/stylesheets/pages/projects.css` | `.panel-path`, `.tile-move` | B |
| `test/integration/web/project_attachments_test.rb`, `project_page_test.rb`, `page_query_budget_test.rb`, `home_test.rb` | the page and its budget | B |
| `docs/invariants/project-intake.md` | one bullet: the listing reads, never mints | B |

**Dependencies:** Task A and Task B touch disjoint files and run in parallel; B codes against the API below and runs its tests once A has committed (poll for `git log -1 -- app/services/maker/project_folder_listing.rb`). Task C is the close-out.

---

### Task A: `LibraryTree#children_of` and `Maker::ProjectFolderListing`

**Files:** modify `app/services/maker/library_tree.rb`; create `app/services/maker/project_folder_listing.rb`; modify `test/services/maker/library_tree_test.rb`; create `test/services/maker/project_folder_listing_test.rb`.

- [ ] **Step 1: `children_of`** — in `LibraryTree`, after `dir_ids`:

```ruby
    # The dir Entries directly under one dir (nil = the library root). Built ONCE, lazily, from the
    # rows the constructor already plucked — a second `where(parent_node_id:)` per level is exactly
    # the per-file query this class exists to avoid. Order is the pluck's; callers that care sort.
    def children_of(node_id)
      @children ||= @dirs.values.group_by(&:parent_node_id)
      @children.fetch(node_id, [])
    end
```

Test (in `library_tree_test.rb`, following its fixtures): children of a dir are its live dir children only (a tombstoned child and a file child are absent); children of an unknown id are `[]`; asking twice issues no query (`assert_no_queries` or the file's query-count idiom).

- [ ] **Step 2: the listing** — `app/services/maker/project_folder_listing.rb`:

```ruby
module Maker
  # What a project's folder holds — the read-only half of "the folder is the truth" (stage 2, S2-2).
  #
  # RESOLVES THE FOLDER FROM `folder_node_id` AND NOTHING ELSE. It never calls
  # Project#ensure_library_folder!: looking at a folder must not mkdir one (the #relocate bug
  # docs/invariants/project-intake.md records), so a project with no live folder simply lists
  # nothing and answers `available? == false`. Liveness is answered by the LibraryTree, which holds
  # LIVE dirs only — no extra query.
  #
  # THE WALK IS IN MEMORY OVER ONE PLUCK OF THE USER'S DIRS, then ONE files query and ONE count, so
  # the cost is constant in the number of files and folders (page_query_budget_test.rb pins it).
  # Two rules shape the walk: a dot-prefixed dir is skipped, the same display rule
  # Node.visible_entries applies to entries (never a scan skip — §14b); and a dir holding a `.git`
  # marker child is a WORKING TREE, listed as ONE Repo and never entered, because a checked-out
  # firmware repo is one thing in a project, not three hundred source files under "Code".
  #
  # ROLE COMES FROM THE FILENAME (Maker::FileAttachment.role_for), never a stored column: most
  # folder files have no attachment row at all, and a row's role is a snapshot (ProjectFolders).
  class ProjectFolderListing
    FILE_CAP = 300   # tiles the panel will render; the rest is a count and a link to the folder
    DIR_CAP  = 500   # dirs the walk will enter; bounds the IN (...) list on SQLite

    # One tile. `attachment` is nil for a folder file (the folder is the relation); a Linked row
    # (a file attached to the project but living OUTSIDE its folder) carries its row so the tile
    # can offer Detach and Move-into-project. `linked` is the folder test, not the row's presence.
    Row = Data.define(:node, :attachment, :linked) do
      def node_id = node.node_id
      def role = Maker::FileAttachment.role_for(node.name)
      def backup? = Maker::FileAttachment.backup?(node.name)
      def linked? = linked
    end

    Repo = Data.define(:node_id, :name, :path)

    attr_reader :folder_id, :path, :files, :repos, :total

    # `load_files: false` answers `total` (and `repos`) without the files query — Home's hero.
    def initialize(user, project, tree: nil, load_files: true)
      @user = user
      @tree = tree || Maker::LibraryTree.new(user)
      @folder_id = project.folder_node_id.presence
      @folder_id = nil unless @folder_id && @tree.dir?(@folder_id)
      @path = @folder_id && @tree.path_for(@folder_id)
      @repos = []
      dir_ids = @folder_id ? collect_dirs(@folder_id) : []
      scope = dir_ids.empty? ? user.nodes.none : files_in(dir_ids)
      @total = dir_ids.empty? ? 0 : scope.count
      rows = load_files && !dir_ids.empty? ? scope.order(:name, :node_id).limit(FILE_CAP + 1).to_a : []
      @truncated = rows.size > FILE_CAP
      @files = rows.first(FILE_CAP).map { |n| Row.new(node: n, attachment: nil, linked: false) }
    end

    def available? = !@folder_id.nil?
    def truncated? = @truncated
    def node_ids = @files.map(&:node_id)
    def node_id_set = @node_id_set ||= node_ids.to_set

    private

    def files_in(dir_ids)
      @user.nodes.present.where(kind: "file", parent_node_id: dir_ids).visible_entries(false)
    end

    # Breadth-first from the folder itself (always entered, even when it is a working tree — a
    # project that IS a repo still lists its files). A `seen` set is the cycle guard the tree's
    # own ancestor walk has for the same reason: a cycle is unrepresentable on a mount and perfectly
    # representable in a row set.
    def collect_dirs(root_id)
      out = [ root_id ]
      queue = [ root_id ]
      seen = Set[root_id]
      until queue.empty? || out.size >= DIR_CAP
        parent = queue.shift
        @tree.children_of(parent).each do |child|
          next unless seen.add?(child.node_id)
          next if child.name.start_with?(".")
          if working_tree?(child.node_id)
            @repos << Repo.new(node_id: child.node_id, name: child.name, path: @tree.path_for(child.node_id))
            next
          end
          out << child.node_id
          queue << child.node_id
        end
      end
      out
    end

    def working_tree?(dir_id)
      @tree.children_of(dir_id).any? { |d| Library::RepoMetadata.marker?(d.name) }
    end
  end
end
```

(If `DIR_CAP` is hit, `truncated?` should also read true — set `@truncated ||= out.size >= DIR_CAP` after the walk, via an ivar the constructor reads. Keep it simple and test it.)

- [ ] **Step 3: tests** — `test/services/maker/project_folder_listing_test.rb`. Build nodes with the suite's helper (`create_node!` if it exists for unit tests; else `user.nodes.create!(node_id:, name:, kind:, parent_node_id:, mtime: 1, size: 1)`), a project with `folder_node_id` set to a dir you created (do NOT call `ensure_library_folder!` in setup — the point is the listing needs no port). Cases, each one test:
  1. files at the folder root and in `docs/`/`models/` subfolders are all listed; a file at the library root is not; `path` is `"Projects/desk-lamp"`; `total` equals the count.
  2. a dot-dir's contents are skipped (`.stversions/x.stl` absent) and a `.git` marker dir is never listed as a repo of its own.
  3. a subdir holding a `.git` child is ONE `Repo` (name, path) and its files are absent from `files`; the folder root being a working tree still lists the root's files.
  4. a tombstoned subfolder's files are absent (the tree holds live dirs only).
  5. `FILE_CAP + 1` files → `files.size == FILE_CAP`, `truncated?`, `total == FILE_CAP + 1` (use `insert_all` for speed).
  6. no `folder_node_id`, or one naming a tombstoned dir → `available? == false`, `files == []`, `total == 0`, **and no node was created**: assert `user.nodes.count` unchanged and stub `Maker::LibraryFolder.ensure_path!` to raise using the house `replacing` helper (`grep -rn "def replacing" test/`).
  7. `load_files: false` → `files == []` while `total` and `repos` are right, and exactly two queries run (the dirs pluck and the count) — use the query-count idiom from `page_query_budget_test.rb` / `test/support`.
  8. `Row#role` reads the name: a folder file named `plate.dxf` is `"vector"`; `Row#backup?` for a LightBurn backup name.

- [ ] **Step 4: run, then mutation-check** (stage first): (a) delete the `child.name.start_with?(".")` skip → test 2 red; (b) make `working_tree?` return false → test 3 red; (c) replace `@tree.dir?(@folder_id)` liveness with `true` and call `project.ensure_library_folder!(user)` for a nil folder → test 6 red (the `replacing` stub raises). Report each verbatim; restore; `git status --porcelain`.

- [ ] **Step 5: commit** (`git add` the four files; `git commit -m "... -- <paths>"` with a pathspec, since another agent shares the index):

```
Maker::ProjectFolderListing: what a project's folder holds, read from one pluck and two queries
```

---

### Task B: the panel, the stats, the hero

**Files:** `app/controllers/projects_controller.rb`, `app/controllers/home_controller.rb`, `app/views/projects/_attachments.html.erb`, `_attachment_group.html.erb`, `_repo_group.html.erb` (new), `show.html.erb`, `app/assets/stylesheets/pages/projects.css`, `test/integration/web/project_attachments_test.rb`, `project_page_test.rb`, `page_query_budget_test.rb`, `home_test.rb`, `docs/invariants/project-intake.md`.

- [ ] **Step 1: write the failing tests first.** In `project_attachments_test.rb` (read its helpers — `sign_in`, `attach_node` — and ADD a helper that creates a node INSIDE the project folder: `folder = project.ensure_library_folder!(user)` once per test, then nodes with `parent_node_id: folder.node_id`, or under a subfolder node you create with `kind: "dir"`):
  - **"the panel lists the folder, grouped by role from the filename, whether or not a row exists"** — `bracket.stl` at the folder root with an attachment, `shade.stl` in `models/` with NO attachment, `photo.jpg` in `images/` → `.attachment-group-head` "Models (2)", "Images (1)", three tiles, no Linked group.
  - **"a file attached from elsewhere is Linked, with Detach and Move into project"** — one attachment to a node at the library root → `.attachment-group-head` text `/Linked from elsewhere \(1\)/`; that tile has `button.tile-detach` and a `form[action=?]` `relocate_project_attachments_path(project)` button `.tile-move` (read `_move_conflict.html.erb` for the param name the relocate door expects, and `Projects::AttachmentsController#node_id_param`).
  - **"a repository inside the folder is one entry and its files are not tiles"** — a `firmware/` dir under the folder with a `.git` dir child and `main.c` inside → `.attachment-group-head` text `/Repositories \(1\)/`, a `.repo-tile a[href=?]` `files_path(folder: firmware.node_id)`, and NO tile named `main.c`.
  - **"folder files do not get Detach"** — the bracket tile above has no `.tile-detach`.
  - **"the panel caps at FILE_CAP and points at the folder"** — `FILE_CAP + 1` files in the folder (insert_all) → `.attachment-tile` count `Maker::ProjectFolderListing::FILE_CAP`, and `.attachments-truncated a[href=?]` `files_path(folder: folder.node_id)` with text `/Showing 300 of 301/`.
  - Update the existing grouping test ("groups attachments by type and omits empty categories") so its four nodes live in the folder (they were at the library root, which is now the Linked case). Keep every other existing assertion in that file; where one names a node at the root, it is asserting the Linked case now — say so in the test.
  - Empty state: no folder files, no linked, no repos, nothing missing → `p.muted` "No files in this project yet." (replaces "No files attached yet."; the count-0 assertion at line ~86 still holds).
  - `project_page_test.rb:32` `/2 files/` — its two attachments: put them in the folder (then `/2 files/` holds) and add `assert_select ".project-stats", text: /1 linked/` for a third attachment outside.
  - `page_query_budget_test.rb` "projects#show does not grow…": the seed lambda must now grow the FOLDER too — per iteration create a subfolder under `project.ensure_library_folder!(@user)` with a file in it, plus an attachment to a node OUTSIDE the folder (the Linked case), plus a task and an entry. Assert constant as before.
  - `home_test.rb`: the hero's file count reads the folder — add to the hero test one file inside the current project's folder and assert `.home-hero .project-stats` `/1 file\b/`; a project with an attachment to a root node and nothing in the folder shows `/0 files/`.

- [ ] **Step 2: the controller.** In `ProjectsController#show`, MOVE the `@upload_parent_node_id = begin @project.ensure_library_folder!(current_user).node_id rescue nil end` block ABOVE the listing (keep its comment; add: "AND it runs before the listing, which reads the folder_node_id it (re)writes"), then replace the `@page_thumbs` / `@addon_origins` block with:

```ruby
    # THE FOLDER IS WHAT THE PANEL SHOWS; @attachments stay the file→project RELATION (detach,
    # cover, addon origin, the missing count). Maker::ProjectFolderListing reads folder_node_id
    # and never mints a folder — the ensure above is the one writer, and it runs first.
    @listing = Maker::ProjectFolderListing.new(current_user, @project)
    inside = @listing.node_id_set
    @linked_rows = @attachments.reject { |a| inside.include?(a.node_id) }
                               .map { |a| Maker::ProjectFolderListing::Row.new(node: @page_nodes[a.node_id], attachment: a, linked: true) }
    tile_ids = @listing.node_ids + @linked_rows.map(&:node_id)
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, tile_ids + entry_photo_ids.select { |id| @page_nodes.key?(id) }
    )
    @addon_origins = addon_origins_for(tile_ids)
```

(`@attachments` and `@missing_attachment_count` are computed exactly as today, above.) In `HomeController#index`, `files: @project.file_attachments.count` becomes `files: Maker::ProjectFolderListing.new(current_user, @project, load_files: false).total` — with a one-line comment that Home and the project page count the same thing.

- [ ] **Step 3: the views.** `_attachments.html.erb` — keep the panel head, actions and the scan-reload span as they are; add the folder path beside the heading: `<%= link_to @listing.path, files_path(folder: @listing.folder_id), class: "panel-path mono muted" if @listing.available? %>`. Replace the body from `<% if @attachments.empty? … %>` down with:

```erb
  <% backups, live = @listing.files.partition(&:backup?) %>
  <% grouped = live.group_by { |r| Maker::FileAttachment::ROLE_LABELS.key?(r.role) ? r.role : "other" } %>
  <% if live.empty? && backups.empty? && @linked_rows.empty? && @listing.repos.empty? && @missing_attachment_count.zero? %>
    <p class="muted">No files in this project yet.<% if @listing.available? %> Upload one, or drop files into <span class="mono"><%= @listing.path %></span>.<% end %></p>
  <% else %>
    <div data-controller="thumbs filemenu" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% Maker::FileAttachment::ROLE_LABELS.each do |role, label| %>
        <% group = grouped[role] %>
        <% next if group.blank? %>
        <%= render "attachment_group", key: role, label: label, rows: group, open: true %>
      <% end %>
      <% if backups.any? %>
        <%= render "attachment_group", key: "backups", label: "Backups", rows: backups, open: false %>
      <% end %>
      <% if @listing.repos.any? %>
        <%= render "repo_group", repos: @listing.repos %>
      <% end %>
      <% if @linked_rows.any? %>
        <%= render "attachment_group", key: "linked", label: "Linked from elsewhere", rows: @linked_rows, open: true %>
      <% end %>
    </div>
    <% if @listing.truncated? %>
      <p class="muted attachments-truncated">Showing <%= @listing.files.size %> of <%= @listing.total %> files.
        <%= link_to "Open the folder", files_path(folder: @listing.folder_id) %></p>
    <% end %>
    <% if @missing_attachment_count.positive? %> … (unchanged) … <% end %>
  <% end %>
```

Rewrite the partial's header comment to say what the panel now is (the folder, then Backups, then Repositories, then Linked; why the relation and the listing are two things; that `@page_nodes` is for the Linked rows and the photos). `_attachment_group.html.erb`: locals `key, label, rows, open`; each tile reads `row.node` (never `@page_nodes` — a folder row carries its node); the `.tile-meta` block renders ONLY for `row.linked?`, with Detach (as today, `row.attachment`) followed by a `button_to "Move into project", relocate_project_attachments_path(@project), params: { <the relocate param>: row.node_id }, class: "btn small tile-move"`. New `_repo_group.html.erb`: a `section.attachment-group` with `details open` and summary "Repositories (n)", each repo a `.attachment-tile.repo-tile` with `link_to files_path(folder: repo.node_id)` around a `span.thumb.generic-thumb` "REPO" and `span.grid-name` `repo.name`. `show.html.erb` stats: `<span><b><%= @listing.total %></b> <%= "file".pluralize(@listing.total) %></span>` and, when `@linked_rows.any?`, `<span><b><%= @linked_rows.size %></b> linked</span>`; update the ERB comment above it (it names `@attachments` as the source).

CSS (`pages/projects.css`, inside its `@layer pages`): `.attachments-panel .panel-path { font-size: 12px; margin-left: 8px; }`, `.repo-tile .generic-thumb { letter-spacing: .08em; }` — nothing else unless a test shows a need. Do not redefine a component selector (`test/css_hygiene_test.rb`).

- [ ] **Step 4: docs.** In `docs/invariants/project-intake.md`, add `app/services/maker/project_folder_listing.rb` to the header's path list and one bullet under Filing: **"THE PAGE LISTS THE FOLDER AND NEVER FILES OR MINTS IT.** `Maker::ProjectFolderListing` reads `folder_node_id`, answers liveness through the LibraryTree, and creates nothing; the one writer on `projects#show` is the pre-existing best-effort `ensure_library_folder!` for the upload control, which runs before the listing. A file inside the folder with no attachment row is still listed — the folder is the relation the panel shows; `maker_file_attachments` stays the relation detach, cover and addon origin read."

- [ ] **Step 5: run** (after Task A's commit exists): `bin/rails test test/integration/web/project_attachments_test.rb test/integration/web/project_page_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/home_test.rb test/integration/web/page_nodes_test.rb test/integration/web/project_tasks_test.rb test/integration/web/attach_auto_move_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb`, then `bin/ci style`. Then ONE system-test file: `bin/rails test test/system/projects_models_pages_test.rb` (its Detach test attaches a root node → the Linked tile; it must still pass).

- [ ] **Step 6: mutation-check** (stage first): (a) drop the `reject` so outside attachments render in role groups → the Linked test red; (b) count attachments in the stats instead of `@listing.total` → `project_page_test` red; (c) in the controller, build `@page_thumbs` per row (`rows.each { ThumbnailMap.for(user, [id]) }`) → the budget test red. Report each verbatim; restore.

- [ ] **Step 7: commit** with a pathspec:

```
The project page shows its folder: role groups from the filenames, Linked for files outside, one entry per repository
```

---

### Task C: close-out

- [ ] `bin/ci` green, identical run counts on the three legs; look at the page on the dev server (a project with folder files, a linked file and a repo); `/finish-branch`; `bin/log arc --from-pr <n>`.
