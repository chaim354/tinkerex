# Redesign slice 6 — the project hub and Recent — Implementation Plan

> **For agentic workers:** in this repo, execute with **`.claude/commands/execute-plan.md`** (CLAUDE.md
> §15: batched by file, parallel where independent, one capped quality review per task). It
> overrides the generic superpowers subagent loop. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
- **Home becomes Recent:** the files you changed lately, your active projects, and an attention row
  only when something needs it.
- **A project page becomes a hub:** a cover-and-name header, a ⋯ menu, a "Recently changed" row in its
  Files panel, tiles that open the Library, and panels that appear only when they hold something or
  you add one.

**Architecture:**
- **Recent** is `HomeController#index`, trimmed and relabelled. A new `upload_primary!` in
  `FolderDestination` lets a page with no folder make the top bar's Upload its one accent, while
  Upload still asks with the chooser.
- **The hub** changes in two layers:
  - Presentation: the head, the tiles' link target, a recent-files query on `Maker::ProjectFolderListing`.
  - Which panels render: computed in `ProjectsController#show` only. `Maker::ProjectKind.layout_for`,
    the stored `panels` JSON and the public page are untouched.
- **"+ Add panel"** opens an empty panel for one visit through `?add=<key>`. Nothing is persisted.

**Tech Stack:** Rails 8, Hotwire, Minitest request and system tests.

**Spec:** `docs/superpowers/specs/2026-10-08-structural-redesign-design.md` §4.2, §6, §7 (Recent) and §11
(slice 6). Slices 1–5 (#381–#385) are merged.

**Required reading for every task:**
- `docs/invariants/design-system.md`: rules 3, 8, 9, 11, 12 and 13 (13 names the hub's two accents).
- `docs/invariants/project-intake.md`, lines 59–78 and 268–275: the page lists the folder and never
  files or mints it; a missing folder is an answer.
- `docs/invariants/files-preview.md`, "The inspector".
- CLAUDE.md §14d and §14e (query budgets).

The rules most likely to bite:
- **The hub's panel layout is shared** with the public page, its feed, its bundle and its BOM CSV,
  through `Maker::PublicProject#layout`. Do not put "empty means absent" into `layout_for` or `Layout`.
- **`Projects::TasksController` turbo-replaces `#project-tasks`.** The element must be on the page for
  the first add to land.
- **A Recent or hub tile is not a selection item.** Neither page has a `selection` controller, so never
  call `with_selection` there.
- **Class names are a contract.** Restyle; never rename `.page-head`, `.head-actions`, `.project-hero`,
  `.attachment-tile`, `.panel--quiet` or any other pinned class.
- **No emoji in the interface.** Pictographs U+1F300–U+1FAFF; `✓` and `✕` are words.
- **Query budgets assert constancy in N. No `%>` inside an ERB comment. No sideways scroll at 375px.
  Every new template is rendered by a `template_hygiene_test` page.**
- **Mutation-check every guard.** Restore by re-applying your own snapshot. Never
  `git checkout --` a file holding uncommitted work. Then `rm -rf tmp/cache/bootsnap*`.

---

## Decisions this plan applies

From the spec:
- **Recent:** 16 recently changed files as tiles that open their folder with the file selected; 6
  active project tiles; attention only when non-empty; one empty state; Upload is Recent's accent.
- **The hub:** cover-and-name header with a ⋯ menu; Files and README always; on-demand panels with
  "+ Add panel"; tiles open `/files?folder=…&selected=…`.
- **The projects index:** cover tiles with name and status; archived projects behind a quiet link,
  which already exists.

Amendments found while planning, recorded in the spec by Task 4:

1. **There is no project "Print log" panel.** Prints belong to 3D models (`Maker::PrintRun belongs_to
   :model`), and slice 5's model strip carries them.
2. **The README stays inside the Files panel**, where it already renders on every project. The spec's
   "README panel, always" is met by that card. A new `readme` panel key would widen a vocabulary the
   public page, the layout editor's YAML and their tests share, for no visible gain.
3. **On-demand panels are decided in `ProjectsController#show`, not in the layout.**
   - An on-demand panel is Build log, Tasks, BOM, Wiring, Releases or Sheets.
   - It renders on the normal page only when it has a row, or when this request asks for it with
     `?add=<key>`.
   - The layout editor still shows every panel, and Customise page's Hide/Show is unchanged. A panel the
     maker hid stays hidden.
   - The public page already omits empty panels in each of its own partials, so it is untouched.
4. **"+ Add panel" opens a panel for one visit; it does not persist.** It is a `details.menu` in the
   hub's head listing the on-demand panels absent because they are empty, each a link to
   `project_path(@project, add: key, anchor: <panel id>)`.
   - The empty panel renders with its composer.
   - Once it holds a row, it stays for good.
   - If nothing is added, it is gone on the next visit. That is "on demand".
   - No new key in the `panels` JSON means nothing for `Maker::LayoutDocument`'s Save to carry or lose.
5. **The two-column grid stays at 900px, not 1100px.** Between 900 and 1099px the sidebar is the 56px
   icon rail, so the main column is about as wide there as it is at 1100px with the full sidebar. The
   breakpoint is also hard-coded in `masonry_controller.js` and shared with the public page.
6. **The Files panel gains a "Recently changed" row** above its existing groups: the 8 newest files
   anywhere under the project folder. It needs `Maker::ProjectFolderListing#recent_files`, one query.
   - Today the panel shows only the folder's root files, which intake usually leaves near-empty; each
     subfolder is its own panel.
   - The README card, the loose, generated and backups groups, and Linked stay.
   - The head's folder path becomes "Open folder →".
7. **Hub file tiles and list rows open the Library with the file selected**
   (`files_path(folder: node.parent_node_id, selected: node.node_id)`, via a new
   `FilesHelper#library_file_path`). This covers the Files panel, folder panels and the generated group.
   - Photos, Schematics and the hero keep their own targets.
   - The file menu's Open follows the tile's link, so it lands in the Library too, where the
     inspector's Open reaches the file page.
8. **The head**:
   - The cover (`_hero`) sits in the head on `--photo-stage`, with a PROJECT eyebrow above the name.
     The eyebrow goes *outside* the `h1`; a test pins the h1's exact text.
   - Badges, the description and tags are unchanged.
   - Actions are Edit, Customise page, "+ Add panel" when any panel is absent, and a ⋯ menu. The menu
     holds Publish settings (`#publish`), then Archive, Unarchive or Not a project.
   - The label stays "Customise page", which tests pin.
   - The `publish` panel stays at the foot, and its Save publishing stays the hub's second accent.
9. **Recent's details**:
   - Files are a wrapping grid of 160px tiles, not a 16-tile horizontal strip.
   - Active projects and Attention each render only when non-empty.
   - The Prints section goes (failed prints stay in Attention).
   - The page head is the heading alone; New ▾ in the top bar already has Project.
   - With no files, the Files section is the one empty state, "No files yet", and its sentence points
     at the top bar's Upload. No second upload control, which would duplicate
     `id="topbar_upload_file"` and the accent.
   - The sidebar and tab bar say "Recent" with a clock icon, under the same `[:home]` key and route.
10. **The 📦 project placeholder becomes `rail_icon(:projects)`**, on the hub's cards and the public
    explore card. The projects index card gains a status badge for active, paused and done (planning
    is never badged), beside the other badges in `.project-tile` and outside the link.
    `projects_flow_test` pins `.project-card .badge` at 0.

## Files

| file | change | task |
|---|---|---|
| `app/controllers/home_controller.rb`, `app/views/home/index.html.erb`, `app/assets/stylesheets/pages/home.css` | Recent | 1 |
| `app/controllers/concerns/folder_destination.rb`, `app/views/layouts/_topbar_upload.html.erb` | `upload_primary!` | 1 |
| `app/helpers/shell_helper.rb` (`ICON_PATHS[:recent]`, `tabbar_links`), `app/views/layouts/_rail.html.erb` | "Recent" | 1 |
| `test/integration/web/home_test.rb`, `test/system/home_test.rb`, `topbar_upload_test.rb` (both), `shell_layout_test.rb`, `test/system/shell_test.rb` (the Recent lines), `accent_spend_test.rb` ("/"), `page_query_budget_test.rb` (home#index), `template_hygiene_test.rb` (home) | updated | 1 |
| `app/services/maker/project_folder_listing.rb` | `#recent_files` | 2 |
| `app/helpers/files_helper.rb` | `#library_file_path` | 2 |
| `app/controllers/projects_controller.rb` (`#show`: `@recent_files`) | recent row | 2 |
| `app/views/projects/show.html.erb` (head), `_hero.html.erb`, `_attachments.html.erb`, `_file_tile.html.erb`, `_file_rows.html.erb`, `_card.html.erb`, `app/views/public/_project_card.html.erb` | head, tiles, recent row, card status and icon | 2 |
| `app/assets/stylesheets/pages/projects.css` | head and recent row | 2 |
| project tests (Task 2's table) | updated | 2 |
| `app/controllers/projects_controller.rb` (`#show`: `@absent_panels`, `@add_panel`) | on-demand panels | 3 |
| `app/views/projects/show.html.erb` (the panel loop and "+ Add panel") | on-demand panels | 3 |
| panel tests (Task 3's table) | updated | 3 |
| spec, `docs/invariants/{design-system,files-preview,project-intake}.md` | the record | 4 |

**Order:**
- **Task 1 (Recent) and Task 2 (hub presentation) run in parallel.** Their app files are disjoint. They
  share four test files in separate hunks (`shell_test`, `template_hygiene_test`,
  `page_query_budget_test`, `accent_spend_test`), and the orchestrator resolves any cherry-pick
  conflict.
- **Task 4 (docs) runs alongside them.**
- **Task 3 runs after Task 2.** It edits the same `#show` and `show.html.erb`.

Each implementer starts with `git reset --hard <the base commit on claude/redesign-slice-6>`, because a
fresh worktree starts on `main`.

---

### Task 1: Home becomes Recent

**Files:** Task 1's rows above.

- [ ] **Step 1: `upload_primary!` (`app/controllers/concerns/folder_destination.rb`)**

```ruby
  included do
    helper_method :folder_destination, :upload_primary?
  end

  private

  def folder_destination = @folder_destination

  # UPLOAD IS THIS SCREEN'S ONE ACCENT ACTION (design-system.md rule 13). A page that shows a folder
  # says so through use_folder_destination(primary: true); a page that shows NONE (Recent) says so here,
  # and its Upload still asks with the chooser — this changes Upload's weight, never its destination.
  # A Destination with a nil node_id would mean the library ROOT, not "ask", which is why this is its own
  # flag rather than a Destination built for a page with no folder.
  def upload_primary? = @upload_primary || @folder_destination&.primary || false
  def upload_primary! = (@upload_primary = true)
```

Update the concern's header sentence that says primary is "the Library and the project hub, nowhere
else" to add Recent.

In `app/views/layouts/_topbar_upload.html.erb`:
- The line becomes `<% btn_class = upload_primary? ? "upload-btn primary" : "upload-btn" %>`.
- Update its comments: the no-folder list becomes "Recent, Tools, Settings, Search", and the primary
  sentence adds Recent.
- Update the matching "Home, Tools, Settings and Search" comments in
  `app/javascript/controllers/upload_pick_controller.js`.

- [ ] **Step 2: The controller (`app/controllers/home_controller.rb`)**

- `RECENT_FILES = 16`.
- Rename `RECENT_PRINTS` → `ATTENTION_PRINTS` (it is now only the failed-prints limit) and delete
  the `@recent_prints` query.
- `index` ends with `upload_primary!`, after the reads, with a comment: "Recent shows no folder, so
  Upload asks with the chooser — but it is this page's one action (spec §4.2)."
- Rewrite the header comment so the page is Recent: recently changed files, active projects, and
  attention when non-empty. Keep the "every list is bounded" sentence.

- [ ] **Step 3: The view (`app/views/home/index.html.erb`)**

```erb
<% content_for :title, "Recent — Tinkerex" %>

<div class="page-head">
  <h1>Recent</h1>
</div>

<%# RECENTLY CHANGED (structural redesign §7): the newest live files, as tiles that open their folder in
    the Library with the file selected — a link, never a selection item (this page has no selection
    controller). A file at the library root has no parent, and Rails drops the nil `folder`, so its link
    is /files?selected=… (files/show.html.erb relies on the same). %>
<section class="panel home-section home-files">
  <div class="panel-head"><h2>Recently changed</h2><%= link_to "Library", files_path, class: "muted" %></div>
  <% if @recent_files.empty? %>
    <p class="empty home-empty">No files yet. Upload, in the top bar, puts your first one in the folder you choose.</p>
  <% else %>
    <div class="recent-grid" data-controller="thumbs filemenu" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% @recent_files.each do |node| %>
        <% ext_label = File.extname(node.name).delete(".").upcase.first(4) %>
        <% href = library_file_path(node) %>
        <% if Maker::Previews::Registry.for_filename(node.name).present? %>
          <%= link_to href, class: "grid-card file-cell",
                      data: thumb_cell_data(node.node_id, ext_label).merge(file_menu_data(node.node_id, node.name, @addon_origins[node.node_id])) do %>
            <%= render "files/thumb", thumb: @covers.thumb(node.node_id), ext_label: ext_label,
                       url: preview_src(@covers.thumb(node.node_id)), photo: Maker::FileAttachment.photo?(node.name) %>
            <span class="grid-name"><%= node.name %></span>
          <% end %>
        <% else %>
          <%= link_to href, class: "grid-card", data: file_menu_data(node.node_id, node.name, @addon_origins[node.node_id]) do %>
            <span class="thumb generic-thumb" aria-hidden="true"><%= ext_label.presence || "FILE" %></span>
            <span class="grid-name"><%= node.name %></span>
          <% end %>
        <% end %>
      <% end %>
    </div>
  <% end %>
</section>

<% if @recent_projects.any? %>
  <section class="panel home-section home-projects">
    <div class="panel-head"><h2>Active projects</h2><%= link_to "All projects", projects_path, class: "muted" %></div>
    <div class="recent-grid" data-controller="thumbs" data-thumbs-url-value="<%= thumbnails_files_path %>">
      <% @recent_projects.each do |project| %>
        <%= render "projects/card", project: project, thumb: @covers.thumb(project.cover_node_id) %>
      <% end %>
    </div>
  </section>
<% end %>

<% if @failed_prints.any? || @low_stock.any? %>
  <section class="panel home-section home-attention">
    … the existing "Needs attention" head and attention-list markup, unchanged, minus the
      `.empty` branch …
  </section>
<% end %>
```

`library_file_path` is Task 2's helper. If Task 1 lands first, add it to `app/helpers/files_helper.rb`
here exactly as Task 2 Step 1 writes it; whichever task lands second drops its own copy. Keep the
Attention markup byte-for-byte. Delete `home/_tile_row.html.erb` if nothing renders it any more, and
check `template_hygiene_test`'s coverage list.

`app/assets/stylesheets/pages/home.css`:
- Replace `.tile-row` and the `.print-*` rules with
  `.recent-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: var(--space-3); }`.
- Add `.recent-grid .thumb { aspect-ratio: 1 / 1; }`, unless `.grid-card .thumb` already sets it; check
  `pages/files.css`.
- Remove dead rules (`.print-list`, `.print-row`, `.print-outcome*`, `.tile-row*`) only after grepping
  app/ and test/.

- [ ] **Step 4: "Recent" in the shell (`app/helpers/shell_helper.rb`, `app/views/layouts/_rail.html.erb`)**

- Add `recent: "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2zM8 5v3l2 1.5"` to `ICON_PATHS`: a clock, drawn
  with the same stroke and no fill.
- In `tabbar_links`, the first entry becomes `[ "Recent", root_path, :recent, current == :home ]`. The
  third element is the icon key; the lit test keeps reading `[:home]`.
- In `_rail.html.erb`, the first link's `title:` becomes "Recent", its icon `rail_icon(:recent)`, and
  its label `<span class="rail-label">Recent</span>`.
- `sidebar_aria([ :home ])`, `SECTIONS["home"]` and the brand's `aria-label` are unchanged.
- Leave the `:home` icon entry if anything else draws it; otherwise delete it.

- [ ] **Step 5: Tests**

| test | change |
|---|---|
| `test/integration/web/home_test.rb` | `h1` "Recent". The empty-account test asserts `.home-files .home-empty`, `.home-projects` count 0 and `.home-attention` count 0. The bounded-lists test seeds 17 files and asserts `RECENT_FILES` (16) tiles. Delete the prints test, but keep its failed-print attention assertions in a renamed test. **New:** a tile's href is `files_path(folder: parent, selected: node)`, and a root file's is `files_path(selected: node)`. |
| `test/system/home_test.rb` | Replace the horizontal-overflow test: at desktop the grid wraps (one tile's top is lower than the first's), and at 375 there is no sideways scroll against `document.documentElement.clientWidth`. Seed 17 files. |
| `test/integration/web/topbar_upload_test.rb` | **New:** `get root_path` renders `.topbar-upload[data-controller='upload-pick'] label.upload-btn.primary[data-action=?]` with `"click->upload-pick#pick"`. Keep the settings test (quiet chooser), which guards the flag leaking to every page without a folder. |
| `test/system/topbar_upload_test.rb` | Rename "on Home…" → "on Recent…". No logic change. |
| `test/integration/web/shell_layout_test.rb` | `root_path => "Recent"` (L24); the first rail link is "Recent" (L54–63); the tab bar is `%w[Recent Library Projects Tools]` (L243–247) |
| `test/system/shell_test.rb` | L359–369 seed for the grid instead of the tile-row overflow; L389–390 `main h1` "Recent" |
| `test/system/accent_spend_test.rb` | `"/" => [ "Upload" ]`, replacing the "quiet until slice 6" comment. Re-measure and update the mutation notes. |
| `test/integration/web/page_query_budget_test.rb` "home#index…" | seed at least 17 files per size so the 16-file limit is straddled, using a local count in that test, never the global constants; rename to "…projects, files, failed prints or low stock" |
| `test/integration/web/template_hygiene_test.rb` | the home fixture still renders Attention (the M3 bolt, Lamp cord seeds); if `_tile_row` is deleted, nothing to add |

- [ ] **Step 6: Run and mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/home_test.rb test/integration/web/topbar_upload_test.rb test/integration/web/shell_layout_test.rb test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb`.
Then run the s3 leg on `home_test.rb` and `topbar_upload_test.rb`, using
`env LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=ci-not-a-real-bucket LIBRARY_S3_REGION=us-east-1 LIBRARY_S3_ACCESS_KEY_ID=ci LIBRARY_S3_SECRET_ACCESS_KEY=ci LIBRARY_S3_PREFIX=library`.
Then the system tests:
`bin/rails test test/system/home_test.rb test/system/topbar_upload_test.rb test/system/accent_spend_test.rb test/system/shell_test.rb`.

| mutation | must redden |
|---|---|
| `upload_primary!` deleted from `HomeController#index` | the new Recent primary test; accent_spend's "/" row |
| `upload_primary?` returns true for every page (`@upload_primary \|\| true`) | the settings "asks with the chooser, quietly" test |
| a Recent tile links to `file_path(node.node_id)` | the new tile-href test |
| the `if @failed_prints.any? \|\| @low_stock.any?` guard removed (Attention always renders) | the empty-account test's `.home-attention` count 0 |
| `RECENT_FILES` back to 8 | the bounded-lists test |

- [ ] **Step 7: Commit.** Subject: "Home is Recent: the files you changed, your active projects, and
  attention only when it is needed".

---

### Task 2: The hub's head, its tiles, and the Files panel's recent row

**Files:** Task 2's rows above.

- [ ] **Step 1: Two small read helpers**

`app/helpers/files_helper.rb`:

```ruby
  # WHERE A FILE OPENS FROM A PAGE WITHOUT ITS OWN INSPECTOR (structural redesign §6 and §7): its folder
  # in the Library with the file selected, so the inspector answers "what is this" and its Open reaches
  # the file page. Recent and the project hub link here; the Library's own tiles keep file_path, which
  # selection intercepts. A file at the root has no parent, and Rails drops the nil `folder`.
  def library_file_path(node) = files_path(folder: node.parent_node_id, selected: node.node_id)
```

`app/services/maker/project_folder_listing.rb`, a public method:

```ruby
    # The newest files anywhere under the project folder (structural redesign §6, the Files panel's
    # "Recently changed" row). ONE query over the same subtree `files_in` already scopes, ordered by
    # updated_at; [] when the folder is unavailable. Not part of the name-ordered, capped listing: a
    # folder with 301 files has its newest files somewhere past the cap.
    def recent_files(limit = 8)
      return [] if @dir_ids.blank?

      files_in(@dir_ids).order(updated_at: :desc, node_id: :asc).limit(limit).to_a
    end
```

Use whatever ivar or reader `initialize` keeps the subtree's dir ids in. If it keeps only a local,
store it as an ivar in `initialize`. `files_in` must already apply the visible-entries rule the listing
uses, so check it; if it doesn't, apply the same scope the listing applies.

- [ ] **Step 2: The controller (`ProjectsController#show`)**

After `@listing = …` and the `use_folder_destination` line:

```ruby
    # THE FILES PANEL'S "RECENTLY CHANGED" ROW (slice 6): the 8 newest files under the folder, one query.
    @recent_files = @listing.available? ? @listing.recent_files : []
```

Add their ids to the one `@page_thumbs` ThumbnailMap call and to `addon_origins_for`'s ids, so each
stays one call. Find both lines (~397 and ~411) and union `@recent_files.map(&:node_id)` into their id
lists.

- [ ] **Step 3: The Files panel (`app/views/projects/_attachments.html.erb`)**

- In the head, the `link_to @listing.path, files_path(folder: @listing.folder_id), class: "panel-path mono muted"`
  becomes `link_to "Open folder →", files_path(folder: @listing.folder_id), class: "panel-path muted"`.
  Keep its `if @listing.available?`, and put the path in the link's `title:`.
- Right after the README/repo card block and before the Loose group:

```erb
<% if @recent_files.any? %>
  <%# RECENTLY CHANGED (structural redesign §6): the newest files anywhere under the folder — intake
      files most things into subfolders, so the folder's root (the Loose group below) is often near-empty.
      Each tile opens the Library with the file selected (library_file_path). %>
  <div class="recent-files">
    <h3 class="recent-files-head">Recently changed</h3>
    <div class="attachment-tiles">
      <% @recent_files.each do |node| %>
        <%= render "file_tile", row: @listing.row_for(node.node_id) || node %>
      <% end %>
    </div>
  </div>
<% end %>
```

Read `_file_tile.html.erb` first. It takes a `row` (an attachment-group row with `node_id`, `linked?`,
`attachment`). Build what it needs for a plain listed node the way the Loose group does, without
inventing a second tile partial. If `row_for` misses a node (past the listing's cap), use the same
minimal row shape the Loose group builds. Use the tile container class the Loose group uses
(`attachment-tiles` or its real name).

- [ ] **Step 4: Tiles open the Library**

- `app/views/projects/_file_tile.html.erb`: `link_to file_path(row.node_id), …` →
  `link_to library_file_path(node), …`, where `node` is the tile's node already in hand there.
- `app/views/projects/_file_rows.html.erb` L41: the same.

These two partials are shared by the Files panel, folder panels, the generated group and the attachment
groups, which is the point: one change. Photos, Schematics and `_hero` keep `file_path`. Update any
comment in those two partials that says the tile opens the file page.

- [ ] **Step 5: The head (`app/views/projects/show.html.erb` L11–76, `_hero.html.erb`)**

- Move `<%= render "hero" %>` (today below the stats line, ~L104) into the head, as the first child of
  `.page-title`. `.page-head` must keep exactly two children, `.page-title` and `.head-actions`, per
  template hygiene.
- Inside `.page-title`, after the hero, add `<span class="eyebrow">Project</span>` *before* the `h1`.
- Badges, the public link and the publish link stay where they are.
- `.head-actions` keeps "Edit" and "Customise page" as `btn small`. Then (Task 3 inserts "+ Add panel"
  here) a ⋯ menu:

```erb
    <details class="menu project-menu" data-controller="menu">
      <summary class="btn small icon" aria-label="More actions">⋯</summary>
      <div class="menu-list">
        <%= link_to "Publish settings", "#publish", class: "menu-item" %>
        <%# Archive / Unarchive / Not a project move here VERBATIM — same button_to, same confirms; only
            the class becomes menu-item (with `danger` kept on Archive). %>
        …
      </div>
    </details>
```

Move the three `button_to` forms in unchanged except `class: "btn small …"` → `class: "menu-item"`
(Archive keeps `danger`: `class: "menu-item danger"`).

`_hero.html.erb` keeps its markup and classes. Put the cover on `--photo-stage` in CSS (Step 6).

- [ ] **Step 6: Styles (`app/assets/stylesheets/pages/projects.css`, tokens only)**

```css
  /* THE HUB'S HEAD (structural redesign §6): the cover on the photo stage, the PROJECT eyebrow, then the
     name. The hero partial is unchanged; it is placed and sized here. */
  .project-head .page-title { display: grid; grid-template-columns: auto minmax(0, 1fr); column-gap: var(--space-3); align-items: start; }
  .project-head .project-hero { grid-row: 1 / span 3; width: 96px; height: 96px; margin: 0; background: var(--photo-stage); border-radius: var(--radius-control); overflow: hidden; }
  .project-head .project-hero-img { width: 100%; height: 100%; object-fit: cover; background: var(--photo-stage); }
  .project-head .project-hero-name { display: none; }
  .project-head .eyebrow { display: block; font: 600 11px/16px var(--font-ui); letter-spacing: .08em; text-transform: uppercase; color: var(--fg-muted); }
  .recent-files { margin: var(--space-3) 0; }
  .recent-files-head { margin: 0 0 var(--space-2); font: 600 12px/16px var(--font-ui); color: var(--fg-muted); text-transform: uppercase; letter-spacing: .06em; }
  @media (max-width: 719px) { .project-head .project-hero { width: 64px; height: 64px; } }
```

Read `_hero.html.erb` and the existing `.project-hero*` rules before writing these, and qualify rather
than redeclare. If the hero renders a poll cell (not an image), make the cell fill the 96px stage. Check
the page at 375px; `shell_test` asserts `.project-hero img` there.

- [ ] **Step 7: Cards — status and icon**

- `app/views/projects/_card.html.erb` L14 and `app/views/public/_project_card.html.erb` L35: replace 📦
  with `<%= rail_icon(:projects) %>`, inside the same `aria-hidden` span.
- Add a CSS rule beside `.project-thumb-empty` sizing the icon (copy
  `pages/models.css`'s `.model-card .project-thumb-empty .rail-icon`): `.project-card .project-thumb-empty .rail-icon`.
- `projects/_card.html.erb`, beside the existing badges in `.project-tile` and outside the link, render
  a status badge for `%w[active paused done]`:
  `<span class="badge status-<%= project.status %>"><%= project.status.capitalize %></span>`.
  The components `.badge.status-*` already exist.
- Fix `ProjectsController`'s stale L30–32 comment, which says the web never shows statuses other than
  archived.

- [ ] **Step 8: Tests**

| test | change |
|---|---|
| `test/integration/web/project_attachments_test.rb` L121–132 | `.attachment-tile a[href=?]`, `library_file_path(node)` (i.e. `files_path(folder: …, selected: "n-1")`) |
| `test/integration/web/projects_flow_test.rb` L52–58 / L423–441 / L488–511 | Archive, Unarchive and Not a project are `.head-actions details.project-menu form[action=?] button.menu-item`; the confirm texts are unchanged |
| `test/integration/web/project_page_test.rb` L52–58 | the same move for Archive |
| `test/integration/web/publishing_test.rb` L54 | `.page-head a[href='#publish']` still matches: the existing publish link plus the menu item. Confirm the count, or assert the menu item |
| new in `project_page_test.rb` | "the head carries the cover, the PROJECT eyebrow outside the h1, and a ⋯ menu"; "the Files panel shows the 8 newest files under the folder, newest first, each opening the Library" (seed 9 in nested folders with distinct `updated_at` values; creation order must disagree with recency) |
| new in `projects_flow_test.rb` (index) | an active project's tile shows `.project-tile .badge.status-active`, a planning one shows none, and `.project-card .badge` stays 0 |
| `test/integration/web/models_pages_test.rb`-style guard | the projects index and the public explore card contain no 📦 (`assert_no_match "\u{1F4E6}"`) and render `.project-thumb-empty svg.rail-icon` |
| `test/integration/web/page_query_budget_test.rb` projects#show | still constant (the recent row is one query); confirm |
| `test/system/shell_test.rb` | the hub at 375 still has no sideways scroll; `.project-hero img` is still found |

- [ ] **Step 9: Run and mutation-check**

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/ test/services/maker/project_folder_listing_test.rb`,
then the s3 leg on the project test files you touched, then
`bin/rails test test/system/shell_test.rb test/system/accent_spend_test.rb test/system/page_editor_test.rb`.

| mutation | must redden |
|---|---|
| `recent_files` orders by `:name` | the new "8 newest … newest first" test |
| `_file_tile` back to `file_path` | the attachments href test |
| the eyebrow moved inside the `h1` | `projects_flow_test`'s exact `h1` text |
| the status badge rendered inside `.project-card` | `.project-card .badge` count 0 |
| 📦 restored in `projects/_card` | the no-emoji guard |

- [ ] **Step 10: Commit.** Subject: "A project page is a hub: cover and name in its head, a ⋯ menu, a
  recent row, and tiles that open the Library".

---

### Task 3: Panels that appear when they have something, and "+ Add panel"

**Base:** Task 2's commit.

- [ ] **Step 1: Failing tests (`test/integration/web/project_page_test.rb`)**

Replace the "quiet panels" tests (L173–186, L188–195, L319–328) with:

```ruby
    # ON-DEMAND PANELS (structural redesign §6, slice 6): an empty Build log, Tasks, BOM, Wiring, Releases
    # or Sheets is ABSENT from the normal page — not quiet — and "+ Add panel" opens one for this visit.
    test "a fresh project shows Files and Publish, and offers the empty panels to add" do
      get project_path(@fresh)
      %w[build-log tasks bom wiring releases sheets].each do |name|
        assert_select "section.#{name}-panel", count: 0
      end
      assert_select "section.attachments-panel"
      assert_select "section.publish-panel#publish"
      assert_select ".head-actions details.add-panel .menu-list a.menu-item[href=?]",
                    project_path(@fresh, add: "tasks", anchor: "project-tasks"), text: "Tasks"
    end

    test "?add= opens one empty panel, quiet, with its composer, and nothing else" do
      get project_path(@fresh, add: "tasks")
      assert_select "section.tasks-panel.panel--quiet form.task-form"
      assert_select "#project-tasks", count: 1
      assert_select "section.build-log-panel", count: 0
    end

    test "a panel with a row stays without ?add=, and drops out of the add menu" do
      @fresh.tasks.create!(user: @user, title: "Cut the base")
      get project_path(@fresh)
      assert_select "section.tasks-panel"
      assert_select ".add-panel a.menu-item", text: "Tasks", count: 0
    end

    test "a panel the maker hid stays hidden even with ?add=, and is not offered" do
      @fresh.update!(panels: { "hidden" => %w[tasks] })
      get project_path(@fresh, add: "tasks")
      assert_select "section.tasks-panel", count: 0
      assert_select ".add-panel a.menu-item", text: "Tasks", count: 0
    end

    test "?add= with an unknown key is ignored" do
      get project_path(@fresh, add: "publish")
      assert_response :success
      get "#{project_path(@fresh)}?add[]=tasks"
      assert_response :success
      assert_select "section.tasks-panel", count: 0
    end
```

Use the file's own fixture names: a fresh project with no rows, and `@user`. The anchor for each key is
that panel's existing element id. Read each partial to collect them: Tasks is `project-tasks`; the
others are their `section`'s `id`. A partial with no id gets one in this task.

Run: `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/project_page_test.rb`.
Expected: the new tests fail; the empty panels render quiet.

- [ ] **Step 2: The controller (`ProjectsController#show`)**

Add a constant and a private predicate to `ProjectsController`:

```ruby
  # ON-DEMAND PANELS (structural redesign §6, slice 6): absent from the normal page while empty, unless
  # this request opens one with ?add=<key> ("+ Add panel").
  ON_DEMAND = %w[build_log tasks bom wiring releases sheets].freeze

  # Each answer reads data #show already loaded. BOM, Wiring and Releases are loaded only when visible,
  # and only a visible panel is ever asked about, so nil never reaches here for a panel that matters —
  # `.present?` tolerates it anyway.
  def panel_has_rows?(key)
    case key
    when "build_log" then @entries.any?
    when "tasks" then @tasks.any?
    when "sheets" then @sheets.any?
    when "bom" then @bom_lines.present?
    when "wiring" then @connections.present?
    when "releases" then @releases.present?
    end
  end
```

Near the end of `#show`, after every panel's data is loaded and before
`render … if @panel_key`:

```ruby
    # Decided HERE, never in Maker::ProjectKind.layout_for: the layout is shared with the public page,
    # its feed, its bundle and its BOM CSV (Maker::PublicProject#layout), which already omit empty panels
    # in their own partials. A panel the maker HID stays hidden (`visible?`), and the editor (@editing)
    # still shows every panel, so none of this runs there.
    unless @editing
      requested = params[:add] if params[:add].is_a?(String)
      @add_panel = requested if ON_DEMAND.include?(requested) && @panel_layout.visible?(requested)
      @absent_panels = ON_DEMAND.select do |key|
        @panel_layout.visible?(key) && key != @add_panel && !panel_has_rows?(key)
      end
    end
```

Read the real ivar names first. `@bom_lines`, `@releases` and `@connections` are the plan's guesses
from the explorer's map.

- [ ] **Step 3: The view (`app/views/projects/show.html.erb`)**

The normal-mode loop renders `groups: @panel_layout.groups`. It becomes
`groups: @panel_layout.groups(@panel_layout.visible - Array(@absent_panels))`. Read `Layout#groups`'s
signature first; it takes `keys = visible`.

In `.head-actions`, between "Customise page" and the ⋯ menu:

```erb
    <% if Array(@absent_panels).any? %>
      <%# "+ ADD PANEL" (slice 6): the on-demand panels absent because they are empty. Each opens its panel
          for this visit (?add=), with its composer; it stays once it holds a row. %>
      <details class="menu add-panel" data-controller="menu">
        <summary class="btn small">+ Add panel</summary>
        <div class="menu-list">
          <% @absent_panels.each do |key| %>
            <%= link_to panel_title(@panel_layout, key), project_path(@project, add: key, anchor: PANEL_ANCHORS.fetch(key)),
                        class: "menu-item" %>
          <% end %>
        </div>
      </details>
    <% end %>
```

`PANEL_ANCHORS` is a small frozen hash in `ProjectsHelper`, mapping key → the panel element's id from
Step 1. Note `.head-actions` must not push `.page-head` past two children; this is inside
`.head-actions`.

- [ ] **Step 4: Tests that assumed empty panels render**

| test | change |
|---|---|
| `project_tasks_test.rb` L34–58, `project_build_log_test.rb` L107–114, `project_wiring_test.rb` L57–80, `project_releases_test.rb` L79–100, `project_sheets_test.rb` L240–248 | visit `project_path(project, add: "<key>")` where they scrape a composer from an empty project |
| `project_tabs_test.rb` L28–55 | a tab holding only empty panels: either seed a row in each, or assert the tab drops out, whichever the tab markup does (`_panel_groups` renders only panes whose bodies render). Decide by reading it, and say which in the commit. |
| `project_layout_editor_test.rb` L117–138 | the editor page (`@editing`) still renders every slot, so assert on `edit_layout_project_path`; if the test is about the normal page, seed a task |
| `test/system/projects_models_pages_test.rb` L47–60 | visit with `add: "build_log"` before "Add entry" |
| `test/system/page_tabs_test.rb`, `page_editor_test.rb` | run them; seed rows where a test needs a populated panel on the normal page |
| `page_query_budget_test.rb` L304–346 (hiding lowers cost) | unchanged; confirm |

- [ ] **Step 5: Run and mutation-check**

Run `LIBRARY_PATH=$(mktemp -d) bin/rails test test/integration/web/` and the s3 leg on the project test
files. Then run `bin/rails test test/system/` for the project and page system tests (`page_editor`,
`page_tabs`, `page_blocks`, `projects_models_pages`, `shell_test`, `accent_spend`).

| mutation | must redden |
|---|---|
| `@absent_panels` not subtracted in the loop | "a fresh project shows Files and Publish…" |
| `&& @panel_layout.visible?(requested)` dropped | "a panel the maker hid stays hidden even with ?add=" |
| `params[:add].is_a?(String)` dropped | the `add[]=` arm (it must not 500) |
| `!panel_has_rows?(key)` → `true` | "a panel with a row stays without ?add=" |
| the computation moved into `Maker::ProjectKind.layout_for` (empty → hidden) | a public page test with an empty-but-visible panel; if none exists, add one asserting the public page is unchanged |

- [ ] **Step 6: Commit.** Subject: "A project's panels appear when they hold something, and + Add panel
  opens one".

---

### Task 4: Record the slice (docs only; runs alongside Tasks 1 and 2)

- **Spec:** append "**Amended 2026-10-09 (slice 6's plan):**" after slice 5's, summarising the ten
  amendments in prose. Update §6 (no Print log; README inside Files; on-demand decided in `#show`; "+ Add
  panel" is per-visit; 900px; the recent row; tiles; the head) and §7's Recent bullets the same way.
- **`docs/invariants/design-system.md`:**
  - Rule 13: Recent's accent is Upload, through `upload_primary!`, which never changes a destination.
  - Rule 8: the first place is "Recent" (clock icon, `[:home]`).
- **`docs/invariants/files-preview.md` "The inspector":** Recent and the hub have no inspector. Their
  tiles open the Library with the file selected (`library_file_path`) and are never selection items.
  The Library's own tiles keep `file_path`.
- **`docs/invariants/project-intake.md`**, near L268–275 ("the page lists the folder"): the Files
  panel's Recently changed row reads `ProjectFolderListing#recent_files`. It is one query, it never
  mints, and it is not part of the capped, name-ordered listing.
- **A new rule** in the most fitting invariants doc (`design-system.md` if no project-page section
  exists): on-demand panels are decided in `ProjectsController#show`, never in `layout_for`, because the
  layout is shared with the public page, its feed, its bundle and its BOM CSV. Also: "+ Add panel" is
  per-visit (`?add=`) and persists nothing.
- Commit: "Slice 6's record: the project hub and Recent". Do not add lines to CLAUDE.md.

### Task 5: Close out

- [ ] Bare `bin/ci`: all gates green, with identical run counts on the three backend legs.
- [ ] `/finish-branch`: a PR with what changed, the amendments, verification and not-verified (no deploy;
  phones headless only; the real library has 9 mostly empty auto-created projects, which is the case
  on-demand panels are for). Then `bin/log arc --from-pr <n>`. **Merging needs the user's go-ahead.**
