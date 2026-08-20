// Pagination, sheet rendering, and the print document, for the Measure view's to-scale print.
//
// Takes shapes in millimetres and a paper, returns pages of shapes in millimetres, renders a page
// as an <svg>, and — at the bottom of this file — assembles those pages into a hidden iframe and
// spools it. Knows nothing about Stimulus, about the Measure controller, or about file formats:
// it reads `b`, `p`, `k` and `i` off a shape and nothing else.
//
// TWO THIRDS OF IT IS PURE AND THE LAST THIRD IS NOT, WHICH IS WHERE TO LOOK FOR LIFECYCLE.
// `buildPrintFrame` owns a NODE ON THE HOST PAGE (one `.measure-print-frame` iframe, replaced
// rather than accumulated) and `printSheets` calls the browser's own print(). Nothing above them
// touches the document they are called from.
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

  // THE UNION BOX IS GEOMETRY ONLY. A size label hangs up to ~4.4 mm BELOW its part's bbox and is
  // not accounted for here, so on the last row a part clearing the content box by less than that
  // has its label sliced or lost — measured on Letter: 226 mm labelled, 228 cut, 230 gone. Padding
  // the box here would fix it and would silently move every page count Tasks 2 and 3 pinned, so it
  // is recorded rather than fixed. The measurement and the failure direction are in `labelNode`.
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
  // A SECOND PASS, so every label sits above every outline rather than under whichever contour
  // was appended after it — parts overlap routinely (this repo's own nested-plate fixture is a
  // plate with a hole on the same centre) and SVG paints in document order.
  //
  // INSIDE THE SAME CLIPPED, TRANSLATED GROUP, and both halves are deliberate. The label's
  // position is in the same millimetres as its part, so it must ride the page transform or it
  // prints at the file's own coordinates — for a part sitting at x = 100 in its file, the page
  // translate is MARGIN - 100 and the label lands 90 mm from where its outline is. And it
  // must be CUT by the same window: a part taller than one tile is kept whole on every tile it
  // touches, so its label hangs below THIS tile's content box and would otherwise print straight
  // across the calibration ruler, on the sheet whose one job is to certify the scale.
  for (const shape of page.shapes) {
    const label = meta.sizeLabel(shape)
    if (label) group.appendChild(labelNode(doc, shape, label))
  }
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

// A PART'S SIZE, PRINTED UNDER IT — and NOTHING HERE MEASURES ANYTHING. The words are whatever
// `meta.sizeLabel` returned (measure_controller.js, so the paper and the on-screen readout cannot
// drift apart) and the POSITION comes from `b`, the FULL-RESOLUTION bbox. Both halves are the same
// rule: `p` holds the THINNED drawing points, RDP at 0.01 mm, so anything read off them
// under-reports every curve — and a hole small enough to thin below MIN_CIRCLE_POINTS loses its
// diameter outright, printing a bounding box where a ⌀ belongs (CLAUDE.md §14h). A label is the
// one thing on this sheet a maker might read INSTEAD of measuring, so it is the last place a
// thinned number may reach.
//
// CENTRED, WITH ITS BASELINE 3.6 MM UNDER THE BBOX'S BOTTOM EDGE. `text` supplies the 3 mm type
// (a nominal browser size is absurd at 1:1 on paper). MEASURED at that size rather than reasoned,
// through getBBox — a font-metric box, so wider than the ink: the label occupies b[3] + 0.69 mm to
// b[3] + 4.39 mm. It therefore clears the outline it belongs to, and its whole reach is less than
// the 10 mm OVERLAP, which is what makes the cost below a LAST-ROW problem rather than a general
// one: a part whose bottom edge falls in a tile's overlap band appears on the tile after it too,
// with room to spare for the label. measure_print_test.rb drives exactly that — the same label is
// clipped away on the top tile and prints whole on the one below.
//
// THE LABEL IS INSIDE THE CLIP AND THAT COSTS SOMETHING — recorded because it is invisible on the
// sheet. Pagination is computed from the geometry's own union box and knows nothing about a label
// hanging under it, so on the LAST row a part whose bbox bottom clears the content box by less
// than 4.4 mm prints correctly at 1:1 with its label sliced through, and by less than 0.69 mm with
// no label at all. Measured on Letter, whose content box is 230.4 mm tall: a 226 mm part is
// labelled, a 228 mm part's label is cut across the middle, a 230 mm part has none. That is the
// price of the clip — the alternative is a label belonging to a part that runs onto the next tile
// printed across THIS tile's calibration ruler — and it fails toward a missing annotation, never
// toward a wrong number.
//
// NOTHING DE-CONFLICTS TWO LABELS, AND THE LEVER FOR THAT IS DELIBERATELY NOT HERE. Two contours
// sharing a bottom edge and an x range — one outline on a cut layer and the same outline on a
// score layer is the ordinary way to get there — print their labels on top of each other; that
// case is mild, since the same bbox yields the same string and it reads as bold text. The
// reachable one is a label printed across ANOTHER PART'S GEOMETRY: the ink reaches b[3] + 4.39 mm,
// so any part whose top edge sits within ~4.4 mm below another's bottom edge takes 3 mm of type
// across its outline — and kerf-tight nesting puts parts that close routinely. This
// function places what it is handed; WHICH parts are labelled is `meta.sizeLabel` returning null,
// which is the controller's decision and the only place that knows what the user selected.
function labelNode(doc, shape, label) {
  const node = text(doc, (shape.b[0] + shape.b[2]) / 2, shape.b[3] + 3.6, label, "middle")
  // NOT DECORATION: this is what tells a size label from the five furniture texts, for
  // measure_print_test.rb and for anything that ever has to find them again.
  node.setAttribute("data-role", "size")
  return node
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
// THE BUDGET IS A WORST CASE, NOT AN AVERAGE, because a filename is arbitrary user input. Every
// number below was MEASURED in the browser at 3 mm sans-serif and is RE-MEASURED AND ASSERTED by
// measure_print_test.rb, so a font change on the CI box goes red here rather than silently
// overprinting the warning.
//
//   WORST_GLYPH — the widest printable ASCII advance. It is "@" at 3.0432 mm, NOT the "W"
//     (2.8296) that is the obvious guess. Rounded UP to 3.05.
//   WORST_WIDE  — the widest NON-ASCII advance, measured across CJK, kana, Hangul, fullwidth,
//     Cyrillic, Greek, Arabic, Hebrew, Devanagari, symbols and emoji: every emoji tested comes
//     out at 3.7042 mm, ahead of fullwidth/CJK at 3.0638. Rounded UP to 3.71. "…" (U+2026) is
//     non-ASCII and so is charged at this rate; it actually advances 2.9979, so the ellipsis is
//     over-charged, which is the safe direction.
//   NARROW      — characters that genuinely advance far less than "@": digits (1.6673, the widest
//     of the set), space, the middle dot, and `- . _ : / ,`. Charged at DATE_GLYPH.
//
// CHARGING BY CLASS IS WHAT MAKES THIS CORRECT FOR BOTH SCRIPTS RATHER THAN FOR ONE BY LUCK.
// An earlier revision counted CHARACTERS at a single ASCII rate, and it was wrong twice over in
// the same place: `s.length`/`s.slice` count UTF-16 CODE UNITS, so an astral character was cut in
// half and painted as two replacement boxes; and non-ASCII advances EXCEED the ASCII worst case
// (emoji 3.7042 against 3.05 charged), so the width was under-reserved as well. THOSE TWO ERRORS
// PARTLY CANCELLED, which is why the sheet looked fine: an emoji costs TWO code units, so the
// length over-count ran ahead of the width under-charge and the name came out shorter than
// budgeted rather than longer. Fixing only the first — iterating code points and leaving one
// rate — removes the compensation and lands the ink on the warning. Both halves or neither, and
// both halves have their own mutation in measure_print_test.rb: code-unit indexing is caught by
// the lone-surrogate assertion, single-rate charging by the emoji sheet's geometry (measured,
// "the header ran into [81.28, 128.72]"). Shipped clearances on A4, the tightest paper:
// 7.85 mm for an all-"@" name, 9.70 for all-emoji, 16.75 for all-CJK.
//
// STILL SPLIT, DELIBERATELY UNADDRESSED: a ZWJ emoji sequence or a combining mark can be cut, so
// a family emoji may come apart into its members. That is cosmetic and it is over-charged (seven
// code points billed for one glyph), never an overflow. Grapheme segmentation (Intl.Segmenter) is
// the upgrade if it ever matters; it is not taken here because it would add a second code path,
// only one of which any test would walk.
//
// ACCEPTED COST: a worst-case budget is pessimistic for ordinary text — roughly 1.35 mm/character
// actually renders — so a name that would have fitted still gets an ellipsis. That is the trade
// this is meant to make: the failure it replaces is silent and lands on the warning.
//
// EXPORTED so the test can assert them against a fresh browser measurement. The geometric
// assertion alone cannot: the shipped layout clears the warning by 7.85 mm, and a `W`-tuned 2.83
// still clears it by 4.80 mm, so only a direct assertion on the constant sees that mistake.
export const WORST_GLYPH = 3.05
export const WORST_WIDE = 3.71
const DATE_GLYPH = 1.7
const NARROW = "0123456789 ·:/,._-"
const WARNING_HALF = 24
const HEADER_GAP = 2
const FONT = 3

const glyphWidth = (c) =>
  NARROW.includes(c) ? DATE_GLYPH : (c.codePointAt(0) < 128 ? WORST_GLYPH : WORST_WIDE)

const textWidth = (s) => Array.from(s).reduce((total, c) => total + glyphWidth(c), 0)

// THE DATE IS CHARGED THROUGH THE SAME FUNCTION, WHICH IS WHAT CLOSES A RESIDUAL RATHER THAN
// DOCUMENTING IT. An earlier revision billed the suffix at a flat digit rate on the grounds that
// `meta.date` is a fixed ISO string this app supplies — true today, and it would have become false
// the moment a caller passed a locale form: `Wednesday, August 19, 2026` is 26 characters carrying
// a "W", ~29 mm under-charged, and the warning is overprinted again with nothing to say so. Billing
// it per class costs an ISO date exactly what the flat rate did (all 13 of its characters are in
// NARROW) and reserves honestly for anything else. A long date now eats the NAME's budget instead
// of the warning — visibly wrong on the sheet, which is the failure direction that can be found.
function headerLabel(name, date, content) {
  const suffix = ` · ${date}`
  return truncateMiddle(String(name),
                        content.w / 2 - WARNING_HALF - HEADER_GAP - textWidth(suffix)) + suffix
}

// Take code points from the head and the tail alternately, head first, until the width budget is
// spent. ITERATING Array.from IS THE POINT: indexing `s` would split a surrogate pair.
function truncateMiddle(s, budget) {
  const cps = Array.from(s)
  if (textWidth(s) <= budget) return s
  let left = budget - glyphWidth("…")
  if (left < 0) return "…"
  let head = 0, tail = 0, takeHead = true
  while (head + tail < cps.length) {
    const c = takeHead ? cps[head] : cps[cps.length - 1 - tail]
    if (glyphWidth(c) > left) break
    left -= glyphWidth(c)
    if (takeHead) head++; else tail++
    takeHead = !takeHead
  }
  return cps.slice(0, head).join("") + "…" +
         (tail ? cps.slice(cps.length - tail).join("") : "")
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

// THE PRINT DOCUMENT.
//
// The class exists for the removal below and for the tests that count frames — NOT for styling.
// The frame is styled inline precisely so that it needs no stylesheet: nothing in
// app/assets/stylesheets or in any view names this class, checked rather than assumed.
const FRAME_CLASS = "measure-print-frame"

// A HIDDEN IFRAME, and not either alternative: window.open gets eaten by popup blockers, and a
// print-only container in this page would mean an `@page { margin: 0 }` that applies to every
// other print of the page it lives in.
//
// SPLIT FROM printSheets SO THE DOCUMENT IS ASSERTABLE WITHOUT A SPOOLER. A headless browser has
// no print dialog to observe, and calling printSheets in a test would call a real print(). So
// everything about the DOCUMENT is pinned here and `printSheets` below is deliberately the one
// export in this file with no test over it — verified, not assumed: renaming it away leaves the
// whole suite green. The controller's own counted print stub is what reaches it.
export function buildPrintFrame(shapes, paper, meta) {
  // FIRST, BEFORE THE FRAME EXISTS. buildSheets throws for an empty selection and for a job over
  // MAX_SHEETS — the two conditions a user reaches by ordinary use — and a frame created ahead of
  // it would leave a hidden iframe attached to the page on every refused click.
  //
  // IT IS NOT A GENERAL "NOTHING AFTER THIS POINT THROWS" CLAIM, and the distinction is worth
  // keeping straight. `renderSheet` runs BELOW the append and can throw too — `meta.sizeLabel` is
  // the caller's own function, and `el` throws by design on a mis-call — which leaves one frame
  // holding an empty document. That case is bounded and self-healing, because the sweep below
  // removes ALL prior frames rather than the first: a strand is cleared by the next print, and
  // cannot accumulate. What this ordering buys is that the ROUTINE refusals cost nothing.
  const { pages } = buildSheets(shapes, paper)

  // AND THE PRIOR FRAMES GO BEFORE THE NEW ONE IS BUILT, which is what keeps `clipId` honest.
  // `mp-clip-${col}-${row}` is unique within ONE grid; a re-print that appended into the existing
  // frame would put a second grid's identical `(col, row)` pairs into the same document, where a
  // `url(#id)` resolves to the FIRST match anywhere in it — so sheet 7 would clip against sheet
  // 1's window. A fresh document per print is what makes the key sufficient. If that ever changes,
  // the id needs a per-document counter, not a bigger key.
  //
  // querySelectorAll, NOT querySelector, and it is one character that removes a whole line of
  // reasoning. A singular removal is sufficient only while at most one frame can ever be stranded,
  // which is an argument about the throw sites above rather than a property of this line. The
  // sweep needs no such argument and matches what the tests clean up with.
  for (const stale of document.querySelectorAll(`.${FRAME_CLASS}`)) stale.remove()
  const frame = document.createElement("iframe")
  frame.className = FRAME_CLASS
  frame.setAttribute("aria-hidden", "true")
  // NOT DECORATION: a bare <iframe> is 300 x 150, in flow and bordered, so without this every
  // print drops a visible empty box into the Measure page. `border:0` is part of it — dropping
  // that alone measures 4 x 4 rather than 1 x 1, since getBoundingClientRect is the border box.
  frame.style.cssText = "position:fixed;right:0;bottom:0;width:1px;height:1px;opacity:0;border:0"
  document.body.appendChild(frame)

  const doc = frame.contentDocument
  // BUILT AS NODES, NEVER doc.write ON A MARKUP STRING. `meta.name` is a library filename, which
  // is user-controlled and can legitimately contain `<` on a NAS-scanned share — interpolating it
  // into markup written to a SAME-ORIGIN iframe is an injection with this page's cookies behind
  // it. The Measure view already keeps exactly this rule for the drawing itself, and every <text>
  // on a sheet reaches `textContent` through `el`'s text door for the same reason (see `el`).
  const style = doc.createElement("style")
  // `@page` IS THE ONLY THING THAT TELLS THE PRINTER WHAT SHAPE THE PAPER IS, and it must be built
  // from THIS paper: a hard-coded rule prints A4, A3 and Tabloid declared as Letter, and the
  // printer then fits a 210 mm page into a 215.9 mm declaration with every part 2.8% wrong.
  // `margin: 0` matters as much — without it the browser applies its own default page margin and
  // then has to shrink a paper-sized sheet to fit inside it, which is a silently mis-scaled 1:1
  // print. (No figure is quoted for that default because none was measured here.)
  //
  // `display: block` IS LOAD-BEARING, NOT TIDINESS: an <svg> is inline by default, and CSS
  // fragmentation breaks apply to block-level boxes, so an inline sheet ignores `break-after` and
  // the pages run together. And `svg:last-child` is what stops the job spooling a TRAILING BLANK
  // PAGE — one wasted sheet on every print. Both legacy and modern spellings are emitted; Chrome
  // re-serializes the pair as `break-after` alone, which is why measure_print_test.rb reads the
  // COMPUTED value rather than comparing this string to what the CSSOM gives back.
  //
  // `background:#fff` IS THE ONE DECLARATION HERE WITH NO ASSERTION OVER IT, deliberately and
  // labelled as such. Browsers do not print backgrounds unless the user turns them on, so it has
  // no demonstrable effect on any print this repo can drive, and no test asserts it. It stays as
  // belt and braces for a viewer who HAS turned them on under a forced-dark UA — unverified, and
  // recorded as unverified rather than dressed up as a measured requirement.
  style.textContent =
    `@page { size: ${paper.w}mm ${paper.h}mm; margin: 0 }` +
    "html,body { margin:0; padding:0; background:#fff }" +
    "svg { display:block; page-break-after:always; break-after:page }" +
    "svg:last-child { page-break-after:auto; break-after:auto }"
  doc.head.appendChild(style)
  for (const page of pages) doc.body.appendChild(renderSheet(doc, page, meta))

  return frame
}

// THE DEFAULT SPOOLER, EXPORTED FOR ONE REASON — the same reason `el` is. Everything else about
// printing is assertable through the `print` seam below, but the seam's own DEFAULT is only
// reachable when the argument is omitted, and then it is handed a real window with a real print
// dialog behind it. Exporting it lets the browser tier hand it a double instead, which is the
// difference between a two-line function that is believed to work and one that has been shown to.
//
// FOCUS BEFORE PRINT, AND THE ORDER IS PINNED RATHER THAN MEASURED. It is the ordering every
// hidden-iframe print idiom uses — the frame's window must be the one the dialog attaches to —
// but this repo cannot drive a print dialog, so no browser has been observed here where reversing
// it does the wrong thing. Read it as unverified belt and braces whose ORDER is nonetheless
// guarded, so it cannot be quietly swapped on the strength of a reading of this comment.
//
// AND IT IS NOT IN TENSION WITH THE FRAME'S `aria-hidden`, though it looks like it. That attribute
// hides the frame from assistive technology; this focuses a WINDOW so a print job attaches to the
// right document. The frame holds nothing focusable and nothing a reader would ever land on, so
// there is no focus-inside-hidden-content trap here — only a print target being named.
export const spool = (w) => { w.focus(); w.print() }

// Returns the sheet count. Throws whatever buildSheets throws — the caller surfaces it.
//
// THE `print` SEAM IS THE SAME TESTABILITY MOVE AS SPLITTING buildPrintFrame OUT, and it exists
// because the alternative was not available. The frame's window is a SEPARATE REALM — probed:
// `frame.contentWindow.print !== window.print` — and it does not exist until this function has
// created the frame and spooled it in the same synchronous turn, so no stub of the PAGE's
// `window.print` can ever reach it. (A test CAN get there by redefining
// `HTMLIFrameElement.prototype.contentWindow`, which is `configurable: true`; that is a
// page-global monkeypatch, not a stub of anything this module names.) With the seam, which window
// is spooled, that it happens exactly once, that it happens SYNCHRONOUSLY, and the returned count
// are all assertable without a spooler.
//
// THE readyState BRANCH: THE FIRST ARM IS THE ONE THAT RUNS, AND THE SECOND IS NOT A WORKING
// FALLBACK. Both halves are measured in this repo's own headless Chrome, and the second is worse
// than the "belt and braces" an earlier draft of this comment called it:
//
//   `frame.contentDocument.readyState` reads "complete" the instant the iframe is appended, so
//     `go()` runs synchronously and the listener is never installed. The document also SURVIVES
//     the frame's own load handling — re-read 400 ms later it is the same Document object carrying
//     the same sheets — so nothing here is racing a navigation that would replace what we built.
//   THE FRAME'S `load` EVENT NEVER ARRIVES. Deleting the first arm so only the listener remains
//     spools ZERO times, still zero 400 ms later: a dynamically created, src-less iframe does not
//     fire `load` on the element here. So on an engine that reported a non-complete readyState,
//     this would print NOTHING — the failure the second arm looks like it prevents is the failure
//     it would cause.
//
// It stays because deleting it would be a behaviour change argued from one browser, and because
// there is genuinely nothing to await: this document is built by synchronous node insertion, with
// no parser and no subresources. But do not read it as protection. If an engine is ever found that
// reports "loading" here, PROBE WHAT THAT ENGINE DOES — do not trust this line to catch it.
// measure_print_test.rb pins `afterLoad`, which is what would go red the day `load` starts firing.
export function printSheets(shapes, paper, meta, print = spool) {
  const frame = buildPrintFrame(shapes, paper, meta)
  const doc = frame.contentDocument
  // COUNTED ABOVE THE BRANCH, so the return value means ONE thing. Read inside each arm it is
  // taken after print() on the synchronous path and before it on the deferred one — a difference
  // no caller could see coming, on a number a caller reports to a user as "3 sheets".
  const sheets = doc.querySelectorAll("svg").length
  // The document has to settle before print(), or an empty frame goes to the spooler.
  const go = () => print(frame.contentWindow)
  if (doc.readyState === "complete") go()
  else frame.addEventListener("load", go, { once: true })
  return sheets
}
