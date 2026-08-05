// Pagination and sheet furniture. Knows nothing about SVG or PDF — it takes primitives in
// millimetres and returns pages of primitives in millimetres, page-local.
//
// A plan that FITS produces one page through this same path; there is no separate small-tray
// branch to keep in step with the tiled one.

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
      const originX = c * stepX, originY = r * stepY
      pages.push({
        paper, originX, originY, col: c, row: r, cols, rows,
        prims: [
          ...translate(clip(prims, originX, originY, pw, ph), MARGIN - originX, MARGIN - originY),
          ...furniture(pw, ph, c, r, cols, rows),
        ],
      })
    }
  }
  return { cols, rows, pages }
}

// Keep anything that touches this tile. A bounding-box test, deliberately: a line crossing the
// tile edge is kept whole and simply drawn past it, which the printer's own margin then trims.
// Exact clipping would buy nothing, because the overlap band already guarantees that a mark near
// an edge appears on both tiles.
function clip(prims, ox, oy, pw, ph) {
  return prims.filter((p) => {
    const pad = p.kind === "line" ? 0 : (p.size ?? 0) * 4
    const x1 = (p.kind === "line" ? Math.min(p.x1, p.x2) : p.x) - pad
    const x2 = (p.kind === "line" ? Math.max(p.x1, p.x2) : p.x) + pad
    const y1 = (p.kind === "line" ? Math.min(p.y1, p.y2) : p.y) - (pad ? p.size : 0)
    const y2 = (p.kind === "line" ? Math.max(p.y1, p.y2) : p.y) + (pad ? p.size : 0)
    return x2 >= ox && x1 <= ox + pw && y2 >= oy && y1 <= oy + ph
  })
}

function translate(prims, dx, dy) {
  return prims.map((p) => (p.kind === "line"
    ? { ...p, x1: p.x1 + dx, y1: p.y1 + dy, x2: p.x2 + dx, y2: p.y2 + dy }
    : { ...p, x: p.x + dx, y: p.y + dy }))
}

function furniture(pw, ph, c, r, cols, rows) {
  const out = []
  const line = (x1, y1, x2, y2, role) => out.push({ kind: "line", x1, y1, x2, y2, role })

  // Trim crosshairs at the printable corners.
  for (const [ x, y ] of [ [ MARGIN, MARGIN ], [ MARGIN + pw, MARGIN ],
                           [ MARGIN, MARGIN + ph ], [ MARGIN + pw, MARGIN + ph ] ]) {
    line(x - 4, y, x + 4, y, "mark")
    line(x, y - 4, x, y + 4, "mark")
  }

  // The calibration bar: 100 mm with a tick every 10 mm, bottom-left inside the printable area.
  // This is the ONLY defence against the browser print dialog's "Fit to printable area", which
  // rescales silently and which no page can detect or prevent. On EVERY page, because pages get
  // separated and a partial print is exactly when a scale error most needs catching.
  const by = MARGIN + ph - 6
  line(MARGIN, by, MARGIN + 100, by, "calib-bar")
  for (let i = 0; i <= 100; i += 10) line(MARGIN + i, by, MARGIN + i, by - 3, "calib-tick")
  out.push({ kind: "text", x: MARGIN + 50, y: by + 4.5, size: 3, anchor: "middle",
             text: "100 mm — check with a ruler", role: "calib-label" })

  // Registration for taping tiles together. NOT the title block, which was declined: on a single
  // sheet there is nothing to register against, so it is omitted entirely.
  if (cols * rows > 1) {
    out.push({ kind: "text", x: MARGIN + pw, y: by + 4.5, size: 3, anchor: "end",
               text: `Sheet ${c + 1},${r + 1} of ${cols}×${rows}`, role: "page-label" })
  }
  return out
}

const round = (v) => (Math.round(v * 10) / 10).toString().replace(/\.0$/, "")
