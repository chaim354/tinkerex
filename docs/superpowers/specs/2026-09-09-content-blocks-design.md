# Content blocks: prose, links and pictures between the panels, and a page that packs

**Date:** 2026-09-09. **Status:** approved in conversation (owner), slice 2 of the project-page
configurator. **Builds on:** `2026-09-09-page-editor-design.md` (slice 1: the edit mode, the slot
per panel, `Maker::LayoutDocument`, the YAML). **Stories:** 6.5 (a maker arranges the project page),
5.x (the visitor sees what the maker arranged).

## 1. Why

The page editor arranges panels the app generates: files, photos, the build log. It cannot hold a
sentence the maker wrote about the project, a link to the Printables page, or one picture placed
where it belongs in the story. The README does some of that, but it is one document at one place
and it lives in the folder. Slice 2 gives the page its own content: blocks that sit in the same
order as the panels, are arranged by the same editor, and travel in the same YAML.

Two neighbours come along because the same edit mode is the natural place for them: the **page
intro** (the cover and the description, editable in place), and a layout defect slice 1 made
visible: on a wide screen a short half-width panel leaves a **gap** under itself until its taller
neighbour ends, because a CSS grid aligns rows. The owner asked for no gap.

## 2. The blocks

**Three kinds.**

- **Text** — an optional heading and a body in GitHub-flavoured Markdown, rendered through the same
  renderer and sanitiser the README uses (`Maker::Markdown`, extracted from `Maker::Readme`), so a
  block can do what a README can do and nothing more. Chosen over the rich-text editor the build
  log uses because Markdown travels as plain text in the YAML and can be edited outside the app.
- **Link** — a URL (http or https only), a title, and one optional line. Renders as a card with the
  host name; on the visitor's page the anchor carries `rel="noopener nofollow"`.
- **Image** — one image from the **project folder**, with an optional caption. Renders large at that
  point on the page, the hero's rule (`inline_image?` decides picture versus thumbnail), and links
  to the file's page. Only files inside the folder, because the YAML names an image by its path
  under the folder and a file elsewhere in the library has no such path; the photo rows the page
  already loads are the picker's source, filtered to the folder.

**Adding.** "Add block ▾" in the top bar offers the three kinds. The new block lands **first in the
grid**, with its editor open, carrying the same strip as a panel: handle, Up/Down, eye, Full/Half,
and **Delete** in place of the pencil and the view switch (a block's content is its own editor).
Drag it where it goes. Chosen over insertion points between panels from two mockups.

**Editing, in the slot body while in edit mode.** Text: heading input, Markdown box, and a Preview
button that posts the Markdown to a read-only helper and swaps in the rendered HTML. Link: URL,
title and line inputs, with the card drawn live from them (the host name parsed in the browser).
Image: a grid of the folder's images to pick from, and a caption input.

**Deleting** removes the block from the draft at once; Cancel (a reload) brings it back; Save makes
it final. A block is never deleted by its absence from pasted YAML (§5).

**Defaults and limits.** Text and image blocks default to full width, a link block to half. Heading
and title up to 80 characters, line and caption up to 200, body up to 20 KB, at most **40 blocks**
per project: Add block is disabled at the cap, Apply refuses a text that would exceed it, Save
refuses too. Blocks can be hidden like any panel and are hidden on both pages.

## 3. The page intro

In edit mode a card sits above the grid: the cover (or "no cover"), a **Change cover** picker over
the folder's images, a Remove, and the **description** as a text box (plain text, the column as it
is today). Both save with the one Save. Outside edit mode nothing changes: the description
paragraph and the hero render as they do now. A cover set from a file's own page that lives outside
the folder keeps working; the picker simply cannot choose one, and the YAML writes no `cover:` for
it, with a note.

## 4. The layout model

**A table.** `maker_project_blocks`: `project_id`, `key` (12 hex characters, unique per project),
`kind` (`text` | `link` | `image`), `heading`, `body`, `url`, `line`, `caption`, `node_id`, and
timestamps. `Maker::ProjectBlock` validates the kind, the lengths, the URL scheme, and that the
fields match the kind. One query loads a project's blocks for either page.

**Keys.** `block:<key>` joins the layout's vocabulary beside fixed keys and `folder:<node_id>`.
`Maker::ProjectKind.layout_for` takes `blocks:` (pairs of key and kind, in row order) the way it
takes `folders:`; totality holds — a key whose row is gone drops out of every map — and a block the
stored order does not name lands **first** (it is what Add block did a moment ago). `default_width`
answers per block kind; the `Layout` keeps a key-to-kind map for it. Titles and intros do not apply
to blocks (they have their own heading), and `offered_views` answers none.

**The column** is unchanged in shape: `order`, `hidden`, `views`, `widths`, `titles`, `intros`. Block
content lives in the rows, never in the JSON (approach chosen over a `blocks` map in the column,
which would grow without bound and blur the layout into content).

## 5. The document

**The draft** (what the browser holds and Save posts) gains a `page` mapping and block entries:

```json
{ "layout": 1,
  "page": { "description": "A desk lamp with a printed shade.", "cover": "5c32…" },
  "panels": [
    { "key": "block:3f9a1b2c4d5e", "kind": "text", "hidden": false, "width": "full",
      "heading": "Why a printed shade", "body": "A paper shade yellows…" },
    { "key": "block:new-1", "kind": "link", "hidden": false, "width": "half",
      "url": "https://www.printables.com/model/12345", "title": "Printables page", "line": "Sliced files." },
    { "key": "block:new-2", "kind": "image", "hidden": false, "width": "full",
      "file": "9acd…", "caption": "The shade lit, side on." },
    { "key": "attachments", "hidden": false, "width": "full", "view": "tiles" } ] }
```

A block added in this session has a `block:new-<n>` key until Save assigns a real one. `file` and
`cover` are node ids in the draft.

**The YAML** names an image by its path under the project folder and a block by `block: <kind>`,
so the discriminator is one of `panel`, `folder`, `block` — exactly one per entry:

```yaml
layout: 1
page:
  description: |
    A desk lamp with a printed shade and a walnut base.
  cover: photos/lamp-front.jpg
panels:
  - block: text
    id: 3f9a1b2c4d5e
    heading: Why a printed shade
    body: |
      A paper shade yellows; PETG at 0.2 mm diffuses about as well.
    width: full
  - block: link
    url: https://www.printables.com/model/12345
    title: Printables page
    line: Sliced files and the print profile.
    width: half
  - block: image
    file: photos/side.jpg
    caption: The shade lit, side on.
  - panel: attachments
    width: full
    view: tiles
```

**Export** writes `page` (description as a block scalar when present; `cover:` by path, omitted
with a note when the cover is outside the folder), and every block with its content; a saved block
carries `id:`, an unsaved one does not.

**Apply** keeps slice 1's merge rules and adds:

1. a block entry with an `id:` this project knows **updates** that block (attributes given replace,
   absent keep); one without an id, or with an id this project does not know (pasted from another
   project), **creates** a new block; blocks the text does not mention keep their place;
2. `page.description` and `page.cover` replace when given, keep when absent; a `cover:` path that
   names no image in the folder is skipped with a note;
3. an image `file:` that names no image in the folder is an **error** for a new block (the block
   would be empty) and a note for an existing one (it keeps its picture);
4. a `url:` that is not http or https, a heading or line over its limit, a body over 20 KB, a block
   kind outside the three, an entry naming two of `panel`/`folder`/`block`, or a result over 40
   blocks is an error.

**Save** treats the draft as the whole truth of blocks: rows for `new-` keys are created and given
real keys (the order rewritten to match), rows for existing keys updated, rows the draft does not
list destroyed — all in one transaction with the column, the description and the cover. A draft
that fails validation writes nothing and returns to the editor with the reasons, as today.

## 6. Doors and rendering

- **Helpers** (`Projects::LayoutsController`, owner-only, read-only): `yaml`, `parse` and a third,
  `preview` — Markdown in (20 KB cap), sanitised HTML fragment out.
- **The write** stays the panels door's `layout` branch, extended with the block upsert and the page
  fields; `Maker::LayoutDocument` yields the column, the block list and the page fields from one
  validated draft. Reset (DELETE) removes the layout override as today and leaves blocks, the
  description and the cover alone — they are content, not arrangement.
- **Rendering.** One block partial per page. On the maker's page an image block renders the picture
  through the blob route for an inline image and its thumbnail otherwise, like the hero; on the
  visitor's page through the public seam (`file_url_for` / `preview_url_for`), and it renders
  **nothing** when the file is not permitted or sits in a hidden folder — the derived-content rule.
  Text and link blocks always render. Markdown is rendered on each request through the shared
  sanitiser (about a millisecond each; forty at most).
- **The editor.** `layout_editor_controller.js` grows: the Add block menu, the block editors
  (heading/body/preview, url/title/line, picker/caption), Delete, the page-intro card, and the extra
  fields in the draft. Block slots carry `data-kind` and their content in data attributes like every
  other draft field, so the draft is still read off the slots.
- **The bundle** is unchanged: blocks are not files.

## 7. No gaps

On a wide screen the panel grid packs: a `masonry` Stimulus controller on `.project-panels`, on all
three renders (the public page loads the same JavaScript), switches the grid to one-pixel rows with
no row gap and gives every direct child a row span equal to its measured height plus the gap, so
the next panel starts right under the shorter one. A `ResizeObserver` re-measures as thumbnails and
previews arrive, a `MutationObserver` as blocks are added, deleted or dragged. Below the two-column
breakpoint, and without JavaScript, the grid is exactly today's. Chosen over server-side flex
columns (pure CSS, but pairs would read down a column instead of across, phones would need the
order restored, and the editor's flat drag list would break) and over CSS masonry (no Chrome
support).

## 8. Errors and edges

- A block's Markdown is sanitised on every render; nothing from the column is trusted as HTML.
- A link URL is checked twice: on Apply (error) and on Save (refused) — `http` and `https` only.
- An image whose file has left the folder renders nothing; in edit mode the block says "picture not
  in the folder" and offers the picker.
- Two tabs: last Save wins, whole, as slice 1 recorded.
- The masonry measurement runs after layout; a slot whose height changes (an image loading late)
  re-spans on its own. If JavaScript fails, the page is today's grid, gaps included.
- Query cost: the blocks are one query per page render, constant in the number of blocks; the
  picker and the page intro read rows the page already loaded.

## 9. Testing

**Unit** — `Maker::ProjectBlock` validations (kind, lengths, scheme, kind-field agreement);
`Maker::Markdown` renders and sanitises (a script tag, an `onerror`, a `javascript:` link all
stripped; headings, lists, links kept); `Maker::LayoutDocument` with blocks and page: export with
and without ids, paths for images and cover, Apply's update/create/keep rules, the cover note, the
image-file error and note, the URL and cap errors, Save's three outputs; `Maker::ProjectKind`
vocabulary with blocks, new-block-first, per-kind defaults, totality.

**Integration** — both pages render each block kind in its slot at its width; an unpermitted or
hidden-folder image renders nothing for a visitor; hidden blocks are absent; Save creates rows for
new blocks and rewrites the order with real keys, updates existing, destroys removed, sets the
description and cover, all or nothing (a bad block in the draft leaves every row untouched); the
preview helper returns sanitised HTML and 404s for a non-owner; the edit page renders the Add block
menu, the page intro and each block's editor; the query budget is constant in blocks on both pages;
the template, Stimulus and CSS hygiene sweeps cover the new partials and controller.

**Browser** — add a text block from the menu, type Markdown, Preview shows it rendered, Save, the
page shows it; a link block's card follows the inputs live; an image block picks a folder image;
Delete removes and Save persists the removal; a block drags between panels; the page intro changes
the cover and description; and the packing: with a tall left half and a short right half, the next
slot's top sits within one gap of the short one's bottom.

Every guard mutation-checked.

## 10. Decisions a future editor might undo

1. **Blocks are rows referenced by the layout**, not content in the JSON column.
2. **Markdown, not rich text**, so content travels as text in the YAML.
3. **Content travels in the YAML**; Apply matches blocks by id, creates for unknown ids, never
   deletes by omission. Save treats the draft as the whole truth of blocks.
4. **Images from the project folder only**, so the YAML can name them by path.
5. **Add block lands first**, from the top bar, no insertion points.
6. **Reset leaves blocks, the description and the cover alone**: they are content.
7. **No gaps by measured row spans, one mechanism on all three renders**, degrading to today's
   grid without JavaScript.
8. **40 blocks, 20 KB a body**, caps stated and tested.
9. **Settled in execution (2026-09-09):**
   - **Save filters the merged draft to the blocks the BROWSER posted**
     (`Projects::PanelsController#held_by_browser`). `Maker::LayoutDocument#merge` deliberately
     KEEPS an entry the document does not name — that is decision 3's "never deleted by omission",
     and it is what lets a layout pasted from a smaller project leave this one's panels alone. The
     editor's Save is the opposite rule: it posts every slot it holds, so a block that is absent is
     one whose slot was deleted. The two meet at the door, and only a BLOCK's absence carries that
     meaning; a panel or folder the draft omits is untouched.
   - **The export names a dropped image block in its header** (`IMAGE_OUTSIDE_NOTE`), as it already
     did for a cover from outside the folder. An image whose file has left the folder has no
     shareable path, and a silent drop re-applied to the same page moved that block to the end.
   - **An `id:` updates only when the KIND matches too**; otherwise it creates. A pasted layout's id
     can collide with an unrelated block here, and updating across kinds would rewrite it.
   - **The editor's draft states every field of a block's kind, empty ones included**, so emptying
     the heading box empties the heading. The document merges an ABSENT attribute into what the row
     holds — right for a paste, wrong for a maker who has just cleared a box. Empty strings cost
     nothing downstream: the merge deletes them, so the YAML drawer never shows `line: ''`.
   - **`.page-intro` was already taken** — the trash and repository pages' one-line explanation in
     `pages/preview.css` — and that one is `.head-note` now. Two meanings for one class name is the
     pre-2026-09 `.btn` bug with a new face, and this one would have been silent and one-directional:
     `pages` is declared after `components`, so the older rule's 72ch cap would have squeezed the new
     card and nothing would have changed in the other direction. For the same layer reason, a text
     block's `.markdown` drops the README's 360px scroll cap in `pages/projects.css` rather than
     beside the other block rules in `components.css`.
   - **The pack moves the grid under a drag in progress.** Lifting a slot re-spans every one below
     it, so a browser test that drops onto coordinates resolved before the lift misses — silently.
     `test/system/page_blocks_test.rb`'s `drag` resolves the target twice for that reason. A person
     never meets it: they watch the ghost move and release when it looks right.

   - **Block Markdown resolves relative links and images against the project folder by the
     README's rule**, through the one `Maker::Markdown.folder_resolver` (found in task C's review:
     without it every relative link in a block silently became text, while the README beside it
     linked). §11 used to list this as out of scope; it is in.
   - **Save asks the server's block rules in the browser first** (`blockProblem` in
     `layout_editor_controller.js`), because a refused draft re-renders the editor from the row and
     every other unsaved change in the session goes with it. The server keeps its rules; the client
     copy exists so the refusal names the block and loses nothing (found in task D's review). The
     body is byte-counted like the server, not in the UTF-16 units `maxlength` would count.

## 11. Out of scope

Video embeds (CSP work); reusing a block across projects; block text in the download bundle;
per-visitor visibility beyond hidden; a block picker for files outside the folder; undo
beyond Cancel; slices 3 to 6.
