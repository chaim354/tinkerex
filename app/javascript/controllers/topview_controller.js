import { Controller } from "@hotwired/stimulus"
import { sections, parseArt, gridFrom, compartments } from "lib/tray_layout"

// A plan of the tray you are describing, drawn from the params already on the form.
//
// WHY THIS COSTS NOTHING: a tray's compartments are fully determined by sx/sy (or the layout art)
// plus the material thickness — all of which are in the DOM. So this needs no sidecar call and no
// round trip, redraws on the keystroke rather than on a debounce, and CANNOT drift from the cut
// sheet, because it is reading the very values the generator is about to be handed.
//
// It is the design, NOT the joinery: no finger tabs, no half-lap slots. That is deliberate for a
// plan view, and it is the one thing it cannot warn you about — a wall segment left ending in mid
// air is unsupported once there is no floor, and this view will happily draw it.
//
// Self-gating, like traylayout_controller: a generator with neither a layout nor sx+sy has no
// compartments to plan, so the panel removes itself rather than showing an empty frame.
export default class extends Controller {
  static targets = [ "form", "panel", "canvas", "summary" ]

  connect() {
    this.layout = this.formTarget.querySelector('[name="params[layout]"]')
    this.sx = this.formTarget.querySelector('[name="params[sx]"]')
    this.sy = this.formTarget.querySelector('[name="params[sy]"]')
    this.thickness = this.formTarget.querySelector('[name="params[thickness]"]')

    if (!this.layout && !(this.sx && this.sy)) { this.panelTarget.remove(); return }
    // A `layout` param is NOT proof of a tray layout. FrontPanel has one too and it is a different
    // DSL entirely — outline/rect/circle/text — which the tray grammar cannot read and never will.
    // So the gate is whether the first read actually yields a grid, not whether the field exists;
    // otherwise that generator ships a Top view panel that is blank forever.
    if (!this.draw()) { this.panelTarget.remove(); return }

    this.redraw = () => this.draw()
    this.formTarget.addEventListener("input", this.redraw)
    this.formTarget.addEventListener("change", this.redraw)
    this.panelTarget.hidden = false
  }

  disconnect() {
    if (!this.redraw) return // gated out at connect; nothing was ever bound
    this.formTarget.removeEventListener("input", this.redraw)
    this.formTarget.removeEventListener("change", this.redraw)
  }

  // `layout` WINS over sx/sy wherever it exists, because that is the order boxes.py resolves them
  // in: it reads the compartment sizes back out of the art, so once a layout is present the size
  // fields no longer describe the tray. Drawing from sx/sy here would show a tray nobody is getting.
  #model() {
    if (this.layout) return parseArt(this.layout.value)
    return gridFrom(sections(this.sx.value), sections(this.sy.value))
  }

  // Returns whether it drew — connect() uses that to decide the panel belongs on this page at all.
  draw() {
    const model = this.#model()
    // Mid-edit the art is routinely unparseable. Leave the last good drawing up rather than
    // flashing an error at someone in the middle of typing a number.
    if (!model) return false
    const t = Number(this.thickness?.value) > 0 ? Number(this.thickness.value) : 3
    const { id, groups } = compartments(model)

    this.canvasTarget.innerHTML = this.#svg(model, id, groups, t)
    const merged = groups.filter((g) => g.length > 1).length
    this.summaryTarget.textContent =
      `${groups.length} compartment${groups.length === 1 ? "" : "s"}` +
      (merged ? ` · ${merged} merged` : "")
    return true
  }

  #svg({ cols, rows, hwalls, vwalls }, id, groups, t) {
    const nc = cols.length, nr = rows.length
    const sum = (a) => a.reduce((x, y) => x + y, 0)
    // The grid is rigid: a cell sits at the same place whether or not its walls are drawn. A removed
    // wall therefore does not move anything — it hands its own thickness to the compartment, which
    // is why a merge is wider than the two cells added together.
    const hasL = vwalls.some((r) => r[0]), hasT = hwalls[0].some(Boolean)
    const x0 = hasL ? t : 0, y0 = hasT ? t : 0
    const colX = (c) => x0 + sum(cols.slice(0, c)) + c * t
    const rowY = (r) => y0 + sum(rows.slice(0, r)) + r * t
    const w = x0 + sum(cols) + (nc - 1) * t + (vwalls.some((r) => r[nc]) ? t : 0)
    const h = y0 + sum(rows) + (nr - 1) * t + (hwalls[nr].some(Boolean) ? t : 0)

    const out = []
    const rect = (x, y, rw, rh, cls) =>
      out.push(`<rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${Math.max(0, rw).toFixed(2)}" ` +
               `height="${Math.max(0, rh).toFixed(2)}"${cls ? ` class="${cls}"` : ""}/>`)

    // ONE <g> per compartment, whatever it is made of. A merged compartment is several rectangles —
    // its cells plus the gaps where the walls were — so grouping is what makes "how many
    // compartments does this tray have" answerable from the drawing rather than from the caption.
    groups.forEach((cells, k) => {
      const cls = cells.length > 1 ? "tv-cell tv-cell-merged" : "tv-cell"
      out.push(`<g class="${cls}" data-compartment="${k}">`)
      for (const [ r, c ] of cells) {
        // Cells PLUS the gaps between them, so a merged run reads as one continuous opening
        // rather than tiles with seams down the middle.
        rect(colX(c), rowY(r), cols[c], rows[r])
        if (c + 1 < nc && id[r][c + 1] === k) rect(colX(c) + cols[c], rowY(r), t, rows[r])
        if (r + 1 < nr && id[r + 1][c] === k) rect(colX(c), rowY(r) + rows[r], cols[c], t)
        if (c + 1 < nc && r + 1 < nr &&
            id[r][c + 1] === k && id[r + 1][c] === k && id[r + 1][c + 1] === k)
          rect(colX(c) + cols[c], rowY(r) + rows[r], t, t)
      }
      out.push("</g>")
    })

    for (let r = 0; r < nr; r++)
      for (let i = 0; i <= nc; i++)
        if (vwalls[r][i]) rect(colX(i) - t, rowY(r), t, rows[r], "tv-wall")
    for (let r = 0; r <= nr; r++)
      for (let c = 0; c < nc; c++)
        if (hwalls[r][c]) rect(colX(c), rowY(r) - t, cols[c], t, "tv-wall")
    // Fill the crossings, or every corner shows a notch the real tray does not have.
    for (let r = 0; r <= nr; r++)
      for (let i = 0; i <= nc; i++)
        if ((r > 0 && vwalls[r - 1][i]) || (r < nr && vwalls[r][i]) ||
            (i > 0 && hwalls[r][i - 1]) || (i < nc && hwalls[r][i]))
          rect(colX(i) - t, rowY(r) - t, t, t, "tv-wall")

    for (const cells of groups) {
      const rs = cells.map((v) => v[0]), cs = cells.map((v) => v[1])
      const r0 = Math.min(...rs), r1 = Math.max(...rs)
      const c0 = Math.min(...cs), c1 = Math.max(...cs)
      const cw = sum(cols.slice(c0, c1 + 1)) + (c1 - c0) * t
      const ch = sum(rows.slice(r0, r1 + 1)) + (r1 - r0) * t
      // An L-shaped compartment has no honest width x height, so say so rather than quote its
      // bounding box as if it were the opening.
      const label = cells.length === (r1 - r0 + 1) * (c1 - c0 + 1)
        ? `${round(cw)}×${round(ch)}` : "irregular"
      const size = Math.max(4, Math.min(cw / 6, ch / 3, 9))
      out.push(`<text x="${(colX(c0) + cw / 2).toFixed(2)}" y="${(rowY(r0) + ch / 2).toFixed(2)}" ` +
               `font-size="${size.toFixed(2)}" class="tv-label">${label}</text>`)
    }

    const pad = Math.max(6, t * 2)
    return `<svg viewBox="${-pad} ${-pad} ${w + pad * 2} ${h + pad * 2}" class="tv-svg" role="img" ` +
           `aria-label="Top view: ${groups.length} compartments, ` +
           `${round(w)} by ${round(h)} millimetres">${out.join("")}</svg>`
  }
}

const round = (v) => (Math.round(v * 10) / 10).toString().replace(/\.0$/, "")
