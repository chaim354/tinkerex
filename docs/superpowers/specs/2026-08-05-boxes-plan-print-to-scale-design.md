# Box Generator — the compartment plan, exportable and printable to scale

**Date:** 2026-08-05
**Branch:** `claude/box-layouts-export-print-e3a7ce`
**Status:** design, approved — not yet planned or implemented

---

## 1. What exists today

The Box Generator is a runtime bundle in the sibling `tinkerex-addons` repo (`addons/boxes/`),
served by the `addons` Kamal accessory. **Republishing the bundle is the deploy; Rails is never
rebuilt** (§14c). It mounts same-origin into the host page via `Tools::AddonsController#show` →
the `addon` Stimulus controller.

Inside it, `top_view.js` draws a **compartment plan** of the tray:

- It reads the very params the generator is about to be handed — the `layout` art, or `sx`/`sy`,
  plus `thickness` — so it needs no sidecar call and **cannot drift from the cut sheet**.
- `tray_layout.js` owns the grammar (`parseArt`, `gridFrom`, `sections`, `compartments`) in one
  place, deliberately, because a second copy of a parser is this repo's recorded failure shape.
- Its private `svg()` function emits an SVG whose **user units are already millimetres**.

But that SVG carries only a `viewBox` — no physical `width`/`height` — and
`app/assets/stylesheets/application.css:290` sets `width: 100%; max-height: 320px`. So the plan
renders at whatever size the sidebar happens to be. **Nothing about it is to scale today.**

There is also no download and no print anywhere in the addon. The cut sheet goes into an
`<img src="data:image/svg+xml,…">`, and the only way to get a file out is *Save to library*,
which writes a single file (`<base>.svg`, the cut sheet). No `@media print` or `@page` rule
exists anywhere in the application.

## 2. What we are building

The **compartment plan** — not the cut sheet — emitted at **true 1:1 scale**, through four sinks:

1. **Print** — a clean print view of just the plan, at true size.
2. **Download PDF** — the format that reliably carries physical size across viewers and printers.
3. **Download SVG** — the same drawing, `width`/`height` in millimetres.
4. **Save to library** — `<base>-plan.svg` written beside the cut sheet on Save.

When the plan exceeds one sheet of paper it is **tiled** across pages with an overlap band,
alignment marks and page labels. A plan that fits produces one page through the same code path.

On the sheet: **hairline outlines, no fills**; **compartment size labels**; and a **100 mm
calibration bar**.

### Why the plan and not the cut sheet

The cut sheet is flat panels — it cannot tell you whether your screwdriver fits compartment 4.
The plan is the assembled tray seen from above, so printing it 1:1 lets you set real parts into
the drawn compartments before committing material. That is the use this feature exists for.

### Non-goals

Deliberately excluded, and each is a decision rather than an oversight:

- **A title block** (name / generator / thickness / date). Declined by the user. Page labels on
  tiled sheets stay, because those are registration for taping pages together, not decoration.
- **Cut marks on compartment openings** (scissor the sheet into a physical gauge). Declined.
- **Exporting the cut sheet.** Separate feature; the sidecar already emits real mm, so it is
  mostly a download button, and it is not this.
- **Server-side rendering** of any of it. Rejected in §4.
- **Rasterisation (PNG).** The host never grew a rasterisation endpoint, deliberately, and
  nothing here needs one.

## 3. Requirements, as decided

| Decision | Choice |
|---|---|
| Artifact | the top-view compartment plan |
| Sinks | print, PDF download, SVG download, save to library — all four |
| Oversize | tile across pages; single page when it fits, same path |
| Sheet content | compartment size labels; hairline outlines, no fills; 100 mm calibration bar |
| Sheet content, excluded | title block, cut marks |
| Where it is built | entirely client-side, including a hand-rolled PDF writer |
| Module split | `plan.js` and `sheet.js` stay separate |
| Paper | a selector (A4 / Letter / A3 / Tabloid), default A4, remembered in `localStorage` |

## 4. Approach: everything client-side

**Chosen.** A new `sheet.js` + `plan.js` + `pdf.js` in the boxes bundle. Deploy is
`bin/build-push` in the addons repo; Rails is never rebuilt; §9 licensing is untouched because
there is no new dependency; and it preserves `top_view.js`'s stated property — no round trip,
cannot drift. The cost we accept is owning ~130 lines of PDF writer whose xref byte offsets are
fiddly.

**Rejected — server-side PDF.** Posting the model to Rails or a new sidecar would give the most
robust PDF and cost the most of everything else: a Rails redeploy, a third sidecar under §14c's
three deploy-hygiene rules, a licence review, and it would break the no-round-trip property for a
drawing that is already fully computed in the browser.

**Rejected — no PDF writer, use the print dialog's Save-as-PDF.** Genuinely cheaper and less to
get wrong, but it makes "Download PDF" a two-step, and a browser-generated PDF still obeys that
dialog's scale setting — so the guarantee that the PDF is exact by construction disappears,
which is the main reason to offer a PDF at all.

## 5. Architecture — one coordinate model, three renderers

| Module | Status | Purpose |
|---|---|---|
| `tray_layout.js` | unchanged | the grammar and `compartments()` — already the single source of the vocabulary |
| **`plan.js`** | new | the coordinate model in millimetres, plus the screen and print mark emitters |
| **`sheet.js`** | new | pagination and sheet furniture: primitives + paper → `pages[]` |
| **`pdf.js`** | new | primitives → PDF bytes |
| `top_view.js` | edit | still mounts the panel; renders *from* `plan.js`; exposes `getPlan()` |
| `editor.js` | edit | the Print / PDF / SVG controls and the paper selector; the second file on save |

The load-bearing move is **extracting the coordinate maths that currently lives inside
`top_view.js`'s private `svg()`**. A print routine that recomputed compartment positions itself
would be a second copy of that maths, and this repo has the receipts on what that costs:
`importer_controller.js`'s `roleFor` is a third copy of an unrelated vocabulary and has drifted
twice (§14d). The on-screen panel therefore becomes a *consumer* of `plan.js` rather than a thing
left alone beside it — which is what makes "the printed sheet matches what you are looking at" a
structural fact instead of a promise.

### 5.1 `plan.js`

**"One geometry" means the coordinate model, not one primitive list.** Screen and print genuinely
draw different marks — the screen fills cell and wall rectangles, print strokes inset opening
outlines and fills nothing (§5.2) — so a single shared primitive array would be a fiction. What
must not be duplicated is the *maths underneath both*, because that is where a divergence would be
silent and wrong.

So `plan.js` exports one model builder and two primitive emitters, all three in one module:

```
buildModel({ cols, rows, hwalls, vwalls }, thickness)
  -> { w, h, colX, rowY, t, id, groups }     // the coordinate model; no marks

screenPrims(model) -> prims                  // filled cells, merged runs, walls, crossings
printPrims(model)  -> prims                  // inset opening outlines, tray outline, labels
```

`prims` is a flat array, every coordinate in **millimetres**, origin at the plan's top-left (the
outside face of the outer wall), y increasing **downward**:

```
{ kind: "rect", x, y, w, h, role }          // role: "cell" | "cell-merged" | "wall"
{ kind: "line", x1, y1, x2, y2, role }      // role: "opening" | "outline"
{ kind: "text", x, y, text, role, size }    // x,y = centre; size in mm
```

`buildModel` is the existing `svg()`'s coordinate maths lifted unchanged — `colX`, `rowY`, the
`x0`/`y0` offsets for a present outer wall, and the rule that the grid is rigid so a removed wall
hands its own thickness to the compartment. That rule is why a merged compartment is wider than
its two cells added together, and it must survive the extraction intact.

`screenPrims` must reproduce today's drawing exactly; `test/system/tray_top_view_test.rb` is the
check on that.

**Label type scale.** On screen the label size is computed in millimetres —
`Math.max(4, Math.min(cw / 6, ch / 3, 9))` — which is up to a 9 mm character on paper, absurd at
1:1. `printPrims` clamps instead to **2.5–4 mm** (roughly 7–11 pt), still derived from the
compartment size so a narrow compartment gets a smaller label, but bounded to something a sheet
of paper can carry. A label wider than its compartment is dropped rather than allowed to overrun
into the neighbour.

### 5.2 Drawing compartments without fills

Hairline-outline mode cannot simply stroke each cell rectangle — a merged compartment is several
rectangles, and stroking each would draw internal seams down the middle of an opening that has
none. Computing a rectilinear union would work but is more machinery than this needs.

The direct read of the data model is simpler and exact:

> For each compartment group, for each cell in it, for each of its four sides: if the neighbour
> across that side is not in the same group, emit a line along that side **inset by `t/2`** — the
> wall's inner face.

Absent walls emit nothing, so merged cells read as one continuous opening with no seams; present
walls emit an edge on each side, so the drawn opening is the **real opening**, not the opening
plus the material. That inset matters: at 1:1 for fit-checking, being wrong by `t` on every
dimension defeats the purpose. Collinear adjacent segments may be left unmerged — visually
identical.

The tray's overall outside rectangle is drawn as a slightly heavier line, so the sheet reads as a
tray rather than as loose boxes.

### 5.3 `sheet.js`

```
paginate({ w, h, prims }, { paper, margin, overlap }) -> { cols, rows, pages: [...] }
```

- **Printable area** = paper minus a 10 mm margin on all sides. 10 mm is safe on effectively
  every consumer inkjet and laser; the common hardware limits are 0.25 in (6.35 mm) and
  0.5 in (12.7 mm), and this clears both on the sizes that matter.
- **Overlap**: each tile repeats a 10 mm band of its right and bottom neighbour's content, so
  there is something to align and tape against rather than a butt joint.
- **Marks**: corner crosshairs at the trim line of each tile.
- **Label**: `Sheet 2,1 of 3×2`, bottom-left, outside the trim line. This is registration, not the
  title block that was declined.
- **Order**: row-major.
- **Calibration bar**: 100 mm with 10 mm ticks and the caption *"100 mm — check with a ruler"*, on
  **every** page. Per-page and not once per set, because pages get separated and because a partial
  print is exactly when you most want to catch a scale error.
- **Page-count guard**: refuse above 40 sheets with a message naming the count. A typo'd `sx` of
  `5000` otherwise tries to print several hundred pages.

`sheet.js` knows nothing about SVG or PDF. It emits translated primitives; the renderers draw them.

### 5.4 `pdf.js`

```
buildPdf(pages, { paper }) -> Uint8Array
```

A minimal PDF 1.4: header, a Catalog, a Pages node, one Page plus one Contents stream per sheet,
one Font object (`/Helvetica`, a base-14 font, so **no font embedding**), an xref table, a
trailer, `startxref`, `%%EOF`. Streams are **uncompressed** — no deflate, no dependency.

- **Units.** MediaBox in points: `mm × 72 / 25.4`. A4 is `[0 0 595.28 841.89]`.
- **The y-axis flips.** SVG's y grows downward; PDF's grows upward from the bottom-left. Every
  primitive is transformed on the way in. This is the single most dangerous line in the module,
  because a flipped plan is **invisible on a symmetric tray** and only shows up on an asymmetric
  one — the exact test blind spot this repo keeps rediscovering. The PDF tests use an
  **asymmetric** layout for this reason, and only for this reason.
- **Operators used.** `w` (line width), `re` + `S` (stroke a rectangle), `m`/`l`/`S` (lines),
  `g`/`G` (grey), `BT /F1 <size> Tf <x> <y> Td (<text>) Tj ET`.
- **Text escaping.** `\(`, `\)`, `\\`. One real trap: the compartment label uses **`×`
  (U+00D7)**, the only non-ASCII character in the whole drawing. Emit it as the octal escape
  `\327` under `/Encoding /WinAnsiEncoding` — that renders correctly *and* keeps the file
  byte-for-byte ASCII, which incidentally leaves the door open to putting a PDF through the
  library's JSON `files` contract later (see §7).
- **xref offsets** are 10-digit, zero-padded, byte offsets from the file start. They are computed
  by building the body first and recording each object's offset as it is appended — never by
  predicting lengths.

### 5.5 Print

A **hidden iframe**, and specifically not the two alternatives:

- Not `window.open` — a popup blocker can eat it.
- Not a print-only container in the host page — the bundle would have to inject a `<style>` that
  hides the host's own chrome, fighting CSS the addon does not own.

The iframe gets a complete document with `@page { size: <paper>; margin: 0 }` and one page SVG per
sheet at exactly those millimetres, then `iframe.contentWindow.print()`.

The calibration bar is the honest admission here: **the browser's print dialog defaults to "Fit to
printable area" and will rescale the sheet without saying so.** Nothing in the page can prevent
that or detect it. The bar is what lets the user catch it in one second with a ruler.

## 6. UI

Three buttons and a selector in the `.box-topview` panel header, beside the existing summary:

```
Top view          8 compartments · 2 merged     [A4 ▾] [Print] [PDF] [SVG]
```

The panel already removes itself when the first draw yields no grid — which is how FrontPanel,
whose `layout` param is a different DSL entirely, is kept out. So the controls exist only where a
plan exists, and need no gate of their own.

Mid-edit the art is routinely unparseable and the panel deliberately leaves the last good drawing
up. The export controls act on **that same last good plan**, so what you print is what you are
looking at.

## 7. Save to library

`editor.js`'s save appends a second entry to the `files` array:

```js
{ name: `${base}-plan.svg`, content_type: "image/svg+xml", body: <untiled plan SVG> }
```

**Untiled and full size** (`width="400mm"`). Tiling is a property of the printer, not of the
drawing; an archival artifact should not arrive pre-chopped into sheets.

This needs **no Rails change**. `Tools::AddonsController::MAX_FILES` is 8, and `parse_files`
already refuses duplicate names within one batch. §14c's *"each save writes one file — its
output"* recorded the deletion of the write-only `.params.json`, which duplicated
`AddonState#data`; a second genuine output is not that.

**Why SVG and not PDF into the library.** `parse_files` requires `f["body"].is_a?(String)` and the
payload arrives as JSON, so the body must be valid UTF-8 — binary cannot round-trip. Putting a PDF
in the library would need base64 plus a host-side decode, i.e. a Rails redeploy, which would cost
the whole bundle-only property for no gain: SVG previews through the existing pipeline and the PDF
is one click away as a download.

## 8. Error handling

| Condition | Behaviour |
|---|---|
| Art unparseable mid-edit | export acts on the last good plan (`top_view.js` already holds it) |
| Generator has no grid at all (e.g. FrontPanel) | the panel removes itself; no controls exist |
| Plan exceeds 40 sheets | refuse, with a message naming the sheet count and the plan's mm size |
| Print blocked or iframe fails | surface a message in the panel; the SVG/PDF downloads remain |

Nothing here throws to the console silently. The panel already owns a status line pattern
(`data-topview="summary"`); messages reuse it.

## 9. Testing

`bin/ci` cannot see bundle JS at all. The addons repo has **no JS test runner** — the only
automated coverage is this repo's system tests running against the fixture snapshot in
`test/fixtures/addons/boxes/`, and `bin/check-fixture-drift` refuses to publish a bundle that
diverges from that fixture.

**Assert the wire format, not the round-trip** (§14e). A test that parses our own PDF with our own
reader is precisely the `FakeS3` shape — an exact inverse of the bug, 79/80 green over silent data
loss. So:

1. **SVG** — assert the root element's literal `width="210mm" height="297mm"` and that the
   `viewBox` matches, against a plan whose mm size the test computes independently.
2. **PDF** — assert the literal `/MediaBox [0 0 595.28 841.89]` bytes, and that a known rectangle
   appears at the **y-flipped** coordinate. Use an **asymmetric** layout, because a flipped plan is
   invisible on a symmetric one.
3. **Tiling** — a plan wider than one sheet produces the expected page count, and page (1,0)'s
   primitives are the page (0,0) primitives translated by exactly `printable_width - overlap`.
4. **Mutation checks** (§15), each restored afterwards:
   - drop the `mm` suffix from the SVG root → test 1 must go red;
   - remove the y-flip in `pdf.js` → test 2 must go red;
   - drop the overlap from the tile origin → test 3 must go red.
   A guard that has never failed has not been shown to work.
5. **Once against the real thing** — open a generated PDF in a real viewer rather than trusting
   the writer. The repo already ships pdfium.
6. **One manual acceptance step, stated plainly**: print a sheet and measure the 100 mm bar with a
   ruler. Nothing automated can prove the paper is right, and this spec does not pretend otherwise.

## 10. Work split — two repos

| Repo | Work |
|---|---|
| `tinkerex-addons` | `plan.js`, `sheet.js`, `pdf.js`; edits to `top_view.js` and `editor.js` |
| `tinkerex` (this one) | mirror the whole bundle into `test/fixtures/addons/boxes/`; new system tests; `application.css` only if the panel header needs layout for the new controls |

The fixture mirror is not optional bookkeeping: without it the host's tests stay green while the
shipped addon changes, and `bin/check-fixture-drift` will refuse the publish. Publishing is the
deploy, so the fixture and the bundle land together or not at all.

## 11. Risks

- **The PDF writer is new code we own.** Mitigated by keeping it to rects, lines and base-14 text
  with no compression, by computing xref offsets from the built body rather than predicting them,
  and by opening the result in a real viewer once.
- **The browser print dialog can still rescale.** Unpreventable and undetectable from the page.
  Mitigated by the calibration bar, and by the PDF download for anyone who wants certainty.
- **Extracting `plan.js` touches working, tested code.** `test/system/tray_top_view_test.rb`
  already covers the on-screen panel, so it is a refactor with a net under it — run it before and
  after and require it unchanged and green.
- **Printer margins vary.** 10 mm clears the common 6.35 mm and 12.7 mm hardware limits, but an
  unusual printer could still clip a trim mark. The calibration bar is inside the printable area,
  so a clipped mark never invalidates the scale check.
