# Folder panels — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md` — batch by FILE, run
> independent tasks in PARALLEL, one capped full-depth review per task that re-runs its mutations.
> Task A lands FIRST (everyone depends on its interface); B and C then run in parallel; D after both.

**Spec:** `docs/superpowers/specs/2026-09-08-folder-panels-design.md` — its eight decisions bind.

**Goal:** each direct subfolder of a project folder is a panel in the chooser (hide, move) with its
own persisted view — tiles, list, or the Finder browser — on the maker's page and, read-only, on
the visitor's; a hidden folder leaves the visitor's page and the bundle.

**Architecture:** folder keys `folder:<node_id>` join the `panels` JSON layout beside the fixed
keys, plus a `views` map; the layout stays TOTAL against the project's CURRENT depth-one folders;
no migration; defaults reproduce today's page.

**Branch:** `claude/folder-panels`. Rules that bind: CLAUDE.md §14d (a verb more than one controller
performs gets a named service; `Public::` reads `pub` only — seam guard), §14e (query cost asserted
as constancy, never a literal), §15 (mutation-check every guard); `docs/invariants/design-system.md`
(component selectors in components.css, page sheets qualify); `docs/invariants/files-preview.md`
(the thumb wire contract; `files/_thumb` takes `url:`); the S4-1 quiet-panel rule; the S4-7 layout
rules in `app/services/maker/project_kind.rb`'s header.

## The shared interface (Task A owns it; B, C, D consume it and never redefine it)

```ruby
Maker::Project::VIEWS = %w[tiles list browser].freeze
Maker::ProjectFolderListing#panel_folders      # => [[node_id, repo?], …] for `tree` (depth one, disk order)
Maker::ProjectKind.folder_key(node_id)         # => "folder:#{node_id}"
Maker::ProjectKind.default_view(key, repo:)    # => "browser" if repo, else "tiles" (Files: "tiles")
Maker::ProjectKind.layout_for(kind:, overrides:, folders: [])
Layout = Data.define(:order, :hidden, :views, :repo_ids) do
  def visible = order - hidden
  def visible?(key) / hidden?(key)              # as today
  def folder?(key) = key.start_with?("folder:")
  def folder_id(key) = key.delete_prefix("folder:")
  def view_for(key)                            # views[key] || default_view(key, repo: repo_ids.include?(folder_id(key)))
end
Maker::Project#panel_layout(folders: [])       # calls layout_for with self[:panels]
Maker::Project#visible_panels(folders: [])
```

`folders: []` is the default so every caller that has no listing (Home, the chooser before its
listing, tests) keeps working; a caller that HAS a listing passes `listing.panel_folders`.

## File structure

| task | owns |
|---|---|
| A | `app/services/maker/project_kind.rb`, `app/models/maker/project.rb`, `app/services/maker/project_folder_listing.rb`, `test/services/maker/project_kind_test.rb`, `test/models/maker/project_test.rb` |
| B | `app/controllers/projects_controller.rb`, `app/controllers/projects/panels_controller.rb`, `app/views/projects/show.html.erb`, NEW `app/views/projects/_folder_panel.html.erb`, `app/views/projects/_attachments.html.erb`, `app/views/projects/_panel_chooser.html.erb`, `app/views/projects/_attachment_group.html.erb`, `app/views/projects/_file_tree_section.html.erb`, `app/views/projects/_generated_group.html.erb`, `app/views/projects/_file_rows.html.erb` (only if it reads `@view`), `app/assets/stylesheets/pages/projects.css`, `test/integration/web/project_page_test.rb`, `test/integration/web/project_panels_test.rb`, `test/integration/web/project_attachments_test.rb` |
| C | `app/services/maker/public_project.rb`, `app/views/public/projects/_page.html.erb`, NEW `app/views/public/projects/_folder_panel.html.erb`, `app/views/public/projects/_files.html.erb`, `app/assets/stylesheets/pages/public.css`, `test/integration/web/public_project_test.rb`, `test/integration/web/public_bundle_test.rb`, `test/integration/web/project_preview_test.rb` |
| D | `test/integration/web/page_query_budget_test.rb`, `test/integration/web/template_hygiene_test.rb`, `test/system/repo_browser_test.rb`, `test/system/shell_test.rb` |

---

### Task A: the layout knows the folders

**Steps**
1. Read `project_kind.rb` in full, `Maker::Project#panel_layout`/`#visible_panels`, `ProjectFolderListing#tree`/`Dir`, and `project_kind_test.rb`'s layout cases.
2. `ProjectFolderListing#panel_folders = tree.map { |d| [ d.node_id, d.repo? ] }` (one line, in memory).
3. `Maker::Project::VIEWS`; `#panel_layout(folders: [])`, `#visible_panels(folders: [])` threading `folders:`.
4. `ProjectKind`: `folder_key`, `default_view`, and `layout_for(kind:, overrides:, folders: [])`:
   - `folder_keys = folders.map { |id, _| folder_key(id) }`, `repo_ids = folders.select { _2 }.map(&:first)`, `vocabulary = PANELS + folder_keys`.
   - `known(list, vocabulary)` filters against the vocabulary (not `PANELS` alone).
   - `preset_order(preset, folder_keys)` = `(LEAD + first + PANELS) & PANELS` with `folder_keys` INSERTED immediately after `"attachments"` — so a folder the stored order does not name lands after Files in disk order.
   - `order = (known(over["order"]) + preset_order) & vocabulary`; `hidden = (over.key?("hidden") ? known(over["hidden"]) : preset[:hidden]) - ALWAYS`; `views = (over["views"] || {}).select { |k, v| vocabulary.include?(k.to_s) && VIEWS.include?(v.to_s) }.to_h { |k, v| [k.to_s, v.to_s] }`.
   - `Layout.new(order:, hidden:, views:, repo_ids:)`. Rewrite the header's layout paragraph (folder keys, totality against CURRENT folders, the after-Files placement, the views map).
5. Tests in `project_kind_test.rb`: folder keys appear after Files in disk order when unnamed; a stored order interleaving a folder above `build_log` is honoured; a stored folder key whose folder is gone is DROPPED (not rendered, not in order); a nested folder's key never appears (the caller passes depth-one only — pin the contract by passing depth-one and asserting the vocabulary); `hidden` may name a folder and may not name `attachments`; `views` filters unknown keys and unknown values; `view_for` answers `browser` for a repo folder with no stored view, `tiles` for a plain one and for `attachments`, and the stored view otherwise; `folders: []` reproduces today's layouts byte for byte (assert against the existing expectations). `project_test.rb`: `panel_layout(folders:)` threads.
6. Mutations (report each): (i) drop the vocabulary filter for folder keys → the stale-key test goes red; (ii) insert folder keys at the END instead of after Files → the placement test goes red; (iii) skip the `VIEWS` filter → the unknown-view test goes red; (iv) `default_view` ignoring `repo:` → the browser-default test goes red.
7. Commit (`-F`, pathspec). Run `bin/rails test test/services/maker/project_kind_test.rb test/models/maker/project_test.rb test/integration/web/project_page_test.rb test/integration/web/project_panels_test.rb test/integration/web/public_project_test.rb` — the last three must STILL PASS unchanged (folders default to `[]`).

---

### Task B: the maker's page

**Steps**
1. Read the spec §4, `projects/_attachments.html.erb` in full, `_file_tree_section`, `_attachment_group`, `_generated_group`, `_file_tile`, `_file_rows`, `_repo_browser`, `show.html.erb`'s panel loop, `_panel_chooser`, `ProjectsController#show` (lines ~90–345: `@panel_layout` at 96 is built BEFORE `@listing` at 194 — move it after, passing `folders: @listing.panel_folders`), `resolve_project_view` (retire it and `@view`; the `project_view` cookie is simply no longer read), `Projects::PanelsController`.
2. `ProjectsController#show`: `@panel_layout = @project.panel_layout(folders: @listing.panel_folders)` after the listing; `@panel_labels = Maker::Project::PANEL_LABELS.merge(@listing.tree.to_h { |d| [ Maker::ProjectKind.folder_key(d.node_id), d.name ] })`; delete `@view`/`resolve_project_view`/`PROJECT_VIEWS`/`DEFAULT_PROJECT_VIEW`. Every reader of `@panel_layout` that ran between lines 96 and 194 (`bom_shown` at 152) must move below it too — read them.
3. `Projects::PanelsController`: build `listing = Maker::ProjectFolderListing.new(current_user, @project, load_files: false)` in `set_project` and `layout = @project.panel_layout(folders: listing.panel_folders)`; `known` filters against `Maker::Project::PANELS + folder keys`; `moved`/`chosen` carry `stored.slice("hidden", "views")` / `"views"` forward; NEW branch `viewed` for `params[:view]` (`{ key => value }`, one pair): validates key ∈ vocabulary and value ∈ `VIEWS`, writes `stored.merge("views" => stored_views.merge(key => value))`, redirects to the panel's anchor (`project_path(@project, anchor: key)`); an invalid pair writes nothing and redirects with no notice change.
4. `show.html.erb` loop: `if @panel_layout.folder?(key)` → `render "projects/folder_panel", dir: @listing.tree.find { |d| d.node_id == @panel_layout.folder_id(key) }, key:, view: @panel_layout.view_for(key)` (the `find` is in memory over ≤ DIR_CAP dirs; a nil dir cannot happen because the layout was built from the same tree — assert with a comment, not a branch).
5. NEW `projects/_folder_panel.html.erb`: `section.panel.folder-panel` with `id: key`; head: name, count (`dir.subtree_file_count` minus generated for a plain folder — reuse `_file_tree_section`'s rule), path link `files_path(folder: dir.node_id)`, `repo` badge + Commits/History links for `dir.repo?`, and the view toggle (three `button_to`s to `project_panels_path(@project)`, `method: :patch`, `params: { view: { key => v } }`, `class: "toggle#{' active' if view == v}"`, inside `div.view-toggle[role=group]`); body: `tiles` → the dir's visible files as `_file_tile` in a `.files-grid`, then `render partial: "file_tree_section", collection: dir.children, as: :dir, locals: { view: }`; `list` → `_file_rows` for the files then the same nesting; `browser` → `render "repo_browser", dir:`. Empty (no visible files, no children) → quiet: heading + `<p class="muted">Empty folder.</p>`. Wrap the body in `data-controller="thumbs filemenu"` with `data-thumbs-url-value`.
6. `_attachments.html.erb`: remove the `file_tree_section` collection render and the page-wide toggle; add the panel's own toggle (`key: "attachments"`, same markup); thread `view:` to `attachment_group`/`generated_group` instead of `@view`. `_file_tree_section`, `_attachment_group`, `_generated_group` (and `_file_rows` if it reads `@view`) take a required `view:` local. Grep for every `@view` in `app/views/projects/` and leave none.
7. `_panel_chooser.html.erb`: label from `@panel_labels.fetch(key)` (no more `PANEL_LABELS.fetch(key)`); the `aria-label`s likewise; a folder row shows a small `folder` (or `repo`) badge. Nothing else changes: the same checkbox, hidden order field and move buttons.
8. CSS in `pages/projects.css` (qualified, per design-system): `.folder-panel .view-toggle`, the quiet state; reuse `.attachments-panel`'s tile grid classes rather than new component selectors.
9. Tests. `project_page_test.rb`: with a project folder holding `models/` (two .stl), `firmware/` (a working tree: a `.git` dir child), an empty `notes/` dir and a nested `models/old/`: three folder panels render after Files in disk order, each with its name and count; `firmware` renders `.repo-browser` (browser default), `models` renders `.files-grid` tiles, `notes` is quiet; `models/old` renders INSIDE the models panel as a nested section and is NOT a panel; a stored order putting `folder:<firmware>` above `build_log` is honoured; a hidden folder panel is absent; a stored view of `list` renders `table` rows in that panel only; the Files panel renders no subfolder section; junk in `views` renders the page. `project_panels_test.rb`: the chooser lists folder rows with their names and the same field names; `PATCH view[folder:<id>]=list` persists and the page renders it; an unknown view value or key writes nothing; Save keeps `views`; a move keeps `views`; Reset clears them. `project_attachments_test.rb`: whatever asserted the old page-wide toggle now asserts the per-panel toggles.
10. Mutations (report each): (i) render folder panels from `@listing.tree` directly instead of the layout's order → the interleaved-order test goes red; (ii) drop the `hidden` check for folder keys → the hidden-folder test goes red; (iii) the view toggle posts but `viewed` ignores `params[:view]` → the persistence test goes red; (iv) `_folder_panel` renders `browser` for every folder → the tiles test goes red; (v) put the `file_tree_section` collection back into `_attachments` → "Files renders no subfolder section" goes red.
11. `bin/rails test test/integration/web/project_page_test.rb test/integration/web/project_panels_test.rb test/integration/web/project_attachments_test.rb test/integration/web/template_hygiene_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb`, `bin/rubocop`; commit.

---

### Task C: the visitor's page and the bundle

**Steps**
1. Read the spec §5, `Maker::PublicProject` (`sections`, `visible_panels`, `bundle_files`, `thumbs`, `page_nodes`), `public/projects/_page.html.erb`'s loop and map, `public/projects/_files.html.erb`, `public_bundle_test.rb`, `public_project_test.rb`'s files-panel and hidden-panel cases, `project_preview_test.rb`.
2. `PublicProject`: `def visible_panels = layout.visible` where `layout = @layout ||= project.panel_layout(folders: listing.panel_folders)`; expose `layout` (for `folder?`, `folder_id`, `view_for`, `hidden`); `def hidden_folder_ids = layout.hidden.select { layout.folder?(_1) }.map { layout.folder_id(_1) }`; `def hidden_file_ids = @hidden_file_ids ||= listing.tree.select { hidden_folder_ids.include?(_1.node_id) }.flat_map(&:subtree_file_ids).to_set`; `bundle_files` rejects `hidden_file_ids`; `def loose_rows = listing.loose` and delete `sections` if `_files` was its only reader (grep first); `def folder_dir(key)` finds the Dir in `listing.tree`.
3. `_page.html.erb` loop: folder branch → `render "public/projects/folder_panel", pub:, key:, dir: pub.folder_dir(key), view: pub.layout.view_for(key)`. Keep every partial name fully qualified (the header explains why).
4. NEW `public/projects/_folder_panel.html.erb`: read-only; head with name and count; body `tiles` → `.files-grid` of `files/_thumb` cells with `url: pub.preview_url_for(id)` linking to `pub.view_url_for(id)`; `list` and `browser` → the same table `_files` renders today (name, download); nested folders as sub-headings with their rows (the same walk `sections` did, scoped to this dir). Empty → omitted (the visitor's page omits empty panels — S3-4's rule, stated in `_page`'s header).
5. `_files.html.erb`: root only — `pub.loose_rows`; heading count is the loose count.
6. CSS: qualify in `pages/public.css` only if a new selector is needed.
7. Tests. `public_project_test.rb`: folder panels render in the maker's order, hidden ones absent, a repo folder renders as a list for a visitor even with `views: { key => "browser" }`, the Files panel lists only root files, a `.heic`/photo-free folder with only a README… (keep to what the fixture has: `models/` holds `base.stl`; add a second folder to `seed_public_project!`? NO — that fixture is shared by five suites; build the extra folder in this test only with `make_dir!`/`make_file!` and a scan). `public_bundle_test.rb`: hiding a folder removes its files from the manifest and the page while `GET` on one of them still answers 200 (decision 2), `truncated` unchanged, the button count matches the manifest. `project_preview_test.rb`: the owner's preview renders the same folder panels.
8. Mutations (report each): (i) `bundle_files` without the hidden filter → the bundle test goes red; (ii) `_page` rendering folders from `listing.tree` instead of the layout → the order/hidden tests go red; (iii) the visitor's `browser` view rendering `.repo-browser` → the list-for-visitors test goes red (and the seam guard for any route helper the partial might reach for).
9. `bin/rails test test/integration/web/public_project_test.rb test/integration/web/public_bundle_test.rb test/integration/web/project_preview_test.rb test/integration/web/public_feed_test.rb test/architecture_invariants_test.rb`; `bin/rubocop`; commit.

---

### Task D: budgets, sweeps and the browser mount (after B and C)

**Steps**
1. `page_query_budget_test.rb`: a case for `projects#show` and one for `public projects#show` whose N is the number of depth-one folders (each with two files): constant in N (`assert_constant_queries`, never a literal).
2. `template_hygiene_test.rb`: the sweep's project already has `firmware` (a working tree) and `pcb` inside its folder, so two folder panels render; set `panels: { "views" => { "folder:d-pcb" => "list" } }` on `@project` in setup so the LIST branch of the private folder panel renders too (the default renders tiles on pcb and the browser on firmware — three branches, two folders, so one override); the public page gets its `_folder_panel` through the same project. Assert both new partials appear in `rendered` (the coverage assertion does this by construction — confirm by removing one render and watching it name the file).
3. `test/system/repo_browser_test.rb`: the browser now mounts INSIDE a folder panel — update the selectors; add: a PLAIN folder switched to `browser` through the toggle mounts the Miller columns and lists its files.
4. `test/system/shell_test.rb`: the phone sweep's project page now renders folder panels — add the panel to whatever fixture the sweep visits and assert `.folder-panel` present; the overflow check covers the head's toggle.
5. Mutations: (i) a per-folder query in `_folder_panel` (e.g. `current_user.nodes.find_by` per panel) → the budget goes red; (ii) remove the `_folder_panel` render from `_page` → the coverage assertion names the public partial.
6. Commit.

---

### Task E: close-out (orchestrator)

- `docs/user-stories.md`: 6.5 (panel choices) gains this evidence and stays `works`; 6.4/6.1 unchanged.
- `project_kind.rb`'s header is the one home for layout rules — A rewrote it; check it says folder keys, totality against current folders, after-Files placement, views.
- `TINKEREX_SYNC_DIR=… bin/ci`; three legs at identical run counts; push; `gh pr create`; `bin/log arc --from-pr N`. **No merge without the owner's go-ahead.**
