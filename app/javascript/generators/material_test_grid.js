import makerjs from "makerjs"

// Material Test Grid — power × speed sweep for dialing in laser settings. Pure: values -> SVG string.
// Geometry via Maker.js (Rectangle per cell + captions for labels), exported with toSVG. v1 is a
// simple labeled grid (no color-coded laser layers — a future param); the maker assigns per-row/
// column settings in their laser software.
const clampInt = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.round(Number(v) || 0)))
const num = (v, d) => (Number.isFinite(Number(v)) ? Number(v) : d)
const lerp = (a, b, t, n) => (n <= 1 ? a : a + (b - a) * (t / (n - 1)))
const round = (x) => Math.round(x * 100) / 100

export default {
  key: "material-test-grid",
  title: "Material Test Grid",
  description: "Power × speed sweep to dial in laser settings.",
  params: [
    { name: "cols", label: "Speed steps (X)", type: "int", default: 5, min: 1, max: 20 },
    { name: "rows", label: "Power steps (Y)", type: "int", default: 5, min: 1, max: 20 },
    { name: "speedMin", label: "Speed min", type: "float", default: 100 },
    { name: "speedMax", label: "Speed max", type: "float", default: 500 },
    { name: "powerMin", label: "Power min (%)", type: "float", default: 10 },
    { name: "powerMax", label: "Power max (%)", type: "float", default: 100 },
    { name: "cell", label: "Cell size (mm)", type: "float", default: 10, min: 1, max: 100 },
    { name: "gap", label: "Gap (mm)", type: "float", default: 4, min: 0, max: 50 },
    { name: "material", label: "Material label", type: "text", default: "" },
    { name: "labels", label: "Show cell labels", type: "bool", default: true },
  ],

  generate(v) {
    const cols = clampInt(v.cols, 1, 20)
    const rows = clampInt(v.rows, 1, 20)
    const cell = num(v.cell, 10)
    const gap = num(v.gap, 4)
    const pitch = cell + gap
    const labels = v.labels === true || v.labels === "true" || v.labels === "on"
    const width = cols * pitch - gap
    const height = rows * pitch - gap

    // Each caption lives on its OWN child model: a model holds a single `caption`, so two calls on
    // one model would keep only the last. Maker.js Y is up, so row 0 sits at the TOP (highest y).
    const model = { models: {} }
    const cap = (name, text, p1, p2) => {
      const m = {}
      makerjs.model.addCaption(m, text, p1, p2)
      model.models[name] = m
    }

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const sq = new makerjs.models.Rectangle(cell, cell)
        sq.origin = [c * pitch, (rows - 1 - r) * pitch]
        model.models[`c_${r}_${c}`] = sq
      }
    }

    // Standard test-grid layout: speed labelled ONCE per column across the top, power labelled ONCE
    // per row down the left side — legible, never overlapping (vs. a value crammed into every cell).
    if (labels) {
      for (let c = 0; c < cols; c++) {
        const speed = round(lerp(num(v.speedMin, 100), num(v.speedMax, 500), c, cols))
        const y = height + gap
        cap(`sp_${c}`, String(speed), [c * pitch, y], [c * pitch + cell, y])
      }
      for (let r = 0; r < rows; r++) {
        const power = round(lerp(num(v.powerMin, 10), num(v.powerMax, 100), r, rows))
        const cy = (rows - 1 - r) * pitch + cell / 2
        cap(`pw_${r}`, `${power}%`, [-cell, cy], [-0.1, cy])
      }
    }

    // Axis titles + material title. "Power ↓" uses a vertical anchor (Maker.js rotates the text).
    cap("_speedTitle", "Speed →", [0, height + 2.2 * gap + cell * 0.3], [width, height + 2.2 * gap + cell * 0.3])
    cap("_powerTitle", "Power ↓", [-cell - gap, 0], [-cell - gap, height])
    const title = (v.material && String(v.material).trim()) || "Material Test Grid"
    cap("_title", title, [0, -1.6 * gap], [width, -1.6 * gap])

    const svg = makerjs.exporter.toSVG(model, {
      units: makerjs.unitType.Millimeter,
      useSvgPathOnly: false,
      fontSize: `${Math.max(1.5, cell / 6)}px`,
    })
    // Captions inherit the cut group's fill:none/stroke, which renders label text as a blobby
    // outline. Make label text crisp filled-black (the cut <line>s are untouched).
    return svg.replace(/<text /g, '<text fill="#000" stroke="none" ')
  },
}
