# Box plan — to-scale export and print — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit the Box Generator's tray compartment plan at true 1:1 scale — printed, downloaded as SVG or PDF, and saved to the library — tiled across pages when it exceeds one sheet.

**Architecture:** Extract the coordinate maths out of `top_view.js`'s private `svg()` into a new `plan.js`, so the on-screen panel and every export read one model. `plan.js` also emits print marks (opening outlines via a slot lattice). `sheet.js` paginates into pages with overlap, alignment marks and a 100 mm calibration bar. `pdf.js` writes an uncompressed base-14 PDF. Everything is client-side, so publishing the bundle remains the entire deploy.

**Tech Stack:** Plain ES modules (no framework, no dependency), Rails 8 system tests via Capybara + headless Chrome.

**Spec:** `docs/superpowers/specs/2026-08-05-boxes-plan-print-to-scale-design.md`

---

## Where the code lives, and why the fixture comes first

The bundle ships from a **sibling repo**, `/Users/charlesschwartz/Desktop/tinkerex-addons`, at
`addons/boxes/*.js`. That repo has **no JS test runner at all**. The only automated coverage for
bundle JS is *this* repo's system tests running against a verbatim snapshot in
`test/fixtures/addons/boxes/`, and `tinkerex-addons/bin/check-fixture-drift` refuses to publish a
bundle that differs from that snapshot.

So the working order is: **write and test in this repo's fixture, mirror to the bundle repo at the
end** (Task 9). That is not a shortcut — the drift script enforces that the two are byte-identical,
so the fixture *is* the bundle. Developing in the bundle repo instead would mean copying after every
edit just to run a test.

One wrinkle to know before Task 9: `check-fixture-drift` defaults `TINKEREX_PATH` to `../tinkerex`,
which is the **main checkout**, not this worktree. Task 9 passes the worktree path explicitly.

## File structure

| File | Repo | Status | Responsibility |
|---|---|---|---|
| `test/fixtures/addons/boxes/plan.js` | tinkerex | create | coordinate model + print marks |
| `test/fixtures/addons/boxes/sheet.js` | tinkerex | create | pagination, calibration bar, marks, page labels |
| `test/fixtures/addons/boxes/pdf.js` | tinkerex | create | primitives → PDF bytes |
| `test/fixtures/addons/boxes/export.js` | tinkerex | create | SVG rendering + the four sinks (print/pdf/svg/library) |
| `test/fixtures/addons/boxes/top_view.js` | tinkerex | modify | consume `buildModel`; expose `getPlan()` |
| `test/fixtures/addons/boxes/editor.js` | tinkerex | modify | paper selector + Print/PDF/SVG controls; second file on save |
| `test/system/plan_export_test.rb` | tinkerex | create | all new system tests |
| `app/assets/stylesheets/application.css` | tinkerex | modify | layout for the new panel-header controls |
| `addons/boxes/*` | tinkerex-addons | mirror | the shipped bundle |

`export.js` is a fifth module the spec's table did not name: the sinks need a home, and putting
them in `editor.js` would push blob/iframe/print mechanics into a file whose job is the form.

## Reference — the fixture's TrayLayout generator

`test/support/fake_boxes_sidecar.rb` defines the generators the tests drive. `TrayLayout` defaults
to `sx = "50*3"`, `sy = "50*2"`, `thickness = 3.0`, every wall present. That model's outer size is
therefore, by `buildModel`'s own arithmetic:

- `w = 3 + 150 + 2×3 + 3 = 162 mm`
- `h = 3 + 100 + 1×3 + 3 = 109 mm`

162 × 109 mm fits one A4 printable area (190 × 277 mm), so it is the single-page case. `sx = "50*5"`
gives `w = 3 + 250 + 4×3 + 3 = 268 mm`, which tiles into two columns. These exact numbers are used
in the assertions below.

---

### Task 1: Extract the coordinate model into `plan.js`

Pure refactor. `test/system/tray_top_view_test.rb` is the test — it must stay green **unchanged**,
because it already asserts the drawing (`[data-compartment]` counts, the merge behaviour).

**Files:**
- Create: `test/fixtures/addons/boxes/plan.js`
- Modify: `test/fixtures/addons/boxes/top_view.js:76-88` (the head of `svg()`)

- [ ] **Step 1: Run the existing test to establish the baseline**

```bash
bin/rails test test/system/tray_top_view_test.rb
```

Expected: 5 runs, 0 failures. If it is not green before you start, stop — you cannot tell a
refactor regression from a pre-existing failure.

- [ ] **Step 2: Create `plan.js` with the model builder**

```js
import { compartments } from "./tray_layout.js"

// THE COORDINATE MODEL, in ONE place. Both the on-screen panel (top_view.js's svg()) and every
// to-scale export read colX/rowY/w/h/t from here, so a printed sheet cannot disagree with the
// drawing it was printed from. A print routine that recomputed compartment positions itself would
// be a second copy of this arithmetic, which is this repo's recorded failure shape (§14d's
// `roleFor`, a third copy of a vocabulary, drifted twice).
//
// Every value is in MILLIMETRES, origin at the plan's top-left — the outside face of the outer
// wall — with y increasing DOWNWARD (SVG's convention; pdf.js flips it).
//
// Lifted verbatim from top_view.js's svg(): the grid is RIGID, so a cell sits at the same place
// whether or not its walls are drawn, and a removed wall hands its own thickness to the
// compartment. That is why a merged compartment is wider than its two cells added together.
export function buildModel({ cols, rows, hwalls, vwalls }, thickness) {
  const t = Number(thickness) > 0 ? Number(thickness) : 3
  const nc = cols.length, nr = rows.length
  const sum = (a) => a.reduce((x, y) => x + y, 0)
  const hasL = vwalls.some((r) => r[0]), hasT = hwalls[0].some(Boolean)
  const x0 = hasL ? t : 0, y0 = hasT ? t : 0
  const colX = (c) => x0 + sum(cols.slice(0, c)) + c * t
  const rowY = (r) => y0 + sum(rows.slice(0, r)) + r * t
  const w = x0 + sum(cols) + (nc - 1) * t + (vwalls.some((r) => r[nc]) ? t : 0)
  const h = y0 + sum(rows) + (nr - 1) * t + (hwalls[nr].some(Boolean) ? t : 0)
  const { id, groups } = compartments({ cols, rows, hwalls, vwalls })
  return { cols, rows, hwalls, vwalls, nc, nr, t, x0, y0, colX, rowY, w, h, id, groups, sum }
}
```

- [ ] **Step 3: Rewire `top_view.js` to consume it**

Add to the imports at the top of `top_view.js`:

```js
import { buildModel } from "./plan.js"
```

Replace the head of `svg()` — currently lines 76-88, from `function svg(...)` down to and including
the `const out = []` line — with this. Everything below `const out = []` stays exactly as it is:

```js
function svg(m, id, groups, t) {
  const { cols, rows, hwalls, vwalls, nc, nr, colX, rowY, w, h, sum } = buildModel(m, t)
  void id; void groups // the caller's copies; buildModel recomputes them identically

  const out = []
```

Then, in `draw()`, replace the `compartments(m)` call and the `canvas.innerHTML` line with:

```js
    const model = buildModel(m, t)
    const { id, groups } = model
    lastModel = model

    canvas.innerHTML = svg(m, id, groups, t)
```

and declare `let lastModel = null` immediately above `const draw = () => {`.

- [ ] **Step 4: Expose the model for the exporters**

At the end of `mountTopView`, change the returned object to:

```js
  return {
    // The LAST GOOD model — mid-edit the art is routinely unparseable and draw() deliberately
    // leaves the previous drawing up, so an export must use what is on screen, not refuse.
    getPlan: () => lastModel,
    destroy() {
      root.removeEventListener("input", redraw)
      root.removeEventListener("change", redraw)
    },
  }
```

- [ ] **Step 5: Run the test — it must still pass, unchanged**

```bash
bin/rails test test/system/tray_top_view_test.rb
```

Expected: 5 runs, 0 failures. A refactor that changes the drawing is a bug, not a refactor.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/addons/boxes/plan.js test/fixtures/addons/boxes/top_view.js
git commit -m "refactor(boxes): extract the plan coordinate model into plan.js"
```

---

### Task 2: `printPrims` — opening outlines via the slot lattice

**Files:**
- Modify: `test/fixtures/addons/boxes/plan.js`
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/system/plan_export_test.rb`:

```ruby
require "application_system_test_case"
require_relative "support/fake_boxes_sidecar"

# The to-scale export of the tray compartment plan: outlines, pagination, SVG, PDF and print.
#
# WHY THESE ASSERT THE WIRE FORMAT. §14e: FakeS3 decoded copy_source with the exact inverse of the
# encoder, so 79/80 tests were green over silent permanent data loss. Parsing our own PDF with our
# own reader would be that shape again. So these assert the BYTES a viewer will see — the literal
# `width="162mm"`, the literal `/MediaBox [...]` — never a round-trip through our own code.
#
# The bundle is loaded through the real host asset proxy and its modules are imported directly in
# the browser, so what is under test is the shipped artifact, not a Ruby transliteration of it.
class PlanExportTest < ApplicationSystemTestCase
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    FakeBoxesSidecar.install!
    sign_in_as "planexport@example.com"
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  # Import a bundle module through the host's real asset proxy and run `body` against it. The page
  # must already be an addon page so the session cookie and same-origin both hold.
  def in_module(specifier, body)
    visit tools_addon_path("boxes")
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("/tools/boxes/asset/#{specifier}")
        .then((m) => done(#{body}))
        .catch((e) => done("ERROR: " + e.message));
    JS
  end

  # A 2x1 tray, both walls present -> two separate compartments, so the shared wall shows TWO
  # opening edges (one per face), not one line down the middle.
  test "an unmerged wall draws both of its faces" do
    count = in_module("plan.js", <<~JS)
      (() => {
        const model = m.buildModel({
          cols: [50, 50], rows: [40],
          hwalls: [[true, true], [true, true]],
          vwalls: [[true, true, true]],
        }, 3)
        const prims = m.printPrims(model)
        const xs = prims.filter((p) => p.kind === "line" && p.x1 === p.x2).map((p) => p.x1)
        return JSON.stringify([...new Set(xs)].sort((a, b) => a - b))
      })()
    JS

    # Walls at x = 0..3, 53..56, 106..109. The openings are [3,53] and [56,106], so the vertical
    # outline lines sit at exactly those four faces.
    assert_equal "[3,53,56,106]", count
  end

  # The same tray with the middle wall REMOVED: one compartment, and the two inner faces are gone.
  # This is the assertion that proves merged cells have no seam down the middle.
  test "a removed wall leaves one opening with no internal seam" do
    xs = in_module("plan.js", <<~JS)
      (() => {
        const model = m.buildModel({
          cols: [50, 50], rows: [40],
          hwalls: [[true, true], [true, true]],
          vwalls: [[true, false, true]],
        }, 3)
        const prims = m.printPrims(model)
        const xs = prims.filter((p) => p.kind === "line" && p.x1 === p.x2).map((p) => p.x1)
        return JSON.stringify([...new Set(xs)].sort((a, b) => a - b))
      })()
    JS

    assert_equal "[3,106]", xs
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: FAIL — both tests return `"ERROR: m.printPrims is not a function"`.

- [ ] **Step 3: Implement `printPrims`**

Append to `plan.js`:

```js
const WALL = -1

// The print marks: hairline OPENING OUTLINES, no fills. NO INSET — read this before "fixing" it.
// A wall is drawn at colX(i) - t with width t (top_view.js), so it occupies [colX(c) - t, colX(c)]
// and its inner face IS the cell boundary colX(c). Insetting by t/2 would make every opening t too
// small on both axes, which is precisely the error a 1:1 fit-check exists to avoid.
//
// The outline is computed on a SLOT LATTICE rather than by merging rectangles, because the lattice
// is correct by construction: (2*nc+1) x (2*nr+1) slots, odd = cell, even = the wall band between
// (width t, or 0 at an outer edge with no outer wall). Label every slot with a compartment id or
// WALL, then emit a segment wherever two adjacent labels differ. Absent walls take the id of the
// cells they join, so a merged run has no internal edge; present walls are WALL, so both faces
// show.
export function printPrims(model) {
  const { cols, rows, hwalls, vwalls, nc, nr, t, x0, y0, colX, rowY, w, h, id, groups } = model

  // Slot boundary coordinates. xs has 2*nc+2 entries: the edges of every band and cell in order.
  const xs = [ 0 ]
  for (let c = 0; c < nc; c++) { xs.push(colX(c)); xs.push(colX(c) + cols[c]) }
  xs.push(w)
  const ys = [ 0 ]
  for (let r = 0; r < nr; r++) { ys.push(rowY(r)); ys.push(rowY(r) + rows[r]) }
  ys.push(h)

  const NX = 2 * nc + 1, NY = 2 * nr + 1
  const at = (i, j) => (i < 0 || j < 0 || i >= NX || j >= NY ? WALL : label[j][i])
  const label = []
  for (let j = 0; j < NY; j++) {
    const row = []
    for (let i = 0; i < NX; i++) row.push(slotLabel(i, j))
    label.push(row)
  }

  function slotLabel(i, j) {
    const oddI = i % 2 === 1, oddJ = j % 2 === 1
    const c = (i - 1) / 2, r = (j - 1) / 2
    if (oddI && oddJ) return id[r][c]                              // a cell
    if (oddI && !oddJ) {                                           // horizontal band above row j/2
      const rr = j / 2
      if (rr === 0 || rr === nr || hwalls[rr][c]) return WALL
      return id[rr - 1][c] === id[rr][c] ? id[rr][c] : WALL
    }
    if (!oddI && oddJ) {                                           // vertical band left of col i/2
      const cc = i / 2
      if (cc === 0 || cc === nc || vwalls[r][cc]) return WALL
      return id[r][cc - 1] === id[r][cc] ? id[r][cc] : WALL
    }
    // a corner: part of an opening only when all four touching cells are one compartment
    const cc = i / 2, rr = j / 2
    if (cc === 0 || cc === nc || rr === 0 || rr === nr) return WALL
    const k = id[rr - 1][cc - 1]
    return (id[rr - 1][cc] === k && id[rr][cc - 1] === k && id[rr][cc] === k) ? k : WALL
  }

  const prims = []
  const line = (x1, y1, x2, y2, role) => prims.push({ kind: "line", x1, y1, x2, y2, role })

  for (let j = 0; j < NY; j++) {
    for (let i = 0; i < NX; i++) {
      const me = at(i, j)
      if (me === WALL) continue
      if (at(i - 1, j) !== me) line(xs[i], ys[j], xs[i], ys[j + 1], "opening")
      if (at(i + 1, j) !== me) line(xs[i + 1], ys[j], xs[i + 1], ys[j + 1], "opening")
      if (at(i, j - 1) !== me) line(xs[i], ys[j], xs[i + 1], ys[j], "opening")
      if (at(i, j + 1) !== me) line(xs[i], ys[j + 1], xs[i + 1], ys[j + 1], "opening")
    }
  }

  // The tray's own outside edge, heavier — without it the sheet reads as loose boxes rather than
  // as a tray, and there is nothing to check the outside dimension against.
  line(0, 0, w, 0, "outline"); line(0, h, w, h, "outline")
  line(0, 0, 0, h, "outline"); line(w, 0, w, h, "outline")

  prims.push(...labels(model))
  return prims
}

// Compartment size labels, at a PRINT type scale. On screen the size is computed in millimetres —
// up to a 9 mm character — which is absurd at 1:1 on paper. Clamp to 2.5-4 mm (roughly 7-11 pt),
// still derived from the compartment so a narrow one gets a smaller label, and drop a label that
// would overrun its own compartment rather than let it run into the neighbour.
function labels({ cols, rows, t, colX, rowY, groups, sum }) {
  const out = []
  for (const cells of groups) {
    const rs = cells.map((v) => v[0]), cs = cells.map((v) => v[1])
    const r0 = Math.min(...rs), r1 = Math.max(...rs)
    const c0 = Math.min(...cs), c1 = Math.max(...cs)
    const cw = sum(cols.slice(c0, c1 + 1)) + (c1 - c0) * t
    const ch = sum(rows.slice(r0, r1 + 1)) + (r1 - r0) * t
    const rect = cells.length === (r1 - r0 + 1) * (c1 - c0 + 1)
    const text = rect ? `${round(cw)}×${round(ch)}` : "irregular"
    const size = Math.max(2.5, Math.min(4, cw / 12, ch / 4))
    if (text.length * size * 0.55 > cw || size > ch) continue
    out.push({
      kind: "text", x: colX(c0) + cw / 2, y: rowY(r0) + ch / 2, text, size, role: "label",
    })
  }
  return out
}

const round = (v) => (Math.round(v * 10) / 10).toString().replace(/\.0$/, "")
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: 2 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/addons/boxes/plan.js test/system/plan_export_test.rb
git commit -m "feat(boxes): print marks for the compartment plan (opening outlines, labels)"
```

---

### Task 3: `sheet.js` — pagination, calibration bar, marks

**Files:**
- Create: `test/fixtures/addons/boxes/sheet.js`
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing tests**

Append inside `PlanExportTest`:

```ruby
  # 268 x 109 mm on A4 (210 x 297, 10 mm margins -> 190 x 277 printable, 10 mm overlap -> 180 mm
  # of new content per tile after the first): two columns, one row.
  test "a plan wider than the sheet tiles into two pages" do
    result = in_module("sheet.js", <<~JS)
      (() => {
        const pages = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return JSON.stringify({ n: pages.pages.length, cols: pages.cols, rows: pages.rows })
      })()
    JS

    assert_equal({ "n" => 2, "cols" => 2, "rows" => 1 }, JSON.parse(result))
  end

  # MUTATION TARGET: drop the overlap from the tile origin and this goes red. The second tile must
  # start one overlap band BEFORE the first tile ended, or there is nothing to align and tape by.
  test "the second tile repeats an overlap band of the first" do
    dx = in_module("sheet.js", <<~JS)
      (() => {
        const pages = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return String(pages.pages[1].originX - pages.pages[0].originX)
      })()
    JS

    assert_equal "180", dx, "printable 190 mm minus a 10 mm overlap band"
  end

  test "a plan that fits produces one page through the same path" do
    n = in_module("sheet.js", <<~JS)
      String(m.paginate({ w: 162, h: 109, prims: [] }, m.PAPERS.A4).pages.length)
    JS

    assert_equal "1", n
  end

  # Every page carries its own bar: pages get separated, and a partial print is exactly when a
  # scale error most needs catching.
  test "every page carries a 100 mm calibration bar" do
    bars = in_module("sheet.js", <<~JS)
      (() => {
        const pages = m.paginate({ w: 268, h: 109, prims: [] }, m.PAPERS.A4)
        return JSON.stringify(pages.pages.map((p) =>
          p.prims.filter((q) => q.role === "calib-bar")
                 .map((q) => Math.round(q.x2 - q.x1))))
      })()
    JS

    assert_equal "[[100],[100]]", bars
  end

  test "an absurd plan is refused rather than printing hundreds of sheets" do
    err = in_module("sheet.js", <<~JS)
      (() => {
        try { m.paginate({ w: 5000, h: 5000, prims: [] }, m.PAPERS.A4); return "no error" }
        catch (e) { return e.message }
      })()
    JS

    assert_match(/\\A784 sheets/, err)
    assert_match(/5000 × 5000/, err)
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: the 5 new tests FAIL with `ERROR: Failed to fetch dynamically imported module` (there is
no `sheet.js` yet).

- [ ] **Step 3: Implement `sheet.js`**

```js
// Pagination and sheet furniture. Knows nothing about SVG or PDF — it takes primitives in
// millimetres and returns pages of primitives in millimetres, page-local.
//
// A plan that fits produces ONE page through this same path; there is no separate small-tray
// branch to keep in step.

export const PAPERS = {
  A4:       { name: "A4",       w: 210,   h: 297 },
  Letter:   { name: "Letter",   w: 215.9, h: 279.4 },
  A3:       { name: "A3",       w: 297,   h: 420 },
  Tabloid:  { name: "Tabloid",  w: 279.4, h: 431.8 },
}

// 10 mm clears the two common hardware limits (0.25 in = 6.35 mm, 0.5 in = 12.7 mm) on every
// consumer inkjet and laser we care about.
export const MARGIN = 10
// Repeated content on the right and bottom of each tile: something to align and tape against
// rather than a butt joint.
export const OVERLAP = 10
// A typo'd sx of 5000 would otherwise try to print several hundred sheets.
export const MAX_SHEETS = 40

export function paginate({ w, h, prims }, paper) {
  const pw = paper.w - MARGIN * 2, ph = paper.h - MARGIN * 2
  const stepX = pw - OVERLAP, stepY = ph - OVERLAP
  const cols = w <= pw ? 1 : Math.ceil((w - OVERLAP) / stepX)
  const rows = h <= ph ? 1 : Math.ceil((h - OVERLAP) / stepY)

  if (cols * rows > MAX_SHEETS) {
    throw new Error(
      `${cols * rows} sheets — this plan is ${round(w)} × ${round(h)} mm, which is more than ` +
      `${MAX_SHEETS} sheets of ${paper.name}. Check sx/sy, or choose a larger paper size.`)
  }

  const pages = []
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const originX = cols === 1 ? 0 : c * stepX
      const originY = rows === 1 ? 0 : r * stepY
      pages.push({
        paper, originX, originY, col: c, row: r, cols, rows,
        prims: [
          ...translate(clip(prims, originX, originY, pw, ph), MARGIN - originX, MARGIN - originY),
          ...furniture(paper, pw, ph, c, r, cols, rows),
        ],
      })
    }
  }
  return { cols, rows, pages }
}

// Keep anything that touches this tile. Cheap bounding-box test — a line crossing the tile is kept
// whole and simply drawn past the edge, which the printer's own margin then trims. Exact clipping
// would buy nothing: the overlap band already guarantees a mark near an edge appears on both tiles.
function clip(prims, ox, oy, pw, ph) {
  return prims.filter((p) => {
    const x1 = p.kind === "line" ? Math.min(p.x1, p.x2) : p.x - (p.size ?? 0) * 4
    const x2 = p.kind === "line" ? Math.max(p.x1, p.x2) : p.x + (p.size ?? 0) * 4
    const y1 = p.kind === "line" ? Math.min(p.y1, p.y2) : p.y - (p.size ?? 0)
    const y2 = p.kind === "line" ? Math.max(p.y1, p.y2) : p.y + (p.size ?? 0)
    return x2 >= ox && x1 <= ox + pw && y2 >= oy && y1 <= oy + ph
  })
}

function translate(prims, dx, dy) {
  return prims.map((p) => (p.kind === "line"
    ? { ...p, x1: p.x1 + dx, y1: p.y1 + dy, x2: p.x2 + dx, y2: p.y2 + dy }
    : { ...p, x: p.x + dx, y: p.y + dy }))
}

function furniture(paper, pw, ph, c, r, cols, rows) {
  const out = []
  const line = (x1, y1, x2, y2, role) => out.push({ kind: "line", x1, y1, x2, y2, role })

  // Trim crosshairs at the printable corners.
  for (const [ x, y ] of [ [ MARGIN, MARGIN ], [ MARGIN + pw, MARGIN ],
                           [ MARGIN, MARGIN + ph ], [ MARGIN + pw, MARGIN + ph ] ]) {
    line(x - 4, y, x + 4, y, "mark")
    line(x, y - 4, x, y + 4, "mark")
  }

  // The calibration bar, bottom-left inside the printable area: 100 mm with a tick every 10 mm.
  // This is the ONLY defence against the browser print dialog's "Fit to printable area", which
  // rescales silently and which no page can detect.
  const by = MARGIN + ph - 6
  line(MARGIN, by, MARGIN + 100, by, "calib-bar")
  for (let i = 0; i <= 100; i += 10) line(MARGIN + i, by, MARGIN + i, by - 3, "calib-tick")
  out.push({ kind: "text", x: MARGIN + 50, y: by + 4.5, size: 3,
             text: "100 mm — check with a ruler", role: "calib-label", anchor: "middle" })

  // Registration for taping tiles together. Not the title block that was declined: on a single
  // sheet there is nothing to register, so it is omitted entirely.
  if (cols * rows > 1) {
    out.push({ kind: "text", x: MARGIN + pw, y: by + 4.5, size: 3, anchor: "end",
               text: `Sheet ${c + 1},${r + 1} of ${cols}×${rows}`, role: "page-label" })
  }
  return out
}

const round = (v) => (Math.round(v * 10) / 10).toString().replace(/\.0$/, "")
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: 7 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/addons/boxes/sheet.js test/system/plan_export_test.rb
git commit -m "feat(boxes): paginate the plan onto sheets with overlap and a calibration bar"
```

---

### Task 4: `export.js` — the SVG renderer

**Files:**
- Create: `test/fixtures/addons/boxes/export.js`
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  # THE WIRE FORMAT. A viewBox alone is what the panel already had, and it is exactly what is NOT
  # to scale — the physical width/height attributes are the whole feature.
  # MUTATION TARGET: drop the "mm" suffix and this goes red.
  test "a page SVG carries its physical size in millimetres" do
    head = in_module("export.js", <<~JS)
      (() => {
        const svg = m.pageSvg({ paper: { name: "A4", w: 210, h: 297 }, prims: [] })
        return svg.slice(0, svg.indexOf(">") + 1)
      })()
    JS

    assert_includes head, 'width="210mm"'
    assert_includes head, 'height="297mm"'
    assert_includes head, 'viewBox="0 0 210 297"'
  end

  # The untitled full-size plan is what goes to the library: tiling is a property of the printer,
  # not of the drawing.
  test "the library SVG is the whole untiled plan at full size" do
    head = in_module("export.js", <<~JS)
      (() => {
        const svg = m.planSvg({ w: 268, h: 109, prims: [] })
        return svg.slice(0, svg.indexOf(">") + 1)
      })()
    JS

    assert_includes head, 'width="268mm"'
    assert_includes head, 'height="109mm"'
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: the 2 new tests FAIL — no `export.js`.

- [ ] **Step 3: Implement the renderer half of `export.js`**

```js
import { printPrims } from "./plan.js"
import { paginate, PAPERS, MARGIN } from "./sheet.js"
import { buildPdf } from "./pdf.js"

// The renderers and the four sinks. Everything below emits MILLIMETRES: one SVG user unit is one
// millimetre, and the root carries width/height in mm so the drawing has a physical size rather
// than merely a shape. A viewBox alone is what the on-screen panel already had — and is exactly
// what is not to scale.

const STROKE = { opening: 0.25, outline: 0.5, mark: 0.25, "calib-bar": 0.4, "calib-tick": 0.3 }

export function pageSvg({ paper, prims }) {
  return svgDoc(paper.w, paper.h, prims)
}

export function planSvg({ w, h, prims }) {
  return svgDoc(w, h, prims)
}

function svgDoc(w, h, prims) {
  const body = prims.map(prim).join("")
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${n(w)}mm" height="${n(h)}mm" ` +
         `viewBox="0 0 ${n(w)} ${n(h)}">` +
         `<g fill="none" stroke="#000" stroke-linecap="square">${body}</g></svg>`
}

function prim(p) {
  if (p.kind === "line") {
    return `<line x1="${n(p.x1)}" y1="${n(p.y1)}" x2="${n(p.x2)}" y2="${n(p.y2)}" ` +
           `stroke-width="${STROKE[p.role] ?? 0.25}"/>`
  }
  return `<text x="${n(p.x)}" y="${n(p.y)}" font-family="Helvetica, Arial, sans-serif" ` +
         `font-size="${n(p.size)}" text-anchor="${p.anchor ?? "middle"}" ` +
         `dominant-baseline="middle" fill="#000" stroke="none">${esc(p.text)}</text>`
}

const n = (v) => (Math.round(v * 100) / 100).toString()
const esc = (s) => String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]))

// The whole plan, full size, untiled — what goes to the library.
export function planSvgFor(model) {
  return planSvg({ w: model.w, h: model.h, prims: printPrims(model) })
}

export function pagesFor(model, paperName) {
  return paginate({ w: model.w, h: model.h, prims: printPrims(model) }, PAPERS[paperName])
}
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: 9 runs, 0 failures. (`pdf.js` does not exist yet, so if the import of `buildPdf` breaks
the module load, comment that import out and restore it in Task 5 — note it in the commit.)

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/addons/boxes/export.js test/system/plan_export_test.rb
git commit -m "feat(boxes): render the plan to millimetre-dimensioned SVG"
```

---

### Task 5: `pdf.js`

**Files:**
- Create: `test/fixtures/addons/boxes/pdf.js`
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the PDF declares its page size in points" do
    head = in_module("pdf.js", <<~JS)
      (() => {
        const bytes = m.buildPdf([ { paper: { name: "A4", w: 210, h: 297 }, prims: [] } ])
        return new TextDecoder("latin1").decode(bytes)
      })()
    JS

    assert head.start_with?("%PDF-1.4"), "not a PDF: #{head[0, 40].inspect}"
    assert_includes head, "/MediaBox [0 0 595.28 841.89]"
    assert_includes head, "/BaseFont /Helvetica"
    assert_includes head, "%%EOF"
  end

  # THE Y-FLIP. PDF's origin is bottom-left; SVG's is top-left. A flipped plan is INVISIBLE on a
  # symmetric tray, so this uses a deliberately asymmetric one — a line 10 mm from the TOP must
  # land 287 mm up the page, not 10.
  # MUTATION TARGET: remove the flip in pdf.js and this goes red.
  test "PDF coordinates are flipped from SVG's top-left origin" do
    body = in_module("pdf.js", <<~JS)
      (() => {
        const bytes = m.buildPdf([ { paper: { name: "A4", w: 210, h: 297 },
          prims: [ { kind: "line", x1: 0, y1: 10, x2: 50, y2: 10, role: "outline" } ] } ])
        return new TextDecoder("latin1").decode(bytes)
      })()
    JS

    # 297 - 10 = 287 mm = 813.54 pt. The unflipped value would be 28.35.
    assert_includes body, "813.54 l"
    assert_not_includes body, "28.35 l"
  end

  # The one non-ASCII character in the whole drawing. \\327 is × under WinAnsiEncoding, and being an
  # octal escape it keeps the file byte-for-byte ASCII.
  test "the multiplication sign is emitted as an octal escape" do
    body = in_module("pdf.js", <<~JS)
      (() => {
        const bytes = m.buildPdf([ { paper: { name: "A4", w: 210, h: 297 },
          prims: [ { kind: "text", x: 50, y: 50, size: 3, text: "120×80", role: "label" } ] } ])
        const s = new TextDecoder("latin1").decode(bytes)
        return JSON.stringify({ body: s, ascii: [...bytes].every((b) => b < 128) })
      })()
    JS

    parsed = JSON.parse(body)
    assert_includes parsed["body"], "(120\\32780) Tj"
    assert parsed["ascii"], "the PDF must stay byte-for-byte ASCII"
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: the 3 new tests FAIL — no `pdf.js`.

- [ ] **Step 3: Implement `pdf.js`**

```js
// A minimal PDF 1.4 writer, for a drawing that is only axis-aligned lines and short text. No
// compression, no font embedding (Helvetica is one of the base-14 fonts every viewer has), no
// dependency — which is why this is ~120 lines rather than a vendored library, and why §9's
// licence constraint never comes up.
//
// THE Y-AXIS FLIPS. SVG's y grows downward from the top-left; PDF's grows upward from the
// bottom-left. Every coordinate is transformed on the way in. This is the most dangerous line in
// the module because a flipped plan is INVISIBLE on a symmetric tray — the tests use an asymmetric
// one for exactly that reason.

const PT = 72 / 25.4 // millimetres -> points

export function buildPdf(pages) {
  const objects = [] // 1-based; objects[i] is the body of object i+1
  const add = (body) => { objects.push(body); return objects.length }

  const fontId = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica " +
                     "/Encoding /WinAnsiEncoding >>")
  const pagesId = objects.length + 1 + pages.length * 2 + 1 // reserved below
  const kids = []

  for (const page of pages) {
    const content = contentStream(page)
    const streamId = add(`<< /Length ${content.length} >>\nstream\n${content}\nendstream`)
    const pageId = add(
      `<< /Type /Page /Parent ${pagesId} 0 R ` +
      `/MediaBox [0 0 ${pt(page.paper.w)} ${pt(page.paper.h)}] ` +
      `/Resources << /Font << /F1 ${fontId} 0 R >> >> /Contents ${streamId} 0 R >>`)
    kids.push(pageId)
  }

  const realPagesId = add(
    `<< /Type /Pages /Count ${kids.length} /Kids [${kids.map((k) => `${k} 0 R`).join(" ")}] >>`)
  const catalogId = add(`<< /Type /Catalog /Pages ${realPagesId} 0 R >>`)

  // The /Parent references above were written against a PREDICTED id. Predicting offsets is how
  // this kind of writer goes wrong, so assert rather than hope.
  if (realPagesId !== pagesId) throw new Error(`pdf: /Parent mispredicted (${pagesId} vs ${realPagesId})`)

  return assemble(objects, catalogId)
}

function contentStream({ paper, prims }) {
  const H = paper.h
  const out = []
  let width = null
  for (const p of prims) {
    if (p.kind === "line") {
      const w = strokeWidth(p.role)
      if (w !== width) { out.push(`${num(w * PT)} w`); width = w }
      out.push(`${pt(p.x1)} ${pt(H - p.y1)} m ${pt(p.x2)} ${pt(H - p.y2)} l S`)
    } else {
      const size = p.size * PT
      // PDF has no text-anchor: shift by an estimate of the string width. Helvetica's average
      // advance is ~0.5 em, which is close enough for a label that only has to sit inside a
      // compartment it was already measured against.
      const est = p.text.length * size * 0.5
      const dx = p.anchor === "end" ? -est : p.anchor === "start" ? 0 : -est / 2
      out.push(`BT /F1 ${num(size)} Tf ${num(p.x * PT + dx)} ${num((H - p.y) * PT - size * 0.35)} Td ` +
               `(${escapeText(p.text)}) Tj ET`)
    }
  }
  return out.join("\n")
}

function strokeWidth(role) {
  return { opening: 0.25, outline: 0.5, mark: 0.25, "calib-bar": 0.4, "calib-tick": 0.3 }[role] ?? 0.25
}

// Keeps the file ASCII: \( \) \\ are required by the format, and \327 is × under WinAnsiEncoding.
function escapeText(s) {
  return String(s).replace(/[\\()]/g, (c) => `\\${c}`).replace(/[-￿]/g, (c) => {
    const code = c.charCodeAt(0)
    return code === 0x00d7 ? "\\327" : "?" // × is the only non-ASCII character this drawing emits
  })
}

function assemble(objects, catalogId) {
  let out = "%PDF-1.4\n"
  const offsets = []
  objects.forEach((body, i) => {
    offsets.push(out.length)
    out += `${i + 1} 0 obj\n${body}\nendobj\n`
  })
  const xref = out.length
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  for (const off of offsets) out += `${String(off).padStart(10, "0")} 00000 n \n`
  out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\n` +
         `startxref\n${xref}\n%%EOF\n`

  const bytes = new Uint8Array(out.length)
  for (let i = 0; i < out.length; i++) bytes[i] = out.charCodeAt(i) & 0xff
  return bytes
}

const num = (v) => (Math.round(v * 100) / 100).toString()
const pt = (mm) => num(mm * PT)
```

- [ ] **Step 4: Run the tests**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: 12 runs, 0 failures.

- [ ] **Step 5: Open a generated PDF in a real viewer — do not skip this**

§14e: a fake that shares the code's misunderstanding confirms it. Our tests read our own bytes, so
one check against real software is required.

```bash
bin/rails runner 'puts "generate a PDF via the UI, save it to ~/Downloads, then: open -a Preview <file>"'
```

Generate a plan PDF through the running app (Task 6 wires the button) and open it in Preview. It
must render, show the tray, and report A4 in Tools → Show Inspector. Record the result in the
commit message.

- [ ] **Step 6: Commit**

```bash
git add test/fixtures/addons/boxes/pdf.js test/system/plan_export_test.rb
git commit -m "feat(boxes): write the plan as an uncompressed base-14 PDF"
```

---

### Task 6: The four sinks and the UI controls

**Files:**
- Modify: `test/fixtures/addons/boxes/export.js`
- Modify: `test/fixtures/addons/boxes/editor.js:60-68` (the top-view panel) and its mount block
- Modify: `app/assets/stylesheets/application.css:286-293`
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
  test "the top view offers print and export controls" do
    visit tools_addon_path("boxes")
    find(".addon-card", text: "TrayLayout").click
    assert_selector ".box-topview svg", wait: 5

    assert_selector '[data-export="print"]'
    assert_selector '[data-export="pdf"]'
    assert_selector '[data-export="svg"]'
    assert_selector '[data-export="paper"]'
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The print surface is a hidden iframe: not window.open (popup blockers) and not a print-only
  # div in the host page (it would have to hide chrome the addon does not own). Asserting on the
  # iframe's real document is asserting on exactly what the printer receives.
  test "printing builds a sheet whose SVG is sized in millimetres" do
    visit tools_addon_path("boxes")
    find(".addon-card", text: "TrayLayout").click
    assert_selector ".box-topview svg", wait: 5

    find('[data-export="print"]').click
    head = page.evaluate_script(<<~JS)
      (() => {
        const f = document.querySelector("iframe.plan-print-frame")
        if (!f) return "NO FRAME"
        const s = f.contentDocument.querySelector("svg")
        return s ? s.outerHTML.slice(0, s.outerHTML.indexOf(">") + 1) : "NO SVG"
      })()
    JS

    assert_includes head, 'width="210mm"'
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # A generator with no compartments has no panel, so it has no controls and needs no gate of its
  # own — the same self-gating that keeps FrontPanel out.
  test "a generator with no compartments offers no export controls" do
    visit tools_addon_path("boxes")
    find(".addon-card", text: "ABox").click
    assert_selector ".box-preview"

    assert page.has_no_selector?('[data-export="print"]')
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: the 3 new tests FAIL on the missing `[data-export]` selectors.

- [ ] **Step 3: Add the sinks to `export.js`**

Append:

```js
// THE FOUR SINKS. All of them render the SAME model through the same renderers above, so what you
// print, download and save cannot disagree with the panel you are looking at.

const PRINT_FRAME_CLASS = "plan-print-frame"

// A hidden iframe, deliberately, and not the two alternatives: window.open can be eaten by a popup
// blocker, and a print-only container in the host page would mean injecting a <style> that hides
// chrome this bundle does not own.
export function printPlan(model, paperName) {
  const { pages } = pagesFor(model, paperName)
  const paper = PAPERS[paperName]

  document.querySelector(`.${PRINT_FRAME_CLASS}`)?.remove()
  const frame = document.createElement("iframe")
  frame.className = PRINT_FRAME_CLASS
  frame.setAttribute("aria-hidden", "true")
  frame.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;opacity:0;border:0"
  document.body.appendChild(frame)

  const doc = frame.contentDocument
  doc.open()
  doc.write(
    `<!doctype html><html><head><meta charset="utf-8"><title>Tray plan</title><style>` +
    `@page { size: ${paper.w}mm ${paper.h}mm; margin: 0 }` +
    `html,body { margin:0; padding:0; background:#fff }` +
    `svg { display:block; page-break-after:always; break-after:page }` +
    `svg:last-child { page-break-after:auto; break-after:auto }` +
    `</style></head><body>${pages.map(pageSvg).join("")}</body></html>`)
  doc.close()

  // The load has to settle before print(), or an empty frame goes to the spooler.
  const go = () => { frame.contentWindow.focus(); frame.contentWindow.print() }
  if (doc.readyState === "complete") go()
  else frame.addEventListener("load", go, { once: true })
}

export function downloadSvg(model, paperName, base) {
  const { pages } = pagesFor(model, paperName)
  // One page -> one file. Several -> the untiled plan, because a browser download is one file and
  // a pile of separate page SVGs is worse than the whole drawing.
  const svg = pages.length === 1 ? pageSvg(pages[0]) : planSvgFor(model)
  save(new Blob([ svg ], { type: "image/svg+xml" }), `${base}-plan.svg`)
}

export function downloadPdf(model, paperName, base) {
  const { pages } = pagesFor(model, paperName)
  save(new Blob([ buildPdf(pages) ], { type: "application/pdf" }), `${base}-plan.pdf`)
}

function save(blob, name) {
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
```

- [ ] **Step 4: Add the controls to `editor.js`**

Replace the `<h3>` block of the top-view panel (currently lines 61-65) with:

```js
          <h3>
            Top view
            <span class="box-topview-summary muted" data-topview="summary"
                  role="status" aria-live="polite"></span>
          </h3>
          <div class="box-topview-actions">
            <label class="box-topview-paper">
              <span class="visually-hidden">Paper size</span>
              <select data-export="paper">
                <option value="A4">A4</option>
                <option value="Letter">Letter</option>
                <option value="A3">A3</option>
                <option value="Tabloid">Tabloid</option>
              </select>
            </label>
            <button type="button" class="btn ghost btn-sm" data-export="print">Print</button>
            <button type="button" class="btn ghost btn-sm" data-export="pdf">PDF</button>
            <button type="button" class="btn ghost btn-sm" data-export="svg">SVG</button>
          </div>
```

Add the import at the top of `editor.js`:

```js
import { printPlan, downloadPdf, downloadSvg, planSvgFor } from "./export.js"
```

After `destroyers.push(mountTopView(...))`, capture the handle and wire the controls:

```js
  const topView = mountTopView($("topview-panel"), $("groups"))
  destroyers.push(topView)

  // The panel removes ITSELF when the first draw yields no grid (that is how FrontPanel's very
  // different `layout` DSL is kept out), so the controls exist only where a plan exists and need
  // no gate of their own.
  const paperSel = root.querySelector('[data-export="paper"]')
  if (paperSel) {
    paperSel.value = localStorage.getItem("boxes.paper") || "A4"
    paperSel.addEventListener("change", () => localStorage.setItem("boxes.paper", paperSel.value))
  }

  const exportBase = () =>
    ($("name").value.trim().replace(/[^a-z0-9]+/gi, "-").toLowerCase() || generator.key.toLowerCase())

  // Mid-edit the art is routinely unparseable and the panel deliberately keeps the last good
  // drawing up — so an export uses that same model. What you print is what you are looking at.
  const onExport = (event) => {
    const which = event.target.closest("[data-export]")?.dataset.export
    if (!which || which === "paper") return
    const model = topView.getPlan?.()
    if (!model) return
    try {
      if (which === "print") printPlan(model, paperSel.value)
      if (which === "pdf") downloadPdf(model, paperSel.value, exportBase())
      if (which === "svg") downloadSvg(model, paperSel.value, exportBase())
    } catch (e) {
      const summary = root.querySelector('[data-topview="summary"]')
      if (summary) summary.textContent = e.message
    }
  }
  root.addEventListener("click", onExport)
  destroyers.push({ destroy: () => root.removeEventListener("click", onExport) })
```

- [ ] **Step 5: Add the stylesheet rules**

Append to `app/assets/stylesheets/application.css` after line 293:

```css
.box-topview-actions { display: flex; gap: 6px; align-items: center; margin: 0 0 8px; }
.box-topview-actions select { font-size: 12px; padding: 2px 4px; }
.btn-sm { padding: 3px 8px; font-size: 12px; }
```

- [ ] **Step 6: Run the tests**

```bash
bin/rails test test/system/plan_export_test.rb test/system/tray_top_view_test.rb
```

Expected: 20 runs, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add test/fixtures/addons/boxes/export.js test/fixtures/addons/boxes/editor.js \
        app/assets/stylesheets/application.css test/system/plan_export_test.rb
git commit -m "feat(boxes): print, PDF and SVG controls on the top-view panel"
```

---

### Task 7: Save the plan to the library beside the cut sheet

**Files:**
- Modify: `test/fixtures/addons/boxes/editor.js:126-135` (the save handler)
- Test: `test/system/plan_export_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
  # MAX_FILES is 8 and parse_files already refuses duplicate names in a batch, so a second output
  # needs no host change. §14c's "each save writes ONE file" recorded deleting the write-only
  # .params.json, which duplicated AddonState#data; a second genuine output is not that.
  test "saving a tray writes the plan beside the cut sheet" do
    visit tools_addon_path("boxes")
    find(".addon-card", text: "TrayLayout").click
    assert_selector ".box-topview svg", wait: 5

    find('[data-role="name"]').set("Drawer insert")
    find('[data-role="save"]').click
    assert_selector '[data-role="save-status"]', text: "Saved."

    node_names = Maker::AddonState.order(:id).last.addon_files.map { |f| f.node.name }
    assert_equal [ "drawer-insert-plan.svg", "drawer-insert.svg" ], node_names.sort
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
```

- [ ] **Step 2: Run to verify failure**

```bash
bin/rails test test/system/plan_export_test.rb -n /beside the cut sheet/
```

Expected: FAIL — only `drawer-insert.svg` is written.

- [ ] **Step 3: Implement**

In `editor.js`'s `onSaveClick`, replace the `files` append with:

```js
    // The plan goes in UNTILED and full size: tiling is a property of the printer, not of the
    // drawing, and an archival artifact should not arrive pre-chopped into sheets. SVG rather than
    // PDF because parse_files requires a String body over JSON — binary cannot round-trip, and a
    // base64 path would cost a Rails redeploy for something the PDF download already gives.
    const outputs = [ { name: `${base}.svg`, content_type: "image/svg+xml", body: result.svg } ]
    const planModel = topView.getPlan?.()
    if (planModel) {
      outputs.push({
        name: `${base}-plan.svg`, content_type: "image/svg+xml", body: planSvgFor(planModel),
      })
    }
    body.append("files", JSON.stringify(outputs))
```

- [ ] **Step 4: Run the test**

```bash
bin/rails test test/system/plan_export_test.rb
```

Expected: 21 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add test/fixtures/addons/boxes/editor.js test/system/plan_export_test.rb
git commit -m "feat(boxes): save the tray plan to the library beside the cut sheet"
```

---

### Task 8: Mutation-check every new guard

§15: a guard that has never failed has not been shown to work. Each of these must go **RED**, then
be restored. This is a task, not a suggestion — this repo's dominant failure mode is a green suite
over something that never worked.

**Files:** temporary edits only, all reverted.

- [ ] **Step 1: The millimetre suffix**

In `export.js`'s `svgDoc`, change `width="${n(w)}mm"` to `width="${n(w)}"`.

```bash
bin/rails test test/system/plan_export_test.rb -n /physical size in millimetres/
```

Expected: FAIL. Restore, re-run, confirm green.

- [ ] **Step 2: The PDF y-flip**

In `pdf.js`'s `contentStream`, change both `H - p.y1` / `H - p.y2` to `p.y1` / `p.y2`.

```bash
bin/rails test test/system/plan_export_test.rb -n /flipped from SVG/
```

Expected: FAIL on the missing `813.54 l`. Restore, re-run, confirm green.

- [ ] **Step 3: The tile overlap**

In `sheet.js`, change `const stepX = pw - OVERLAP` to `const stepX = pw`.

```bash
bin/rails test test/system/plan_export_test.rb -n /repeats an overlap band/
```

Expected: FAIL (190, not 180). Restore, re-run, confirm green.

- [ ] **Step 4: The no-seam merge**

In `plan.js`'s `slotLabel`, make the vertical-band arm always `return WALL`.

```bash
bin/rails test test/system/plan_export_test.rb -n /no internal seam/
```

Expected: FAIL. Restore, re-run, confirm green.

- [ ] **Step 5: Record the results**

```bash
git commit --allow-empty -m "test(boxes): mutation-check the four to-scale guards

Each guard was broken and confirmed RED, then restored:
mm suffix, PDF y-flip, tile overlap, merged-cell seam."
```

---

### Task 9: Mirror the bundle and verify no drift

**Files:**
- Create/modify in `/Users/charlesschwartz/Desktop/tinkerex-addons/addons/boxes/`

- [ ] **Step 1: Check the bundle repo is clean and on a branch you may commit to**

```bash
git -C /Users/charlesschwartz/Desktop/tinkerex-addons status --short --branch
```

Expected: clean. If it is dirty, stop and ask — do not mix someone else's work into this.

- [ ] **Step 2: Mirror the fixture into the bundle**

The fixture is a verbatim snapshot, so the copy is the whole step.

```bash
cp test/fixtures/addons/boxes/*.js /Users/charlesschwartz/Desktop/tinkerex-addons/addons/boxes/
```

- [ ] **Step 3: Run the drift check against THIS worktree**

`check-fixture-drift` defaults to `../tinkerex`, which is the main checkout, not this worktree.

```bash
TINKEREX_PATH="$(pwd)" /Users/charlesschwartz/Desktop/tinkerex-addons/bin/check-fixture-drift
```

Expected: `ok: every snapshotted bundle matches the host's fixture`.

- [ ] **Step 4: Commit in the bundle repo**

```bash
git -C /Users/charlesschwartz/Desktop/tinkerex-addons add addons/boxes
git -C /Users/charlesschwartz/Desktop/tinkerex-addons commit -m "feat(boxes): to-scale export and print of the tray plan

plan.js extracts the coordinate model out of top_view.js's private svg(),
so the panel and every export read one geometry. sheet.js paginates with a
10 mm overlap band and a per-page 100 mm calibration bar; pdf.js writes an
uncompressed base-14 PDF; export.js holds the four sinks."
```

Do **not** publish. Publishing is the deploy, and the deploy comes after review.

---

### Task 10: Full gates, docs, PR

- [ ] **Step 1: Run every gate**

```bash
bin/ci
```

Expected: all gates pass, and the three test legs (test, test-share, test-s3) report **identical**
counts. If they differ, stop — a divergence across backends is a real finding, not noise.

- [ ] **Step 2: Update `docs/STATUS.md`**

Add an entry under the current arc naming: the four sinks, the tiling behaviour, the two-repo split,
and the one thing that is **not** automated — that only printing a sheet and measuring the 100 mm
bar proves the paper is right.

- [ ] **Step 3: Commit the docs**

```bash
git add docs/STATUS.md
git commit -m "docs(status): to-scale export and print of the box compartment plan"
```

- [ ] **Step 4: Push and open the PR**

Per CLAUDE.md's close-out rule: on a `claude/*` branch with green gates, commit, push and open the
PR without asking. State in the PR body what was verified (the system tests, the four mutation
checks, the PDF opened in a real viewer) and what was not (the physical print measurement, and
Linux/Windows CI, which is skipped rather than passing).

---

## Self-review

**Spec coverage.** §2's four sinks → Tasks 6 and 7. §5.1 model → Task 1. §5.2 lattice outlines →
Task 2. §5.3 pagination, overlap, marks, calibration bar, 40-sheet guard → Task 3. §5.4 PDF, units,
y-flip, `\327` → Task 5. §5.5 hidden iframe → Task 6. §6 UI and paper selector → Task 6. §7 library
save → Task 7. §8 error handling → the `try/catch` in Task 6 plus the guard in Task 3. §9 testing,
including the real-viewer check and the manual measurement → Tasks 5, 8, 10. §10 two-repo split →
Task 9.

**Gap found and closed:** §8's "print blocked or iframe fails" had no task; it is now the `try/catch`
writing to the summary line in Task 6 step 4.

**Naming consistency.** `buildModel` / `printPrims` (plan.js), `paginate` / `PAPERS` (sheet.js),
`pageSvg` / `planSvg` / `planSvgFor` / `pagesFor` / `printPlan` / `downloadPdf` / `downloadSvg`
(export.js), `buildPdf` (pdf.js), `getPlan` (top_view.js) — each defined once and used under that
name everywhere.

**Known soft spot, stated rather than hidden.** `pagesId` in `pdf.js` is predicted before the Pages
object is appended, because a /Page's /Parent must reference it. Step 3 of Task 5 asserts the
prediction rather than trusting it, so a mis-predicted id fails loudly at build time instead of
producing a subtly broken PDF.
