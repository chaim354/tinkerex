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
        shapes,
      })
    }
  }
  return { cols, rows, pages }
}
