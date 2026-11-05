# The README panel, with live tables and images

**Date:** 2026-11-05. **Status:** approved in conversation (owner), section by section. **Request,
verbatim:** "readme should live in their own panel and should have an editor that can dynamically
insert tables or images that if they change the readme will change".

Decided with the owner before this was written: a live table may draw on **files in a folder, the
bill of materials, tasks and the build log**; a live image points at **any project file by
identity**, a photo showing itself and anything else its preview; the live content lives in the
file as **a directive plus a saved snapshot**, refreshed on every Save from the app, rendered live
on the page; and the mechanism is **one markdown emitter per source**, reused for the file and the
page, rather than partial-rendered regions.

## 1. Why, and what is there today

The project folder's README is rendered on the project page by `Maker::Readme` — read through the
port, capped, sanitised by `Maker::Markdown`, relative links resolved against the folder — and
edited in place by `projects/_readme_editor` (a lazy CodeMirror textarea posting to
`Projects::ReadmesController#update`, the one editing door that needs no repository). Two things
about where it sits are the request:

- **It is a card inside the Files panel** (`projects/_readme_card`, or the README half of the root
  repository card when the folder is a working tree). It cannot be moved, sized or hidden on its
  own, and on the public page it is pinned above the hero regardless of the layout.
- **Everything in it is static prose.** The owner's own catan README (2026-11-05) is a parts table
  whose cells link files by hand; every rename, addition and deletion in the folder makes it wrong
  until someone edits it.

The repo already has the pieces: a panel vocabulary the layout editor arranges
(`Maker::Project::PANELS`), content blocks that resolve a file by node id at render time, a
markdown renderer with a folder resolver and an image arm, a file chooser that can be rooted at a
folder, and a thumbnail map that enqueues what is missing.

## 2. The README panel

`readme` joins `Maker::Project::PANELS` as a fixed panel, first in the list, labelled **README** in
`PANEL_LABELS`, **full width by default** (`FULL_BY_DEFAULT`), and **leading every kind's default
order** (`Maker::ProjectKind::LEAD` becomes `readme attachments photos`). It is **not** in `ALWAYS`:
a maker may hide it, no preset does, and the layout editor brings it back.

A new `projects/_readme.html.erb` renders the panel: `<section class="panel readme-panel"
id="project-readme">`, a heading, the rendered markdown in `.markdown`, the note where there is one,
and the existing `projects/_readme_editor` as its door — so "Write a README" has a home when the
folder holds none. `panel_has_rows?("readme")` answers `@readme_row.present?`, so a page opened
with `?add=readme` renders it quiet like any other empty on-demand panel.

**What leaves:** `projects/_readme_card` is deleted, and `projects/_attachments` renders the root
repository card only for its git facts. `Maker::RepoCard.for` takes `readme:` (default `true`); the
root card is built with `readme: false` and `projects/_repo_card` renders no README region for it.
Nested repositories' cards are unchanged: their README is not the project's.

**Hidden means unread.** `ProjectsController#show` reads the README through the port only when the
panel is visible, which today's page pays for whether or not anyone looks. The template-hygiene and
query-budget tests that name the card move to the panel.

**The public page** adds `"readme" => "public/projects/readme"` to its `public_panels` map and
drops the fixed section above the hero: a visitor sees the README where the maker placed it, and a
hidden README is hidden there too, the rule every other panel already follows.

**Layout-edit mode** renders the panel through `projects/_panel_body` like every fixed panel, with
`editable: false`: that mode arranges the page, and a form inside a slot the editor drags is not
wanted.

## 3. The file format

A live region is two HTML comments on their own lines with the snapshot between them, each marker
separated from the body by a blank line (probed: kramdown swallows a table that starts directly
under a comment into one paragraph):

```markdown
<!-- tinkerex:files laser -->

| File | Kind | Size | Modified |
|---|---|---|---|
| [tile-edge-test.lbrn2](laser/tile-edge-test.lbrn2) | Laser | 50 KB | 2026-07-20 |

<!-- /tinkerex -->
```

**Grammar.** An opening marker is `<!-- tinkerex:<directive> [arguments] -->` alone on a line,
whitespace around the parts tolerated; the closing marker is `<!-- /tinkerex -->` alone on a line.
The body is everything between them. An opening marker followed by end of file, or by another
opening marker, with no closing marker in between is an **empty region** — that is how a
hand-typed directive works; the next Save fills it and adds the closing marker. Regions never nest.

**The five directives:**

| directive | argument | source |
|---|---|---|
| `files <path>` | a folder of the project, relative to the project folder (`laser`, `models/printed`); `.` is the root's loose files | the files directly under that folder |
| `bom` | none | the current BOM revision's lines |
| `tasks` | none | the project's tasks |
| `log [N]` | the newest N entries, default 10, at most 50 | the build log |
| `image <node_id> [caption]` | a node id; everything after it is the caption | one project file, by identity |

**The body is generated, on every render and every Save.** Whatever a maker types between the
markers is replaced, so editing inside a region loses that edit and nothing else. A directive the
app does not recognise, or one whose arguments do not parse, is **left as written** in the file and
on the page (the body renders; the markers are stripped like every other region's).

**Why comments:** GitHub, VS Code and this app's own file-page preview hide them, so outside the app
the README reads as the table or picture it held at the last Save. Finder shows raw text either way.

**Caps:** twenty regions per README (further ones are left as written); two hundred rows in a table,
then one line *… and N more*; `log` at most 50. The Save checks `FilesController::EDITABLE_MAX_BYTES`
against the **expanded** file (§6).

## 4. What each directive emits

One emitter per directive, each a small class under `Maker::Readme::Live`, writing plain GFM that
goes through the existing renderer. The same emitter answers for the file and the page; `image` is
the one place they differ, and it says so.

- **`files <path>`** — a table of **File, Kind, Size, Modified**, sorted by name. File is
  `[name](relative/path)` against the project folder; Kind is `Maker::FileAttachment::ROLE_LABELS`
  for the row's role (what the Files panel groups by); Size is the node's size in human form;
  Modified is the node's `mtime` as a date in the app's zone, `—` when unknown. Backups are left out
  (`Row#backup?`), and subfolders are not descended: the directive names one folder and lists its
  own files. A path that matches no folder of the project emits one italic line, *No folder `x` in
  this project.*
- **`bom`** — **Ref, Part, Qty, Supplier** over `current_bom.lines` in position order. Part is the
  line's target (`BomLine#target_kind`): the inventory item's name, a design file as
  `[name](relative/path)` when it is in the folder and its name otherwise, or the free-text
  `part_name`. Qty is `quantity unit`. Supplier is the supplier's name or blank. No BOM, or no lines,
  emits *No bill of materials yet.*
- **`tasks`** — a GFM task list in position order: `- [x] title` for `done`, `- [ ] title` for
  `todo`, `- [ ] title *(doing)*` for `doing`. kramdown's GFM parser renders these as disabled
  checkboxes (probed). No tasks emits *No tasks yet.*
- **`log [N]`** — **Date, Entry**, newest first by `logged_at`. Entry is **Milestone:** for a
  milestone entry, then the body's plain text squished and cut at 120 characters. No anchor links:
  the renderer rewrites `#fragment` into the README's own namespace, so a link to an entry would
  not land. No entries emits *No build log entries yet.*
- **`image <node_id> [caption]`** — the caption defaults to the file's name. A photo
  (`Maker::FileAttachment.inline_image?`) emits `![caption](relative/path)` in both modes. Any
  other file: **in the file** a link line, `[caption](relative/path)`, because an image tag whose
  source is an STL is a broken picture on GitHub; **on the page** `![caption](relative/path)`,
  which the image arm (§5) turns into the file's ready thumbnail — or, while the thumbnail is still
  rendering, the same link line as the file gets, which the next load fixes. A node that is not
  live in the project folder emits *This file is no longer in the project.* in both modes.

**Escaping.** Cell text has `|` escaped as `\|` and newlines squished; link text has `]` escaped;
paths are emitted as the catalog holds them. Everything then passes through `Maker::Markdown`'s
sanitiser as prose does, so nothing an emitter writes can reach the page as markup.

## 5. Rendering

**`Maker::Readme::Live`** (new, `app/services/maker/readme/live.rb` and one file per emitter under
`app/services/maker/readme/live/`) does three things:

1. **Parse** — `Live.regions(text)` scans for markers and returns the regions in order: directive,
   arguments, body range, and whether the region is closed. Pure string work, no I/O.
2. **Expand** — each recognised region's body is replaced by its emitter's output for a **mode**
   (`:page` or `:file`) against a **context**.
3. **Splice** — the result is the original text with each recognised region rewritten as marker,
   blank line, body, blank line, marker in `:file` mode, and as **the body alone** in `:page` mode.
   An unrecognised region is copied verbatim in `:file` mode and loses only its markers in `:page`
   mode — the markers are stripped for every region on the page, recognised or not, so nothing
   depends on how the sanitiser treats a comment.

**The context** (`Live::Context`) wraps what the caller already loaded and fills gaps lazily, one
query each, memoised: `listing` (paths, rows, dirs, `row_for`), `bom_lines`, `tasks`, `entries`
(with `rich_text_body`), `thumb(node_id)`, and the two link lambdas. The project page passes its
own ivars; a hidden BOM panel means `@bom_lines` is empty and the context loads the lines itself.
Query counts stay constant in N: `page_query_budget_test.rb` seeds a README holding all five
regions.

**Order on the project page.** `ProjectsController#show` reads and parses the README **before** it
builds `@page_thumbs`, so the `image` regions' node ids ride the page's one thumbnail query (and
are enqueued by it when missing), and renders **after**. `Maker::Readme.for` therefore splits:
`Maker::Readme.source(...)` returns the capped text plus the parsed regions (or the note), and
`Maker::Readme.render(source, context:)` expands and renders. A caller with no context (a nested
repository's card, `Maker::MarkdownFile`) renders the text as written with markers stripped.

**The image arm becomes node-aware, once.** Today the maker's image arm maps every issued `<img
src>` to the byte route. It becomes: an image file keeps the byte route; any other file resolves to
its **ready thumbnail** (`preview_src` over the context's thumb) and, with none ready, the `<img>`
is dropped — which is why the `image` emitter already writes a link in that case rather than an
image. The same split on the public page uses `file_url_for` and `preview_url_for`. This also fixes
a maker's hand-written `![x](models/robber.stl)` in prose, which renders broken bytes today.

**The public page** builds a context from `Maker::PublicProject`'s own memoised readers and renders
**every** directive, tasks included: the maker put the region in the README deliberately, and the
bundle already ships the file with its snapshot. Its link lambdas are the public byte and preview
URLs; a BOM part that is an inventory item is a name, not a link.

**The file page and the MCP** are unchanged: `Maker::MarkdownFile` renders the file as it is,
snapshot showing, markers stripped; `read_text_file` returns the bytes.

## 6. Saving

`Projects::ReadmesController#update` builds a context from the listing and expands the posted text
in `:file` mode **before** the existing checks and `Maker::TextSave`, so the snapshot is as fresh as
the Save and an empty region is filled and closed. Order of refusals, unchanged where they exist:
no folder; blank body; **expanded** body over `EDITABLE_MAX_BYTES` — "This README is too large to
edit here once its live tables are filled in."; the README on disk over the cap; then the stale,
removed, clobber and unreachable arms as today. The door still takes no node id, name or parent, so
the one-door rule in `docs/invariants/git-editing.md` does not loosen; that file gains one line
saying the door expands regions.

A README saved from the Files page, or edited in Finder, keeps its old snapshot until the next Save
from the panel. The page is live either way. Nothing here writes to the file on a scan, a BOM edit
or a task change — the owner chose this over an app that rewrites the file, which would cost a
write per change, a version per write on `chunk_remote` and a pending edit per write in a working
tree.

## 7. The editor

`projects/_readme_editor` keeps its lazy CodeMirror buffer, its disabled-until-loaded controls, its
draft-on-refusal behaviour and its no-JavaScript fallback, and gains an **Insert bar** above the
mount with five controls, all handled by the existing `readme` Stimulus controller (no new
identifier):

- **Files table** — a small menu, rendered by the partial from `@listing`: *Root files* (`.`) and
  each first-level subfolder by name. Choosing one inserts a `files <path>` region at the cursor.
- **Bill of materials**, **Tasks**, **Build log** — insert their one-line directive.
- **Image** — opens the Miller-columns chooser in `file` mode rooted at the project folder
  (`chooseFile({ childrenUrl, rootId: <folder node id>, rootLabel: <folder name> })`), so the pick
  cannot leave the project; a pick inserts `image <nodeId> <name>`, the name standing as a caption
  the maker may replace.

Every insert writes the opening marker, a blank line and the closing marker, then moves the cursor
below. **On load the controller collapses each region to its opening line**: the bodies are
generated, editing them is wasted, and the server regenerates them regardless of what is posted
(the collapse is a courtesy, not a rule). Nothing new is pinned — CodeMirror is one bundle, the
chooser and thumbnails exist — and the inserts are plainly absent without JavaScript, where a
directive can still be typed by hand.

## 8. Edge cases

- **A source that is gone** — a folder removed, a file trashed or moved out of the project — emits
  its one italic line in both modes; nothing is dropped silently.
- **Markers out of shape** — a second opening marker before a closing one ends the previous region
  empty; a closing marker with no open region is ordinary text.
- **Paths** are matched as strings against the listing's folder paths after `cleanpath`, never
  against the disk; `..` climbs to nothing and emits the missing-folder line.
- **Node ids** are matched against the listing's rows; anything else is "no longer in the project".
- **Caps** are applied in order of appearance; a region past the twentieth is left as written.
- **Thumbnails not ready** fall back to the link form on the page; the thumbnail map enqueues the
  render, so a reload shows the picture.
- **Nested repository READMEs**, the file-page preview and the MCP never expand.

## 9. Not changed, and out of scope

The README's names and preference order, caps and read limit, `Maker::Markdown`'s sanitising and
anchor rules, `Maker::TextSave`, the stale and clobber refusals, the no-history note, the public
bundle (which ships the file as it is) and the demo seed are unchanged. Refreshing the demo seed's
catan README with a live region, and expanding the README on a Save from the Files page, are
follow-ups, not part of this.

## 10. Testing

- **`test/services/maker/readme/live_test.rb`** over an in-memory listing: the grammar (open and
  close, unclosed, nested opener, unknown directive left as written, the region cap), each emitter
  (sort order, labels, sizes and dates, the `.` root, the missing-folder line, BOM target kinds,
  task statuses, log order and cap and the milestone prefix, escaping of `|` and `]`), and the
  `image` split asserted as **the only difference** between `:file` and `:page` output over a README
  holding every directive.
- **`Projects::ReadmesController`**: a Save writes the snapshot, read back through the port on all
  three backend legs; a tampered body is replaced; an unclosed directive is closed; the size cap is
  checked on the expanded text; the stale and blank refusals are untouched.
- **Project page**: the panel renders at `#project-readme` with a live files table; `readme` hidden
  costs no port read (counted through a port spy, as `library_unreachable_test.rb` does); the
  repo-root case renders git facts in the card and the README in the panel; layout-edit mode renders
  the panel without the door; `page_query_budget_test.rb`'s seed holds all five regions and the page
  stays constant in N.
- **Public page**: the README renders in layout order, hidden stays hidden, regions expand with the
  public byte and preview URLs, and a photo versus a model split the image arm.
- **Vocabulary**: `project_kind_test.rb`'s "opens with Files then Photos" becomes "README, Files,
  Photos"; `PANEL_LABELS` totality holds; `template_hygiene_test.rb` names the panel.
- **Mutation checks** before any of these counts: the card back in Files (panel test red), the blank
  line out of the splice (table test red), the image split removed (file-mode test red).
- Bare `bin/ci` on all three backend legs, with identical RUN counts.

## 11. Files touched

`app/models/maker/project.rb`, `app/services/maker/project_kind.rb`, `app/services/maker/readme.rb`,
`app/services/maker/readme/live.rb` (+ `live/*.rb`), `app/services/maker/repo_card.rb`,
`app/services/maker/public_project.rb`, `app/controllers/projects_controller.rb`,
`app/controllers/projects/readmes_controller.rb`, `app/helpers/projects_helper.rb`,
`app/views/projects/_readme.html.erb` (new), `_readme_editor.html.erb`, `_attachments.html.erb`,
`_repo_card.html.erb`, `_readme_card.html.erb` (deleted), `app/views/public/projects/_readme.html.erb`
(new), `_page.html.erb`, `app/javascript/controllers/readme_controller.js`,
`app/assets/stylesheets/pages/projects.css`, `docs/invariants/git-editing.md`, and the tests in §10.
