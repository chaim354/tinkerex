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
| Models index, model pages, shelves | **Folded into the Library**: the model strip, the "3D models" place, shelves as a Settings rule | `/models*` → 301 to Library views; `/models/shelves` → `/settings/shelves` |
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

- **The model strip**: when the current folder is a catalogued model (`maker_models.auto_node_id`),
  a compact strip sits above the grid with the cover, the status badge, the print settings summary
  and "Log a print". It replaces the model page.
- **The "3D models" place**: `/files?view=models`, every model folder as a cover tile, which is the
  old Models index as a Library view.
- **Redirects**: `/models` → `/files?view=models`; `/models/:id` → the model's folder. A manual
  model with no folder keeps a restyled `/models/:id` page; that is the one exception, not a second
  catalog.
- **Shelves** move to Settings as the rule for what counts as a model; they stop being navigation.
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

**Tools.** `/tools` stays a gallery. Every tool page gains a **destination bar**: "Saves to
Projects/shop-stool · Change", where Change opens the file chooser. The destination resolves in
this order:

1. `?in=<node_id>` when it names a live folder (New ▸ from a folder sets it; Reopen from a file sets
   the file's folder);
2. otherwise the folder of the tool's most recent output for this user;
3. otherwise the library root.

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
| Tool page | the destination bar's folder (§7) |
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
- **Cross-repo check before slice 4 merges**: `addon_bundle_test` pins `.current-project select` on
  the addon host page. Check whether `chaim354/tinkerex-addons` reads it. If it does, the
  destination bar exposes the destination under a new, documented host contract
  (`docs/invariants/addons.md`), and the addons repo moves to it before this repo removes the old
  one.
- **Routes**: `/` renders Recent (it already does through `HomeController`); `/models*` redirects
  (§5.4); `/models/shelves` moves to `/settings/shelves` with a redirect. **This reverses a
  2026-09-10 move and the old redirect must go in the same change**: today `/settings/shelves`
  301s to `/models/shelves`, because the cohesion sweep put shelves under the section they serve.
  With Models gone, the section they serve is Settings. Adding the new redirect without deleting the
  old one is a redirect loop.
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
| 4. Folder destinations | retire the current project, Upload into the top bar, the tool destination bar, intake-only attach | 3, the cross-repo check |
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

**The main risk is slice 4.** It changes uploads, tools and an addon host contract together, which
is why it waits until the inspector exists (so "where did my file go" has an answer on screen) and
why it has its own cross-repo check.
