# Selecting shapes in Measure and downloading them as SVG — design

**Date:** 2026-09-02
**Status:** approved, ready for planning

## Problem

The Measure view already knows how to select shapes. `Select parts` marks contours, a plain click
targets one, and the Print button resolves three arms in precedence order — marked set → clicked
contour → all. What it cannot do is hand you those shapes as a file. The only way out of the view
is paper.

A maker who wants one bracket profile out of a 40-part sheet — to nest it differently in a vector
app, or to import it as a CAD sketch and build a fixture around it — has no path that does not
involve re-drawing it.

This adds a `SVG` button beside `Print` that downloads the selected shapes.

## The finding that shapes the design: the curves are already there, and the payload drops them

The obvious implementation builds the SVG from `shape.p`, the drawing points already in the
browser. Those points are RDP-thinned at 0.01 mm (`Geometry::SIMPLIFY_TOLERANCE`) and rounded to
`PRECISION = 2`, so every curve would export as a run of short segments. Accurate, but a circle
arrives in CAD as ~49 line segments you cannot dimension or constrain.

That turns out to be an artifact of one missing parameter rather than a limit of the format.

**The files carry real curve primitives.** A `.lbrn2` has `<Shape Type="Ellipse" Rx= Ry=>` and
`<Shape Type="Path">` whose `<VertList>` holds cubic bezier control points (`c0x c0y c1x c1y`) with
a `<PrimList>` of `B<a> <b>` segments — 42 of the 58 files in the corpus use `B` segments. DXF has
true `CIRCLE` and `ARC` entities. SVG has `<circle>`, `<ellipse>` and bezier `d` data.

**Both traversals already emit exact descriptors, and the thumbnails already use them:**

- `Lbrn2.each_geometry` yields `(cut_index, points, closed?, ellipse_or_nil, image_or_nil,
  object_id)` — `app/services/maker/previews/lbrn2.rb:255`
- `Dxf.each_geometry` yields `(layer, points, closed?, curve_or_nil, object_id)` —
  `app/services/maker/previews/dxf.rb:74`
- `Lbrn2.to_svg` draws a real `<ellipse>` from it (`lbrn2.rb:239`); `Dxf.to_svg` draws a real
  `<circle>` / `<path A>` (`dxf.rb:340`)

**The geometry payload throws them away**, because `Geometry::Collector#add` has no slot for one:

```ruby
def add(layer:, points:, closed:, object_id:, image: false)   # geometry.rb:121
```

so both call sites discard it by name — `_ellipse` at `lbrn_geometry.rb:67`, `_curve` at
`dxf_geometry.rb:37`. The ellipse is lost at the collector, not at the parser. Beziers are lost
one step earlier, flattened at parse (`BEZIER_SAMPLES = 12` per segment) with no descriptor
produced at all.

So the Measure view draws a 32-gon where the thumbnail beside it draws an ellipse.

**Scope decision.** This design carries the descriptors that already exist — ellipses and arcs — into
the payload. It does **not** add descriptors for bezier paths; that would mean new plumbing in three
geometry modules plus a bezier-aware client renderer, and is a separate arc if the polyline
approximation of a freeform curve ever proves insufficient in practice.

## Design

### Server: a `curve:` slot on the collector

`Geometry::Collector#add` gains `curve:` (default `nil`), emitted as a new optional shape key
`"g"` alongside the existing `o c b k i p d`. **In client space** — millimetres, Y-down — so
`measure_controller.js` continues to branch on no file type:

| primitive | payload value |
|---|---|
| ellipse / circle | `["e", cx, cy, rx, ry]` |
| arc | `["a", cx, cy, r, a0, delta]` |

An arc is stored as **centre, radius, start angle and SIGNED sweep in degrees**, with the client
resolving the endpoints itself. Millimetres round at `Geometry::PRECISION`; the two angles round at
`Geometry::ANGLE_PRECISION` (6), because `PRECISION` is a LENGTH and an angle error ε displaces a
point by `r·ε`. The Y-flip's orientation reversal is still resolved SERVER-side — it is the sign of
`delta` — so `measure_controller.js` still learns nothing about file types and reads both SVG flags
off `delta` alone (`large = |delta| > 180`, `sweep-flag = delta > 0`).

> *(This table's arc row read `["a", x0, y0, x1, y1, r, largeArc, sweep]` — **pre-resolved SVG
> `A`-command parameters** — until implementation on 2026-09-02, on the argument that resolving
> them server-side keeps Y-flip knowledge in the module that owns the flip. That form was built,
> reviewed and **found defective**: SVG's endpoint parameterisation puts the centre
> `sqrt(r² − d²)` from the chord midpoint, so an endpoint rounded to `PRECISION` displaces the
> whole arc by about `sqrt(2rδ)`. Measured: **1.37 mm of drawn error at r = 200** on a 180° slot
> end cap, beside `p` points in the same payload good to 0.005 mm — the descriptor was ~240× less
> faithful than the points it exists to improve on, and the error grew with the radius. The signed
> form is 0.00836 mm worst case over all 3600 start angles and flat in radius. The original
> argument was also wrong on its own terms: a signed delta resolved server-side carries no
> file-type knowledge either.)*

Three call sites stop discarding:

- **`LbrnGeometry.build`** — `_ellipse` → `ellipse`. **No transform needed:** `Lbrn2.each_geometry`
  yields points already in SVG space (composed affine, then Y-flip) and `ellipse_from` derives the
  descriptor from those same transformed points. `.mage` rides `LbrnGeometry` and gains it for free.
- **`DxfGeometry.build`** — `_curve` → `curve`, through a new `curve_to_client_space(curve, scale)`
  beside the existing `to_client_space(points, scale)`.
- **`SvgGeometry`** — the only genuinely new work. A new `ellipse_curve_for(node, world)` computes
  the descriptor and `walk` yields it alongside the points; `build` scales both by `sx`/`sy`. It
  must be **gated on the accumulated `world` transform being axis-aligned**, mirroring
  `Lbrn2.axis_aligned?` — a rotated `<circle>` is not an SVG ellipse and must stay a polygon.
  *(This read "`ellipse_contours` returns a descriptor" until implementation on 2026-09-02.
  `contours_for` returns `[[points, closed], ...]` across seven branches and only two of them can
  carry a descriptor, so it was left untouched rather than widened.)*

### What does not change, and why that is the whole safety argument

`b`, `d` and the job box are still computed from **full-resolution points**. The descriptor is
drawing-only.

This is not a new rule being introduced; it is the rule both traversals already state. `dxf.rb:80`:
*"`curve` is a RICHER RENDERING OF THE SAME POINTS, never a substitute for them … a measuring
caller reads the flattened points and is correct ignoring `curve` entirely."* `lbrn2.rb:258` says
the same. Carrying the descriptor into the payload extends that contract to a second consumer
without bending it.

**No circularity heuristic is involved anywhere.** A shape gets a descriptor because the *file*
said `Ellipse` / `CIRCLE` / `ARC`, never because it measured round. `Geometry.diameter`'s accepted
consequence — a genuine 16-gon reports as round — stays confined to the `d` label and never reaches
exported geometry. A designed 16-gon exports as a 16-gon.

**Accuracy is exact, not approximate.** `ellipse_from` derives `cx/cy/rx/ry` from the sampled
points' bounding box, and both sample counts are divisible by 4 — `Lbrn2::ELLIPSE_SAMPLES = 32`,
`SvgGeometry::ELLIPSE_SAMPLES = 64` — so an axis-aligned ellipse's axis extents are sampled
exactly. The descriptor recovers the original radii, which is why the tests assert `rx == 10.0`
rather than a tolerance.

### Client: one element builder, three consumers

`contourNode` exists **twice** today — `measure_controller.js:292` (class + layer colour + hit
twin) and `print_sheet.js:212` (black, 0.2 mm). A third copy in the exporter is this repo's
recorded failure shape: §14d's five `port_writable?` branches, §14b's four skip-list strings, the
third extension→role table.

**New module `app/javascript/lib/shape_svg.js`** exporting `shapeElement(doc, shape)`. It decides
**element type and geometry attributes only** — `<circle>` / `<ellipse>` / `<path A>` /
`<polygon>` / `<polyline>` — and returns a bare node. Each caller applies its own presentation:

*(`<circle>` was not in this list until implementation on 2026-09-02. An `["e", …]` descriptor with
`rx == ry` emits `<circle>` rather than an `<ellipse>` with equal radii: both draw the same picture,
but the export's stated destinations are a vector editor and a CAD sketch import, where `<circle>`
is the unambiguous primitive and an ellipse may arrive as a spline.)*

| caller | presentation |
|---|---|
| `measure_controller.js` | class, `stroke` presentation attribute, hit twin |
| `print_sheet.js` | `fill:none stroke:#000 stroke-width:0.2`, dashed for bitmaps |
| `export_svg.js` | `fill:none`, layer colour, `stroke-width:0.1` |

**The print sheet gets curves too, and it is a correctness fix rather than tidiness.** With
`ELLIPSE_SAMPLES = 32`, a ⌀50 mm circle's sampled chords sit **0.12 mm inside** the true curve
(`r(1 − cos(π/32))` with r = 25). The RDP thinning is bounded at 0.01 mm but cannot recover error
the sampler already introduced. That is visible on paper, on a sheet whose entire purpose is to be
measured and cut against.

The hit twin stays a `<polyline>` from `shape.p`: it is an invisible 8 px target, so approximating
an arc there costs nothing and keeps the twin one shape. Paint-order sorting still reads `s.b`, and
`.measure-contour { fill: transparent }` (`application.css:282`) makes an `<ellipse>` interior
clickable exactly as a `<polygon>` is.

### Client: the exporter

**New module `app/javascript/lib/export_svg.js`** exporting `exportSvg(shapes, { colors })` → a
string. Pure: it builds a detached document and serializes it, touching nothing on the page.

- union bbox of the selected shapes; one `<g transform="translate(-x0 -y0)">` so relative positions
  among several selected parts survive
- `width="{w}mm" height="{h}mm" viewBox="0 0 {w} {h}"` — the same scale mechanism as the print sheet
  and the boxes addon's `planSvgFor`, and what makes the canvas size *be* the part size
- per shape: `shapeElement` + `fill="none"` + `stroke = colors[shape.c] || "#000000"` +
  `stroke-width="0.1"`
- bitmaps export as the dashed rectangle they already show on screen and on paper — selected means
  exported, never silently dropped
- serialized with `XMLSerializer`, prefixed with an XML declaration

**No padding.** The stroke straddles the canvas edge by 0.05 mm. Keeping "a 60 mm part is a 60 mm
document" is worth more than padding the box to flatter a viewer, and stroke width is ignored
entirely on CAD import.

### Client: target-set resolution becomes structural

`print()` and `refreshPrintBar()` each spell the three arms today, under a comment stating they
"are two halves of one claim and must not drift." A third consumer makes that untenable. Extract
onto the controller:

- `targetShapes()` → the array: `marked.size ? [...marked] : selected ? [selected.__shape] : allShapes`
- `targetNoun()` → `"3 parts"` / `"selected"` / `"all"`

`print()`, `refreshPrintBar()` and the new `downloadSvg()` all read them. This is created by the
change rather than unrelated refactoring.

### UI

One button in the existing `.measure-actions` span in `app/views/files/_measure.html.erb`, between
Print and Reset:

```erb
<button type="button" class="btn small ghost" data-action="measure#downloadSvg"
        data-measure-target="svgButton">SVG</button>
```

Visible text stays `SVG` — the bar already carries six controls and a second count-bearing label is
noise — while its `aria-label` / `title` tracks the same arms ("Download 3 parts as SVG"), written
by `refreshPrintBar()`, which becomes the one place the bar's labels are set. The Print button's
count sits immediately beside it, so the target set is never hidden.

**Download:** `Blob` → `URL.createObjectURL` → hidden `<a download="{basename}-parts.svg">` → click
→ `revokeObjectURL`. Empty target returns early, the same guard `print()` carries. There is no
`MAX_SHEETS` analogue because there is no pagination.

`config/importmap.rb` pins `lib/` per file, so two new pin lines.

## Revisions

`Geometry::SHARED_REVISION` **0 → 1**. That one line is the correct edit: it moves
`LbrnGeometry::PAYLOAD_REVISION` (4 → 5), `DxfGeometry` (1 → 2) and `SvgGeometry` (1 → 2) together, and
propagates to all four formats since `.mage` reads `LbrnGeometry`. Correct because the change is in
the shared collector *and* in all three formats.

**`SCHEMA_VERSION` is deliberately NOT bumped.** Verified rather than reasoned: `FilesController#geometry`
resolves the row through `Maker::Previews::Enqueue.current_preview`, which matches on revision — so
a stale-revision row is **not found**, falls into the `preview.nil?` branch, enqueues and answers
`pending`. A pre-bump payload can never reach the client. The `"g"` key is additive and optional
regardless; bumping `v` would make `payload.v !== SCHEMA_VERSION` throw *"This preview needs a newer
version of the page — reload"* for payloads the client reads perfectly. §14h names `SCHEMA_VERSION`
as the easy thing to bump by mistake.

**Cost:** every already-measured file re-renders its geometry payload on next open — lazily, one job
per file actually opened, not a library sweep. Revisions are per kind, so **no thumbnails rebuild**;
that is precisely why `payload_revision(kind)` exists.

## The untested branch this closes

**No fixture in the repo has a rotated transform.** Every `<XForm>` across all seven `.lbrn2` and
two `.mage` fixtures is a translate or a scale, and `plate.svg`'s `<circle>` sits under
`transform="translate(10,10)"`. So `Lbrn2.axis_aligned?` is **already an untested branch** — deleting
the gate is a green mutation today.

This change raises its stakes: the gate stops governing only thumbnail crispness and starts
governing exported geometry. A rotated ellipse exported as an axis-aligned one is wrong geometry in
a file someone will cut.

**Add a rotated-ellipse fixture on both the lbrn2 and svg legs**, asserting no `"g"` key is emitted.
`plate.svg` must not be modified — its own header states that every number in it is an assertion.

## Testing

Two tiers, following `test/system/measure_print_test.rb`'s own split.

**Server (`bin/rails test`)**

- an `Ellipse` yields `["e", cx, cy, rx, ry]` with **exact** values (`rx == 10.0`, not a tolerance)
- a rotated ellipse yields no `"g"` key — the new fixtures
- a DXF `ARC` yields `["a", …]` with the Y-flip and unit scale applied
- an SVG `<circle>` under a translate yields a descriptor at the translated centre; under a rotate,
  none
- `b` and `d` assert **unchanged** against current values, so a regression in *measurement* is
  caught by the same test that adds *drawing*
- `GeometryTest`'s existing enumeration of `REVISIONED_BY` covers the revision arithmetic

**Browser, pure tier** — `import("lib/export_svg")` through `page.evaluate_async_script`, exactly as
`in_print_sheet` does. Assert the **wire format literally**: `width="20mm"`, `viewBox="0 0 20 20"`,
`<ellipse cx="10" … rx="10"`, `stroke="#ff0000"`. Never a round-trip through our own parser — §14e's
FakeS3 lesson, where inverse encode/decode kept 79 of 80 tests green over silent data loss.

**Browser, end-to-end** — real fixture, real `Select parts` clicks, real `SVG` click.
`ApplicationSystemTestCase` is `driven_by :selenium, using: :headless_chrome` with **no download
directory configured**, so rather than fight Chrome's download plumbing the test shims
`URL.createObjectURL` before the click and captures the Blob's text. That still drives the real
button and the real `targetShapes()` resolution.

**CSP** — a `blob:` anchor download is unverified territory and the policy is report-only. The system
tests already fail on SEVERE console messages, so this gets checked in a browser. §14e: a CSP header
that parses is not a CSP that works, and only a browser knows.

**Mutation checks** (§15, and each must be performed, not assumed):

| mutate | must go red |
|---|---|
| delete the `axis_aligned?` gate | the rotated-ellipse fixtures |
| `translate(-x0 -y0)` → `translate(0 0)` | the origin-normalization assertion |
| exporter re-derives size from `shape.p` | nothing — confirming that trap is structurally absent, since the exporter writes no labels |
| revert `SHARED_REVISION` to 0 | the revision-arithmetic assertions |
| emit a descriptor for every closed shape rather than only where the file supplied one | the 16-gon / square assertions |

## Explicitly out of scope

- **Bezier descriptors.** `.lbrn2` `B` segments and SVG path curves stay flattened. A separate arc
  if the polyline approximation proves insufficient in use.
- **Saving the export into the library.** The boxes addon does this for its plan, but it needs a
  server write path branching per backend (share/s3 POST bytes vs `chunk_remote`'s two-phase
  presigned upload) plus collision handling. The ask was a download.
- **DXF or PDF export.** SVG only.
- **Preserving original file coordinates.** Normalized to the origin; the alternative is recorded in
  case the "re-import alongside the original" case ever arises.
