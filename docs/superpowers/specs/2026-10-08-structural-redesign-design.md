# Structural redesign: a library-first front end

Date: 2026-10-08. Branch: `claude/structural-redesign-spec`. Status: **approved in brainstorming,
section by section; awaiting the user's review of this document**, then an implementation plan.

The visual half of this redesign is a published design system, the **Tinkerex Design System**
artifact (`https://claude.ai/artifact/GUSYE99yUak6g9TzwsXGVR`, private to its owner until shared).
It defines the tokens, type scale, components and the class-name and token-name contracts this spec
builds on. This document is the structural half: which pages exist, the frame that holds them,
and how a maker moves between them.

## 1. Why

- **The front end is organised around features the owner does not use.** Measured on the share
  deployment on 2026-09-07: 3,232 files, 9 projects (8 auto-created, all `planning`), 10 tasks,
  3 build-log entries, and **zero** print runs, inventory items, BOMs, suppliers, locations, sheets
  or releases. Previews and the box generator carry all the use. About a fifth of the files sit
  outside `Projects/`.
- **The navigation gives every built feature equal weight.** The rail lists Home, Files, Models,
  Projects, Inventory, Tools and Trash as peers, so the library (where the use is) competes with
  four sections that are mostly empty.
- **There are two catalogs for one library.** Models is a second gallery over the same folders
  Files shows, with its own pages and shelves.
- **A global "current project" decides where files land, wherever you are.** It has needed three
  rounds of fixes (session-only storage, the rail card's promise, the remember toggle) because the
  destination is not where the maker is looking.
- **Opening a file loses your place.** Every file opens a separate page, so browsing a folder of
  previews is click, back, click, back.

The UI cohesion audit (2026-09-10) concluded the *visual* system was sound and the pages spent it
badly. The user has since asked for a complete redesign, visual and structural. The visual half is
the artifact; this is the rest.

## 2. Decisions (settled in brainstorming, 2026-10-08 — do not relitigate without new information)

1. **The library is the centre.** One visual library of every file is the main surface. Projects
   are folders with extras; tools act on files.
2. **Extras are tucked in, on demand.** Tasks, build log, BOM, sheets, releases, print log and
   inventory stay built but appear only once used or added. Nothing is deleted; the navigation
   shrinks to what is used.
3. **Models becomes a lens on the library**, not a separate section. A model folder is a library
   folder with a richer header; "3D models" is a saved view in the sidebar.
4. **A file opens in an inspector first, a workspace second.** One click selects and shows a
   right-hand inspector; Open (or double-click) goes to a full-width workspace for deep work.
5. **Tools live in both places.** The `/tools` gallery stays a real section, and generators also
   start from the library's New menu and reopen from their output file.
6. **New files land in the folder you're in.** The global current project is retired.
7. **A project keeps a separate hub page** (option B of two mocked), with the folder one click
   away. Its extra panels follow decision 2: shown only once used.
8. **The frame is a places sidebar** (Recent, Library, projects, pinned places, then Tools, Trash
   and Settings), not an icon rail with sections and not a top bar alone.

### Still open — confirm before slice 1

The design system proposes three visual choices the user has not yet confirmed. Each is
independent of the structure and can flip without changing anything below.

- **Light ("Paper") as the default theme**, dark ("Graphite") one click away.
- **Safety orange** (`#c2410c` light, `#ff7a33` dark) replacing today's amber as the accent.
- **Tile size:** square stages at least 160px wide fit 4 per row where today fits 5. The
  alternative is a 140px minimum.

## 3. The map

| Today | Redesign | URL |
|---|---|---|
| Home (current-project card, continue, attention) | **Recent**, the landing page: recently changed files, active projects, an attention row when non-empty | `/` |
| Files | **Library**: folder grid or list, with the inspector | `/files?folder=…&selected=…` |
| File page | **Workspace**: the full-width deep-work page | `/files/:id` (unchanged) |
| Models index, model pages, shelves | **Folded into the Library**: the model strip, the "3D models" place, shelves as a Settings rule | `/models` → 301 to `/files/models`; `/models/:id` → 302 to its folder when that folder shows its strip; `/models/shelves` → 301 to `/settings/shelves` |
| Projects index | The sidebar's Projects list, plus an index page with archived projects | `/projects` (unchanged) |
| Project page | **Project hub** (§6) | `/projects/:id` (unchanged) |
| Inventory section | **Hidden until used** (§7) | `/inventory*` (unchanged) |
| Tools | **Tools** gallery, plus New ▸ and Reopen | `/tools*` (unchanged) |
| Trash, Settings, Search, tag pages | Unchanged in place, restyled | unchanged |
| Public pages | **Restyled only**; visitors never get the maker's shell | `/u/…` (unchanged) |
| Current project (rail card, top-bar chip, preference) | **Removed** (§8) | `PATCH /current_project` removed |

Every URL a bookmark, the desktop client or a published page holds keeps working.

## 4. The shell

### 4.1 Places sidebar (replaces `aside.rail`)

216px (`rail-width`), on `bg`, with a hairline right edge. Top to bottom:

1. **Brand**: the CSS mark and "Tinkerex", linking to `/`.
2. **Recent** and **Library**.
3. **PROJECTS**: active (non-archived) projects ordered by most recent activity, up to 8, then
   "All projects →" to `/projects`. A project link opens its hub.
4. **PLACES**: pinned folders and saved views, in the order pinned. It ships with **3D models**
   (§5.4). A folder is pinned and unpinned from its ⋯ menu ("Pin to sidebar"). Pins are stored by
   `node_id`, so a renamed or moved folder keeps its pin (a move keeps its `node_id`, §14b). A pin
   whose node is tombstoned is hidden, not deleted, so restoring the folder restores the pin.
5. **Foot**: Tools, Inventory (only once the user has inventory items), Trash, Settings, and one
   account row (the email with a menu holding the theme switch and Sign out).

The current page carries `aria-current="page"` and the ink marker. The marker never uses the
accent. `ShellHelper::SECTIONS` becomes the sidebar's highlight map: it matches Recent, Library
(including the workspace and repo pages), a specific project hub, a pinned place when the current
folder is that place or beneath it, Tools, Inventory, Trash and Settings.

**Collapsed** (the `rail` cookie, rendered server-side, as today): 56px, icons only for Recent,
Library, Projects, Tools and Trash. The project and place lists hide; the Projects icon opens the
index.

### 4.2 Top bar

48px, on `bg`: the breadcrumb (`content_for :crumbs`, as today), the search field (⌘K; the flat
whole-library search `FilesController#index` already serves), **New ▾** and **Upload**.

- **New ▾**: Folder, Text file, Project, then one entry per available generator ("Box…",
  "OpenSCAD…"), then Inventory item. Each creates in the current folder (§8).
- **Upload**: on the Library, Recent and project hubs it is the screen's one `.btn.primary`. It
  uploads to the current folder and its caption names the destination ("Saves to
  Projects/shop-stool"). On a page with no folder (Recent, Tools, Settings) it opens the existing
  file chooser to pick one first. On a page with its own primary (a form's Save, a tool's Save) it
  renders as `.btn`. Both upload flows keep their exact markup (`port_writable?` decides which, as
  today).

### 4.3 Widths

| width | sidebar | inspector | top bar |
|---|---|---|---|
| ≥ 1100px | 216px, or 56px by cookie | docked right, 300px | breadcrumb, search, New, Upload |
| 720–1099px | 56px icons regardless of cookie | slides over the grid from the right | same |
| < 720px | hidden; a bottom bar with Recent · Library · Projects · Tools | a full-screen sheet | breadcrumb and one "+" (New and Upload); search on its own full-width row |

No page scrolls sideways at 375px (`test/system/shell_test.rb`'s rule carries over).

## 5. Library, inspector, workspace

### 5.1 The Library view

`FilesController#index`, as today, with:

- **Toolbar**: type filter and active chips, the count, Grid | List, sort. Upload and New move to
  the top bar.
- **Folders navigate on click** (they stay links). **Files select on click**: an ink ring on the
  tile, and the inspector opens. Double-click or Enter opens the workspace. Arrow keys move the
  selection; Escape clears it.
- **The selection is in the URL** as `?selected=<node_id>`, so Back, reload and shared links
  restore it. A `selected` that is not a live node in the current listing is ignored, never an
  error.
- The list view is `table.files` as today; selecting a row behaves the same.

### 5.2 The inspector

A Turbo Frame (`inspector`) rendered for the one selected node, 300px wide, on `surface`:

- the type label, the name, a large preview (`thumb-stage` for renders, `photo-stage` for photos);
- **Open** (to the workspace), Download, and ⋯ (Rename, Move, Pin to sidebar for folders, Move to
  Trash);
- `dl.meta`: size, modified, dimensions (`.measure-dims`) where geometry exists, version on
  `chunk_remote`, LightBurn layers for `.lbrn2`;
- **Projects**: the project folder it sits in, plus linked projects, with the existing attach form;
- **Made with**: for generator output, the tool's name and **Reopen** (§7);
- **Notes**: the count and "Add a note".

It reuses the file page's existing partials (meta, attach-to-project, notes, connections) rather
than new copies. It loads one node, so it adds no per-row query; the Library page's query budget is
unchanged.

### 5.3 The workspace

`FilesController#show`, same URL. Full width, with the sidebar kept. The header holds the
breadcrumb, the name, Download, ⋯, and "Back to folder" (to the folder with this file selected).
The viewer takes the full width: the 3D viewer, Measure, gerber, PDF, image, or the code editor
with history and commit. The inspector's content sits in a collapsible right column. Nothing inside
the viewers, the preview stack or Measure changes (`docs/invariants/measure-view.md`,
`files-preview.md` stand).

### 5.4 Models as a lens

- **The model strip** (`files/_model_strip`): when the current folder is a catalogued model's
  folder (`maker_models.folder_node_id`, answered by `Maker::ModelFolder.model_in`) and no project
  claims it, a compact strip sits above the grid with the cover, the title, the status badge,
  designer · license · source, the print settings summary, notes, Edit and Remove from catalog /
  Delete, and the print log with "Log a print". It replaces the model page for every model that has
  a folder to land on.
- **The "3D models" place**: `/files/models` (`Files::ModelsController`, `files_models_path`), every
  catalogued model as a cover tile with its own status, tag, title and sort filters, which is the
  old Models index as a Library view. Its primary action is Import model, still at `/models/new`.
- **Redirects**: `/models` → 301 to `/files/models`, keeping `q`, `status`, `tag` and `sort`.
  `/models/:id` → 302 to the model's folder when `Maker::ModelFolder.landing_folder_id` names one:
  live, claimed by no project, and showing this model's strip. Every other model keeps its
  `/models/:id` page: a one-file model, an import whose `Models/<slug>` was never made or is in the
  trash, and a model whose folder a project claims. Those are the exceptions, not a second catalog.
- **Shelves** move to Settings (`Settings::ShelvesController`, `/settings/shelves`) as the rule for
  what counts as a model; they stop being navigation, and `/models/shelves` 301s there.
  `docs/invariants/model-intake.md`'s rules (nearest shelf, path vs node id, dismiss is not
  delete) are unchanged.

## 6. The project hub

`ProjectsController#show`, option B:

- **Header**: the cover on `photo-stage`, a PROJECT label, the name in `display`, visibility and
  archived badges, the description. Actions: Edit, Customise layout (the existing layout editor),
  and ⋯ (Publish settings, Archive). The top bar's Upload targets the project's folder.
- **Files panel, always**: the project folder's contents (folder-as-truth, stage 2's decision),
  the 8 most recently changed files, then a "Linked" group for files elsewhere. "Open folder →" goes
  to the Library view. A tile links to `/files?folder=…&selected=…`; the hub has no inspector of
  its own.
- **README panel, always**: the folder's README, editable as today.
- **On-demand panels**: Build log, Tasks, BOM, Sheets, Releases, Print log. A panel renders only
  when it has rows or the user added it from **"+ Add panel"**. This is the existing `panels`
  layout machinery with a new default layout (Files, README, then panels that have data), not a
  second system.
- **Layout**: two columns at 1100px and up (Files wide; log and tasks beside it; README below), one
  column on a phone.
- **Projects index** (`/projects`): cover tiles with name and status; archived projects behind a
  quiet link. New ▸ Project creates the project and its folder under `Projects/`.

## 7. Tools, inventory, Recent

**Tools.** `/tools` stays a gallery. A tool page starts its save in a **default folder**, and the
bundle's own "Save into" field shows it and changes it. There is no host destination bar: slice 4's
plan dropped it, and the amendment in §11 says why. The default resolves in this order, as that
amendment settled it:

1. `?in=<node_id>` when it names a live folder of the user's (New ▸ from a folder sets it);
2. otherwise, when `?state=` names one of this tool's saved states, the folder that state's output
   lives in now (every Reopen link already carries it, so Reopen from a file sets the file's folder);
3. otherwise the folder of the tool's most recent live output for this user, mapped up to its
   project's folder when it sits inside one;
4. otherwise the library root.

This replaces the current-project default in `Tools::AddonsController` (`@default_parent_node_id`).
Output saved inside a project folder is filed and attached by the existing project intake sweep
(`docs/invariants/project-intake.md`), which already works by folder. `attach_addon_files_to_current_project`
goes. Output still goes through `Maker::Addons::LibraryOutput`, the one output path (§14c).

**Inventory.** The sidebar entry renders only when the user has at least one inventory item.
Otherwise inventory is reached from New ▸ Inventory item and from a BOM panel's "Add part". Its
pages are restyled, not restructured.

**Recent** (`/`, `HomeController#index`):

- **Recently changed**: 16 live file nodes by `updated_at`, as tiles; a tile opens its folder with
  the file selected.
- **Active projects**: 6 cover tiles.
- **Attention**: failed prints in the last 30 days and low-stock items, rendered only when
  non-empty.
- An empty library shows one empty state, "No files yet", with Upload.

It reads columns that exist; no counters, no activity table.

## 8. Where new files land

The **current folder** is the destination everywhere:

| page | current folder |
|---|---|
| Library | the folder being viewed (the library root at `/files`) |
| Project hub | the project's folder |
| Workspace | the file's folder |
| Tool page | the folder its save starts in (§7), shown by the bundle's own "Save into" field, not a host bar (slice 4's amendment, §11) |
| Recent, Tools gallery, Settings, Search | none: Upload asks with the file chooser |

The upload forms carry the destination as the parent folder parameter the upload doors already
accept. Nothing chooses a destination from session or user state.

## 9. Compatibility

### 9.1 Contracts that change, on purpose

- **The current project is retired**: `CurrentProject` (concern), `CurrentProjectController` and
  its route, the rail card, the phone top-bar chip, and the remember preference
  (`Settings::PreferencesController`). The pinned selectors `.current-project select` and
  `form[action=current_project_path] select[name=project_id]` go with them, and the tests that pin
  them (about 24 files reference the concept) are rewritten against folder destinations.
- **The columns stay for one release**: `users.current_project_id` and
  `users.remember_current_project` are left unused, then dropped by a later migration. Adding a
  drop runs forward everywhere; nothing in `db/migrate/` is rewritten (§10).
- **Cross-repo check before slice 4 merges: done while planning slice 4 (2026-10-09), and it
  passed.** `addon_bundle_test` pinned `.current-project select` on the addon host page, so the
  question was whether `chaim354/tinkerex-addons` reads it. It does not. Nothing in that repo
  (`main` @ `b0e6c0f`) reads `.current-project select`, `current_project`, `project_id` or any host
  DOM. The only host values its bundles read are the raw ctx keys `defaultFolder` and
  `defaultFolderLabel` (three copies of `folder_field.js`). So the host kept those keys and changed
  only what fills them, and no new host contract was needed. The addons repo took a README
  correction (`chaim354/tinkerex-addons#16`) and no code.
- **Routes**: `/` renders Recent (it already does through `HomeController`); `/models` 301s to
  `/files/models`, and `/models/:id` 302s to the model's folder when that folder shows its strip
  (§5.4); `/models/shelves` moves to `/settings/shelves` with a 301. **This reverses a
  2026-09-10 move and the old redirect must go in the same change**: until slice 5
  `/settings/shelves` 301'd to `/models/shelves`, because the cohesion sweep put shelves under the
  section they serve. With Models gone, the section they serve is Settings. Adding the new redirect
  without deleting the old one is a redirect loop.
- **Navigation highlighting**: `ShellHelper::SECTIONS` grows into the sidebar's highlight map
  (§4.1); `shell_layout_test` is updated.
- **Pins need storage**: a `maker_pins` table (`user_id`, `node_id`, `position`). It is a new
  table, so it goes through the new-table guards (tenant scoping, the dangling-id and
  structural-orphan cases), and pins are reaped with their node the way attachments are (a
  tombstoned node hides its pin; only a reaped node removes it).

### 9.2 Unchanged

- The 52 addon-shared classes and every other test-pinned class name (restyle, never rename).
- Both upload flows' markup, the viewers, the preview stack, Measure, the code editor.
- The cascade (`@layer tokens, base, components, shell, pages;`, `vendor-overrides.css` alone
  unlayered), theme and rail state as cookies with no inline script, and the CSP.
- The public surface's isolation (`Public::` never reads the session, §14d).

### 9.3 Docs that move in the same branches

- `docs/invariants/design-system.md` (§14m): the sidebar replaces the rail, the default theme (if
  confirmed), folder destinations instead of the current project, the inspector frame.
- `docs/invariants/model-intake.md`: the model strip and redirects replace the model pages.
- `docs/invariants/files-preview.md`: the inspector reuses the preview partials.
- `docs/invariants/project-intake.md`: intake is now the only way tool output reaches a project.

## 10. Testing

- **Request tests** for every new route and redirect, the `selected` parameter (live node, stale
  node, node outside the listing), the tool destination order (§7), and Upload's destination per
  page (§8).
- **System tests**: selection in the URL survives reload and Back; arrow keys and Enter; the
  inspector as a sheet at 375px; sidebar collapse persists across a Turbo visit and a reload; no
  horizontal overflow at 375×812 on Recent, the Library (grid, list, inspector open), a workspace,
  a project hub and a tool page.
- **Query budgets** (`page_query_budget_test.rb`): the inspector, the sidebar (projects and pins)
  and Recent assert constancy in N, never a literal.
- **Guards**: the pins table's tenant and orphan guards, the sidebar's single `aria-current`, and a
  guard that no code path reads a destination from session or user state once slice 4 lands. Every
  new guard is mutation-checked.
- **All three backend legs** (`test`, `test-s3`, `test-chunk-remote`) report identical run counts.

## 11. Delivery

One PR per slice, each useful on its own, in this order:

| slice | delivers | depends on |
|---|---|---|
| 1. Visual system | the design system's tokens and components applied to today's structure | the §2 open questions |
| 2. Shell | places sidebar, pins (`maker_pins`), the top bar's New ▾ menu, Inventory on demand in the sidebar | 1 |
| 3. Inspector and workspace | selection, the inspector frame, the workspace header | 2 |
| 4. Folder destinations | retire the current project, Upload into the top bar, the tool's default save folder, intake-only attach | 3, the cross-repo check |
| 5. Models fold-in | the model strip, the 3D models place, the redirects, shelves to Settings | 3 |
| 6. Project hub and Recent | the default layout, "+ Add panel", tile links to selection, Recent | 2 |
| 7. Cleanup | dropping the retired current-project columns (Inventory on demand landed in slice 2) | 4 |

**Amended 2026-10-08 (slice 2's plan):** the top bar's Upload moved from slice 2 to slice 4, because
its destination IS slice 4's change; moving the button first would write its destination logic
twice. The current-project card stays in the sidebar until slice 4 for the same reason. The
conditional Inventory entry moved forward into slice 2, where the sidebar is built.

**Amended 2026-10-09 (slice 3's plan):** the inspector's actions are Open, Download and Delete —
Rename and Move need web doors that do not exist yet, and Pin belongs to the folder's own menu. It
shows the note count with a link to the page's notes rather than the composer. "Back to folder" is
the file page's breadcrumb, whose folder link reselects the file; the existing Back keeps its
referer contract (and the referer already carries `?selected=`). The workspace's side column is not
collapsible: the 3D, Gerber and Measure viewers size themselves to their container when built, so a
column that changes width after load needs a resize contract with each of them first.

**Amended 2026-10-09 (slice 4's plan):** tool pages get no host destination bar. All three shipped
bundles already render their own "Save into" field, seeded from the host's `defaultFolder` and sent
back as `folderNodeId`. A host bar would be a second chooser that could disagree with the bundle's,
and its Change could only take effect by reloading with `?in=`, which throws away the tool's unsaved
settings. So the host decides only the default, and §7's order grew from three steps to four:
`?in=`; then `?state=`'s own output folder; then the tool's most recent live output, mapped up to its
project's folder; then the root. The `?state=` step meets "Reopen from a file sets the file's folder"
without changing a link, because every reopen link already carries `state=`. The mapping exists
because intake files `Projects/<slug>/x.svg` into `design/`. A same-name save into `design/` is a
terminal 422, while a save into the project root reaches the 409 "save as revision 2" offer. Home's
current-project hero goes in this slice with the concept it showed. Recent stays in slice 6. Until
then Home keeps its other sections, keeps "New project" as its primary, and uploads through the top
bar's Upload, which asks for a folder there. So §4.2's Upload is `.btn.primary` on the Library and
the project hub only. It is quiet everywhere else, including a tool page, whose primary is its own
Save. The hub's Files-panel upload moves to the top bar, which leaves
one door per destination and the two accent controls the cohesion spec's decision 3 allows a hub.
An upload into the project folder attaches through intake, and `Projects::UploadsController` stays
for build-log entries. The top-bar Upload keeps both Files flows' outcomes exactly, redirects
included. At phone width Upload sits beside New, so §4.3's single "+" waits for slice 7's cleanup,
and below 1100px the caption hides and the button's `title` carries it. The New ▾ menu now creates
in the same validated folder as Upload on every page that shows one; it used to read the raw
`params[:folder]`, and only on the Files index. Its tool entries carry `in=` that folder. Finally,
`users.current_project_id` and `users.remember_current_project` become `ignored_columns` rather than
merely unused (§9.1), so no code can read either by accident before slice 7 drops them.

**Amended 2026-10-09 (slice 5's plan):** the 3D models view lives at `/files/models`, not
`/files?view=models`. `?view=` is already the Library's list/grid toggle and is saved in the
`files_view` cookie, so a `models` value would be saved as the Library's view and the next plain
folder link would render the models view. Every control built from `files_query_base` (sort,
dot-files, search, Rescan) would also drop it, and the view's own filters (status, tag, title search,
its own sort values) collide with the Library's `q` and `sort`. A path of its own avoids all three,
and as a `Files::` controller it reads as a Library page: the sidebar's 3D models place lights for it,
and the phone tab bar lights Library. The strip keys on `folder_node_id`, not the `auto_node_id` §5.4
first named. An imported model's `Models/<slug>` sets only `folder_node_id`, an auto folder model sets
both to the folder, and a one-file auto model has no folder at all (its `auto_node_id` is a file on a
shelf), so it gets no strip. There is no "manual" origin, so the model page is not one exception: it
survives for every model with no strip to land on. That is one-file models (about half of what the
sweep creates), imports whose `Models/<slug>` was never made or is in the trash, and a model whose
folder a project now claims, because a project's claim wins. `Maker::ModelFolder` is the one answer to
"which model does this folder show?" and "where does `/models/:id` go?", so the strip and the redirect
cannot disagree. `/models/:id` redirects only when `landing_folder_id` names a folder, and it is a 302,
not a 301, because the answer changes when a folder is trashed or restored. `/models` itself is a
permanent 301 to `/files/models` that keeps `q`, `status`, `tag` and `sort`. The strip carries the
cover, title, status badge, designer · license · source, the print-settings summary, notes in a
`<details>`, Edit, Remove from catalog / Delete with the model page's exact wording and branches, and
the print log with "Log a print". It does not repeat the page's 3D viewer, image gallery, instructions
PDFs or file tree, because the folder's own listing, the inspector and the workspace already show
those files. Logging or deleting a print redirects back, so from the strip the maker stays in the
folder; deleting a model still lands on 3D models. Import stays at `/models/new`, linked as the 3D
models view's primary action, and still lands on `model_url`, which now redirects to the new
`Models/<slug>` folder and its strip. Shelves move to `Settings::ShelvesController` at
`/settings/shelves`. The 2026-09-10 redirect from `/settings/shelves` to `/models/shelves` is deleted
in the same change, as §9.1 requires, so `/models/shelves` can 301 the other way without a loop.
Shelves light Settings and stop being navigation; the 3D models view keeps one muted sentence pointing
at them. Finally, the emoji placeholders slice 1 deferred become the 3D models icon
(`rail_icon(:models)`), and the `_print_log` partial takes strict locals so the strip and the page
share one copy.

**The main risk is slice 4.** It changes uploads, tools and an addon host contract together, which
is why it waits until the inspector exists (so "where did my file go" has an answer on screen) and
why it has its own cross-repo check.
