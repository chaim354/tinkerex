# A click opens the file, and a model gets its own page — design

2026-10-21. Two parts, one branch (`claude/file-click-model-page`).

The owner's request, verbatim: "clicking on a 3d model with multiple files should not open the file
viewer also clicking on any file anywhere should just open it no preview you can add that as an
option in the write click like "details"".

Decisions taken with the owner before this was written:

| question | answer |
|---|---|
| What does a plain click on a file do? | Single click opens the file's page in the same tab; double-click opens it in a new tab |
| What does "open" mean? | The file's page (`files#show`), not the raw bytes |
| Where does the side panel go? | Right-click › **Details** |
| What should a multi-file model open instead of its Library folder? | Its own page: the model's files on the left, a large pane on the right, like Printables |
| What does clicking a file in that list do? | Shows it in the right pane |

## Part 1 — A click opens the file

### Behaviour

- **Single click** on a file tile or file row opens `file_path(node)` in the same tab.
- **Double-click** opens the same page in a new tab (`window.open(href, "_blank", "noopener")`).
- **Everything else keeps the link's own behaviour**, which is why every tile stays an
  `<a href=file_path>`: a Cmd/Ctrl/Shift/Alt click or a middle click is the browser's, Enter (a
  click whose `detail` is 0) opens the page, and with JavaScript off every tile is a plain link.
- **Right-click › Details** is a new entry in the file menu, placed after Open:
  - **in the Library** it opens the side panel (the inspector) for that file — exactly today's
    single-click result: the ink ring, `?selected=<id>` replaced into the URL, the frame loaded;
  - **everywhere else** (Recent, the project hub) it navigates to
    `files_path(folder: node.parent_node_id, selected: node.node_id)`, the Library with that file's
    panel open. A file at the library root has no parent, so its folder param is omitted.
- **In the Library a click no longer selects.** The panel opens only through Details or a page
  rendered with `?selected=`. While the panel is open, the arrow keys move the selection and Escape
  closes it, as today; while it is closed, the arrow keys are the browser's.

### Where

Every file tile and file row that links to a file page:

- the Library grid and list (`files/_grid`, `files/_list`, both link branches of each);
- Recent (`home/index`);
- the project hub: `projects/_file_tile`, the name link in `projects/_file_rows`, `_photos`,
  `_schematics`, `_hero`, and an image block in `_block_panel`;
- search results (`shared/_result_group`, the file arms);
- the file page's photo tiles (`files/_connections`, the `photo-cell` links);
- the model page's gallery and file list (Part 2, where a single click shows the file in the pane
  instead of navigating).

**Not changed:** links inside written text — Markdown and README links, BOM part names
(`projects/_bom_lines`), the connections panel's sentences — stay ordinary links; a double-click on
text selects a word, and it should keep doing so. Folders still navigate on click. Model cards in
the 3D models view open the model page (Part 2) and are links to a model, not a file. **The public
pages are out of scope**: they are sessionless, visitor-facing, carry no file menu, and §14d keeps
them apart.

### How

**One Stimulus controller, `fileopen`, mounted once on each layout's `<main>`**, and one helper,
`FilesHelper#file_open_data`, that a file link merges into its `data:` to opt in
(`action: "click->fileopen#click"`, appended to any existing action, never replacing it — the file
menu's `contextmenu->filemenu#open` and the poll's attributes share the hash). `fileopen#click`:

1. returns at once (the browser handles it) for `detail === 0`, any modifier, or a non-primary
   button;
2. `preventDefault()`s otherwise;
3. on `detail === 1`, starts a **250 ms** timer that re-issues the click with `link.click()` — a
   synthetic click has `detail === 0`, so step 1 lets it through and Turbo follows the link with
   every `data-turbo-*` attribute it carries (which is what makes the model page's frame links in
   Part 2 work with no second code path);
4. on `detail === 2`, cancels the timer and opens the link's **new-tab URL** —
   `data-fileopen-new-tab-url` when the link carries one (the model page's list, whose `href` is
   the model page), else its `href`;
5. ignores `detail > 2`, and ignores a second click that arrives after the timer already fired
   (a slow double-click opens the page here, once — never here *and* in a new tab).

**The 250 ms wait is the cost of telling a click from the first half of a double-click, and it is
stated here rather than hidden.** It is mostly invisible: Turbo 8 (turbo-rails 2.0.23) prefetches a
link's page on hover, so the visit the timer starts is usually answered from the prefetch cache.
The alternative without a wait — single click opens, "Open in new tab" in the menu instead of a
double-click — was offered and not chosen.

**Details goes through an event, so the menu never needs to know which page it is on.**
`file_menu_data` gains a `details_url` (the Library URL above), built by the server like every
other entry (filemenu_controller.js's rule: no URL is assembled in the browser). The menu's
Details entry dispatches a cancelable `filemenu:details` event on the cell; in the Library,
`with_selection` wires `filemenu:details->selection#details`, which selects the tile and calls
`preventDefault()` on the event. If nothing cancelled it, the menu navigates to `details_url`.
`file_menu_data` therefore takes the node (`file_menu_data(node, origin)`) instead of an id and a
name, since it now needs the parent too; every caller already holds the node. The menu's
open-gate (`if (!noteUrl && !deleteUrl) return`) is unchanged — every file cell carries both.

**`selection_controller.js` keeps** `select`, `close`, the URL replace and its link sync, Escape, and
the arrows (now gated on `has-inspector`). It **loses** `click` and `open`, and `with_selection`
stops appending `click->selection#click dblclick->selection#open`.

## Part 2 — A model's own page

### Behaviour

- **`/models/:id` always renders the model page.** The 302 to the model's Library folder
  (`Maker::ModelFolder.landing_folder_id`) is removed. A model card in Files › 3D models, a search
  result and Recent's failed-print link all land on the page. Import still lands on `model_url`,
  which is now the page.
- **Layout**, two columns at 900px and up:
  - the page head stays across the top: title, status badge, Edit, Open in Files, Remove from
    catalog / Delete with today's wording and branches;
  - **left**: a **Details** entry, then the model's files as today's folder tree
    (`models/_file_tree`), then the missing-attachments sentence;
  - **right**: a large pane, a Turbo Frame (`model_stage`).
- **The pane starts on** the model's first live instructions attachment (role `instructions`, by
  `position`) when there is one, otherwise on Details.
- **Details** holds what the main and side columns hold today minus the file tree and the
  instructions iframes: the cover with View in 3D and its switcher, the gallery, designer,
  license, source, tags and added date, print settings, notes, and the print log with Log a print.
- **Clicking a file** in the list (or a gallery image) shows it in the pane through the same
  viewer chain the file page uses — image, PDF, KiCanvas, board, code, 3D viewer, Measure, static.
  The pane has a small header: the file name, Download, and "Open file page". A double-click on a
  list entry opens the file page in a new tab (Part 1's rule).
- **The choice is in the URL**: `/models/<slug>?file=<node_id>` or `?file=details`. Reload, Back and a
  shared link show the same pane. A `file` that is not one of this model's listed files is ignored
  and the default applies — never an error. The selected list entry carries `aria-current`.
- **What the pane does not do**: edit or save. Code renders with `editable: false` and no repo
  banner; Measure renders with `save: false` (the public page's mode, already supported); there is
  no thumbnail poll. Editing, committing, notes, attach and history stay on the file page, one
  click away through "Open file page".
- **On a phone** the list stacks above the pane, and a file click scrolls the pane into view.
- **The Library's model strip stays**, and its title links to the model page.

### How

- **List links** are `href=model_path(model, file: id)` with `data-turbo-frame="model_stage"`; the
  frame carries `data-turbo-action="advance"` so a pane change becomes a history entry with the
  `?file=` URL. Each also carries `file_open_data` plus `data-fileopen-new-tab-url=file_path(id)`.
- **A frame request renders the pane alone.** `ModelsController#show` resolves the pane first; when
  `turbo_frame_request?` it renders only the pane and skips the Details data (the hero, gallery,
  print runs, composer choices), so switching files costs one viewer's setup.
- **One viewer chain, two pages.** The `if @kind == …` chain inside `files/show.html.erb`'s
  `.preview` moves into a maker-side partial, `files/_viewer.html.erb`, rendered by the file page and
  by the pane. It lives **outside** `files/viewers/` on purpose: it calls private route helpers
  (`blob_file_path`, `geometry_file_path`, …), which `architecture_invariants_test.rb`'s Public scan
  forbids inside that directory. Its inputs are one value object built by one method —
  `FilePreview#viewer_state_for(user:, node:)` (the stat, `viewer_for`'s kind and board, the current
  thumbnail, the 3MF manifest) — which `FilesController#show` and `ModelsController#show` both call,
  so the two pages cannot disagree about which viewer a file gets. The file page keeps its
  owner-only facts (the repo banner, editing, the recipe panels, History, Notes) by passing
  `editable:` and a banner flag; the pane passes neither.
- **Which files are listed** is today's rule: the model folder's subtree filtered to the model's
  live attachments, or the attachments alone when the model has no folder
  (`ModelsController#file_tree_for_model`). The `file` param is validated against that same set.
- **`Maker::ModelFolder.landing_folder_id` is deleted** with its tests; `model_in` stays (the
  strip's one answer). The module's header comment loses its second question.

## Testing

- **System** (`test/system/`):
  - Library grid and list: a single click lands on the file page; a double-click opens one new
    tab and leaves this one on the Library; Cmd-click is untouched; right-click › Details opens the
    panel with `?selected=`; arrows work only while the panel is open; Escape closes it.
  - Recent and the project hub: right-click › Details lands in the Library with the panel open.
  - The model page: the default pane (a PDF when the model has instructions, else Details); a list
    click swaps the pane and the URL; Back restores the previous pane; reload keeps it; a
    double-click opens the file page in a new tab; at 375px the list stacks and nothing overflows.
- **Request**:
  - `/models/:id` renders 200 for a model whose folder would previously have been the landing;
    another user's model is still a 404.
  - `?file=` with a listed file, a foreign node, a tombstone and garbage — the last three fall back
    to the default.
  - A frame request renders the pane without the Details sections.
  - `file_menu_data` carries `details_url` with the parent folder, and without it for a root file.
- **Query budget** (`page_query_budget_test.rb`): the model page with and without `?file=` is
  constant in the model's file count.
- **Rewritten, not deleted**: `files_selection_test.rb` (click no longer selects),
  `models_redirects_test.rb` (the page renders), `file_menu_wiring_test.rb` (the new entry, the new
  signature), `model_strip_test.rb` (the title link).
- **Guards are mutation-checked** (§15): restore `click->selection#click` and the selection test
  goes red; restore the redirect and the model-page request test goes red; drop `details_url` and
  the wiring test goes red.
- **All three backend legs** report identical run counts.

## Docs that move in this branch

- `docs/invariants/files-preview.md` — "The tiles stay links" and the Recent/project-hub paragraph:
  a click opens, a double-click opens a new tab, Details is the panel's door, and the tiles stay
  links for the same reasons.
- `docs/invariants/model-intake.md` — the redirect is gone; every model has its page.
- `selection_controller.js`'s and `FilesHelper#with_selection`'s header comments.
