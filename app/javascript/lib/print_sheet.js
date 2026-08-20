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

export function contentBox(paper) {
  return { w: paper.w - MARGIN * 2, h: paper.h - MARGIN * 2 - HEADER_H - CALIB_H }
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
      translateX: MARGIN - box[0],
      translateY: MARGIN + HEADER_H - box[1],
      shapes,
    }],
  }
}
