# Measure — select parts and print them to scale for paper fit testing

**Status:** design approved, not built.
**Surfaces:** the Measure view on `.lbrn`/`.lbrn2`, `.mage`, `.dxf` and `.svg` file pages.
**Sibling:** `2026-08-05-boxes-plan-print-to-scale-design.md`. That one prints a tray plan from
the `boxes` addon bundle; this one prints selected outlines from a library file. They solve the
same problem on two surfaces that cannot share code — §10 below is about that, and is the most
load-bearing section in this document.

---

## 1. What exists today

`app/views/files/_measure.html.erb` + `app/javascript/controllers/measure_controller.js` give a
Measure view on the four formats `Maker::Previews::Geometry` can build a payload for. It fetches
`GET /files/:id/geometry`, which resolves to a JSON blob, and draws it as an SVG built with
`createElementNS` from parsed coordinates.

The payload (`Maker::Previews::Geometry`, `SCHEMA_VERSION` 1) already carries everything a
to-scale print needs:

| key | meaning |
|---|---|
| `job` | `{w, h, x, y}` — the document's bbox in mm |
| `shapes[].p` | the contour's points in **mm**, Y-down, **thinned** for drawing (RDP, 0.01 mm) |
| `shapes[].b` | `[x0, y0, x1, y1]` bbox in mm, computed from **full-resolution** points |
| `shapes[].d` | diameter in mm when the server decided the contour is circular, else absent |
| `shapes[].c` | layer key, resolved to a colour through the payload's `colors` map |
| `shapes[].k` | closed flag (polygon vs polyline) |
| `shapes[].i` | bitmap-placeholder flag |
| `shapes[].o` | object id — several contours share one when they came from one `<Shape>` |

Interaction today: click selects one contour (smallest-on-top, by paint order — there is no
point-in-polygon code); ⌥-click widens the readout to every contour sharing that `o`; wheel
zooms about the cursor; left-drag pans, with a 3-screen-pixel slop before a drag stops counting
as a click.

**There is no way to get any of it onto paper.**

## 2. What we are building

A **Select parts** mode in the Measure bar, and a **Print** that lays the selected contours out at
exactly 1:1 across as many sheets as they need, with a calibration gauge so a mis-scaled print is
detectable.

The use case is fit testing: print the hole pattern for a panel-mount switch, hold the paper
against the real switch, and find out before you cut material.

### Non-goals

Explicitly out of scope, and each one is a decision rather than an oversight:

- **No PDF and no SVG download.** The browser's own print preview offers "Save as PDF", and
  either export would put a second copy of the layout maths somewhere.
- **No marquee / rubber-band select.** Left-drag is already pan; a second gesture on the same
  button costs a mode or a modifier, and the toggle already solves the problem.
- **No layer filter.** Layers rarely match the parts you are fit-testing.
- **No packing mode.** Parts print in their true relative positions, always — see §5.2.
- **No centre-crosses on round holes.** Considered and declined.
- **The selection does not survive a reload.** It is in-page state.
- **Label collisions are not solved.** A dense selection can overlap its own size labels. Stated
  here so it is a known limitation rather than a surprise; see §11.

## 3. Requirements, as decided

1. A mode toggle turns plain click into "add/remove from the print set". No modifier keys needed
   for the common case.
2. ⌥-click toggles every contour sharing an object id, matching the readout's existing gesture.
3. Printed parts keep their **true relative positions**.
4. A selection larger than one sheet **tiles**, with an overlap band, registration marks and a
   grid label to tape by.
5. Every sheet carries a calibration gauge and a "do not scale" warning.
6. Every part carries its size, using the **server's** numbers.
7. The sheet's scale is verifiable from the file itself, not asserted in prose.

## 4. Approach: everything client-side, no server change

**No server change at all.** Every number the sheet needs is already in the payload. Concretely
this means:

- no new endpoint, no new route;
- **no `Geometry::SCHEMA_VERSION` bump** — the wire shape does not change;
- **no `PAYLOAD_REVISION` bump on any renderer** — §14h's rule ("a change in `Geometry` must bump
  every format's revision") does not fire, because no renderer's *output* changes. Nothing in any
  deployed library gets re-measured.

Two pipelines were considered and rejected:

- **Server-generated PDF (Prawn, MIT — §9-clean).** Gives a saveable file and PDF viewers have a
  trustworthy "Actual size". Costs a gem, an endpoint, POSTing the selection back, and a second
  copy of the tiling maths living server-side while the on-screen view defines it again in JS —
  the second-copy shape §14b keeps getting bitten by.
- **Client-built SVG download.** Same maths, delivered as files. More clicks, several files for a
  multi-sheet job, and the browser-scaling caveat is unchanged.

**Neither of them fixes the actual risk.** A web page cannot force a print dialog to 100%, and a
PDF does not either. The calibration gauge is the real guarantee in all three designs: it makes a
wrong print *detectable*, which is the only thing available. Given that, browser print gets the
same trustworthiness for a fraction of the code and zero dependencies.

## 5. Architecture

Two files change and one is added.

```
app/javascript/controllers/measure_controller.js   selection mode, print set, wiring
app/javascript/lib/print_sheet.js                  NEW — pagination + sheet building
config/importmap.rb                                NEW — one pin, following lib/file_chooser
app/views/files/_measure.html.erb                  buttons + paper picker
app/assets/stylesheets/application.css             .measure-contour--marked
```

### 5.1 Selection mode (`measure_controller.js`)

A **Select parts** toggle button in `.measure-actions`. While the mode is on:

- plain click toggles the contour under the pointer in or out of the print set. The measurement
  readout **still updates**, so picking parts and learning their sizes are the same gesture.
- ⌥-click toggles every contour sharing that `o`.
- membership lives in a `Set` of the payload's own shape objects, reached by identity through
  `node.__shape`. **No per-contour id needs inventing**, and nothing about the payload changes.
- a member gets `.measure-contour--marked`. This is a **separate class from
  `.measure-contour--selected`**, which stays the measurement highlight — one is "what am I
  reading", the other is "what will print", and collapsing them would make the two questions
  unanswerable at the same time. **Both can apply to one contour at once**: clicking in select
  mode marks it *and* reads it out, so `--selected` and `--marked` must be legible together rather
  than one hiding the other.
- `styleNode()` already resolves an open contour's transparent fat hit-twin to its drawn line;
  marking goes through the same method, or a marked open contour changes the colour of something
  invisible and nothing appears to happen.

The class is applied to the node; per §14h the layer colour stays a **presentation attribute**, so
a class rule outranks it and the mark actually shows.

Bar readout while selecting: `3 parts · 62 × 40 mm` (the union bbox, via the existing `unionOf`).
Buttons: **Print 3 parts** / **Clear**. With an empty set the button reads **Print all** — the
label states what will happen, so a six-sheet surprise cannot come from misreading it.

### 5.2 Coordinates: true positions means *relative*

The content origin is the **selection's** union bbox, not the file's `job` origin.

This is the decision that keeps tiling rare. Two holes 40 mm apart on a 600 mm laser sheet print
on **one** page, 40 mm apart — not on tile 4 of 12 with eleven blank ones. Relative geometry is
what fit testing checks; absolute position in the source document is not.

Points are used as-is otherwise: the payload is already mm, already Y-down, already in the
client's drawing space. **No flip, no scale factor, no dpi constant.**

### 5.3 `print_sheet.js`

Takes shapes in mm and a paper, returns pages of geometry in mm, page-local. Knows nothing about
the DOM, the controller, or file formats.

```js
export const PAPERS = { A4: {...}, Letter: {...}, A3: {...}, Tabloid: {...} }  // boxes' table
export const MARGIN = 10        // clears 0.25in and 0.5in hardware limits
export const OVERLAP = 10       // repeated band to align and tape against
export const HEADER_H = 7       // reserved strip, top
export const CALIB_H = 22       // reserved strip, bottom
export const MAX_SHEETS = 40

export function buildSheets(shapes, paper) -> { cols, rows, pages }
```

`shapes` is the print set, or **every shape in the payload** when the set is empty and the button
read *Print all*. There is no second entry point and no small-selection branch: one selected hole
and a whole 600 mm sheet reach the page through the same call.

Page geometry, per sheet:

```
paper.w x paper.h
  - MARGIN (10) all round        -> printable  pw x ph
  - HEADER_H (7)  off the top    -> reserved
  - CALIB_H  (22) off the bottom -> reserved
  = content box                     pw x (ph - 29)
```

Letter content box: **195.9 × 230.4 mm**. A4: **190 × 248 mm**.

Tiling steps come off the **content box**, not the printable box:

```
stepX = contentW - OVERLAP
cols  = w <= contentW ? 1 : ceil((w - OVERLAP) / stepX)
```

— the same formula as the `boxes` bundle's `sheet.js`, so a plan and a part tile identically.
`cols * rows > MAX_SHEETS` throws, and the message names the actual size and suggests a larger
paper, matching the sibling's wording.

**The strips are reserved, not overlaid, and this is a deliberate divergence from `sheet.js`.**
That module draws its calibration bar *over* the content area, which is safe because it knows its
own content — a tray plan of known extent. We are printing arbitrary user geometry that can be
anywhere on the page, so an overlaid ruler would land across a part outline. Consequence: a real
`<clipPath>` on the content group (§5.4), where `sheet.js` gets away with a bbox filter.

### 5.4 Building the sheet

One hidden iframe. `window.open` gets eaten by popup blockers, and a print-only container in the
host page means injecting a `<style>` that hides app chrome — the sibling's argument, and it holds
here too, with the extra point that `@page { margin: 0 }` in the host document would affect any
other print of that page.

Each page is one `<svg>`:

```
width="215.9mm" height="279.4mm" viewBox="0 0 215.9 279.4"
@page { size: 215.9mm 279.4mm; margin: 0 }
```

**One user unit is one millimetre. That is the entire scale mechanism** — no transform, no dpi
constant, nothing to get wrong. Named `@page` sizes are not used; explicit mm matches the sibling
and is more portable.

Inside: a `<g transform="translate(...)">` holding the contours **and their size labels**, with a
`<clipPath>` set to the content box, then the furniture outside that group. Labels are clipped with
the geometry they belong to, so a label for a part on the next tile cannot bleed into this one; a
label straddling a tile edge is cut here and appears whole on the neighbouring tile, which is what
the overlap band is for.

**Contours are built fresh from `shape.p`, never cloned from the on-screen nodes.** A clone would
drag the transparent fat hit-twins (`.measure-contour--hit`), the hover/selected classes and the
marked class onto paper. Closed shapes are `<polygon>`, open ones `<polyline>`, bitmaps the same
dashed rectangle they draw on screen — it is the rectangle a bitmap occupies that matters for fit,
and its base64 is deliberately not in the payload anyway.

Outlines print **black at 0.2 mm**, not in layer colours. A mono printer turns a layer palette into
indistinguishable greys, and the sheet exists to be cut and measured against.

**The iframe document is built with `createElement`/`createElementNS` and `textContent` — never
`doc.write` on a markup string.** This is the second deliberate divergence from the sibling, and it
is not stylistic: our header carries the **file name**, which is user-controlled and can legitimately
contain `<` on a NAS-scanned share. The sibling's plan has no user text in it. Interpolating a
filename into markup written into a same-origin iframe is an injection, and the Measure view already
keeps exactly this rule for the drawing itself.

### 5.5 Sheet furniture

**Header strip (7 mm, top).** File name and date (ISO `2026-08-19`, not a locale format) left; `Print at 100% — do NOT scale to fit`
centre; `Sheet 2,1 of 2×1` right.

Grid coordinates rather than "Sheet 2 of 6", matching `sheet.js`: when you are taping six sheets
together, the column and row tell you *where* the sheet goes. **On a single sheet the label is
omitted entirely** — there is nothing to register against.

**Calibration strip (22 mm, bottom).** A 100 mm ruler with a tick every 10 mm, labelled
`100 mm — check with a ruler` (the sibling's exact wording, so the two surfaces read the same),
plus a 20 × 20 mm square at the right labelled `20 mm`. The ruler is the primary check; the square
gives a both-axes sanity check and something to put calipers across.

**On every sheet.** Pages get separated, and a partial print is exactly when a scale error most
needs catching.

**Trim crosshairs** at the four printable corners.

**Size labels**, centred under each part's bbox at 3 mm text (the sibling clamps 1:1 text to
2.5–4 mm for the same reason — a nominal size is absurd at real scale).

The text comes from the controller's own `sizeLabel()`, the method the readout uses: `⌀12 mm` when
the server sent `d`, else `40 × 25 mm` from `b`. **Never re-derived from `shape.p`** — those are the
*thinned* drawing points, and measuring from them is §14h's recorded trap: every curve
under-reports, and a small hole that thinned below `MIN_CIRCLE_POINTS` loses its diameter entirely.
Reusing the one method is also what stops the paper and the screen ever disagreeing.

## 6. UI

The Measure bar gains, inside `.measure-actions` (so it appears only once geometry is loaded):

- **Select parts** — a toggle. Off by default; the view behaves exactly as it does today.
- a paper `<select>`: A4 / Letter / A3 / Tabloid (the sibling's `PAPERS` table verbatim),
  remembered in `localStorage`, **defaulting to Letter**.
- **Print 3 parts** / **Print all**
- **Clear** — shown only when the set is non-empty.

`.measure-contour--marked` is a distinct stroke colour and weight from `--selected` and `--hover`.
Like them, it works only because `.measure-contour` declares no `stroke` of its own — a stroke rule
on that class would outrank the layer-colour presentation attribute and flatten every layer to one
colour (§14h).

## 7. Error handling

- **Over `MAX_SHEETS`** — throw from `buildSheets`, caught by the controller and shown in the
  readout: the sheet count, the selection's size in mm, and the suggestion to pick larger paper.
  Nothing is printed.
- **Empty payload / no shapes** — the Select toggle is not rendered; `measure-view--ready` is
  never set, so `.measure-actions` is hidden anyway.
- **A selection whose union bbox is degenerate** (a single zero-length contour) — cannot occur:
  `Collector#add` drops contours of fewer than two points before they reach the payload.

## 8. Testing

New `test/system/measure_print_test.rb`, on `lbrn_measure_test.rb`'s idiom: `FileLayer::Share`
assigned directly against a tmpdir, fixtures written **before** the first render (an empty root
reads as an unmounted mount point), one `Library::Scanner.call`, `render_geometry!`, and a
`FileLayer.reset!` in teardown that is load-bearing rather than decoration.

`print_sheet.js` splits `buildSheets(shapes, paper)` from the frame-and-print step, so the layout
is assertable without a spooler. **`window.print()` itself is one line and is not covered** —
stated rather than papered over.

Following `plan_export_test.rb`'s rule, these **assert the wire format, never a round-trip through
our own reader** (§14e: `FakeS3` shared the adapter's misunderstanding and 79/80 tests were green
over silent data loss):

1. the literal `width="215.9mm"`, `viewBox="0 0 215.9 279.4"`, and
   `@page { size: 215.9mm 279.4mm; margin: 0 }`.
2. **Scale, with teeth.** `nested-plate.lbrn2` is a 60 × 40 plate with a ⌀10 hole on a shared
   centre. Printed, the plate polygon must span exactly 60 user units and the hole exactly 10, on
   a sheet whose declared millimetres and user units are equal. A wrong transform that still draws
   a plausible picture fails this; "did it draw something" does not.
3. **Position, in both directions** (§14h's Z-up lesson — a model lying on its side answers
   "is the frame non-blank?" exactly as well as an upright one). Two selected parts must keep
   their real separation, asserted as a distance, not as presence.
4. **Tiling.** A synthetic input wider than the content box gives the expected `cols`/`rows`; the
   second tile's `originX` equals content width − 10, the overlap band — the same assertion shape
   as the sibling's `assert_equal "180"`. A selection that fits produces one page **through the
   same path**, with no separate small-selection branch.
5. **Single sheet carries no sheet label; a tiled one carries `Sheet 1,1 of 2×1`.**
6. **`MAX_SHEETS`** refuses, and the message names the size.
7. **Calibration furniture appears on every page**, not only the first.
8. **Filename as text.** A node whose name contains `<` must land in the header as `textContent`,
   injecting no element into the iframe.
9. **Selection mode**: click marks, click again unmarks, ⌥-click takes the whole object, Clear
   empties the set, and the readout count tracks it.

### Mutation checks (§15 — mandatory, and none of the above counts until it has failed)

| break this | must go red |
|---|---|
| sheet width `215.9mm` → a px value | the scale assertion (2) |
| delete the `<clipPath>` | a content point escapes the content box and overprints the strip |
| draw calibration furniture on page 1 only | the every-page assertion (7) |
| size label re-derived from `p` instead of `b`/`d` | the ⌀ assertion on the thinned hole |
| `doc.write` with an interpolated name | the filename-as-text assertion (8) |
| omit the sheet label on a tiled job | (5) — and it must **not** fire on the single-sheet case |

The fourth is the sharp one: it is §14h's measure-after-thinning bug reintroduced deliberately, and
the ⌀10 hole in `nested-plate.lbrn2` is small enough that thinning takes it below
`MIN_CIRCLE_POINTS`, so the label loses its diameter entirely rather than merely drifting.

## 9. Existing gates this must not trip

- `test/stimulus_hygiene_test.rb` — no new Stimulus controller is added, so no new identifier; the
  new buttons hang off the existing `measure` controller.
- `test/integration/web/template_hygiene_test.rb` — the partial gains comments. **An ERB comment
  ends at its first `%>`**, so none of them may quote a snippet containing one (§14d).
- `assert_no_console_errors` in the system tier — the iframe must not log.

## 10. Why this does not share code with the `boxes` bundle

The `boxes` addon bundle already prints to scale: `sheet.js` has `paginate()`, `MARGIN`/`OVERLAP`
= 10, `MAX_SHEETS` = 40, a per-page calibration bar and `Sheet c,r of C×R` labels. This design
reimplements the same conventions. That is a copy, and it is deliberate.

**The bundle lives in `chaim354/tinkerex-addons`, a different repo on a different deploy cadence.**
Per §14c, publishing a bundle *is* the addon deploy and Rails is never rebuilt. Importing
`sheet.js` through the addon asset proxy would mean:

- a **core file page** breaking because someone republished an addon;
- the Measure view silently losing its print button on any deployment where the `boxes` addon is
  not configured (OVH blanks `ADDON_SOURCE_URL` outright — §14c);
- a runtime HTTP fetch, behind a 5-minute cache, on a page that today needs none.

The alternative — promoting the pagination to a host pin like `@maker/addon-sdk` — would make it
addon **public API**, unchangeable for the life of `api_version: "1"`, in exchange for one shared
function. That is a far larger commitment than the duplication costs.

So what is shared is the **conventions and the constants**, not the code, and this section is
referenced from a comment at both ends so a future editor finds the sibling rather than
rediscovering it. The two implementations are also not the same size: `sheet.js` carries a `prims`
abstraction because it feeds both an SVG writer and a PDF writer, and we have one output target,
so we build SVG nodes directly.

**If they ever do need to agree mechanically**, the honest move is to move the pagination into one
place — not to add a third copy.

## 11. Risks and accepted limitations

- **Browser/printer scaling cannot be prevented from a web page.** Accepted, and answered by making
  it detectable rather than by pretending otherwise. Every sheet carries the gauge; the header says
  so in words.
- **Label collisions.** A dense selection can overlap its own size labels. Labels are drawn after
  outlines so they sit on top, and only selected parts get one, but no collision avoidance is
  attempted. Revisit only if it bites in real use.
- **A `@page` size that disagrees with the paper in the print dialog** clips the tile edges. The
  picker sets `@page` explicitly, which Chrome honours by selecting the matching paper; other
  browsers may not, and the overlap band absorbs a small mismatch but not a Letter/A3 one.
- **The paper picker's default is Letter**, which is a guess about the operator, not a measurement.
  One constant to change.
