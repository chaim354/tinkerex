# Project folder panels open folders in place; version stacks become a setting

**Date:** 2026-11-24 · **Status:** approved in conversation, awaiting spec review
**Follows:** PR #554 (flat path-headed sections, the untiled pot), deployed as tinkerex#600.

## The owner's report

> "this organization kind of sucks too i kind of want it like the browser but with tiles where you
> can click through also get rid of the stack button and just do by default and put it in settings
> for each project and a master default setting too"

Two independent changes, one spec:

1. **Click-through panels.** A folder panel in Tiles or List view shows ONE folder at a time — its
   subfolders as tiles (or rows) you click into, then its files — instead of unrolling every folder
   beneath it as sections.
2. **Version stacks as a setting.** The per-panel "Stack versions and backups" checkbox goes. Stacking
   is on by default, chosen per project with a master default in Settings.

Decided with the owner (2026-11-24): a folder opens **inside the panel**, not in the Library; **List
clicks through the same way**; **Browser is unchanged**.

## 1. Click-through panels

### What a panel shows

A depth-one folder panel (`projects/_folder_panel`) in Tiles or List view shows its **current
folder**, which starts as the panel's own folder:

- **A path bar** above the contents once a subfolder is open: the panel's folder name, then each
  folder opened beneath it — `out / itx / four-piece`. Every part but the last is a link back up to
  that folder. At the panel's own folder there is no path bar: the panel head already names it.
- **Folder tiles first**, sorted by name: folder glyph (the Library's `.folder-thumb`), the folder's
  name, and how many files it holds in its whole subtree. A repository adds the `repo` badge.
- **Then the folder's own files**, as today's tiles — thumbnails, version stacks, the right-click
  menu, "Pull out"/"Put back".
- **List view** is the same contents as rows: folders first (glyph, name, count), then files, under
  the same path bar.
- **Opening a repository** shows its repo card first (as a depth-one repo panel does today), then its
  contents as tiles or rows. It no longer renders as a closed section with a Finder browser inside.
- **An empty folder** says "Empty folder." under the path bar.

The panel head (title, file count, the Library path link, view buttons) stays as it is and keeps
describing the panel's own folder, not the folder currently open.

**Browser view is unchanged**: the Miller-column browser, mounted at the panel's folder.

### Navigation

- Clicking a folder tile or a path-bar link **replaces only that panel**; the rest of the page does
  not move. Implemented as a Turbo Frame around each folder panel with `target="_top"` — so every
  other link inside it (a file tile, Commits, History, the Library path link, the file menu) still
  navigates the whole page as it does now — and the folder and path links alone opting into the
  frame with `data-turbo-frame`.
- **The URL records each panel's open folder**: `?at[<panel folder node_id>]=<node_id>`, one entry per
  panel that is not at its own folder; other panels' entries are carried along. Links use
  `data-turbo-action="advance"`, so Back steps out of a folder, and a reload or a shared link opens
  the page with each panel where it was.
- **The server renders just the frame** for a Turbo Frame request naming a folder panel (the same
  shape as today's in-place view switch, `ProjectsController#switched_panel_streams`, which renders
  one `projects/panel_body`), and the whole page otherwise.
- **An `at` entry that does not resolve** — a folder since moved or deleted, a node outside that
  panel's subtree, a file, garbage — is ignored and the panel shows its own folder. Never a 404: a
  stale bookmark should degrade to the panel's top, not an error page.
- **Switching a panel's view** (Tiles ↔ List) keeps the folder it is in. Switching to Browser shows
  the browser at the panel's folder; switching back returns to the folder the URL still names.
- **In the page editor** folder panels show their own folder, and folder tiles do not navigate: the
  editor arranges panels, and a click that leaves the draft for another URL is the failure
  `_stack_switch` already avoids there.

### What this replaces

`ProjectsHelper#folder_sections`, `FolderSection` and `projects/_file_tree_section` (PR #554) render
nothing once panels click through; delete them and their tests rather than leave dead partials.
`Maker::PublicProject#folder_sections` — the visitor's page — is a separate surface and stays.

### The tile budget

The 300-tile `FILE_CAP` (`Maker::ProjectFolderListing`) is split across **the folders currently
shown** in Tiles and List panels — each one's **own** files, not its subtree. Every other folder in
the project loads its rows from the second `FILE_CAP` pot #554 added (`#untiled!`), because Photos,
repo cards, README links and backups still read them. This generalises #554's rule ("a folder that
draws no tiles takes none of the cap") to "a folder not on screen takes none of the cap", and like
#554 it is declared to the listing **before its rows load**.

A folder tile's count reads the whole subtree from the walk (`Dir#subtree_file_ids` plus
`subtree_hidden_count`), so it is right even where the cut left rows unloaded.

A shown folder the cap still cuts keeps today's "Showing X of Y files · Open the folder" line.

### The rest of the page

- **Recently changed** (the Files panel's row) keeps today's rule: it leaves out a panel that is
  hidden or in Browser view, decided per **panel**, not per open folder. A file in a subfolder you
  have not opened is still one of the panel's files.
- **The page's one ThumbnailMap** paints what the page draws: the open folders' files, the recent
  row, Photos and the rest as now. It must not take files the page no longer draws as tiles, or it
  enqueues renders for thumbnails nobody sees (the F-S15-1 rule: the drawn tiles and the union are
  one decision).
- The query budget for the page (`page_query_budget_test.rb`) stays constant in N, with one panel
  opened into a subfolder added to what it measures.

## 2. Version stacks as a setting

### Where it is chosen

- **Master default:** a "Version stacks" row on the Settings page (`settings/show`), beside Theme,
  with an On/Off control. Stored as `users.stack_versions`, boolean, **default true, NOT NULL**. On is
  the shipped default for every account, existing and new, so no account-creation door has to set it.
- **Per project:** the project's Edit page (`projects/_form`) gets "Stack versions and backups" with
  three choices — **Use my default**, labelled with what the default currently is ("Use my default
  (On)"), **On**, **Off** — stored as `maker_projects.stack_versions`, **nullable** boolean. NULL
  means "follow my default"; every existing project starts NULL.
- **Resolution, in one place:** `Maker::Project#stacking?` answers
  `stack_versions.nil? ? user.stack_versions : stack_versions`. (Not `#stack_versions?`: that is
  ActiveRecord's own query method for the column, and it reads nil as false.) The layout
  (`Maker::Project#panel_layout`) is handed that answer, and `Maker::ProjectKind::Layout#stacked?(key)`
  — which every caller already asks — becomes `ProjectKind.stacks?(key) && <that answer>`, so no
  panel reads either column itself. `ProjectKind.stacks?(key)` (which panels can stack at all) still
  gates it.

### The Library and Search follow it too

Decided with the owner (2026-11-24, after this spec was approved): the Library's Files page and
Search lose their own "Stack versions and backups" checkbox (the `files_stacks` cookie,
`StackSwitch`) and read `current_user.stack_versions` — one setting outside projects. A `?stacks=`
param is inert and the old cookie is never read again.

### What goes

- The per-panel switch, `projects/_stack_switch`, and its renders in `_folder_panel` and
  `_attachments`, along with its "N files in M entries" note.
- The Files page's and Search's checkboxes, `app/controllers/concerns/stack_switch.rb`, and the
  `.stack-switch` rules in `components.css`.
- `Projects::PanelsController#update_stack` and its route params.
- `panels["unstacked"]`: `Maker::ProjectKind::Layout#unstacked` and its parsing, and
  `PanelsController`'s carry-forward of it. A stored `unstacked` key in an existing row is ignored and
  dropped on the next layout write.

### What stays

- **"Pull out" / "Put back"** on a stacked file (`file_stack_exclusion_path`) — a per-file choice,
  not the switch the owner asked to remove.
- Stacking itself: `ProjectsController#load_version_stacks`, `ProjectsHelper#stack_figures`, the
  stack tiles and rows.

### Live data

On 2026-11-24 one project on the live share deployment has a panel unstacked (user 1, `pc case`,
one key); chunk_remote and s3 have none. After this ships that panel stacks again unless the owner
sets `pc case` to Off. No data migration: dropping the key is the change.

## Testing

- **Listing:** a shown folder's own files take the tiles' cap and its subfolders' files do not; an
  unresolvable `at` falls back to the panel's folder; declaring after the rows load still refuses.
- **Page:** a folder panel draws folder tiles then file tiles at its top; `at[...]` opens a subfolder
  with the right path bar, links and contents; a Turbo Frame request answers the panel alone; List
  shows the same folder as rows; a stale `at` shows the panel's top; another panel's `at` is carried
  in every folder link; file tiles and Commits keep `_top`; the editor's folder tiles do not link.
- **Stacks:** the master default, the project's three choices and their resolution; no
  `stack-panel-switch` renders anywhere; Pull out / Put back still work; the Edit form's RENDERED
  field name round-trips (§14d's `scope:` lesson).
- **System test:** click into a folder, click a path-bar link back up, use Back, and see only the
  panel change.
- **Mutation-check** each new guard (§15): the frame's `target="_top"`, the budget's shown-only rule,
  the `at` fallback, the resolution order.
- All three backend legs and the system gate (`bin/ci`).

## Docs

- `docs/invariants/project-intake.md`: replace #554's FILE_CAP paragraph's "untiled" wording with the
  shown-folders rule.
- `docs/invariants/design-system.md` only if a new component selector is added to `components.css`.

## Out of scope

- The visitor's public project page.
- The Files panel's own layout (the project root's loose files, Backups, Recently changed), except
  losing its stack switch.
- Remembering a panel's open folder anywhere but the URL.
