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
  const { cols, rows, hwalls, vwalls, nc, nr, colX, rowY, w, h, id } = model

  // Slot boundary coordinates: the edges of every band and cell, in order.
  const xs = [ 0 ]
  for (let c = 0; c < nc; c++) { xs.push(colX(c)); xs.push(colX(c) + cols[c]) }
  xs.push(w)
  const ys = [ 0 ]
  for (let r = 0; r < nr; r++) { ys.push(rowY(r)); ys.push(rowY(r) + rows[r]) }
  ys.push(h)

  const NX = 2 * nc + 1, NY = 2 * nr + 1

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

  const label = []
  for (let j = 0; j < NY; j++) {
    const row = []
    for (let i = 0; i < NX; i++) row.push(slotLabel(i, j))
    label.push(row)
  }
  const at = (i, j) => (i < 0 || j < 0 || i >= NX || j >= NY ? WALL : label[j][i])

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
    // An L-shaped compartment has no honest width x height, so say so rather than quote its
    // bounding box as if it were the opening.
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
