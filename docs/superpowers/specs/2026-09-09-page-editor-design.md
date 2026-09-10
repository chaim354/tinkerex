# The page editor: arrange a project's page in place, and share the arrangement as YAML

**Date:** 2026-09-09. **Status:** approved in conversation (owner), slice 1 of the project-page
configurator. **Stories:** 6.5 (a maker arranges the project page), with 5.x (the visitor sees
what the maker arranged) as the mirror.

## 1. Why, and what is already there

A project page is a list of panels: ten fixed ones (Files, Photos, Schematics, Build log, Tasks,
BOM, Wiring, Releases, Sheets, Publish) and, since 2026-09-08, one panel per depth-one folder of
the project's folder. `Maker::ProjectKind::Layout` answers the order, the hidden set and each
panel's view from the `panels` JSON column layered over the project type's preset; the public page
renders the same layout for a visitor.

What a maker can change today, and how: show or hide a panel and move it up or down, through a
`<details>` chooser of checkboxes and arrow buttons closed by default at the bottom of the page;
and each panel's view (tiles, list, browser) through a toggle on the panel that saves at once.
That is the whole of the customisation, and it is hard to find and slow to use: one request per
arrow click, no way to see the result while choosing, and nothing to share.

The owner asked for "an editor/configurator for the project page so people can set it up how they
like", then, in brainstorming, for eight capabilities. They were split into six slices, each
shippable alone, and this spec is the first:

| slice | what | status |
|---|---|---|
| 1 | **the page editor** — reorder, hide, view, width, rename and intro per panel, in place, with a YAML view to copy and paste | this spec; shipped 2026-09-09 (PR #349, arc tinkerex#301) |
| 2 | content blocks — text, link and image blocks between panels; hero and description edited from the same mode | shipped 2026-09-09 (PR #350, arc tinkerex#303; `2026-09-09-content-blocks-design.md`) |
| 3 | tabs — group panels into tabs below an always-visible top group, modelled as separators in the same flat order | shipped 2026-09-09 (PR #351, arc tinkerex#305; `2026-09-09-tabs-design.md`) |
| 4 | a separate public layout, edited from the Preview page with the same editor | next: brainstorm begun 2026-09-09, no spec yet |
| 5 | templates — save an arrangement by name, apply it to another project, make it a type's default | later |
| 6 | per-project look — accent colour, banner, title style, within the design tokens | later |

The editor comes first because it decides the interaction every later slice plugs into.

## 2. The editor

**Entry.** A "Customise page" button in the page head, beside Edit. It opens the same project
page at `/projects/<slug>/layout` with the edit chrome on. Owner only: the route sits behind the
same signed-in, own-projects scoping as the page itself; a visitor's page has no such mode.

**Per panel, a control strip in the panel head:**

- a drag handle — the only place a panel can be picked up, so text inside a panel still selects;
- Up and Down buttons, quiet but always present, so ordering is never mouse-only;
- a pencil that opens a small popover with two fields, title and intro. The title replaces the
  panel's heading; the intro renders as one muted line under the heading, on both pages;
- an eye that hides the panel. A hidden panel stays exactly where it is, ghosted, with a Show
  button, so it can still be dragged and shown again without the bottom-of-page list the old
  chooser needed for that;
- a Full / Half width switch;
- the view switch, for the panels that offer one: tiles and list for Files, all three for a folder
  panel, none for the rest (`Maker::ProjectKind.offered_views` is the one definition, unchanged).
  Changing the view re-fetches that panel's body, so what you see is the real tiles, list or
  browser for this folder, not a stand-in.

**Fixed rules kept.** Files, Photos and Publish stay always shown (`Maker::ProjectKind::ALWAYS`,
unchanged); their eye is replaced by the words "always shown". Publish is also always last: it is
the page's settings box and the head's "Publish" link anchors to it, and a settings box that can
be dragged above the maker's own content is the thing S4-4 argued against. The editor does not
offer to drag it, and a pasted layout that lists it elsewhere gets it moved to the end with a note.

**Titles are display-only.** Renaming the "models/" panel to "Prints" never touches the folder,
and the strip still shows the folder's real name in small type beside the title so the two cannot
be confused.

**Draft, then Save.** Nothing persists until Save. Every change — a drag, a toggle, a rename, an
Apply from the drawer — updates a draft the browser holds and re-renders the page from it. Save
writes the whole draft in one request and returns to the page. Cancel returns to the page and
drops the draft. Reset, after a confirm, removes the project's override entirely (the existing
delete on the panels door) so the page follows its type's defaults again — widths, titles and
intros included.

**The YAML drawer.** "Edit as YAML" in the top bar opens a drawer beside the page. Its text is
the current draft as YAML (§4), regenerated after every change, so a maker learns the format by
watching it follow their drags. Apply parses the text, replaces the draft with the result,
re-renders the page, and reports notes and errors inline below the text; Copy copies the text.
Apply never writes; Save does. The page stays editable while the drawer is open.

**What changes on the normal page.** The inline tiles/list toggles stay and keep saving at once —
they are a quick switch, not an arrangement. The bottom "Panels" chooser is retired: its checkbox
form, its arrow buttons, the `panels=open` render hint and the door branches that served only it
go, and "Customise page" takes its place.

**Visitors** see the same order, hidden set, views, widths, titles and intros on the public page.
A separate public layout is slice 4.

**JavaScript is required** for the editor. Without it the edit page renders the panels as usual
and one line in the top bar says the editor needs JavaScript; no control does anything. This is
deliberate: a draft that lives in the browser has no no-script equivalent short of a second,
per-click write path, which is the shape the retired chooser had and this spec removes.

**Narrow screens.** The same controls render; below the two-column breakpoint the width switch
still works and its label adds "on wide screens", because half-width panels stack there anyway.

## 3. The layout model

**The column.** `maker_projects.panels` (JSON, no migration) gains three maps beside today's
`order`, `hidden` and `views`, all keyed by panel key:

```json
{ "order":  ["attachments", "folder:5c32…", "photos", "build_log", "wiring", "tasks", "publish"],
  "hidden": ["wiring"],
  "views":  { "attachments": "tiles", "folder:5c32…": "list" },
  "widths": { "photos": "half", "build_log": "half" },
  "titles": { "folder:5c32…": "Prints" },
  "intros": { "folder:5c32…": "Everything you need to print, sliced for 0.2 mm." } }
```

Folder panels keep their node-id keys in the column, with the consequence already recorded for
folder panels: on share and s3 a renamed folder is a new folder to the layout and its placement,
view, width, title and intro reset; on chunk_remote the id survives the rename. Only the YAML
(§4) names folders by name.

**The struct.** `Maker::ProjectKind::Layout` gains `widths`, `titles`, `intros` and three readers:
`width_for(key)` ("full" or "half"), `title_for(key)` (the custom title, else the default label
— `Maker::Project::PANEL_LABELS` for a fixed panel, the folder's name for a folder panel) and
`intro_for(key)` (the intro or nil). `layout_for` filters the three maps to the vocabulary and to
legal values the way it already filters `views`, so the column can never hand the page a width it
does not know.

**Default widths move out of the stylesheet.** Today `pages/projects.css` names
`.attachments-panel, .photos-panel, .folder-panel` as the panels that span both columns. That rule
becomes data: `Maker::ProjectKind.default_width(key)` answers "full" for Files, Photos and every
folder panel and "half" for the rest, and both pages render a `panel--full` or `panel--half`
class the sheet keys on. Every existing project renders identically after the change.

**Limits.** A title is plain text, up to 60 characters; an intro is plain text, one line (newlines
collapsed to spaces), up to 200 characters. Both are escaped on render and never markup. A blank
title means "use the default", not an empty heading.

## 4. The YAML, version 1

The drawer's text and the shareable artefact are one format. It names panels by key and folders
by **name** — the depth-one folder's name under the project folder — so a layout copied from one
project applies to another project with the same folder names.

```yaml
# Desk Lamp, page layout. Paste into another project's editor to reuse it.
layout: 1
panels:
  - panel: attachments
    width: full
    view: tiles
  - folder: models
    title: Prints
    intro: Everything you need to print, sliced for 0.2 mm.
    width: full
    view: list
  - panel: photos
    width: half
  - panel: build_log
    width: half
  - panel: wiring
    width: half
    hidden: true
  - panel: tasks
    width: half
  - panel: publish
    width: half
```

**Grammar.** A mapping with `layout` (the integer 1) and `panels` (a list). Each entry is a
mapping naming exactly one of `panel` (a fixed key from `Maker::Project::PANELS`) or `folder`
(a folder name), plus any of `title`, `intro`, `width` (`full` | `half`), `view` (`tiles` |
`list` | `browser`, only where that panel offers it), `hidden` (`true` | `false`). Order is the
list order. Nothing else is accepted: an unknown top-level key, an unknown attribute, or an entry
naming both `panel` and `folder` is an error, because the format's job is to be typed by hand and
a silently ignored misspelling is how a hand-typed `hiden: true` does nothing for a week.

**Export** (draft → text) writes a two-line comment header naming the project, then every panel of
the current layout in order, hidden ones included: `width` always (it is the thing people most
want to share), `view` where the panel offers one, and `title`, `intro` and `hidden` only when set.
Strings are quoted where YAML needs it.

**Apply** (text → draft) merges into the current draft rather than replacing it:

1. listed entries take the order given and the attributes given; an attribute not given keeps the
   draft's current value;
2. panels of this project the text does not mention keep their current settings and follow the
   listed ones in their current relative order — a layout shared from a smaller project therefore
   hides nothing here (chosen over "treat the text as complete", which would hide a folder the
   other project never had);
3. a `folder:` this project lacks is skipped, with a note naming it;
4. `hidden: true` on an always-shown panel is ignored, with a note; `publish` listed anywhere but
   last is moved to the end, with a note;
5. a `view` a panel does not offer, a bad `width`, a title or intro over its limit, an unknown
   `panel:` key, an unknown attribute, a `layout:` other than 1, a document over 16 KB, or YAML
   that does not parse is an **error**; errors block Apply and leave the draft untouched. A
   `layout:` above 1 says "newer than this server".

Notes are shown and do not block. Parsing is `YAML.safe_load` with no permitted classes, on the
server only; the browser never parses or emits YAML (§5).

**The draft itself**, as the browser holds it and as Save posts it, is JSON keyed by panel key:
`{ "layout": 1, "panels": [ { "key": "folder:5c32…", "hidden": false, "width": "full",
"view": "list", "title": "Prints", "intro": "…" }, … ] }`. It is the same document with node ids
in place of folder names; `Maker::LayoutDocument` converts between the two, and only it does.

## 5. Architecture

**One page, two modes.** `GET /projects/:id/layout` routes to `ProjectsController#show` with an
`editing` default, so the edit page loads exactly what the page loads and
`page_query_budget_test.rb` pins it the same way. When editing, the view renders the top bar, the
strip in every panel head, the drawer and the draft as escaped JSON for the controller to read.

**Three read-only helpers**, `Projects::LayoutsController`, owner-scoped like the page:

- `POST /projects/:id/layout/yaml` — draft JSON in, YAML text out (the drawer's refresh);
- `POST /projects/:id/layout/parse` — YAML text in, `{ draft, notes, errors }` out (Apply);
- `GET /projects/:id/layout/panel?key=…&view=…` — one panel's body rendered for that view (the
  view switch). It renders the same partial the page renders, with the view as a local.

None of the three writes anything.

**One write.** Save posts the draft to `PATCH /projects/:id/panels` as a `layout` parameter. The
door gains a document branch: `Maker::LayoutDocument` validates and normalises it, and one
`update!` writes the six-map column. The door keeps its `view` branch (the inline toggle) and its
delete (Reset); its per-click `move` and `visible` branches go with the chooser. A document
naming a folder key that is no longer in the project's vocabulary (renamed on disk mid-edit) is
saved without that entry, with a notice, matching rule 3 above.

**`Maker::LayoutDocument`** owns the format: export, parse, the merge rules, the limits, the
conversion between names and keys, and the column shape it produces. It is the only place the
YAML grammar is written down in code. It takes the project's layout, its depth-one folders and
its kind; it does not read the database itself.

**The client** is one Stimulus controller, `layout_editor`, mounted on the page's panel grid in
edit mode. It owns the draft; wires SortableJS on the grid (handle-only, a ghost class while
dragging, Publish excluded); handles the eye, the width switch, the Up/Down buttons, the pencil
popover and the view switch (fetching the panel body); keeps the drawer's text fresh with a
debounced request after each change; posts Apply; and submits the Save form with the draft in a
hidden field. Cancel is a link. `test/stimulus_hygiene_test.rb` picks the controller up from its
filename; the edit page names it in `data-controller`.

**SortableJS** (MIT, about 45 KB minified) is vendored through the importmap with
`bin/importmap pin sortablejs --download`, its licence beside the other vendored notices, one
pin. Hand-rolled pointer-event dragging was considered and rejected for this slice: touch,
auto-scroll on a long page and drop placement in a two-column grid are each a week of edge cases
the library has already had, and the licence is permissive (§9).

**Styles** follow `docs/invariants/design-system.md`: the top bar, the strip, the ghost state, the
popover and the drawer are components defined in `components.css` on the design tokens, so they
hold in both themes; the page sheet keeps only the grid rule, now keyed on `panel--full`.

**The public page** reads widths, titles and intros through `Maker::PublicProject#layout`, which
already returns this layout, and renders the same classes and heads. The download bundle is
unaffected.

## 6. Errors and edges

- **Bad YAML or a schema error:** the drawer lists the errors, with the line and column where
  Psych reports one; the draft and the page are untouched.
- **A folder renamed on share or s3 while editing:** its key drops out of the vocabulary; Save
  proceeds without that entry and says so. The renamed folder appears at its default place, view
  and width, which is the existing folder-panels rule, not a new one.
- **Two tabs editing:** the last Save wins, whole. The column has no optimistic lock today and this
  slice adds none; a lost arrangement is recoverable by redoing it, and the YAML makes redoing
  cheap. Recorded, not solved.
- **A failed panel re-render** (network, 5xx): the strip keeps the chosen view, the old body stays
  on screen, a toast says the preview did not load, and Save writes the view the maker chose.
- **Save fails validation** (a crafted or stale document): the edit page re-renders with the
  errors in the top bar and the draft intact.
- **Security.** Titles and intros are plain text, escaped on both pages; the draft JSON is embedded
  with `json_escape`; YAML is parsed with `safe_load`, capped at 16 KB, and is never rendered as
  markup. The three helpers and the door are owner-scoped; a visitor cannot reach the edit mode,
  the helpers or the write.
- **Query cost.** The edit page adds no query per panel: the strip reads the layout, the labels
  map and the folders the page already loaded. Pinned by the budget test.

## 7. Testing

**Unit** — `Maker::LayoutDocument`: export → parse → the same draft for a layout with every
attribute set; each merge rule (an unmentioned panel keeps its place; a missing folder is skipped
with a note; `hidden` on an always-shown panel is ignored with a note; `publish` is moved last
with a note); each error (unknown key, unknown attribute, both `panel` and `folder`, a view not
offered, a bad width, over-limit title and intro, `layout: 2`, over 16 KB, unparsable text); names
↔ keys conversion. `Maker::ProjectKind`: `default_width`, the three maps filtered to the
vocabulary, `title_for`'s fallback, totality with the new maps.

**Integration** — the edit page renders the bar, a strip per panel and the drawer for the owner
and 404s for anyone else; the three helpers answer for the owner and 404 otherwise; Save writes
one document and the column holds all six maps; Reset clears widths, titles and intros; the
public page renders `panel--full`/`panel--half`, custom titles and intros, and omits hidden panels;
the query budget is constant on the edit page; the old chooser's form is gone (`assert_select
"#panel-visibility", count: 0`); the template-hygiene and Stimulus-hygiene sweeps cover the new
partials and controller; every existing project's default widths equal today's CSS rule.

**System (Chrome)** — drag a panel by its handle below another and Save → the order is persisted
and the page shows it; switch a panel to Half → the class changes and persists; rename a folder
panel through the pencil → the heading updates and persists, the folder's name is unchanged; open
the drawer, edit the text, Apply → the page re-renders; paste a layout naming a folder this
project lacks → the note appears and the rest applies; Up/Down buttons reorder by keyboard alone;
no SEVERE console message throughout.

**Every guard is mutation-checked** (CLAUDE.md §15): each rule above is broken once and its test
seen red before the slice is called done.

## 8. Decisions a future editor might undo

1. **The editor is the page.** Not a drawer beside a static page and not a settings page: the
   owner chose in-place editing from three mockups, and it keeps the repo's rule that a choice
   lives on the page it is about.
2. **Server-side YAML only.** One implementation of the format, in Ruby, behind two helpers; the
   browser moves JSON. A client-side YAML library would be a second grammar to keep in step.
3. **Apply merges; it does not replace.** A shared layout hides nothing the other project never
   had. The alternative was offered and declined.
4. **Folders by name in the YAML, by node id in the column.** Names are what travel between
   projects; ids are what survive a rename on chunk_remote. `Maker::LayoutDocument` is the only
   translator.
5. **Errors block, notes inform, and a misspelling is an error.** The format is typed by hand.
6. **Default widths are data, not CSS.** The stylesheet cannot be shared as YAML; the layout can.
7. **The chooser is retired, not kept beside the editor.** Two ways to arrange one page drift.
   Its per-click door branches go with it; the inline view toggle stays because it is a switch,
   not an arrangement.
8. **JavaScript is required for editing.** The alternative is a second write path per control.
9. **SortableJS is vendored** rather than hand-rolled, for touch and auto-scroll; MIT.
10. **Save posts the draft JSON, not the drawer's text**, so a refresh still in flight cannot make
    Save write stale text; the drawer is a view of the draft, never its source of truth.
11. **Publish is always last.** New in this slice; the reason is in §2.
12. **The layout lives in the database.** A `tinkerex.yml` in the project folder — written by the
    editor, read back when its content token changes, travelling with the repo and the bundle —
    was designed and offered; the owner chose the in-editor YAML for this slice. The file remains
    the natural mechanism for slice 5, and this format is written so the file can hold it
    unchanged.
13. **Settled in execution (2026-09-09):** the strip sits along the TOP EDGE of the panel card, in the
    slot wrapper, not inside the panel head — ten partials own their heads and the wrapper touches
    none of them. A Save that fails validation returns to the editor with the errors as an alert
    and does not retain the draft; the only reachable cause, a folder renamed mid-edit, is handled
    by dropping the entry with a notice. A failed panel preview keeps the CHOSEN view in the draft
    and says the preview did not load. Export quotes strings where YAML needs it, in Psych's own
    style. The draft is read off the slots' data attributes rather than an embedded JSON blob.
    Publish is normalised last on the way out of `layout_for`, so a row the retired chooser wrote
    with Publish mid-page renders it last from now on.

## 9. Out of scope

Slices 2 to 6 (§1). Also: dragging between the two columns as a distinct gesture (width is a
switch, position is order); per-viewport layouts; a history of arrangements or undo beyond Cancel;
an optimistic lock on the column; hiding Files, Photos or Publish; importing a layout from a file
upload (paste is the door); the public page's own editor.
