# Tabs: groups of panels below an always-visible top, in the same flat order

**Date:** 2026-09-09. **Status:** approved in conversation (owner), slice 3 of the project-page
configurator. **Builds on:** `2026-09-09-page-editor-design.md` (slice 1: the edit mode, the slot
per panel, `Maker::LayoutDocument`, the YAML) and `2026-09-09-content-blocks-design.md` (slice 2:
blocks, the page intro, the packed grid). **Stories:** 6.5 (a maker arranges the project page),
5.x (the visitor sees what the maker arranged).

## 1. Why

A project page with the README, the photos, a build log, tasks, a BOM, three folder panels and a
few blocks is a long scroll, and everything on it has the same weight. The owner asked, in the
configurator brainstorm, to "group panels into tabs". Slice 3 gives the page groups without giving
it a second layout model: a group is a **separator in the same flat order** the editor already
drags, the YAML already carries and Apply already merges. What comes before the first separator
stays on view; the rest becomes tabs.

Three shapes were drawn and one chosen (§10, decision 1): tabs below an always-visible top group,
over a page of headed sections and over tabs that swallow the whole page. The README and the
pictures are what a visitor came for; the rest is one click away.

## 2. The tabs

**On the page** (the maker's and the visitor's, the same): the panels before the first separator
render as today, in the packed grid; then a **tab bar** with one tab per group; then one **pane**
per tab, each its own packed grid, one pane shown at a time; then **Publish**, below the panes, on
view whichever tab is open. A project with no separator renders exactly today's page.

**A tab is a separator.** It has a name and a place in the order, nothing else: no width, no
view, no intro, no hidden flag. The panels and blocks after it, up to the next separator, are its
group. Hiding happens per panel as today; a tab whose panels are all hidden is not shown. The top
group may be empty, in which case the bar sits directly under the head.

**In the editor** the flat list stays flat: a separator is a full-width slot among the panel slots,
with a drag handle, the word *Tab*, a name box, a count hint ("3 panels", "empty") and Delete.
**Add tab** sits in the top bar beside Add block and drops a new empty tab at the bottom, just above
the pinned Publish, with its name box focused; drag panels under it or drag it up. Delete removes
the separator only; its panels join the group above. Nothing persists until Save.

**Publish is pinned below the tabs.** It is the head's `#publish` anchor and it is already the slot
the editor refuses to drag past; a separator cannot be dropped after it, so no group can hold it.

**Limits.** Eight tabs per page. A name is plain one-line text, 1 to 30 characters after whitespace
is collapsed, unique within the project ignoring case. A tab with no name is refused, not defaulted.

**Phones.** Tabs on every width; the bar scrolls sideways when it does not fit. Nothing changes
shape between a phone and a desktop, and a shared tab link means the same thing on both.

## 3. The layout model

**No migration.** A tab is an entry `tab:<key>` in the existing `order` list, `key` being 12 hex
characters minted on Save (`Maker::ProjectKind.new_tab_key`, `SecureRandom.hex(6)`), and its name
is the entry under that key in the existing `titles` map. A tab's name is arrangement, not content,
which is why it lives in the column where a block's text does not (§10, decision 2).

```json
{ "order":  ["attachments", "photos", "tab:3f9a1b2c4d5e", "build_log", "tasks", "block:7e1c…",
             "tab:a0c4d8e2f611", "folder:5c32…", "releases", "publish"],
  "titles": { "tab:3f9a1b2c4d5e": "Build", "tab:a0c4d8e2f611": "Downloads", "folder:5c32…": "Prints" } }
```

**Vocabulary.** `Maker::ProjectKind.layout_for` reads the tab keys off the stored `order` itself
(entries matching `tab:` plus 12 hex characters): the key's presence is the tab, there is no row to
consult. The vocabulary becomes fixed keys plus folder keys plus block keys plus those tab keys, so
`known` keeps them in `order` and `titles` keeps their names. The other maps ignore tab keys:
`hidden`, `views`, `widths` and `intros` are filtered to the vocabulary **without** the tab keys,
so a stray `hidden` on a tab in a stored column is dropped rather than honoured. Totality holds as
it does for every other key: a tab key with no name renders as "Tab"; a ninth or later tab key is
dropped from the order and its panels join the group before it. `TAB_CAP = 8` and
`TAB_NAME_MAX = 30` live beside `TITLE_MAX`; a stored tab name is a title and obeys the
60-character storage rule, which a 30-character name always satisfies — the document is the only
writer and it enforces 30.

**The struct.** `Maker::ProjectKind::Layout` gains `tab?(key)`, `tabs` (the tab keys in order),
`tab_name_for(key)` (the title, else "Tab") and **`groups(keys = visible)`**, the one reader both
pages render from: it walks the given keys, drops `publish`, and answers `Groups(top:, tabs:)`
where `top` is the keys before the first tab key and each `Tab(key:, name:, keys:)` holds the keys
up to the next tab key. `groups(visible)` is the page; `groups(order)` is every group hidden or not.
The pages also need "which tabs have anything to show", and answer it after rendering (§6).

**Slugs.** A tab's place in a URL is `#tab-<slug>`, the parameterized name (`build`,
`downloads`); when a name parameterizes to nothing, or two tabs would share a slug, each such tab's slug is
its key. Renaming a tab changes its slug, and an old link lands on the first tab (§8).

**Reset** (the existing DELETE) removes the override; tabs live only in the override, so Reset
removes them. The confirm names them.

## 4. The document

**The draft** gains tab entries with a `kind` of `tab` and a `name`, nothing else:

```json
{ "layout": 1,
  "panels": [
    { "key": "attachments", "hidden": false, "width": "full", "view": "tiles" },
    { "key": "photos", "hidden": false, "width": "full" },
    { "key": "tab:3f9a1b2c4d5e", "kind": "tab", "name": "Build" },
    { "key": "build_log", "hidden": false, "width": "half" },
    { "key": "tab:new-1", "kind": "tab", "name": "Downloads" },
    { "key": "folder:5c32…", "hidden": false, "width": "full", "view": "list", "title": "Prints" },
    { "key": "publish", "hidden": false, "width": "half" } ] }
```

A tab added in this session has a `tab:new-<n>` key until Save assigns a real one, exactly as a
block does; `from_draft` refuses a tab entry carrying `hidden`, `width`, `view`, `title` or
`intro` ("Entry n: a tab takes only a name").

**The YAML** gains one entry shape:

```yaml
  - tab: Build
    id: 3f9a1b2c4d5e
```

`tab` is the name; `id` is the key, written by every export like a block's. **Apply** resolves a
`tab:` entry in this order: an `id:` this project knows names that tab (so a rename in the text
renames); otherwise a tab of this project with the same name ignoring case names that tab (so a
layout pasted from another project maps *Build* onto *Build* rather than making a second one);
otherwise it creates one, `tab:new-<n>`. A tab entry accepts `tab` and `id` and nothing else; any
other attribute is an error, `hidden: true` included. Two entries resolving to one tab, or two
entries with one name, fall to the existing repeated-entry error. A name blank after whitespace
collapse, or over 30 characters, is an error; a merged draft with more than eight tabs is an error
("This page can hold 8 tabs; the text names 9."). Every error blocks Apply and leaves the draft
untouched, as slice 1 set down.

**Merge** treats a tab like any entry: listed tabs take the order given; a tab the text does not
mention keeps its place among the unmentioned entries, which follow the listed ones in their
current relative order. That rule can move a panel from one group to another when a text lists some
entries and not others — the same way it already moves a panel under a different neighbour — and
the drawer shows the result before anything is saved. Apply never removes a tab; **Save writes the
order as posted**, so a tab absent from the posted draft is gone: Delete then Save removes one, the
text alone cannot.

**Export** writes tabs in place: `- tab: Build` with its `id`, then the entries of its group.

**`column(draft)`** puts tab keys in `order` and their names in `titles`, never in `hidden`,
`widths`, `views` or `intros`. `entry(key)` for a tab is `{ key, kind: "tab", name }`.

## 5. Doors

- **Save** (`Projects::PanelsController#replace`) changes in one place: `rekey` maps `tab:new-<n>`
  to `tab:<minted key>` as it maps `block:new-<n>`, in `order` and in `titles`. No rows, no
  transaction change; the query budget is flat.
- **Helpers** are unchanged: `yaml` exports tabs, `parse` applies them, `preview` is untouched.
- **Reset** is unchanged in mechanism; its confirm text names tabs among what goes.
- **The editor root** renders `data-layout-editor-tab-cap-value` from `TAB_CAP` beside the block
  cap, and the bar disables Add tab at the cap with the cap said out loud, like Add block.

## 6. Rendering

**One shape, two pages.** `projects/show` (not editing) and `public/projects/_page` render from
`layout.groups(visible)`:

1. **No tabs:** today's markup, unchanged — one `.project-panels` grid with every visible key
   including Publish. This branch is byte-for-byte the current template so every existing project
   is untouched.
2. **Tabs:** the top group's `.project-panels` grid (omitted when the top group is empty); then
   `div.tabs[data-controller="tabs"]` holding `nav.tab-bar[role="tablist"]` with one
   `a[role="tab"][href="#tab-<slug>"]` per shown tab, and one
   `section.tab-pane[id="tab-<slug>"][role="tabpanel"]` per shown tab, each opening with
   `h2.tab-heading` (the name) and holding its own `.project-panels` grid with the masonry
   controller; then a final `.project-panels` grid holding Publish — and, on the public page, the
   repository cards before it, so both are on view whichever tab is open.

**A tab is shown only if something in it renders.** The public page already captures each panel's
body and skips empty ones (wiring with no connections, an image block whose file is not permitted);
both pages capture a pane's bodies first and drop a pane with none, and the bar lists only the
panes that survived. A page whose every tab dropped renders as the no-tabs branch's structure with
the top group and Publish.

**The `tabs` controller** (`tabs_controller.js`) shows one pane and hides the headings: it adds
`tabs-ready` to its element, marks one tab `aria-selected` and one pane active, and the sheet hides
the other panes and every `.tab-heading` under `.tabs-ready`. Which one: the hash `#tab-<slug>`
names a tab; a hash that targets an element inside a pane (`#tasks`, a panel's anchor) opens that
pane and then scrolls to the element; otherwise the first tab. A click on a tab prevents the
navigation, shows the pane and rewrites the hash with `history.replaceState`, so the URL is
shareable without a history entry per click; `hashchange` is honoured for links on the same page.
Left, Right, Home and End move between tabs with the roving `tabindex` the ARIA tabs pattern
prescribes. **Without JavaScript** nothing is hidden: every pane renders with its heading, the bar's
links are ordinary anchors to the panes, and the page reads as headed sections.

**Packing.** Each pane's grid carries its own masonry controller. A hidden pane measures zero; when
the tabs controller shows it, the `ResizeObserver` reports the change and the pane re-spans. The
browser test opens a tab by click and asserts the spans are set.

**Phones.** `.tab-bar` is a flex row with `overflow-x: auto` and no wrapping; the grids inside panes
are the single column they already are below the two-column breakpoint.

**Edit mode** renders the flat `order` as today; `_panel_slot` branches for a tab key to the
separator slot: `div.panel-slot.panel-slot--tab.panel--full` with `data-key`, `data-kind="tab"`,
`data-name`, the handle, the *Tab* label, `input.tab-name[maxlength=30]` whose input updates
`data-name`, the count hint, and Delete. It is a `.panel-slot`, so SortableJS drags it and the
existing `onMove` rule keeps Publish last. `draft()` reads it as `{ key, kind: "tab", name }`.
`addTab` clones a `<template>` beside the block templates, inserts the slot before the pinned
Publish, focuses the name box, and at the cap adds nothing and toasts the cap. `adopt` (after
Apply) mints separator slots for tab keys it does not hold and renames those it does. The count
hint is recomputed on every change: the slots between this separator and the next or Publish,
hidden ones included.

**Styles** in `components.css`: `.panel-slot--tab`, `.tab-name`, `.tab-bar`, `.tab-pane`,
`.tab-heading`, `.tabs`; registered in `test/css_hygiene_test.rb`'s component list.

## 7. Errors and edges

- A blank name, a duplicate name ignoring case, a name over 30 characters, more than eight tabs,
  or any attribute but `tab` and `id` on a tab entry: an error on Apply, a refusal on Save.
- The browser's Save gate (`slotProblem`, the block gate generalised) refuses a blank or duplicate
  tab name first, names the tab, scrolls to it and loses nothing else in the session.
- A tab key in a stored `hidden`, `widths`, `views` or `intros`: dropped on read. A tab key with no
  name: "Tab". A ninth tab key: dropped from the order, its panels joining the group before it.
- A deep link to a panel that is hidden, or in a tab that dropped: the first tab, and the hash left
  as it was. A deep link with a stale slug after a rename: the first tab.
- Apply can move a panel between groups by merge rule 2; the drawer shows it before Save.
- Two browser tabs editing one page: last Save wins, whole, as slice 1 recorded.
- The head's `#publish` link needs no tab switch: Publish is outside the panes.
- No JavaScript: sections, nothing hidden, the editor's own no-JavaScript line unchanged.

## 8. Testing

**Unit** — `Maker::ProjectKind`: tab keys read off the stored order join the vocabulary; a tab key
in `hidden`/`widths`/`views`/`intros` is dropped; `groups(visible)` and `groups(order)` split at
the tabs, drop Publish and keep an empty top group; a nameless tab reads "Tab"; the ninth tab drops;
`default_width` and `offered_views` answer nothing for a tab. `Maker::LayoutDocument`: export writes
`tab:` with `id` in place; Apply renames by id, matches by name ignoring case, creates otherwise;
each of the errors in §7; `from_draft` refuses a tab with a width or a hidden flag; `column` puts
the key in `order` and the name in `titles` and nowhere else; merge keeps an unmentioned tab in
place; more than eight tabs is an error with the count.

**Integration** — `project_tabs_test.rb`: the maker's page and the public page render the bar,
the panes, the headings, the pane grids with the masonry controller and Publish after the panes;
a project without tabs renders today's markup (asserted against the current structure, not merely
"a grid"); an empty tab is not in the bar; a tab whose only panel renders nothing publicly is not in
the visitor's bar; repository cards sit in the final grid; the tab and pane ids are the slugs and
fall back to the key on a collision; Save rekeys `tab:new-1` in both `order` and `titles` and
writes the name; Save refuses each of §7's errors with the editor re-rendered; Reset removes tabs;
the editor root renders the cap; the query budget for both pages stays constant in the number of
tabs (`page_query_budget_test.rb`).

**System** — `page_tabs_test.rb`: Add tab, name it, drag a panel under it, Save, the page shows the
bar with the tab and the panel inside it and Publish below; click a tab and the pane shows, packed
(spans set) and the hash reads `#tab-<slug>`; open the page at `#tab-<slug>` and at `#tasks` for a
panel inside a tab and the right pane is open; Delete a tab, Save, its panel is back in the group
above; Save with a blank tab name stays on the editor with a notice, an unsaved Hide survives, and
naming the tab then Save persists both. The no-JavaScript sections are asserted on the markup by
the integration test, not in a browser without scripts.

**Hygiene** — the new component selectors registered; `tabs` resolves in the Stimulus hygiene
sweep; template hygiene over the new partials; every guard mutation-checked with its red output
recorded.

## 9. Not in this slice

Slices 4 to 6 (a separate public layout, templates, per-project look). Also: nesting tabs; hiding a
whole tab with one switch (hide its panels); an icon or count on a tab; remembering the last-open
tab per visitor; sections as an alternative display mode; moving a tab by anything but dragging;
tabs inside the page intro or around Publish; per-tab widths for the pane.

## 10. Decisions a future editor might undo

1. **Tabs below an always-visible top group.** What precedes the first separator is never behind a
   click; chosen over headed sections (no grouping strength) and whole-page tabs (the README and the
   pictures behind a click). Drawn as three mockups and chosen by the owner.
2. **A tab is an entry in `order` named in `titles`, not a row and not an anchored map.** A name is
   arrangement; the flat order already gives it drag, YAML, merge and totality. A table is ceremony
   for thirty characters; a map anchored to a panel breaks when the panel moves.
3. **Publish sits below the tabs, outside every group.** It is the head's anchor and the pinned
   slot; a visitor on any tab sees it. Chosen over "last panel of the last tab".
4. **Apply matches a tab by id, then by name ignoring case, then creates.** A tab's name is its
   identity to a person; a pasted layout should map *Build* onto *Build*. Blocks match by id only
   because their content, not their heading, is what a row holds.
5. **A tab has no hidden flag, no width, no view, no intro.** Hide panels; an all-hidden tab
   disappears. Fewer states, and nothing for the merge to get wrong.
6. **A blank name is refused, not defaulted.** The name box is focused on Add; an unnamed tab in the
   page would be a mystery to a visitor.
7. **Tabs on every width; the bar scrolls.** One mechanism, one set of deep links, one test.
8. **Without JavaScript the page is sections.** Every pane renders with its heading; the controller
   only hides. Nothing on the visitor's page depends on a script to exist.
9. **The no-tabs branch renders today's markup unchanged.** Every existing project must be
   byte-for-byte what it was; the tabs shape is entered only when a separator exists.
10. **Reset removes tabs.** They live only in the override; blocks, the description and the cover
    are content and stay.
