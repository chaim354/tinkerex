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

function el(doc, tag, attrs, text) {
  const node = doc.createElementNS(SVG_NS, tag)
  for (const [ key, value ] of Object.entries(attrs)) {
    // A null or undefined value writes the literal string "undefined". Sheet furniture is full of
    // conditional attributes, so skip here rather than making every call site remember.
    if (value != null) node.setAttribute(key, value)
  }
  // THE TEXT DOOR EXISTS SO `textContent` IS THE ONLY SPELLING AVAILABLE. The header carries a
  // library filename — user-controlled, and legitimately able to contain `<` on a NAS-scanned
  // share — so building it as markup is an injection into a same-origin iframe. Four call sites
  // each remembering that rule is four chances to forget; one door is none.
  if (text != null) node.textContent = text
  return node
}
