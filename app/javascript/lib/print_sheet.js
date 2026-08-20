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
  const w = box[2] - box[0], h = box[3] - box[1]
  const content = contentBox(paper)
  // Steps come off the CONTENT box, not the printable box — the two reserved strips are not
  // available for geometry, so pretending they are would clip a band off every tile but the last.
  const stepX = content.w - OVERLAP, stepY = content.h - OVERLAP
  const cols = w <= content.w ? 1 : Math.ceil((w - OVERLAP) / stepX)
  const rows = h <= content.h ? 1 : Math.ceil((h - OVERLAP) / stepY)

  // THE REFUSAL GOES ABOVE THE PAGE LOOP, NOT AFTER IT — a constraint, not a style preference.
  // Both counts already exist here, so checking them costs nothing; filtering `pages` afterwards
  // means a 100 m selection (an SVG misread at 25.4x, this module's own stated motivation)
  // allocates 244,252 page objects before anything can look, and the tab hangs instead of saying
  // "too many sheets". It also closes ONE degenerate paper for free — read that narrowly: a
  // content box EXACTLY one overlap band wide gives stepX = 0 and therefore cols = Infinity, and
  // `Infinity * rows > MAX_SHEETS` refuses in constant time where the `col` loop would never end.
  // A content box NARROWER than the band is not covered and is not meant to be: stepX goes
  // negative, cols comes out negative (paper.w 25 -> stepX -5 -> cols -18), nothing exceeds
  // MAX_SHEETS, the loop body never runs, and the caller gets an empty `pages` and a silent blank
  // print. Neither shape is reachable from PAPERS, so this is a note about what the guard does
  // and does not do, not a defect — do not read the Infinity case as a general small-paper guard.
  if (cols * rows > MAX_SHEETS) {
    throw new Error(
      `${cols * rows} sheets — this selection is ${round(w)} × ${round(h)} mm, which is more ` +
      `than ${MAX_SHEETS} sheets of ${paper.name}. Select fewer parts, or choose larger paper.`)
  }

  const pages = []
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      // SELECTION space — the tile's offset within the union box. translateX/Y below are
      // PAGE space, and fold in the datum shift by -box[0]/-box[1].
      const originX = col * stepX, originY = row * stepY
      pages.push({
        paper, col, row, cols, rows, originX, originY,
        // Content space -> page space. THE SELECTION's own bbox origin is the datum, not the
        // file's, which is what makes "true positions" mean RELATIVE positions: two holes 40 mm
        // apart on a 600 mm sheet print on one page, 40 mm apart, not on tile 4 of 12.
        translateX: content.x - originX - box[0],
        translateY: content.y - originY - box[1],
        shapes: shapes.filter((s) => touches(s, box, originX, originY, content)),
      })
    }
  }
  return { cols, rows, pages }
}

// Keep any shape whose bbox touches this tile's content box. A BBOX TEST, deliberately: a contour
// crossing the tile edge is kept whole and cut by the <clipPath> at render time, and the overlap
// band already guarantees that a mark near an edge appears on both tiles. Exact clipping here
// would buy nothing and would have to reimplement what the renderer gets from the browser.
//
// EVERYTHING HERE IS SELECTION SPACE, which is what `- box[0]` / `- box[1]` buy: originX/originY
// are the tile's offset within the union box (buildSheets' own comment), so a shape's file
// coordinates have to be shifted onto that datum before they can be compared with one. Drop
// either subtraction and every comparison silently answers about a different coordinate system —
// invisible to any test whose selection happens to start at (0, 0).
function touches(shape, box, originX, originY, content) {
  const x0 = shape.b[0] - box[0], y0 = shape.b[1] - box[1]
  const x1 = shape.b[2] - box[0], y1 = shape.b[3] - box[1]
  return x1 >= originX && x0 <= originX + content.w &&
         y1 >= originY && y0 <= originY + content.h
}

const round = (v) => Math.round(v * 10) / 10

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

  // TWO NESTED GROUPS, AND THE NESTING IS THE WHOLE POINT — DO NOT COLLAPSE THEM INTO ONE.
  //
  // `clipPathUnits` defaults to `userSpaceOnUse`, and that means the user space of the element
  // that REFERENCES the clip — not the page. So putting `clip-path` and `transform` on one group
  // makes the clip window move WITH the geometry instead of staying on the paper. Verified in
  // Chrome by hit testing, not reasoned: with both on one group, a point inside the content box
  // is not painted at all. On this repo's own nested-plate fixture the sheet prints a 20 x 3 mm
  // scrap of one corner; for an ordinary laser file whose parts sit at POSITIVE coordinates the
  // translate is negative, the window lands off-paper entirely, and THE WHOLE SHEET PRINTS BLANK.
  // No error, nothing logged, on a page that is otherwise perfectly formed.
  const clipped = el(doc, "g", { "clip-path": `url(#${clipId})` })
  // ONE TRANSFORM FOR THE WHOLE PAGE, not one per shape: parts keep their relative positions
  // because they are all moved by the same amount.
  const group = el(doc, "g", {
    transform: `translate(${page.translateX} ${page.translateY})`,
  })
  for (const shape of page.shapes) group.appendChild(contourNode(doc, shape))
  clipped.appendChild(group)
  svg.appendChild(clipped)

  furniture(doc, svg, page, meta)
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

// THE ONE DOOR EVERY ELEMENT IN THIS MODULE IS BUILT THROUGH.
//
// EXPORTED FOR ONE REASON: to let the browser tier pin the mis-call guard below. This repo has no
// JS test runner, and nothing reachable through `renderSheet` can put a string in the `attrs`
// slot — so without the export that guard would be a guard that has never failed, which
// CLAUDE.md §15 says is a guard that has not been shown to work. The export is not a second door:
// every element on a sheet is still constructed here.
export function el(doc, tag, attrs, text) {
  // A STRING IN THE `attrs` SLOT DOES NOT THROW, WHICH IS THE WHOLE REASON THIS EXISTS.
  // `el(doc, "text", "Sheet 1,1 of 2×1")` — one dropped `{}` away from the five <text> sites in
  // `furniture` — was expected to raise InvalidCharacterError, since an attribute name cannot
  // begin with a digit. Probed in Chrome: it does not. `Object.entries` walks the string's own
  // indices and `setAttribute` accepts "0" as a name, so the result is
  // `<text 0="S" 1="h" 2="e" ...>` — sixteen junk attributes, no text content, an empty <text>
  // that renders nothing on a page that is otherwise perfectly formed, with nothing thrown and
  // nothing logged. Measured verbatim in measure_print_test.rb, which pins this.
  if (typeof attrs === "string") {
    throw new Error("el(doc, tag, attrs, text): the third argument is the attribute map, not " +
                    "the text — pass el(doc, tag, {}, text).")
  }
  const node = doc.createElementNS(SVG_NS, tag)
  for (const [ key, value ] of Object.entries(attrs)) {
    // An undefined value writes the literal string "undefined" (a null writes "null"). Sheet
    // furniture is full of conditional attributes, so skip here rather than making every call
    // site remember. `text()` below is the live caller: it omits `text-anchor` entirely for the
    // default `start` rather than restating it. MEASURED, not reasoned: an unguarded
    // `text-anchor="undefined"` is an INVALID value, so getComputedStyle reports `start` and the
    // rendered bbox x comes back 99.99999237060547 — byte-identical to the attribute being
    // absent. (An earlier draft quoted a contrasting `middle` figure here; it was measured on a
    // probe string this module never prints, so it reproduced for nothing. Removed rather than
    // re-measured — the byte-identity is the whole claim.) The sheet looks EXACTLY right, which
    // is why measure_print_test.rb asserts the ATTRIBUTE rather than a position.
    if (value != null) node.setAttribute(key, value)
  }
  // THE TEXT DOOR EXISTS SO THAT `textContent` IS THE ONLY SPELLING — and since Task 6 it is:
  // all five <text> sites go through `text()` below, which comes through here. The rule it
  // enforces: the header carries a library filename, user-controlled and legitimately able to
  // contain `<` on a NAS-scanned share, so building it as markup is an injection into a
  // same-origin iframe. Five call sites each remembering that is five chances to forget; one
  // door is none.
  if (text != null) node.textContent = text
  return node
}

// THE SHEET FURNITURE — header, per-sheet calibration gauge, trim crosshairs.
//
// DRAWN STRAIGHT ONTO THE <svg>, NEVER INSIDE THE CLIPPED OR TRANSLATED GROUPS above, and both
// would fail SILENTLY. The clip window is the content box, and the gauge sits BELOW it, so a
// clipped gauge is erased outright; the page transform is the selection's own datum shift, so
// transformed furniture rides off the paper for any selection not at the origin. In both cases
// every label is still in the DOM and still reads back — only the paper is blank.
function furniture(doc, svg, page, meta) {
  const { paper, cols, rows, col, row } = page
  const content = contentBox(paper)
  const right = content.x + content.w
  const top = content.y
  const bottom = top + content.h

  // Trim crosshairs at the content corners — what you align two tiles by before taping. They are
  // the one piece of furniture that deliberately reaches INTO the content box (4 mm each way),
  // because a mark you have to align to is useless drawn only outside the paper's live area.
  for (const [ x, y ] of [ [ content.x, top ], [ right, top ],
                           [ content.x, bottom ], [ right, bottom ] ]) {
    svg.appendChild(line(doc, x - 4, y, x + 4, y))
    svg.appendChild(line(doc, x, y - 4, x, y + 4))
  }

  // ONE FONT-SIZE ABOVE THE CONTENT BOX'S OWN TOP EDGE, rather than a bare `MARGIN + 4` that has
  // to be remembered to agree with HEADER_H. Identical today (17 - 3 = 14); the difference is that
  // shrinking HEADER_H now moves the header with the strip instead of leaving it behind in the
  // geometry. The gauge's own offsets below are a designed layout rather than a formula — what
  // keeps THEM honest against CALIB_H is the strip-containment test, not arithmetic here.
  const headerY = top - FONT
  svg.appendChild(text(doc, content.x, headerY, headerLabel(meta.name, meta.date, content)))
  svg.appendChild(text(doc, content.x + content.w / 2, headerY,
                       "Print at 100% — do NOT scale to fit", "middle"))
  // GRID COORDINATES, and OMITTED ENTIRELY on a single sheet: there is nothing to register
  // against, so "Sheet 1,1 of 1×1" would be noise on the common case.
  if (cols * rows > 1) {
    svg.appendChild(text(doc, right, headerY,
                         `Sheet ${col + 1},${row + 1} of ${cols}×${rows}`, "end"))
  }

  // THE CALIBRATION GAUGE — the only defence against the print dialog's "Fit to printable area",
  // which rescales silently and which no page can detect or prevent. ON EVERY SHEET, because pages
  // get separated and a partial reprint is exactly when a scale error most needs catching.
  //
  // AND IT MUST MEASURE WHAT IT SAYS. A bar labelled "100 mm" that is drawn 90 long certifies a
  // mis-scaled print — strictly worse than printing no gauge at all — and neither the label nor
  // the picture can tell you, because there is nothing on the sheet to compare it against. That is
  // why the tick spacing and the two extents are asserted as numbers rather than as "a bar exists".
  //
  // IT ASSUMES content.w >= ~130 AND DOES NOT CHECK, in the spirit of buildSheets' own small-paper
  // note: the bar is a fixed 100 mm from content.x and the square a fixed 20 mm inset from `right`,
  // so a content box narrower than about 130 mm runs the bar under the square and then off the
  // paper. Every entry in PAPERS clears it (A4, the narrowest, is 190), and `renderSheet` takes an
  // arbitrary `paper` — so read this as a statement of the range this layout covers, not as a
  // guard that exists.
  const by = bottom + 14
  svg.appendChild(line(doc, content.x, by, content.x + 100, by))
  for (let i = 0; i <= 100; i += 10) {
    svg.appendChild(line(doc, content.x + i, by, content.x + i, by - 3))
  }
  svg.appendChild(text(doc, content.x + 50, by + 4.5, "100 mm — check with a ruler", "middle"))

  // A SQUARE AS WELL AS A BAR: a bar checks one axis, and calipers go across a square in both.
  // Its label sits INSIDE it, because the 22 mm strip has no room below a 20 mm square.
  svg.appendChild(el(doc, "rect", {
    x: right - 20, y: bottom + 1, width: 20, height: 20,
    fill: "none", stroke: "#000", "stroke-width": 0.2,
  }))
  svg.appendChild(text(doc, right - 10, bottom + 12, "20 mm", "middle"))
}

// THE HEADER LINE'S THREE TEXTS SHARE ONE ROW, AND THE LEFT ONE IS THE ONLY ARBITRARY-LENGTH
// THING ON THE SHEET. Nothing truncated it until this was measured: on A4 — the narrowest content
// box PAPERS offers, 190 mm — the centred warning occupies x 81.28..128.72, and a 40-character
// filename ("Rev C bracket assembly plate final.lbrn2", an ordinary length on a NAS-scanned share)
// reaches x 81.48 and OVERPRINTS IT. A 70-character name buries the warning outright and runs on
// under the sheet label. The sheet whose entire purpose is "do NOT scale to fit" is then the one
// sheet that cannot say so.
//
// TRUNCATED IN THE MIDDLE, keeping head AND tail: a maker telling `panel-v11.lbrn2` from
// `panel-v12.svg` needs the extension every bit as much as the start, so a trailing "…" is the
// wrong end to cut.
//
// THE BUDGET IS A WORST CASE, NOT AN AVERAGE, because a filename is arbitrary user input. Both
// numbers below were MEASURED in the browser at 3 mm sans-serif and are RE-MEASURED AND ASSERTED
// by measure_print_test.rb, so a font change on the CI box goes red here rather than silently
// overprinting the warning.
//
//   WORST_GLYPH — the widest printable ASCII advance. It is "@" at 3.0432 mm, NOT the "W"
//     (2.8296) that is the obvious guess; "…" is 2.9979, so charging the ellipsis at this rate is
//     safe too. Rounded UP to 3.05.
//   DATE_GLYPH  — the widest advance in ` · YYYY-MM-DD`, which is a digit at 1.6673. The date is
//     charged at its OWN repertoire rather than at WORST_GLYPH because it is a fixed-format string
//     THIS APP supplies, not user input; charging all 13 of its characters at "@" rate would eat
//     22 mm of a 47 mm budget and truncate `plate.lbrn2` for no reason. Residual, stated plainly:
//     a caller that puts something long and wide in `meta.date` is not covered.
//   WARNING_HALF — half the centred warning's own measured width (47.4356 mm), which is what the
//     left text has to clear.
//
// ACCEPTED COST: a worst-case budget is pessimistic for ordinary text — roughly 1.35 mm/character
// actually renders — so a name that would have fitted still gets an ellipsis. That is the trade
// this is meant to make: the failure it replaces is silent and lands on the warning.
// EXPORTED so the test can assert it against a fresh browser measurement. The geometric
// assertion alone cannot: it clears the warning by ~5.7 mm, so a `W`-tuned 2.83 still passes it.
export const WORST_GLYPH = 3.05
const DATE_GLYPH = 1.7
const WARNING_HALF = 24
const HEADER_GAP = 2
const FONT = 3

function headerLabel(name, date, content) {
  const suffix = ` · ${date}`
  const budget = content.w / 2 - WARNING_HALF - HEADER_GAP - suffix.length * DATE_GLYPH
  return truncateMiddle(String(name), Math.floor(budget / WORST_GLYPH)) + suffix
}

function truncateMiddle(s, max) {
  if (max < 3) return "…"
  if (s.length <= max) return s
  const head = Math.ceil((max - 1) / 2)
  return s.slice(0, head) + "…" + s.slice(s.length - (max - 1 - head))
}

function line(doc, x1, y1, x2, y2) {
  return el(doc, "line", { x1, y1, x2, y2, stroke: "#000", "stroke-width": 0.2 })
}

// ANCHOR LAST AND OPTIONAL, WHICH IS DELIBERATE AND IS `el`'s NULLISH GUARD'S ONE LIVE CALLER.
// `text-anchor`'s initial value IS `start`, so the header omits the attribute rather than
// restating the default — spelled as a missing argument here instead of as a branch inside `el`.
//
// The fourth argument goes through `el`'s text door, which sets `textContent` — NEVER an
// interpolated markup string. `meta.name` is a library filename, user-controlled and legitimately
// able to contain `<` on a NAS-scanned share. See printSheets.
//
// FONT-SIZE IS NOT DECORATION: SVG's initial value is 16px, which at one user unit per millimetre
// is a 16 mm line of type — more than twice the 7 mm reserved for the header, printed across the
// geometry. 3 is a BARE NUMBER for the same reason `stroke-width` is (see contourNode): a unit
// suffix inside an SVG attribute resolves through CSS at 96 dpi, so `"3mm"` computes to
// 11.3386px — measured, and its bbox is byte-identical to `font-size="11.3386"` — a header
// nearly four times too tall, on a sheet that still looks like a sheet.
function text(doc, x, y, content, anchor) {
  return el(doc, "text", {
    x, y, "font-size": FONT, "font-family": "sans-serif", "text-anchor": anchor, fill: "#000",
  }, content)
}
