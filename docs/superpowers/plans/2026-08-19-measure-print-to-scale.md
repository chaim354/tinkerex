# Measure — select parts and print to scale — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a *Select parts* mode to the Measure view and a Print that lays the selected contours out at exactly 1:1 across as many sheets as they need, so a maker can hold paper against real hardware before cutting material.

**Architecture:** Entirely client-side. The geometry payload already carries millimetre coordinates, full-resolution bboxes and the server-decided diameter, so **nothing on the server changes** — no endpoint, no `SCHEMA_VERSION` bump, and no `PAYLOAD_REVISION` bump (so no deployed library gets re-measured). A new pure module `app/javascript/lib/print_sheet.js` turns shapes-in-mm into pages-of-shapes-in-mm and renders each page as an `<svg>` whose declared millimetres and user units are equal; `measure_controller.js` gains the selection set and the wiring.

**Tech Stack:** Stimulus (importmap, no bundler), plain SVG DOM built with `createElementNS`, Minitest system tests driven by headless Chrome through Capybara/Selenium.

**Spec:** `docs/superpowers/specs/2026-08-19-measure-print-to-scale-design.md`. Read §10 before touching anything — it is the argument for why this duplicates the `boxes` bundle's `sheet.js` rather than importing it.

---

## Orientation: what already exists

Read these before Task 1. You do not need to change any of them except where a task says so.

| File | What it does |
|---|---|
| `app/services/maker/previews/geometry.rb` | Builds the measure payload. **Do not modify.** Read the `Collector#add` comment for what each key means. |
| `app/javascript/controllers/measure_controller.js` | The Measure view. 363 lines. You will modify it in Tasks 9–11. |
| `app/views/files/_measure.html.erb` | The partial. Modified in Task 9. |
| `app/assets/stylesheets/application.css` lines 115–140 | The Measure block. Modified in Task 9. |
| `test/system/lbrn_measure_test.rb` | The idiom every system test here follows — copy its `setup`, `teardown` and `render_geometry!` verbatim. |

> **Running one system test file:** use `bin/rails test <path>`. `bin/rails test:system TEST=<path>`
> raises `InvalidTestError`, and `bin/rails test:system <path>` **ignores the path and runs all 104
> system tests** — verified, not assumed. Both wrong forms cost minutes per run.
| `test/fixtures/files/nested-plate.lbrn2` | A 60 × 40 plate (x −30..30, y −20..20) with a ⌀10 hole on the same centre. |
| `test/fixtures/files/bezier-circle.lbrn2` | A ⌀20 circle at x −10..10 and a 20 × 20 square at x 40..60 — **disjoint, 50 mm apart**. |
| `test/fixtures/addons/boxes/sheet.js` | The sibling implementation, for reference only. **Do not import it.** |

### STANDING INSTRUCTION: assume the test inputs below are under-powered

This has now cost three findings across the first two tasks, so treat it as a rule rather than a
possibility. **The synthetic inputs written into this plan are illustrative, not sufficient.** Every
one of these was a real green-over-broken:

| Task | The input | What survived it |
|---|---|---|
| 1 | one shape | `unionBox` gutted to `return shapes[0].b` |
| 2 | one shape | `unionBox`'s maxima half swapped to `Math.min` |
| 2 | nothing under 10 mm | dropping the `w <= content.w` guard — which silently yields **0 pages** for any selection smaller than the overlap band, and this file's own ⌀10 hole fixture would hit it |
| 2 | selections only ever one row tall | `translateY` reading `originX` |

The shape is always the same: **a one-element array cannot distinguish `max` from `min`, `[0]` from
a fold, or any branch from its neighbour.** So for every task from here on:

1. Write the plan's tests.
2. **Mutation-check every guard the task adds** — break the thing, confirm red, restore. Not only
   the mutations the task lists; enumerate the branches your code actually has.
3. **When a mutation comes back GREEN, the test is wrong, not the mutation.** Strengthen the input
   until it goes red, then record the observed failure text in a comment. Deviating from the
   plan's literal test data to do this is expected and correct — say so in your report.

### The payload shape you will be working with

```js
// One entry of payload.shapes
{
  o: 3,                       // object id — several contours can share one
  c: "2",                     // layer key, resolved through payload.colors
  b: [-5, -5, 5, 5],          // bbox in mm, from FULL-RESOLUTION points
  k: 1,                       // 1 = closed (polygon), 0 = open (polyline)
  i: 0,                       // 1 = bitmap placeholder rectangle
  d: 10,                      // diameter in mm — ABSENT unless the server decided it is circular
  p: [[5, 0], [4.6, 1.9], ...] // points in mm, Y-down, THINNED for drawing
}
```

**`p` is thinned. `b` and `d` are not.** Every number that gets printed as text must come from `b` or `d`. Measuring from `p` under-reports every curve and loses a small hole's diameter entirely — that is a recorded bug in CLAUDE.md §14h, not a hypothetical.

---

## File structure

| File | Responsibility |
|---|---|
| `app/javascript/lib/print_sheet.js` | **New.** Pagination + sheet rendering. Pure: knows nothing about Stimulus, the controller, or file formats. Reads only `b`, `p`, `k`, `i` off a shape. |
| `config/importmap.rb` | **New line.** One pin, following the existing `lib/file_chooser` pin. |
| `app/javascript/controllers/measure_controller.js` | Selection mode, the print set, the print bar, wiring into `print_sheet.js`. |
| `app/views/files/_measure.html.erb` | The three new buttons and the paper `<select>`. |
| `app/assets/stylesheets/application.css` | `.measure-contour--marked` and the selecting cursor. |
| `test/system/measure_print_test.rb` | **New.** Module-level layout tests plus end-to-end tests through real clicks. |
| `docs/STATUS.md` | The arc entry — part of this work, same branch, same PR (§15). |
| `CLAUDE.md` §14h | The invariants a future editor could undo by accident. |

---

## Task 1: The module skeleton — constants, content box, single-page pagination

**Files:**
- Create: `app/javascript/lib/print_sheet.js`
- Modify: `config/importmap.rb`
- Test: `test/system/measure_print_test.rb` (create)

- [ ] **Step 1: Write the failing test**

Create `test/system/measure_print_test.rb`:

```ruby
require "application_system_test_case"

# Selecting parts in the Measure view and printing them at 1:1 for paper fit testing.
#
# TWO TIERS IN ONE FILE, deliberately. The layout maths in lib/print_sheet.js is pure and is
# exercised directly through `in_print_sheet` with synthetic shapes, because a tiling assertion
# wants inputs chosen to land exactly on a tile boundary and no fixture does that. The
# end-to-end tests below drive real clicks against a real payload, because the maths being right
# about synthetic input proves nothing about whether the payload ever reaches it.
#
# ASSERT THE WIRE FORMAT, NEVER A ROUND-TRIP THROUGH OUR OWN READER. CLAUDE.md §14e: FakeS3
# decoded copy_source with the exact inverse of the encoder, so 79/80 tests were green over
# silent permanent data loss. Parsing our own SVG with our own parser would be that shape again.
# These assert the literal `width="215.9mm"` and the literal point coordinates a printer will see.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, exactly as lbrn_measure_test.rb does it and for the same
# reason: the geometry job has to read REAL BYTES back out of the port. The FileLayer.reset! in
# teardown is load-bearing — a direct assignment does not set @file_layer_backend_pinned, so
# test_helper's teardown will not clean up after it and a Share adapter pointing at a deleted
# tmpdir would leak into the next test in this forked worker.
class MeasurePrintTest < ApplicationSystemTestCase
  # x -30..30, y -20..20 plate with a ⌀10 hole on the same centre.
  NESTED = "nested-plate.lbrn2".freeze
  # A ⌀20 circle at x -10..10 and a 20 x 20 square at x 40..60. DISJOINT, and the gap between
  # their nearest edges is exactly 30 mm while their min-x values are 50 mm apart — which is what
  # makes it the fixture for the separation assertion.
  APART = "bezier-circle.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-print"))
    # The fixtures land BEFORE the first page render: FileLayer::Share reads an EMPTY root as an
    # unmounted mount point, and sign_in_as ends on /files, which renders through the port.
    [ NESTED, APART ].each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-print@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @nested_id = @user.nodes.find_by!(storage_path: NESTED).node_id
    @apart_id  = @user.nodes.find_by!(storage_path: APART).node_id
    render_geometry!(@nested_id, NESTED)
    render_geometry!(@apart_id, APART)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # ---- lib/print_sheet.js: pagination ---------------------------------------------------------

  test "Letter's content box is the printable area less the two reserved strips" do
    box = JSON.parse(in_print_sheet("JSON.stringify(m.contentBox(m.PAPERS.Letter))"))

    # 215.9 - 20 margin = 195.9 wide; 279.4 - 20 margin - 7 header - 22 calibration = 230.4 tall.
    assert_in_delta 195.9, box["w"], 0.001
    assert_in_delta 230.4, box["h"], 0.001
    # And it carries its ORIGIN, which is what stops three call sites re-spelling MARGIN + HEADER_H.
    assert_in_delta 10.0, box["x"], 0.001
    assert_in_delta 17.0, box["y"], 0.001
  end

  # THE TRANSLATION IS THE WHOLE "TRUE POSITIONS" CLAIM, and it is relative rather than absolute:
  # the SELECTION's bbox origin is the datum, not the file's. A part sitting at x 500 in a 600 mm
  # laser sheet prints at the left edge of sheet 1, not on tile 3 of 12 with two blank ones.
  test "a selection that fits produces one page whose translation puts it at the content origin" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets([
        // TWO SHAPES, AND THE ONE SUPPLYING THE MINIMA IS DELIBERATELY NOT FIRST. With a single
        // shape "the selection's bbox" and "this shape's bbox" are indistinguishable, so the test
        // cannot fail for the property it exists to pin: gutting unionBox to
        // `return shapes[0].b` stays GREEN. Verified — that mutation must turn this red.
        { b: [520, 320, 600, 400], p: [[520, 320], [600, 400]], k: 1, i: 0, o: 2 },
        { b: [500, 300, 560, 340], p: [[500, 300], [560, 340]], k: 1, i: 0, o: 1 },
      ], m.PAPERS.Letter))
    JS

    assert_equal 1, out["pages"].length
    assert_equal 1, out["cols"]
    assert_equal 1, out["rows"]
    # MARGIN (10) less the selection's own x0 (500); MARGIN + HEADER_H (17) less its y0 (300).
    assert_in_delta(-490.0, out["pages"][0]["translateX"], 0.001)
    assert_in_delta(-283.0, out["pages"][0]["translateY"], 0.001)
  end

  private

    def in_print_sheet(body)
      visit file_path(@nested_id) unless page.current_path == file_path(@nested_id)
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        import("lib/print_sheet")
          .then((m) => done(#{body}))
          .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
      JS
      raise result if result.is_a?(String) && result.start_with?("ERROR:")
      result
    end

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner. A system test cannot wait for the job:
    # ActiveJob's test adapter never runs what it queues, and `perform_enqueued_jobs`' block form
    # only inlines jobs enqueued DURING the block — the geometry job is enqueued by the browser's
    # own first poll, inside the server thread. `perform_now` sidesteps the adapter and is
    # deterministic, while still being the real pipeline.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end
end
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: both tests FAIL, raising `ERROR: Failed to resolve module specifier 'lib/print_sheet'`.

- [ ] **Step 3: Add the importmap pin**

In `config/importmap.rb`, immediately after the `lib/file_chooser` pin block, add:

```ruby
# The Measure view's to-scale print — pagination and sheet rendering, imported by
# measure_controller.js. A HOST pin like the two above, so it is drawn into every addon's merged
# importmap too. A bundle must NOT import it — the `boxes` bundle ships its own sheet.js
# precisely so neither repo can break the other (the module header argues that in full).
pin "lib/print_sheet", to: "lib/print_sheet.js"
```

- [ ] **Step 4: Create the module**

Create `app/javascript/lib/print_sheet.js`:

```js
// Pagination and sheet rendering for the Measure view's to-scale print.
//
// Takes shapes in millimetres and a paper, returns pages of shapes in millimetres, then renders a
// page as an <svg>. Knows nothing about Stimulus, about the Measure controller, or about file
// formats: it reads `b`, `p`, `k` and `i` off a shape and nothing else.
//
// A SIBLING IMPLEMENTATION EXISTS AND IS DELIBERATELY NOT SHARED. The `boxes` addon bundle prints
// a tray plan to scale through its own sheet.js, with the same MARGIN/OVERLAP/MAX_SHEETS values
// and the same "Sheet c,r of CxR" convention. That bundle lives in chaim354/tinkerex-addons, where
// publishing IS the deploy (CLAUDE.md §14c) and Rails is never rebuilt — so importing it through
// the addon asset proxy would let an addon republish break a core file page, and would remove
// Measure's print button entirely on a deployment with no addon source (OVH blanks
// ADDON_SOURCE_URL outright). The conventions and the constants are copied; the code is not.
// See docs/superpowers/specs/2026-08-19-measure-print-to-scale-design.md §10 before changing this.

export const PAPERS = {
  A4:      { name: "A4",      w: 210,   h: 297 },
  Letter:  { name: "Letter",  w: 215.9, h: 279.4 },
  A3:      { name: "A3",      w: 297,   h: 420 },
  Tabloid: { name: "Tabloid", w: 279.4, h: 431.8 },
}

// 10 mm clears the two common hardware limits (0.25 in = 6.35 mm, 0.5 in = 12.7 mm) on every
// consumer inkjet and laser worth designing for.
export const MARGIN = 10
// Content repeated on the right and bottom of each tile: something to align and tape against
// rather than a butt joint.
export const OVERLAP = 10
// The two strips are RESERVED, NOT OVERLAID, and that is the deliberate divergence from the boxes
// sibling. That module draws its calibration bar over its content area, which is safe because it
// knows its own content — a tray plan of known extent. We print arbitrary user geometry that can
// be anywhere, so an overlaid ruler would land across a part outline.
export const HEADER_H = 7
export const CALIB_H = 22
// A file with absurd units (an SVG read at 25.4x) would otherwise try to print hundreds of sheets.
export const MAX_SHEETS = 40

// THE CONTENT BOX CARRIES ITS ORIGIN, NOT JUST ITS SIZE. Three places need "where does geometry
// start" — the page translation below, the clip rect in renderSheet, and the furniture's own edges
// — and re-spelling `MARGIN + HEADER_H` at each is the N-copies-that-must-agree defect this repo
// keeps recording (§14b's four skip-list strings, §14d's five port_writable branches). Move the
// calibration strip to the top one day and exactly one line changes; miss one of three and
// geometry is DRAWN at one origin and CLIPPED at another, slicing a band off a part on a page that
// still looks entirely correct.
export function contentBox(paper) {
  return {
    x: MARGIN, y: MARGIN + HEADER_H,
    w: paper.w - MARGIN * 2, h: paper.h - MARGIN * 2 - HEADER_H - CALIB_H,
  }
}

export function unionBox(shapes) {
  return [
    Math.min(...shapes.map((s) => s.b[0])), Math.min(...shapes.map((s) => s.b[1])),
    Math.max(...shapes.map((s) => s.b[2])), Math.max(...shapes.map((s) => s.b[3])),
  ]
}

export function buildSheets(shapes, paper) {
  if (!shapes.length) throw new Error("Nothing to print.")
  const box = unionBox(shapes)
  const content = contentBox(paper)

  return {
    cols: 1,
    rows: 1,
    pages: [{
      paper, col: 0, row: 0, cols: 1, rows: 1, originX: 0, originY: 0,
      // Content space -> page space. THE SELECTION's own bbox origin is the datum, not the file's,
      // which is what makes "true positions" mean RELATIVE positions: two holes 40 mm apart on a
      // 600 mm sheet print on one page, 40 mm apart, instead of on tile 4 of 12.
      translateX: content.x - box[0],
      translateY: content.y - box[1],
      shapes,
    }],
  }
}
```

- [ ] **Step 5: Run the test and watch it pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: 2 runs, 0 failures.

- [ ] **Step 5b: Mutation-check, and record it in the tests**

`test/system/README.md`'s rule for this tier: revert the behaviour a test pins, confirm it goes
red, **and say so in a comment naming what you reverted**. Run all three; each must be red for its
own test, then restore:

| break this | must go red |
|---|---|
| `unionBox` body → `return shapes[0].b` | the translation test (`-490.0` vs `-510`) |
| `contentBox` drops `- CALIB_H` | the content-box test (`230.4` vs `252.4`) |
| `translateX: content.x - box[0]` → `content.x` | the translation test (`-490.0` vs `10`) |

Add the observed failure message to each test's comment, the way `lbrn_measure_test.rb` does.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/lib/print_sheet.js config/importmap.rb test/system/measure_print_test.rb
git commit -m "feat(measure): print_sheet.js — paper table, content box, single-page layout"
```

---

## Task 2: Tiling

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

> **Carried over from Task 1's review — do these while the file is open:**
>
> 1. **`unionBox`'s MAXIMA half is not pinned yet, and this task is where it gets its first
>    consumer.** Task 1's test pins only the minima (what `translateX/Y` reads); mutating the max
>    half to `Math.min` stayed green, correctly, because nothing read `box[2]`/`box[3]`. Here
>    `cols`/`rows` read them — so confirm that mutation now turns the tiling test RED, and record
>    the observed failure in a test comment. (Task 2 has no mutation-table step of its own; design
>    the set from the branches `buildSheets` actually has.) If it does not go red, the tiling test
>    is not measuring what it claims.
> 2. **Add the system-tier justification to the test file's header comment.**
>    `test/system/README.md`'s rule is "a behaviour earns a system test if and only if it is
>    observable only in a browser", which pure arithmetic does not meet as written. The real reason
>    is that **this repo has no JS test runner, so a browser is the only executor available**, and
>    `plan_export_test.rb` set that precedent for exactly the same kind of module. Every
>    neighbouring file in this tier justifies its place; this one should too. One or two lines.

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`, after the single-page test:

```ruby
  # 400 mm of content on Letter: the content box is 195.9 wide and the overlap band eats 10 of it,
  # so each tile after the first adds 185.9 mm of NEW content -> ceil((400 - 10) / 185.9) = 3.
  test "a selection wider than the sheet tiles into columns" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 40], p: [[0, 0], [400, 40]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 3, out["cols"]
    assert_equal 1, out["rows"]
    assert_equal 3, out["pages"].length
  end

  # THE SECOND TILE MUST START ONE OVERLAP BAND BEFORE THE FIRST TILE ENDED, or there is nothing
  # to align the two sheets against and the whole tiling is a butt joint you cannot register.
  test "the second tile repeats an overlap band of the first" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 40], p: [[0, 0], [400, 40]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    dx = out["pages"][1]["originX"] - out["pages"][0]["originX"]
    assert_in_delta 185.9, dx, 0.001, "content width 195.9 mm less a 10 mm overlap band"

    # THE SPANNING SHAPE MUST REACH EVERY TILE IT CROSSES, INTERIOR ONES INCLUDED — and this is
    # the only assertion in the file with a shape on more than one tile, which is why it carries
    # weight far beyond its size. `touches` is an inclusive AABB OVERLAP test; swapping its two
    # assignment lines so x1/y1 take b[0]/b[1] silently turns it into a CONTAINMENT test, and
    # every other test here still passes because each of their shapes lands on exactly one tile.
    # The user-visible result of that mutation is three sheets, correctly numbered "1 of 3" to
    # "3 of 3", correctly margined, carrying the calibration bar — and COMPLETELY BLANK. Nothing
    # errors, nothing logs. This one line is what makes it red.
    assert_equal [ [ 1 ], [ 1 ], [ 1 ] ],
                 out["pages"].map { |pg| pg["shapes"].map { |sh| sh["o"] } },
                 "a 400 mm bar spans all three tiles, including the middle one"
  end

  # ROWS, NOT JUST COLUMNS. Every other tiling test here is one row tall, so the `row` loop,
  # `originY` and `translateY` are exercised only at row 0 — and a copy-paste slip like
  # `translateY: content.y - originX - box[1]` passes all of them. Letter's content box is 230.4 mm
  # tall and the overlap band eats 10, so ceil((500 - 10) / 220.4) = 3 rows.
  test "a selection taller than the sheet tiles into rows" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 40, 500], p: [[0, 0], [40, 500]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, out["cols"]
    assert_equal 3, out["rows"]
    dy = out["pages"][1]["originY"] - out["pages"][0]["originY"]
    assert_in_delta 220.4, dy, 0.001, "content height 230.4 mm less a 10 mm overlap band"
    # THE RELATIONSHIP, not a second literal: translateY must pan by exactly the origin step, or
    # every tile draws row 1's content on a sheet labelled row 2.
    assert_in_delta(-dy, out["pages"][1]["translateY"] - out["pages"][0]["translateY"], 0.001)
  end

  # THE GRID MUST BE ASYMMETRIC OR col/row ARE UNOBSERVABLE. Every other tiling test here is 1xN
  # or Nx1, so `col` and `row` are never both non-zero and three separate mutations stay GREEN:
  # swapping `col:`/`row:` on the page object, swapping `cols:`/`rows:`, and transposing the loop
  # nesting. Task 6 draws "Sheet c,r of CxR" out of exactly these fields and Task 8 emits `pages`
  # in array order, so a maker with a 3x2 job would get sheets labelled transposed, or ordered
  # column-major against their own labels, with nothing anywhere going red.
  #
  # 2x2 WOULD NOT DO — with cols == rows every one of those swaps is invisible. 400 x 300 mm on
  # Letter gives 3 columns and 2 rows, which is the smallest grid that can see all three.
  test "pages are emitted row-major and carry their own grid position" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 300], p: [[0, 0], [400, 300]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 3, out["cols"]
    assert_equal 2, out["rows"]
    assert_equal [ [ 0, 0 ], [ 1, 0 ], [ 2, 0 ], [ 0, 1 ], [ 1, 1 ], [ 2, 1 ] ],
                 out["pages"].map { |pg| [ pg["col"], pg["row"] ] }
    # Every page reports the WHOLE grid, not its own position twice over.
    assert out["pages"].all? { |pg| pg["cols"] == 3 && pg["rows"] == 2 }
  end

  # A selection that fits goes through the SAME path, with no small-selection branch to keep in
  # step with the tiled one.
  test "a selection that fits produces one page through the same call" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 60, 40], p: [[0, 0], [60, 40]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, out["pages"].length
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: the two tiling tests FAIL — `cols` is 1 where 3 is expected, and `pages[1]` is nil.

- [ ] **Step 3: Replace `buildSheets`**

In `app/javascript/lib/print_sheet.js`, replace the whole `buildSheets` function with:

```js
export function buildSheets(shapes, paper) {
  if (!shapes.length) throw new Error("Nothing to print.")
  const box = unionBox(shapes)
  const w = box[2] - box[0], h = box[3] - box[1]
  const content = contentBox(paper)
  // Steps come off the CONTENT box, not the printable box — the two reserved strips are not
  // available for geometry, so pretending they are would clip a band off every tile but the last.
  const stepX = content.w - OVERLAP, stepY = content.h - OVERLAP
  const cols = w <= content.w ? 1 : Math.ceil((w - OVERLAP) / stepX)
  const rows = h <= content.h ? 1 : Math.ceil((h - OVERLAP) / stepY)

  const pages = []
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const originX = col * stepX, originY = row * stepY
      pages.push({
        paper, col, row, cols, rows, originX, originY,
        // Content space -> page space. THE SELECTION's own bbox origin is the datum, not the
        // file's, which is what makes "true positions" mean RELATIVE positions: two holes 40 mm
        // apart on a 600 mm sheet print on one page, 40 mm apart, not on tile 4 of 12.
        translateX: content.x - originX - box[0],
        translateY: content.y - originY - box[1],
        shapes,
      })
    }
  }
  return { cols, rows, pages }
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: 7 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): tile a selection larger than one sheet, with a 10 mm overlap band"
```

---

## Task 3: The sheet-count refusal, and per-tile shape filtering

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`:

```ruby
  # An SVG whose units were read 25.4x too large would otherwise silently spool 9,000 sheets.
  test "an absurd selection is refused rather than printing hundreds of sheets" do
    err = in_print_sheet(<<~JS)
      (() => {
        try {
          m.buildSheets([{ b: [0, 0, 20000, 20000], p: [[0, 0]], k: 1, i: 0, o: 1 }],
                        m.PAPERS.Letter)
          return "NO ERROR"
        } catch (e) { return e.message }
      })()
    JS

    # 9,828, not a round number: the message begins with the real count, and quoting a rounded
    # one here would read as computed when it is not.
    assert_match(/\A9828 sheets/, err)
    assert_match(/more than 40 sheets/, err)
    assert_match(/20000 × 20000 mm/, err, "the message must name the size that caused it")
  end

  # THE OTHER REFUSAL, which nothing else in this plan pins — verified by grepping every task, so
  # deleting the guard would have gone unnoticed end to end. It is a module PRECONDITION rather
  # than a user-facing message (Task 11's caller returns early on an empty set before ever calling
  # here), but an unpinned throw is an unpinned throw: `unionBox` on an empty array returns
  # [Infinity, Infinity, -Infinity, -Infinity], so without it `buildSheets` yields NaN geometry and
  # a page full of nothing rather than an error anyone can act on.
  test "an empty selection is refused rather than producing NaN geometry" do
    err = in_print_sheet(<<~JS)
      (() => {
        try { m.buildSheets([], m.PAPERS.Letter); return "NO ERROR" }
        catch (e) { return e.message }
      })()
    JS

    assert_equal "Nothing to print.", err
  end

  # A 400 mm selection puts 3 tiles on the page. Handing every tile every shape would put a
  # thousand-contour selection into the DOM three times over; the clipPath hides them, so nothing
  # would look wrong while the print took three times as long to spool.
  test "a tile carries only the shapes whose bbox touches it" do
    out = JSON.parse(in_print_sheet(<<~JS))
      // The min-supplying shape is second on purpose — see the union test's note in Task 1.
      JSON.stringify(m.buildSheets([
        { b: [300, 0, 310, 10],  p: [[300, 0], [310, 10]],  k: 1, i: 0, o: 2 },
        { b: [0, 0, 10, 10],     p: [[0, 0], [10, 10]],     k: 1, i: 0, o: 1 },
      ], m.PAPERS.Letter).pages.map((p) => p.shapes.map((s) => s.o)))
    JS

    # cols = ceil((310 - 10) / 185.9) = 2. Tile 0 covers content x 0..195.9, tile 1 x 185.9..381.8.
    assert_equal [ [ 1 ], [ 2 ] ], out, "filter preserves array order within each tile"
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: the refusal test returns `"NO ERROR"`; the filtering test gets `[[1, 2], [1, 2]]`.

- [ ] **Step 3: Add the refusal and the filter**

**BEFORE THE PAGE LOOP, NOT AFTER IT — this is a constraint, not a style preference.** The counts
both exist above the loop, so keying the refusal on them there is free; filtering `pages` afterwards
means a 100 m selection (an SVG misread at a bad scale — this module's own stated motivation)
allocates **244,252 page objects** before anything can check, and the tab hangs instead of saying
"too many sheets". Insert immediately after the `const cols = ...` / `const rows = ...` lines:

```js
  if (cols * rows > MAX_SHEETS) {
    throw new Error(
      `${cols * rows} sheets — this selection is ${round(w)} × ${round(h)} mm, which is more ` +
      `than ${MAX_SHEETS} sheets of ${paper.name}. Select fewer parts, or choose larger paper.`)
  }
```

Change the `shapes,` line inside the `pages.push({...})` to:

```js
        shapes: shapes.filter((s) => touches(s, box, originX, originY, content)),
```

And append to the end of the file:

```js
// Keep any shape whose bbox touches this tile's content box. A BBOX TEST, deliberately: a contour
// crossing the tile edge is kept whole and cut by the <clipPath> at render time, and the overlap
// band already guarantees that a mark near an edge appears on both tiles. Exact clipping here
// would buy nothing and would have to reimplement what the renderer gets from the browser.
function touches(shape, box, originX, originY, content) {
  const x0 = shape.b[0] - box[0], y0 = shape.b[1] - box[1]
  const x1 = shape.b[2] - box[0], y1 = shape.b[3] - box[1]
  return x1 >= originX && x0 <= originX + content.w &&
         y1 >= originY && y0 <= originY + content.h
}

const round = (v) => Math.round(v * 10) / 10
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: 11 runs, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): refuse absurd sheet counts, and give each tile only its own shapes"
```

---

## Task 4: `renderSheet` — the mm-exact page and its contours

This is the task the whole feature rests on. **One user unit is one millimetre.** There is no transform, no dpi constant and nothing to get wrong — break the agreement between `width="215.9mm"` and `viewBox="0 0 215.9 279.4"` and every printed part is silently the wrong size while the page still looks perfectly plausible.

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`:

```ruby
  # ---- lib/print_sheet.js: rendering ----------------------------------------------------------

  # A helper that renders one page and hands back its outerHTML, so every assertion below is
  # against the literal markup a printer will be given.
  SIXTY_BY_FORTY = <<~JS.freeze
    [{ b: [0, 0, 60, 40], k: 1, i: 0, o: 1,
       p: [[0, 0], [60, 0], [60, 40], [0, 40], [0, 0]] }]
  JS

  # THE SCALE MECHANISM, ASSERTED AS THE TWO LITERALS THAT CONSTITUTE IT. A width in px with the
  # same viewBox draws an identical-looking page at the wrong size, and no visual check catches it.
  test "a sheet declares its size in millimetres and spans the same number of user units" do
    html = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null }).outerHTML
    JS

    assert_includes html, 'width="215.9mm"'
    assert_includes html, 'height="279.4mm"'
    assert_includes html, 'viewBox="0 0 215.9 279.4"'
  end

  # A 60 x 40 part must span 60 x 40 USER UNITS, which the assertion above has just established
  # are millimetres. Asserting only "a polygon exists" is answered exactly as well by a polygon of
  # the wrong size — CLAUDE.md §14h's Z-up lesson, one feature over.
  test "a 60 x 40 part spans exactly 60 by 40 user units on the sheet" do
    points = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null })
       .querySelector("polygon").getAttribute("points")
    JS

    xs = points.split(/\s+/).map { |p| p.split(",").first.to_f }
    ys = points.split(/\s+/).map { |p| p.split(",").last.to_f }
    assert_in_delta 60.0, xs.max - xs.min, 0.001
    assert_in_delta 40.0, ys.max - ys.min, 0.001
  end

  # TWO PARTS MUST KEEP THEIR REAL SEPARATION — the entire point of "true positions". A transform
  # applied per shape instead of per page would draw both parts perfectly and stack them.
  test "two parts keep their real separation on the sheet" do
    xs = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets([
          // Min-supplier second — see Task 1's union test.
          { b: [50, 0, 60, 10],  k: 1, i: 0, o: 2, p: [[50, 0], [60, 0], [60, 10], [50, 0]] },
          { b: [0, 0, 10, 10],   k: 1, i: 0, o: 1, p: [[0, 0], [10, 0], [10, 10], [0, 0]] },
        ], m.PAPERS.Letter).pages[0],
        { name: "two.lbrn2", date: "2026-08-19", sizeLabel: () => null })
       .querySelectorAll("polygon")).map((n) =>
         Math.min(...n.getAttribute("points").split(/\\s+/).map((p) => parseFloat(p)))))
    JS

    assert_in_delta 50.0, xs.max - xs.min, 0.001, "the two parts are 50 mm apart in the file"
  end

  # THE CONTOURS ARE BUILT FRESH FROM shape.p, NEVER CLONED FROM THE SCREEN. A clone would drag
  # the transparent fat hit-twin (.measure-contour--hit), the hover/selected/marked classes and
  # the layer colour onto paper — a printed sheet with an 8-unit-wide invisible stroke on it.
  test "the sheet carries no screen-only classes and prints in black" do
    html = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null }).outerHTML
    JS

    refute_includes html, "measure-contour"
    assert_includes html, 'stroke="#000"'
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all four FAIL with `ERROR: m.renderSheet is not a function`.

- [ ] **Step 3: Add `renderSheet` and its element helpers**

Append to `app/javascript/lib/print_sheet.js`:

```js
const SVG_NS = "http://www.w3.org/2000/svg"

// Build one page as an <svg> element in `doc`.
//
// `meta` is { name, date, sizeLabel }. `sizeLabel(shape)` comes from measure_controller.js so the
// paper and the on-screen readout cannot disagree — and so that it is NEVER re-derived here from
// `shape.p`, which holds the THINNED drawing points: measuring from those under-reports every
// curve, and a hole small enough to thin below MIN_CIRCLE_POINTS loses its diameter entirely
// (CLAUDE.md §14h). Returning null from it omits the label.
export function renderSheet(doc, page, meta) {
  const { paper } = page
  // ONE USER UNIT IS ONE MILLIMETRE, and these two attributes together are the entire scale
  // mechanism. There is no transform and no dpi constant. Change the width to px, or let the
  // viewBox span anything other than the paper's own millimetres, and every part on the sheet is
  // silently the wrong size while the page still looks right.
  const svg = el(doc, "svg", {
    xmlns: SVG_NS,
    width: `${paper.w}mm`, height: `${paper.h}mm`,
    viewBox: `0 0 ${paper.w} ${paper.h}`,
  })

  const content = contentBox(paper)
  const clipId = `mp-clip-${page.col}-${page.row}`
  const clip = el(doc, "clipPath", { id: clipId })
  clip.appendChild(el(doc, "rect", {
    x: content.x, y: content.y, width: content.w, height: content.h,
  }))
  svg.appendChild(clip)

  // ONE TRANSFORM FOR THE WHOLE PAGE, not one per shape: parts keep their relative positions
  // because they are all moved by the same amount.
  const group = el(doc, "g", {
    "clip-path": `url(#${clipId})`,
    transform: `translate(${page.translateX} ${page.translateY})`,
  })
  for (const shape of page.shapes) group.appendChild(contourNode(doc, shape))
  svg.appendChild(group)

  return svg
}

// BUILT FRESH FROM shape.p, NEVER CLONED FROM THE ON-SCREEN NODE. A clone drags the transparent
// fat hit-twin (.measure-contour--hit, an 8px stroke), the hover/selected/marked classes and the
// layer colour onto paper.
//
// BLACK, not the layer colour: a mono printer turns a layer palette into indistinguishable greys,
// and this sheet exists to be measured and cut against. 0.2 mm is a line you can cut to.
function contourNode(doc, shape) {
  const attrs = {
    points: shape.p.map(([x, y]) => `${x},${y}`).join(" "),
    fill: "none", stroke: "#000", "stroke-width": 0.2,
  }
  // A bitmap's base64 is deliberately absent from the payload; it is the RECTANGLE a photo
  // occupies that matters for fit, and it draws dashed here exactly as it does on screen.
  if (shape.i) attrs["stroke-dasharray"] = "4 3"
  return el(doc, shape.k ? "polygon" : "polyline", attrs)
}

function el(doc, tag, attrs) {
  const node = doc.createElementNS(SVG_NS, tag)
  for (const [ key, value ] of Object.entries(attrs)) node.setAttribute(key, value)
  return node
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all green, 4 more tests than before this task.

- [ ] **Step 5: Mutation-check the scale assertion (CLAUDE.md §15 — this does not count until it has failed)**

Temporarily change `width: `${paper.w}mm`` to `width: `${paper.w}px``. Run:

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: RED — "a sheet declares its size in millimetres…" fails on the missing `width="215.9mm"`. **Restore the `mm`** and re-run to confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): render a page whose user units ARE millimetres"
```

---

## Task 5: The clip path must actually clip

The strips are reserved rather than overlaid, so an unclipped contour prints straight across the ruler. Task 4 added the `clipPath` element; this task proves it is *attached and effective*, which is a different claim.

**Files:**
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/system/measure_print_test.rb`:

```ruby
  # THE STRIPS ARE RESERVED, NOT OVERLAID (the deliberate divergence from the boxes sibling), so a
  # part that runs past the content box must be CUT rather than printed across the calibration
  # ruler. Asserted through the browser's own geometry rather than by reading the attribute back:
  # a clip-path naming an id that does not exist is silently inert, and `getAttribute` reports it
  # as present either way.
  test "a part running past the content box is clipped, not printed over the ruler" do
    box = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        // 500 mm tall on Letter -> tiles vertically, and tile 0's shape runs well past the bottom.
        const page = m.buildSheets(
          [{ b: [0, 0, 40, 500], k: 1, i: 0, o: 1,
             p: [[0, 0], [40, 0], [40, 500], [0, 500], [0, 0]] }],
          m.PAPERS.Letter).pages[0]
        const svg = m.renderSheet(document, page,
          { name: "tall.lbrn2", date: "2026-08-19", sizeLabel: () => null })
        // getBBox needs the node in a rendered tree.
        svg.style.position = "absolute"; svg.style.left = "-9999px"
        document.body.appendChild(svg)
        const b = svg.querySelector("g").getBoundingClientRect()
        const host = svg.getBoundingClientRect()
        const out = { top: b.top - host.top, bottom: b.bottom - host.top, host: host.height }
        svg.remove()
        return JSON.stringify(out)
      })()
    JS

    # The sheet renders at some CSS height; convert the clip's expected bottom into that scale.
    # Content bottom is MARGIN + HEADER_H + 230.4 = 247.4 mm of a 279.4 mm page.
    scale = box["host"] / 279.4
    assert_in_delta 247.4 * scale, box["bottom"], 2.0,
                    "the drawn group must stop at the content box, not run into the calibration strip"
  end
```

- [ ] **Step 2: Run it**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: PASS, with 1 more test than before this task — Task 4 already wired the clip path. **A test that passes the moment you write it has proved nothing yet**, which is what Step 3 is for.

- [ ] **Step 3: Mutation-check it**

In `renderSheet`, temporarily remove the `"clip-path": `url(#${clipId})`,` line from the `group` attributes. Run:

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: RED — the group's bottom now runs to roughly 517 mm of scale instead of 247.4. **Restore the line** and re-run to confirm green.

- [ ] **Step 4: Commit**

```bash
git add test/system/measure_print_test.rb
git commit -m "test(measure): prove the content clip is attached and effective, not merely present"
```

---

## Task 6: Sheet furniture — header, calibration gauge, trim marks

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`:

```ruby
  # ON EVERY SHEET, not only the first. Pages get separated, and a partial print — someone
  # reprinting sheet 3 alone — is exactly when a scale error most needs catching.
  test "every sheet carries the calibration gauge and the do-not-scale warning" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 40], k: 1, i: 0, o: 1, p: [[0, 0], [400, 40]] }],
        m.PAPERS.Letter).pages.map((p) =>
          Array.from(m.renderSheet(document, p,
            { name: "wide.lbrn2", date: "2026-08-19", sizeLabel: () => null })
            .querySelectorAll("text")).map((t) => t.textContent)))
    JS

    assert_equal 3, texts.length
    texts.each_with_index do |sheet, i|
      assert_includes sheet, "100 mm — check with a ruler", "sheet #{i} lost its ruler label"
      assert_includes sheet, "20 mm", "sheet #{i} lost its calibration square label"
      assert_includes sheet, "Print at 100% — do NOT scale to fit", "sheet #{i} lost its warning"
    end
  end

  # GRID COORDINATES, not "Sheet 2 of 6": when you are taping six sheets together the column and
  # row tell you WHERE the sheet goes, which a running count does not.
  test "a tiled job labels each sheet by grid position" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [0, 0, 400, 40], k: 1, i: 0, o: 1, p: [[0, 0], [400, 40]] }],
        m.PAPERS.Letter).pages.map((p) =>
          Array.from(m.renderSheet(document, p,
            { name: "wide.lbrn2", date: "2026-08-19", sizeLabel: () => null })
            .querySelectorAll("text")).map((t) => t.textContent).join("|")))
    JS

    assert_match(/Sheet 1,1 of 3×1/, texts[0])
    assert_match(/Sheet 2,1 of 3×1/, texts[1])
    assert_match(/Sheet 3,1 of 3×1/, texts[2])
  end

  # AND A SINGLE SHEET CARRIES NO LABEL AT ALL — there is nothing to register against, so it would
  # be noise. This is the half a naive implementation gets wrong by printing "Sheet 1,1 of 1×1".
  test "a single sheet carries no page label" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null })
        .querySelectorAll("text")).map((t) => t.textContent))
    JS

    refute(texts.any? { |t| t.include?("Sheet") }, "a single sheet has nothing to register against")
  end

  test "the header names the file and the date" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null })
        .querySelectorAll("text")).map((t) => t.textContent))
    JS

    assert_includes texts, "plate.lbrn2 · 2026-08-19"
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all four FAIL — no `<text>` nodes are produced at all.

- [ ] **Step 3: Add the furniture**

In `renderSheet`, insert `furniture(doc, svg, page, meta)` on the line immediately before `return svg`.

Append to `app/javascript/lib/print_sheet.js`:

```js
function furniture(doc, svg, page, meta) {
  const { paper, cols, rows, col, row } = page
  const content = contentBox(paper)
  const right = content.x + content.w
  const top = content.y
  const bottom = top + content.h

  // Trim crosshairs at the content corners — what you align two tiles by before taping.
  for (const [ x, y ] of [ [ content.x, top ], [ right, top ],
                           [ content.x, bottom ], [ right, bottom ] ]) {
    svg.appendChild(line(doc, x - 4, y, x + 4, y))
    svg.appendChild(line(doc, x, y - 4, x, y + 4))
  }

  svg.appendChild(text(doc, content.x, MARGIN + 4, "start", `${meta.name} · ${meta.date}`))
  svg.appendChild(text(doc, content.x + content.w / 2, MARGIN + 4, "middle",
                       "Print at 100% — do NOT scale to fit"))
  // GRID COORDINATES, and OMITTED ENTIRELY on a single sheet: there is nothing to register
  // against, so "Sheet 1,1 of 1×1" would be noise on the common case.
  if (cols * rows > 1) {
    svg.appendChild(text(doc, right, MARGIN + 4, "end",
                         `Sheet ${col + 1},${row + 1} of ${cols}×${rows}`))
  }

  // THE CALIBRATION GAUGE — the only defence against the print dialog's "Fit to printable area",
  // which rescales silently and which no page can detect or prevent. ON EVERY SHEET, because pages
  // get separated and a partial reprint is exactly when a scale error most needs catching.
  const by = bottom + 14
  svg.appendChild(line(doc, content.x, by, content.x + 100, by))
  for (let i = 0; i <= 100; i += 10) {
    svg.appendChild(line(doc, content.x + i, by, content.x + i, by - 3))
  }
  svg.appendChild(text(doc, content.x + 50, by + 4.5, "middle", "100 mm — check with a ruler"))

  // A SQUARE AS WELL AS A BAR: a bar checks one axis, and calipers go across a square in both.
  // Its label sits INSIDE it, because the 22 mm strip has no room below a 20 mm square.
  svg.appendChild(el(doc, "rect", {
    x: right - 20, y: bottom + 1, width: 20, height: 20,
    fill: "none", stroke: "#000", "stroke-width": 0.2,
  }))
  svg.appendChild(text(doc, right - 10, bottom + 12, "middle", "20 mm"))
}

function line(doc, x1, y1, x2, y2) {
  return el(doc, "line", { x1, y1, x2, y2, stroke: "#000", "stroke-width": 0.2 })
}

function text(doc, x, y, anchor, content) {
  const node = el(doc, "text", {
    x, y, "font-size": 3, "font-family": "sans-serif", "text-anchor": anchor, fill: "#000",
  })
  // textContent, NEVER an interpolated markup string — `meta.name` is a library filename, which is
  // user-controlled and can legitimately contain `<` on a NAS-scanned share. See printSheets.
  node.textContent = content
  return node
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all green, 4 more tests than before this task.

- [ ] **Step 5: Mutation-check both halves of the sheet label**

First, change `if (cols * rows > 1)` to `if (true)`. Run the suite: expected RED on "a single sheet carries no page label" only. Restore.

Then change the calibration block to run only on the first page — wrap the gauge lines in `if (col === 0 && row === 0)`. Run: expected RED on "every sheet carries the calibration gauge…". **Restore both** and confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): sheet furniture — header, per-sheet calibration gauge, trim marks"
```

---

## Task 7: Size labels, from the server's numbers

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`:

```ruby
  # The label text is the CONTROLLER's sizeLabel, injected — so the paper and the on-screen readout
  # have one definition between them and cannot drift apart.
  test "each part is labelled with the size its own sizeLabel returned" do
    texts = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(Array.from(m.renderSheet(document,
        m.buildSheets([
          // Min-supplier second — see Task 1's union test.
          { b: [70, 0, 80, 10], k: 1, i: 0, o: 2, d: 10, p: [[70, 0], [80, 10]] },
          { b: [0, 0, 60, 40],  k: 1, i: 0, o: 1, p: [[0, 0], [60, 40]] },
        ], m.PAPERS.Letter).pages[0],
        { name: "two.lbrn2", date: "2026-08-19",
          sizeLabel: (s) => (s.d != null ? `⌀${s.d} mm` : `${s.b[2] - s.b[0]} × ${s.b[3] - s.b[1]} mm`) })
        .querySelectorAll("text")).map((t) => t.textContent))
    JS

    assert_includes texts, "60 × 40 mm"
    assert_includes texts, "⌀10 mm"
  end

  # LABELS LIVE INSIDE THE CLIPPED GROUP, with the geometry they belong to. Outside it, a label for
  # a part that is on the NEXT tile would print on this one, pointing at nothing.
  test "size labels are clipped with the geometry they belong to" do
    parent = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => "60 × 40 mm" })
       .querySelector("text[data-role='size']").parentNode.tagName
    JS

    assert_equal "g", parent
  end

  # A sizeLabel returning null omits the label rather than printing "null" on the sheet.
  test "a part whose sizeLabel returns null gets no label" do
    count = in_print_sheet(<<~JS)
      m.renderSheet(document,
        m.buildSheets(#{SIXTY_BY_FORTY}, m.PAPERS.Letter).pages[0],
        { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null })
       .querySelectorAll("text[data-role='size']").length
    JS

    assert_equal 0, count
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: the first two FAIL (no `[data-role='size']` node exists; the label texts are absent).

- [ ] **Step 3: Emit the labels**

In `renderSheet`, replace the single contour loop with:

```js
  for (const shape of page.shapes) group.appendChild(contourNode(doc, shape))
  // A SECOND PASS, so every label sits above every outline rather than under the next contour
  // appended after it. Inside the same clipped group: a label belongs to its part, and one for a
  // part on the next tile must not print on this one.
  for (const shape of page.shapes) {
    const label = meta.sizeLabel(shape)
    if (label) group.appendChild(labelNode(doc, shape, label))
  }
```

Append to the file:

```js
// Centred under the part's bbox. 3 mm because at 1:1 a nominal text size is absurd on paper — the
// boxes sibling clamps to 2.5-4 mm for exactly this reason.
//
// THE POSITION COMES FROM `b`, THE FULL-RESOLUTION BBOX, never from `p`. Nothing here re-derives a
// measurement: the text is whatever meta.sizeLabel returned.
function labelNode(doc, shape, content) {
  const node = text(doc, (shape.b[0] + shape.b[2]) / 2, shape.b[3] + 3.6, "middle", content)
  node.setAttribute("data-role", "size")
  return node
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all green, 3 more tests than before this task.

- [ ] **Step 5: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): label each printed part with its server-computed size"
```

---

## Task 8: `printSheets` — the hidden iframe

**Files:**
- Modify: `app/javascript/lib/print_sheet.js`
- Test: `test/system/measure_print_test.rb`

`window.print()` is reached by a counted stub in Task 11 (`stub_print!` patches the
`HTMLIFrameElement.prototype.contentWindow` getter, which is the only moment a test can reach in
before `printSheets` calls print synchronously). What is **not** covered — and cannot be — is that
a physical printer receives correct ink. Everything up to the spooler is.

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`:

```ruby
  # The @page size must match the sheet's own declared size, or the browser prints an A4-shaped
  # page from a Letter-shaped SVG and clips a band off every tile.
  test "the print document declares the paper in millimetres" do
    css = in_print_sheet(<<~JS)
      (() => {
        const frame = m.buildPrintFrame(#{SIXTY_BY_FORTY}, m.PAPERS.Letter,
          { name: "plate.lbrn2", date: "2026-08-19", sizeLabel: () => null })
        const css = frame.contentDocument.querySelector("style").textContent
        frame.remove()
        return css
      })()
    JS

    assert_includes css, "@page { size: 215.9mm 279.4mm; margin: 0 }"
  end

  test "the print document holds one svg per tile" do
    count = in_print_sheet(<<~JS)
      (() => {
        const frame = m.buildPrintFrame(
          [{ b: [0, 0, 400, 40], k: 1, i: 0, o: 1, p: [[0, 0], [400, 40]] }],
          m.PAPERS.Letter, { name: "w.lbrn2", date: "2026-08-19", sizeLabel: () => null })
        const n = frame.contentDocument.querySelectorAll("svg").length
        frame.remove()
        return n
      })()
    JS

    assert_equal 3, count
  end

  # THE FILENAME IS USER-CONTROLLED AND CAN LEGITIMATELY CONTAIN `<` ON A NAS-SCANNED SHARE, so the
  # iframe is built as NODES rather than by doc.write on an interpolated markup string. The boxes
  # sibling can use doc.write because its plan carries no user text; this one does.
  test "a filename containing markup lands as text, injecting nothing" do
    out = JSON.parse(in_print_sheet(<<~JS))
      (() => {
        const frame = m.buildPrintFrame(#{SIXTY_BY_FORTY}, m.PAPERS.Letter,
          { name: "<img src=x onerror=alert(1)>.svg", date: "2026-08-19", sizeLabel: () => null })
        const doc = frame.contentDocument
        const out = {
          imgs: doc.querySelectorAll("img").length,
          header: Array.from(doc.querySelectorAll("text")).map((t) => t.textContent)
                       .find((t) => t.includes(".svg")) || "",
        }
        frame.remove()
        return JSON.stringify(out)
      })()
    JS

    assert_equal 0, out["imgs"], "the name must never be parsed as markup"
    assert_equal "<img src=x onerror=alert(1)>.svg · 2026-08-19", out["header"]
  end

  # A second print must not leave the first frame behind, accumulating a hidden iframe per click.
  test "printing twice leaves exactly one frame" do
    count = in_print_sheet(<<~JS)
      (() => {
        const meta = { name: "p.lbrn2", date: "2026-08-19", sizeLabel: () => null }
        m.buildPrintFrame(#{SIXTY_BY_FORTY}, m.PAPERS.Letter, meta)
        m.buildPrintFrame(#{SIXTY_BY_FORTY}, m.PAPERS.Letter, meta)
        const n = document.querySelectorAll(".measure-print-frame").length
        document.querySelectorAll(".measure-print-frame").forEach((f) => f.remove())
        return n
      })()
    JS

    assert_equal 1, count
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all four FAIL with `ERROR: m.buildPrintFrame is not a function`.

- [ ] **Step 3: Add the frame builder and the print entry point**

Append to `app/javascript/lib/print_sheet.js`:

```js
const FRAME_CLASS = "measure-print-frame"

// A HIDDEN IFRAME, and not either alternative: window.open gets eaten by popup blockers, and a
// print-only container in this page would mean an `@page { margin: 0 }` that applies to every
// other print of the page it lives in.
//
// SPLIT FROM printSheets SO THE DOCUMENT IS ASSERTABLE WITHOUT A SPOOLER. A headless browser has
// no print dialog to observe, so the one line that calls print() is deliberately the only part of
// this file with no test over it.
export function buildPrintFrame(shapes, paper, meta) {
  const { pages } = buildSheets(shapes, paper)

  document.querySelector(`.${FRAME_CLASS}`)?.remove()
  const frame = document.createElement("iframe")
  frame.className = FRAME_CLASS
  frame.setAttribute("aria-hidden", "true")
  frame.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;opacity:0;border:0"
  document.body.appendChild(frame)

  const doc = frame.contentDocument
  // BUILT AS NODES, NEVER doc.write ON A MARKUP STRING. `meta.name` is a library filename, which
  // is user-controlled and can legitimately contain `<` on a NAS-scanned share — interpolating it
  // into markup written to a SAME-ORIGIN iframe is an injection with this page's cookies behind
  // it. The Measure view already keeps exactly this rule for the drawing itself.
  const style = doc.createElement("style")
  style.textContent =
    `@page { size: ${paper.w}mm ${paper.h}mm; margin: 0 }` +
    "html,body { margin:0; padding:0; background:#fff }" +
    "svg { display:block; page-break-after:always; break-after:page }" +
    "svg:last-child { page-break-after:auto; break-after:auto }"
  doc.head.appendChild(style)
  for (const page of pages) doc.body.appendChild(renderSheet(doc, page, meta))

  return frame
}

// Returns the sheet count. Throws whatever buildSheets throws — the caller surfaces it.
export function printSheets(shapes, paper, meta) {
  const frame = buildPrintFrame(shapes, paper, meta)
  const doc = frame.contentDocument
  // The document has to settle before print(), or an empty frame goes to the spooler.
  const go = () => { frame.contentWindow.focus(); frame.contentWindow.print() }
  if (doc.readyState === "complete") go()
  else frame.addEventListener("load", go, { once: true })
  return doc.querySelectorAll("svg").length
}
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all green, 4 more tests than before this task.

- [ ] **Step 5: Mutation-check the injection guard**

Temporarily replace the node-building in `buildPrintFrame` with the sibling's `doc.write` shape:

```js
  doc.open()
  doc.write(`<!doctype html><html><head><style>${style.textContent}</style></head>` +
            `<body><p>${meta.name}</p></body></html>`)
  doc.close()
```

Run: expected RED on "a filename containing markup lands as text" — `imgs` is 1. **Restore the node-building version** and confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/lib/print_sheet.js test/system/measure_print_test.rb
git commit -m "feat(measure): build the print document as nodes in a hidden iframe"
```

---

## Task 9: The UI — buttons, paper picker, and the marked style

**Files:**
- Modify: `app/views/files/_measure.html.erb`
- Modify: `app/assets/stylesheets/application.css:115-140`

No test in this task: it adds markup the next two tasks drive. Task 10's first test fails without it.

- [ ] **Step 1: Add the name value and the new controls to the partial**

In `app/views/files/_measure.html.erb`, change the opening div to carry the file name:

```erb
<div class="measure-view"
     data-controller="measure"
     data-measure-url-value="<%= geometry_file_path(@node.node_id) %>"
     data-measure-name-value="<%= @node.name %>">
```

Replace the whole `<span class="measure-actions">` block with:

```erb
    <span class="measure-actions">
      <%#
        THE PAPER OPTIONS ARE POPULATED BY THE CONTROLLER FROM print_sheet.js's PAPERS table, not
        listed here. A second copy of the paper list in ERB is a second definition that drifts, and
        this select only ever appears once the controller has run anyway.
      %>
      <button type="button" class="btn small ghost" data-action="measure#toggleSelect"
              data-measure-target="selectToggle" aria-pressed="false">Select parts</button>
      <select class="measure-paper" aria-label="Paper size"
              data-measure-target="paper" data-action="measure#paperChanged"></select>
      <button type="button" class="btn small" data-action="measure#print"
              data-measure-target="printButton">Print all</button>
      <button type="button" class="btn small ghost" data-action="measure#clearMarks"
              data-measure-target="clearButton" hidden>Clear</button>
      <button type="button" class="btn small ghost" data-action="measure#reset">Reset view</button>
      <button type="button" class="btn small ghost" aria-label="Return to image"
              data-action="measure#showPoster">✕ Image</button>
    </span>
```

> **An ERB comment ends at its FIRST `%>`**, so a comment that quotes a snippet containing one
> prints its own prose into the page — and no `assert_select` can see it, because the defect
> produces a text node (CLAUDE.md §14d). The comment above deliberately describes markup in words.

- [ ] **Step 2: Add the styles**

In `app/assets/stylesheets/application.css`, insert immediately **before** the `.measure-contour--hover` line:

```css
/* The print set. A SEPARATE CLASS FROM --selected, which is the measurement highlight: one answers
   "what am I reading", the other "what will print", and one contour can be both at once. Declared
   BEFORE --hover/--selected so their stroke wins on a contour that is both, while the fill tint —
   which neither of them sets — goes on saying "this will print". */
.measure-contour--marked { stroke: #06c; stroke-width: 2; fill: rgba(0, 102, 204, .16); }
/* An open contour has no interior, so the tint would paint a meaningless blob between its ends.
   Higher specificity than both rules above, so it wins regardless of source order. */
.measure-contour--open.measure-contour--marked { fill: none; }
```

And append after the `.measure-bitmap` line:

```css
.measure-view--selecting .measure-stage svg { cursor: copy; }
.measure-paper { font-size: 13px; }
```

- [ ] **Step 3: Confirm nothing regressed**

```bash
bin/rails test test/system/lbrn_measure_test.rb
```

Expected: green. In particular `contours are stroked in their LightBurn layer colour, and selection still overrides it` must still assert `rgb(221, 68, 0)` — the new `--marked` rule must not have displaced `--selected`.

- [ ] **Step 4: Commit**

```bash
git add app/views/files/_measure.html.erb app/assets/stylesheets/application.css
git commit -m "feat(measure): select/print controls and the print-set highlight"
```

---

## Task 10: Selection mode in the controller

**Files:**
- Modify: `app/javascript/controllers/measure_controller.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`, before the `private` keyword:

```ruby
  # ---- end to end, through real clicks --------------------------------------------------------

  test "Select parts turns a click into a selection and back again" do
    open_measure_view(@nested_id)
    click_on "Select parts"

    plate = contour_with_min_x(-30)
    plate.click
    assert_selector ".measure-contour--marked", count: 1
    assert_selector ".measure-dims", text: "1 part"

    plate.click
    assert_no_selector ".measure-contour--marked"
    assert_selector ".measure-dims", text: "nothing selected"
  end

  # THE READOUT MUST STILL WORK WHILE SELECTING — picking parts and learning their sizes are the
  # same gesture, and a mode that silenced the measurement would make you leave it to check a size.
  test "selecting a part still reports its size" do
    open_measure_view(@nested_id)
    click_on "Select parts"

    contour_with_min_x(-5).click

    assert_selector ".measure-dims", text: "⌀10 mm"
    assert_selector ".measure-dims", text: "1 part"
  end

  # Off by default: the view behaves exactly as it did before this feature until the toggle is on.
  test "a click outside select mode marks nothing" do
    open_measure_view(@nested_id)

    contour_with_min_x(-30).click

    assert_no_selector ".measure-contour--marked"
    assert_selector ".measure-dims", text: "60 × 40 mm"
  end

  # BOTH HIGHLIGHTS AT ONCE. --selected answers "what am I reading" and --marked "what will
  # print", and clicking in select mode does both — so if either rule hid the other, one of the
  # two questions would be unanswerable exactly when both matter. The stroke is --selected's
  # (declared later in the sheet), the fill tint is --marked's (which neither of the others sets).
  test "a contour that is both read and selected shows both states" do
    open_measure_view(@nested_id)
    click_on "Select parts"

    plate = contour_with_min_x(-30)
    plate.click

    assert plate[:class].include?("measure-contour--marked"), "it must be in the print set"
    assert plate[:class].include?("measure-contour--selected"), "and it must be the one being read"
    # COMPUTED, not declared: reading the attribute reports what we WROTE even when a rule outranks
    # it — that is how an attribute-based version of the sibling assertion in lbrn_measure_test.rb
    # stayed green over a stylesheet that had flattened every colour.
    style = plate.style("stroke", "fill")
    assert_equal "rgb(221, 68, 0)", style["stroke"], "--selected's stroke must win"
    assert_equal "rgba(0, 102, 204, 0.16)", style["fill"], "--marked's tint must still show"
  end

  # ⌥-CLICK WIDENS TO THE WHOLE OBJECT, and on a PARTLY-marked object it COMPLETES rather than
  # inverts — flipping each contour individually would leave the object half in the print set,
  # which is never what clicking the object meant.
  #
  # DRIVEN DIRECTLY, because neither fixture has a multi-contour object: nested-plate.lbrn2 is one
  # Rect plus one Path and bezier-circle.lbrn2's two shapes are separate objects. A LightBurn Text
  # would give one (its BackupPath reuses its parent's object id), and adding that fixture is the
  # honest upgrade if this rule ever grows more cases. What is asserted here is the rule itself.
  test "widening to an object completes it rather than inverting it" do
    open_measure_view(@nested_id)
    click_on "Select parts"
    contour_with_min_x(-30).click
    assert_selector ".measure-contour--marked", count: 1

    marked = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(".measure-view")
        const c = window.Stimulus.getControllerForElementAndIdentifier(el, "measure")
        // The plate is already marked; hand toggleMarks BOTH contours as an object would be.
        c.toggleMarks(c.allShapes)
        return c.marked.size
      })()
    JS

    assert_equal 2, marked, "a partly-marked object completes; it does not invert to zero"
    assert_selector ".measure-contour--marked", count: 2
  end

  test "Clear empties the set" do
    open_measure_view(@nested_id)
    click_on "Select parts"
    contour_with_min_x(-30).click
    contour_with_min_x(-5).click
    assert_selector ".measure-contour--marked", count: 2

    click_on "Clear"

    assert_no_selector ".measure-contour--marked"
  end

  # THE BUTTON SAYS WHAT WILL HAPPEN. An empty set prints the whole file, and the only thing
  # standing between a user and an accidental six-sheet job is that the label told them.
  test "the print button names what it will print" do
    open_measure_view(@nested_id)
    assert_selector "[data-measure-target='printButton']", text: "Print all"

    click_on "Select parts"
    contour_with_min_x(-30).click

    assert_selector "[data-measure-target='printButton']", text: "Print 1 part"
  end
```

And add these two helpers inside the existing `private` section:

```ruby
    # LOCALSTORAGE OUTLIVES A TEST, and the paper choice is deliberately persisted. Selenium
    # reuses ONE Chrome for the whole file, so without the reset the paper test leaks "A4" into
    # every test that runs after it — and Rails randomizes test order, so it leaks INTERMITTENTLY,
    # failing a scale assertion that has nothing to do with paper. Same shape as the browser log
    # buffer that application_system_test_case.rb drains for exactly this reason.
    def open_measure_view(node_id, reset_paper: true)
      visit file_path(node_id)
      page.execute_script("localStorage.removeItem('measure.paper')") if reset_paper
      click_on "Measure"
      # --ready is what reveals the stage and hides the poster; without waiting for it the clicks
      # below race the fetch and land on a display:none SVG.
      assert_selector ".measure-view--ready"
    end

    # NEUTER window.print IN THE IFRAME BEFORE IT EXISTS, and count the calls. Patching the
    # PROTOTYPE getter is what makes this reachable at all: printSheets calls print() synchronously
    # right after appending the frame, so there is no later moment a test could reach in. It is not
    # merely defensive — it turns the one line that would otherwise be uncovered into a counted
    # assertion that the button really does reach the spooler, while guaranteeing nothing spools.
    def stub_print!
      page.execute_script(<<~JS)
        window.__printed = 0
        const desc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, "contentWindow")
        Object.defineProperty(HTMLIFrameElement.prototype, "contentWindow", {
          configurable: true,
          get() {
            const w = desc.get.call(this)
            try { w.print = () => { window.__printed += 1 } } catch (_) {}
            return w
          },
        })
      JS
    end

    # The plate spans x -30..30 and the hole only -5..5, so the minimum x of the rendered `points`
    # attribute identifies each one no matter which was painted on top.
    def contour_with_min_x(expected)
      match = all("svg polygon.measure-contour").find do |poly|
        poly[:points].split(/\s+/).reject(&:empty?).map { |p| p.split(",").first.to_f }.min == expected
      end
      assert match, "no contour whose points reach x=#{expected} — the fixture or the draw changed"
      match
    end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: the five new tests FAIL — `Unable to find link or button "Select parts"` is resolved by Task 9, so these fail on the missing `--marked` class and readout text instead.

- [ ] **Step 3: Add the selection state**

In `app/javascript/controllers/measure_controller.js`:

**(a)** add the name value — change the `static values` line to:

```js
  static values = { url: String, name: String }
  static targets = ["stage", "dims", "fallback", "selectToggle", "paper", "printButton", "clearButton"]
```

**(b)** in `connect()`, after `this.hovered = null`, add:

```js
    // THE PRINT SET. Membership is by IDENTITY on the payload's own shape objects, reached through
    // node.__shape — so nothing about the wire format has to change to give a contour an id.
    this.marked = new Set()
    this.nodeByShape = new Map()
    this.selecting = false
```

**(c)** in `contourNode(shape)`, immediately before `return group`, add:

```js
    // So draw() can resolve a group to the line it should style, the same way styleNode() does.
    group.__visible = node
```

**(d)** in `draw(payload)`, replace the line `for (const s of ordered) svg.appendChild(this.contourNode(s))` with:

```js
    for (const s of ordered) {
      const top = this.contourNode(s)
      svg.appendChild(top)
      // The DRAWN line, not the group and not the transparent hit twin — recorded so marking can
      // reach a contour it was not handed by an event.
      this.nodeByShape.set(s, top.__visible || top)
    }
    this.allShapes = payload.shapes
```

**(e)** replace `pick(event)` entirely with:

```js
  pick(event) {
    if (this.didPan) { this.didPan = false; return }
    const node = this.shapeAt(event)
    if (!node) return

    if (this.selected) this.styleNode(this.selected).classList.remove("measure-contour--selected")
    this.selected = node
    this.styleNode(node).classList.add("measure-contour--selected")

    const shape = node.__shape
    const siblings = this.byObject.get(shape.o) || [shape]
    // Alt-click widens to the whole <Shape> object — every contour the parser gave the same object
    // id, which for a Text is its entire rendered outline rather than one letter.
    const useObject = event.altKey && siblings.length > 1

    if (this.selecting) {
      this.toggleMarks(useObject ? siblings : [shape])
      // BOTH HALVES, because picking parts and learning their sizes are one gesture: a mode that
      // silenced the measurement would make you leave it to check a size.
      const size = useObject ? this.dims(this.unionOf(siblings)) : this.sizeLabel(shape)
      this.setStatus(`${size} · ${this.selectionStatus()}`)
      return
    }
    this.setStatus(useObject ? this.objectLabel(siblings) : this.contourLabel(shape, siblings))
  }

  toggleSelect() {
    this.selecting = !this.selecting
    this.element.classList.toggle("measure-view--selecting", this.selecting)
    this.selectToggleTarget.setAttribute("aria-pressed", String(this.selecting))
    this.selectToggleTarget.textContent = this.selecting ? "Done selecting" : "Select parts"
    this.setStatus(this.selecting ? this.selectionStatus() : "click a contour to measure")
  }

  // AN ALT-CLICK ON A PARTLY-MARKED OBJECT COMPLETES IT rather than inverting it: flipping each
  // contour individually would leave the object half in the print set, which is never what was
  // meant by clicking the object.
  toggleMarks(shapes) {
    const adding = shapes.some((s) => !this.marked.has(s))
    for (const shape of shapes) {
      const node = this.nodeByShape.get(shape)
      if (adding) {
        this.marked.add(shape)
        node?.classList.add("measure-contour--marked")
      } else {
        this.marked.delete(shape)
        node?.classList.remove("measure-contour--marked")
      }
    }
    this.refreshPrintBar()
  }

  clearMarks() {
    for (const shape of this.marked) {
      this.nodeByShape.get(shape)?.classList.remove("measure-contour--marked")
    }
    this.marked.clear()
    this.refreshPrintBar()
    this.setStatus(this.selectionStatus())
  }

  selectionStatus() {
    const n = this.marked.size
    if (!n) return "nothing selected · Print all prints the whole file"
    return `${n} part${n === 1 ? "" : "s"} · ${this.dims(this.unionOf([...this.marked]))}`
  }

  refreshPrintBar() {
    if (!this.hasPrintButtonTarget) return
    const n = this.marked.size
    this.printButtonTarget.textContent = n ? `Print ${n} part${n === 1 ? "" : "s"}` : "Print all"
    this.clearButtonTarget.hidden = n === 0
  }
```

**(f)** in `showPoster()`, replace the last line with:

```js
    this.selected = this.hovered = this.svg = null
    this.marked.clear()
    this.nodeByShape.clear()
    this.selecting = false
    this.element.classList.remove("measure-view--selecting")
    this.refreshPrintBar()
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb test/system/lbrn_measure_test.rb
```

Expected: all green, 7 more tests than before this task; `lbrn_measure_test.rb` still green.

- [ ] **Step 5: Mutation-check that the mode gate is real**

Temporarily change `if (this.selecting) {` in `pick` to `if (true) {`. Run: expected RED on "a click outside select mode marks nothing". **Restore** and confirm green.

Then change `toggleMarks` to flip each contour individually:

```js
    for (const shape of shapes) {
      if (this.marked.has(shape)) { this.marked.delete(shape); ... } else { this.marked.add(shape); ... }
    }
```

Run: expected RED on "widening to an object completes it rather than inverting it" — `marked.size`
is 1, not 2, because the already-marked plate flipped off as the hole flipped on. **Restore** and
confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/measure_controller.js test/system/measure_print_test.rb
git commit -m "feat(measure): a Select parts mode that builds a print set"
```

---

## Task 11: Wire Print, the paper picker, and the refusal message

**Files:**
- Modify: `app/javascript/controllers/measure_controller.js`
- Test: `test/system/measure_print_test.rb`

- [ ] **Step 1: Write the failing tests**

Add to `test/system/measure_print_test.rb`, before `private`:

```ruby
  # THE END-TO-END SCALE ASSERTION, and the one with teeth: it proves the REAL payload reaches the
  # sheet at 1:1, which every synthetic test above deliberately cannot. The fixture's plate is
  # 60 x 40 mm, so its printed polygon must span 60 by 40 user units on a sheet whose user units
  # are millimetres.
  test "a real selected part reaches the sheet at exactly its measured size" do
    open_measure_view(@nested_id)
    stub_print!
    click_on "Select parts"
    contour_with_min_x(-30).click
    click_on "Print 1 part"

    assert_equal 1, page.evaluate_script("window.__printed"), "Print must reach the spooler"
    span = JSON.parse(page.evaluate_script(<<~JS))
      (() => {
        const doc = document.querySelector(".measure-print-frame").contentDocument
        const pts = doc.querySelector("g polygon").getAttribute("points")
          .trim().split(/\\s+/).map((p) => p.split(",").map(Number))
        const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1])
        return JSON.stringify({
          w: Math.max(...xs) - Math.min(...xs),
          h: Math.max(...ys) - Math.min(...ys),
          svgW: doc.querySelector("svg").getAttribute("width"),
        })
      })()
    JS

    assert_in_delta 60.0, span["w"], 0.05
    assert_in_delta 40.0, span["h"], 0.05
    assert_equal "215.9mm", span["svgW"]
  end

  # TWO REAL PARTS KEEP THEIR REAL SEPARATION. bezier-circle.lbrn2's circle reaches x -10..10 and
  # its square x 40..60, so their left edges are 50 mm apart in the file and must be 50 mm apart
  # on the sheet.
  test "two real selected parts keep their separation on the sheet" do
    open_measure_view(@apart_id)
    stub_print!
    click_on "Select parts"
    contour_with_min_x(-10).click
    contour_with_min_x(40).click
    click_on "Print 2 parts"

    gap = page.evaluate_script(<<~JS)
      (() => {
        const doc = document.querySelector(".measure-print-frame").contentDocument
        const lefts = Array.from(doc.querySelectorAll("g polygon")).map((n) =>
          Math.min(...n.getAttribute("points").trim().split(/\\s+/).map((p) => parseFloat(p))))
        return Math.max(...lefts) - Math.min(...lefts)
      })()
    JS

    assert_in_delta 50.0, gap, 0.05
  end

  # THE REFUSAL MUST REACH THE USER, not just the console. buildSheets throws; without the
  # controller's rescue, clicking Print on an absurd selection would do nothing whatsoever and read
  # as a broken button.
  test "an absurd selection reports why it will not print" do
    open_measure_view(@nested_id)
    stub_print!
    # Drive the controller's own error path with a selection no fixture can produce.
    page.execute_script(<<~JS)
      const el = document.querySelector(".measure-view")
      const c = window.Stimulus.getControllerForElementAndIdentifier(el, "measure")
      c.allShapes = [{ b: [0, 0, 20000, 20000], k: 1, i: 0, o: 1, p: [[0, 0], [20000, 20000]] }]
      c.marked.clear()
      c.print()
    JS

    assert_selector ".measure-dims", text: "more than 40 sheets"
    assert_equal 0, page.evaluate_script("window.__printed"), "nothing may be spooled"
  end

  test "the paper picker offers the four sizes and remembers the choice" do
    open_measure_view(@nested_id)
    assert_selector "[data-measure-target='paper'] option", count: 4

    select "A4", from: "Paper size"
    # DELIBERATELY NOT the reset path — this is the one test that must observe the value surviving
    # a page load.
    open_measure_view(@nested_id, reset_paper: false)

    assert_equal "A4", find("[data-measure-target='paper']").value
  end

  test "the Measure view prints without logging a console error" do
    open_measure_view(@nested_id)
    stub_print!
    click_on "Select parts"
    contour_with_min_x(-30).click
    click_on "Print 1 part"

    assert_selector ".measure-print-frame", visible: :all
    assert_no_console_errors
  end
```

- [ ] **Step 2: Run and watch them fail**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: FAIL — the paper select has no options, and clicking Print does nothing.

- [ ] **Step 3: Wire it up**

At the top of `app/javascript/controllers/measure_controller.js`, after the Stimulus import, add:

```js
import { PAPERS, printSheets } from "lib/print_sheet"
```

Add near the other module constants:

```js
// Remembered across visits: the paper in your printer does not change between files.
const PAPER_KEY = "measure.paper"
// A guess about the operator rather than a measurement — one constant to change.
const DEFAULT_PAPER = "Letter"
```

Add these methods to the controller:

```js
  // POPULATED FROM print_sheet.js's PAPERS TABLE, not listed in the ERB: a second copy of the
  // paper list is a second definition, and this select is hidden until the controller runs anyway.
  populatePaper() {
    if (!this.hasPaperTarget || this.paperTarget.options.length) return
    const saved = localStorage.getItem(PAPER_KEY)
    const chosen = PAPERS[saved] ? saved : DEFAULT_PAPER
    for (const key of Object.keys(PAPERS)) {
      const option = document.createElement("option")
      option.value = key
      option.textContent = PAPERS[key].name
      option.selected = key === chosen
      this.paperTarget.appendChild(option)
    }
  }

  paperChanged() {
    localStorage.setItem(PAPER_KEY, this.paperTarget.value)
  }

  print() {
    // An empty set prints the whole file — which is what the button has been saying all along.
    const shapes = this.marked.size ? [...this.marked] : this.allShapes
    if (!shapes || !shapes.length) return
    try {
      printSheets(shapes, PAPERS[this.paperTarget.value] || PAPERS[DEFAULT_PAPER], {
        name: this.nameValue,
        date: new Date().toISOString().slice(0, 10),
        // THE CONTROLLER'S OWN sizeLabel, so the paper and the readout have one definition between
        // them. It reads `d` and `b` — the server's full-resolution numbers — never `p`.
        sizeLabel: (shape) => this.sizeLabel(shape),
      })
    } catch (e) {
      // The sheet-count refusal lands here, and its message names the size that caused it.
      this.setStatus(e.message)
    }
  }
```

In `draw(payload)`, immediately before `this.bindInteractions(svg)`, add:

```js
    this.populatePaper()
    this.refreshPrintBar()
```

- [ ] **Step 4: Run and watch them pass**

```bash
bin/rails test test/system/measure_print_test.rb
```

Expected: all green, 5 more tests than before this task (6 once Step 5 keeps the diameter test).

- [ ] **Step 5: Mutation-check the size-label source — the sharp one**

This is CLAUDE.md §14h's measure-after-thinning trap, reintroduced deliberately. In `print()`, replace the `sizeLabel` line with one that re-derives from the thinned points:

```js
        sizeLabel: (shape) => {
          const xs = shape.p.map((p) => p[0]), ys = shape.p.map((p) => p[1])
          return `${Math.max(...xs) - Math.min(...xs)} × ${Math.max(...ys) - Math.min(...ys)} mm`
        },
```

Add this temporary assertion to the end of the "a real selected part reaches the sheet…" test:

```ruby
    open_measure_view(@nested_id)
    stub_print!
    click_on "Select parts"
    contour_with_min_x(-5).click
    click_on "Print 1 part"
    label = page.evaluate_script(<<~JS)
      document.querySelector(".measure-print-frame").contentDocument
        .querySelector("text[data-role='size']").textContent
    JS
    assert_equal "⌀10 mm", label
```

Run: expected RED — the ⌀10 hole reports a bounding box instead of a diameter. **Restore the real `sizeLabel`**, keep the new assertion (it is a good permanent test — move it into its own `test "a round part prints its diameter, not a bounding box"` block), and confirm green.

- [ ] **Step 6: Commit**

```bash
git add app/javascript/controllers/measure_controller.js test/system/measure_print_test.rb
git commit -m "feat(measure): print the selected parts at 1:1, on remembered paper"
```

---

## Task 12: Documentation and the full gate

**Files:**
- Modify: `docs/STATUS.md`
- Modify: `CLAUDE.md` (§14h)

- [ ] **Step 1: Add the invariants to CLAUDE.md §14h**

Append these bullets to the end of §14h, before the `### 14i.` heading:

```markdown
- **THE PRINT SHEET'S SCALE IS `width="215.9mm"` PLUS A `viewBox` SPANNING 215.9 USER UNITS, AND
  THAT PAIR IS THE WHOLE MECHANISM.** There is no transform and no dpi constant. A px width with
  the same viewBox draws an identical-looking page at the wrong size, on paper, where the error is
  only discoverable with a ruler — which is why `measure_print_test.rb` asserts both literals and
  separately asserts that a 60 mm part spans 60 units. "A polygon exists" is answered exactly as
  well by a polygon of the wrong size.
- **THE HEADER AND CALIBRATION STRIPS ARE RESERVED, NOT OVERLAID — the deliberate divergence from
  the `boxes` sibling**, which draws its bar over its content because it knows its own content is a
  tray plan of known extent. Measure prints arbitrary user geometry that can be anywhere, so an
  overlaid ruler lands across a part outline. The consequence is a real `<clipPath>` where the
  sibling gets away with a bbox filter, and a clip-path naming a missing id is **silently inert**,
  so the guard asserts the browser's own geometry rather than reading the attribute back.
- **THE PRINTED SIZE LABEL COMES FROM `sizeLabel()`, INJECTED FROM THE CONTROLLER, NEVER RE-DERIVED
  FROM `shape.p`.** Those are the THINNED drawing points: measuring from them under-reports every
  curve, and the ⌀10 hole in `nested-plate.lbrn2` thins below `MIN_CIRCLE_POINTS` and loses its
  diameter entirely — printing a bounding box where a ⌀ belongs. Same trap as measuring before
  thinning, one surface further out. Mutation-checked.
- **THE PRINT IFRAME IS BUILT AS NODES, NOT `doc.write` ON A MARKUP STRING**, because the header
  carries a library FILENAME — user-controlled, and legitimately able to contain `<` on a
  NAS-scanned share. The `boxes` sibling can use `doc.write` because its plan carries no user text.
  Copying that pattern across is an injection into a same-origin iframe.
- **`lib/print_sheet.js` DUPLICATES THE `boxes` BUNDLE'S `sheet.js` CONVENTIONS ON PURPOSE** —
  same `MARGIN`/`OVERLAP` = 10, same `MAX_SHEETS` = 40, same `Sheet c,r of C×R`. That bundle lives
  in `chaim354/tinkerex-addons`, where **publishing IS the deploy and Rails is never rebuilt**
  (§14c), so importing it through the addon asset proxy would let an addon republish break a core
  file page — and would remove Measure's print button outright on OVH, which blanks
  `ADDON_SOURCE_URL`. Conventions copied, code not. If they ever must agree mechanically, move the
  pagination to ONE place; do not add a third copy.
- **A SINGLE SHEET CARRIES NO `Sheet 1,1 of 1×1` LABEL**, because there is nothing to register
  against — and both halves of that rule are mutation-checked, since an implementation that always
  labels and one that never does each pass half the tests.
```

- [ ] **Step 2: Add the STATUS.md arc entry**

Add ONE entry for the whole arc (§15: one arc is one entry, amended rather than appended to per
PR), at the appropriate dated position in `docs/STATUS.md`, following the file's existing format.
Fill the bracketed values from what you actually observed — they are the only parts of this plan
that cannot be written in advance, and they are exactly the parts a later pass reconstructs badly:

```markdown
## 2026-08-19: Measure parts print at 1:1 for paper fit testing (branch `claude/svg-pattern-scale-fit-test-5d1311`)

**Shipped:** a **Select parts** toggle on the Measure view and a **Print** that lays the selected
contours out at exactly 1:1, tiling across sheets when they do not fit. Serves all four measurable
formats, because the controller branches on no file type.

**NO SERVER CHANGE, AND THAT IS THE HEADLINE.** Everything the sheet needs was already in the
geometry payload — mm coordinates, the full-resolution bbox, the server-decided diameter. So
`Geometry::SCHEMA_VERSION` did not move, no renderer's `PAYLOAD_REVISION` moved, and **no deployed
library was re-measured**. Verified with `git diff main --stat`: [paste the app/services line, or
state that there is none].

**The scale mechanism is two attributes.** `width="215.9mm"` plus `viewBox="0 0 215.9 279.4"` makes
one user unit one millimetre; there is no transform and no dpi constant. The reserved strips cost
29 mm of every sheet's height (7 header + 22 calibration), giving a Letter content box of
195.9 × 230.4 mm and A4 190 × 248 mm — and they are RESERVED rather than overlaid, unlike the
`boxes` sibling, because this prints arbitrary user geometry that could otherwise land on the ruler.

**Deliberate duplication of the `boxes` bundle's `sheet.js`**, argued in full at
`docs/superpowers/specs/2026-08-19-measure-print-to-scale-design.md` §10: that bundle lives in
another repo where publishing IS the deploy, so importing it would let an addon republish break a
core file page. Conventions and constants copied; code not.

**Mutation checks run**, each observed red then restored: [list each — mm→px turned the scale
assertion red; removing the clip-path let the group run to ~[N] mm; calibration on page 1 only;
`cols * rows > 1` → `true`; doc.write with an interpolated name injected an `<img>`; `sizeLabel`
re-derived from the thinned `p` reported a bounding box where ⌀10 belonged].

**Measured.** `bin/ci` green, all gates, exit 0 ([N] s). The three test legs report identical
counts: [N] runs / [N] assertions. System tier: [N] runs.
```

- [ ] **Step 3: Run the whole suite the way CI does**

```bash
bin/ci
```

Expected: all gates green, exit 0. The three test legs (`test`, `test-share`, `test-s3`) must report **identical** counts — nothing in this change is backend-specific, so a divergence means something reached the server that should not have.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/STATUS.md
git commit -m "docs: record the Measure to-scale print, and the invariants that keep it 1:1"
```

- [ ] **Step 5: Finish the branch**

Use the `/finish-branch` skill, or per CLAUDE.md §15: on a green bare `bin/ci`, commit, push and open the PR without asking. **Do not merge** — that always needs an explicit go-ahead.

---

## Verification checklist

Before calling this done, every one of these must be true:

- [ ] `bin/ci` green, all gates, exit 0, three test legs reporting identical counts.
- [ ] Every mutation check in Tasks 4, 5, 6, 8, 10 and 11 was **run** and observed **red**, then restored.
- [ ] `test/system/lbrn_measure_test.rb` still green — in particular the `rgb(221, 68, 0)` assertion, which proves `--marked` did not displace `--selected`.
- [ ] No file under `app/services/`, `app/controllers/` or `app/models/` was modified. If one was, the design was not followed.
- [ ] `git diff main --stat` shows no change to `SCHEMA_VERSION`, `SHARED_REVISION`, or any `PAYLOAD_REVISION`.
- [ ] Opening a real `.svg`, `.dxf` and `.mage` file page shows the Measure view with the new controls — the controller branches on no file type, and this confirms it.
