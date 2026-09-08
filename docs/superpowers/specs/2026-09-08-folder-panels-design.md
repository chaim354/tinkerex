# Folder panels — each subfolder of a project is a panel with its own view

Date: 2026-09-08. Status: **approved in conversation** (the two product decisions below were the
owner's; the rest is the design that follows from them). Branch `claude/folder-panels`.

## 1. Why

The project page's Files panel already groups the folder the way it sits on disk (stage 3, decision
1: the folder is the truth): loose files first, one section per real subfolder nested as on disk,
then Generated, Backups and Linked. A working tree renders its section CLOSED and, when opened,
shows the Finder-style Miller-columns browser instead of tiles (2026-09-07). But the page has ONE
view — tiles or list, a cookie shared by every section — so a maker who wants the 3D models as
tiles with their previews and the firmware repository as the browser cannot have both, and the
sections cannot be hidden or moved relative to the other panels.

The owner asked for each group to be its own panel so its view can be chosen per group.

## 2. Decisions

**The owner's, on 2026-09-08:**

1. **Each folder section becomes its own panel** — a first-class member of the panel chooser: hide
   it, move it (above the build log if you like), and pick its view.
2. **A hidden folder is hidden from the visitor's page AND from the bundle**, matching how the feed,
   the manifest and the BOM CSV already honour the layout (tinkerex#283). Files stay downloadable by
   direct link, because permission is by folder claim (`Maker::PublicProject#permits?`), not by
   panel.

**Design decisions that follow (mine; say so in the PR):**

3. **Depth one.** A panel per DIRECT subfolder of the project folder. Nested folders render inside
   their parent's panel exactly as `projects/_file_tree_section` nests them today. A repository at
   depth one is a panel like any other; a repository nested deeper stays a closed section inside
   its parent panel, as today.
4. **The Files panel keeps the folder ROOT**: the README or repository card, Loose, and the
   cross-cutting Generated, Backups and Linked groups, plus the truncation and missing-attachment
   notes. Those three groups are not folders and do not become panels.
5. **Panel keys are `folder:<node_id>`.** On chunk_remote the id is the sync server's and a rename
   arrives as a move, so the arrangement survives; on share and s3 the scan pairs renamed FILES by
   content and never directories, so a renamed subfolder gets a NEW id (measured in review) — its
   placement, view and hidden state reset to the defaults, which returns a hidden folder to the
   visitor's page and the bundle until it is hidden again. A path key would break on that rename
   too, and on every chunk_remote move besides, so the id is still the better key; the reset is the
   documented cost. A folder deleted and recreated resets the same way.
6. **Three views, per panel, persisted per project**: `tiles`, `list`, `browser`. The page-wide
   `project_view` cookie and its toggle retire. Defaults reproduce today's page exactly: a
   repository opens in the browser, everything else in tiles; the Files panel defaults to tiles.
7. **Visitors get a list where the maker chose the browser.** The browser reads the session-authed
   `LibraryBrowseController#children`; a public children endpoint is a separate design.
8. **No migration.** `panels` is a JSON column; every existing project renders identically until a
   toggle or the chooser is touched.

## 3. Data

`maker_projects.panels` (JSON, nullable) gains folder keys and a views map:

```json
{ "order":  ["attachments", "folder:7c1e…", "photos", "build_log", "folder:9ab2…", "publish", …],
  "hidden": ["bom", "folder:9ab2…"],
  "views":  { "attachments": "list", "folder:7c1e…": "tiles", "folder:9ab2…": "browser" } }
```

`Maker::ProjectKind.layout_for(kind:, overrides:, folders:)` takes the project's depth-one folders
as `[[node_id, repo?], …]` in disk order and answers `Layout(order, hidden, views)`:

- **Vocabulary** = `Maker::Project::PANELS` ∪ the CURRENT folder keys. Every stored key is
  intersected with it, so a folder key whose directory is gone, nested, or never existed drops out
  — the same totality the layout has always had, extended (an unknown key must never reach
  `render`).
- **Order** = stored order (filtered) + the preset order with the folder keys inserted immediately
  after `attachments` in disk order. A folder the stored order does not name appears there, never
  dropped — the rule that already protects an eleventh fixed panel.
- **Hidden** = stored hidden (filtered) or the kind preset's, minus `ALWAYS`. Folders are hideable;
  `ALWAYS` is unchanged (`attachments photos publish`).
- **Views** = stored views filtered to the vocabulary and to `Maker::Project::VIEWS =
  %w[tiles list browser]`; `Layout#view_for(key)` answers the stored view or the default (`browser`
  for a repository folder, else `tiles`). `Layout#folder?(key)`, `Layout#folder_id(key)`.

`Maker::Project#panel_layout(folders:)` and `#visible_panels(folders:)` take the folder list; the
callers that hold a listing pass `listing.panel_folders` (a new one-line reader:
`tree.map { |d| [d.node_id, d.repo?] }`). The chooser's door builds a dirs-only listing
(`Maker::ProjectFolderListing.new(user, project, load_files: false)`) to know the vocabulary.

## 4. The maker's page

`projects/show.html.erb`'s loop gains one branch: a folder key renders
`projects/_folder_panel` with the `Dir` from `@listing.tree` and the layout's view for it. The map
of fixed keys to partials is unchanged.

**`projects/_folder_panel.html.erb`** (new): a `section.panel.folder-panel` with the folder's name,
its subtree file count, a link to the folder on the Files page, the `repo` badge with Commits and
History for a working tree, and the VIEW TOGGLE — three `button_to`s posting `view[<key>]` to the
panels door. The body by view: **tiles** — `_file_tile` per visible file, nested subfolders through
`_file_tree_section` as today; **list** — `_file_rows` plus the same nesting; **browser** —
`_repo_browser`, which already takes any `Dir` (renamed `_folder_browser` in passing, one call
site). Each folder panel wraps its own `data-controller="thumbs filemenu"`; `@page_thumbs` already
covers every tile id on the page. An empty folder is QUIET (heading and "empty"), per S4-1's
quiet-panel rule; it is not omitted, because the maker put it in the layout.

**`projects/_attachments.html.erb`** loses the `file_tree_section` collection render and the
view toggle, gains its own view toggle, and keeps everything else.

**The chooser** lists folder keys as rows labelled with the folder name (from a `labels` map the
controller builds: `PANEL_LABELS` merged with the listing's names), with the same checkbox and
up/down buttons. `Projects::PanelsController` widens `known` to the vocabulary, accepts
`view[<key>]` and merges it into `views` (a value outside `VIEWS` is ignored), and its `destroy`
still writes `nil`, which now also clears the views.

## 5. The visitor's page and the bundle

`Maker::PublicProject#visible_panels` passes its own listing's folders. `public/projects/_page`'s
loop gains the folder branch: `public/projects/_folder_panel` renders the folder's files as tiles
or list (`browser` reads as list), read-only, from `pub.thumbs` — the same rows
`public/projects/_files` renders today, split per folder. `public/projects/_files` shrinks to the
ROOT: loose files only (`pub.sections` becomes root-only or is replaced by a `loose` reader).

**Hidden folders leave the bundle**: `pub.hidden_folder_ids` (the layout's hidden folder keys) →
`bundle_files` rejects every row under one (`Dir#subtree_file_ids`, in memory). The manifest's
`files`, the button's count and the zip agree by construction; `readme_path`, `bom_csv_url`, the
feed and the CSV are untouched; `deliverable!` is untouched (decision 2).

## 6. What stays invariant

- The layout is TOTAL: no key reaches `render` that is not `PANELS` or a current depth-one folder.
- `ALWAYS` is unchanged; a folder can be hidden, the root cannot.
- Query cost stays constant in the number of folders on both pages: folders come from the tree the
  listing already built, views from the JSON already loaded, thumbnails from the one
  `ThumbnailMap` the page already builds. `page_query_budget_test.rb` grows a case whose N is the
  number of depth-one folders.
- The public partials read `pub` and nothing else (the seam guard).
- `Maker::ProjectKind`'s header remains the one home for layout rules; this spec is the story.

## 7. Verification

Per task, mutation-checked: layout totality (a stale folder key drops out; a nested folder's key is
refused; an unknown view is ignored); the view toggle persists and renders (each of the three views
on a plain folder, the browser mounting through `filebrowser_controller` in a system test); the
chooser's folder rows wire to the same form (extend `project_panels_test.rb`); Files renders the
root only; the visitor's page mirrors order and hiding; a hidden folder's files leave the manifest
and the page while its direct link still answers; the template sweep renders both new partials;
budgets constant in folder count; three legs at identical run counts.

## 8. Out of scope, named so it is not re-derived

Panels for nested folders; the browser for visitors (needs a public children endpoint);
per-kind folder defaults (the presets do not know folder names); persisted open/closed state per
section; Generated, Backups and Linked as panels; per-file views inside a panel.
