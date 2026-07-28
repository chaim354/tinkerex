import { Controller } from "@hotwired/stimulus"

// Keeps a TrayLayout's `layout` ASCII art in sync with its sx/sy compartment sizes — the same job
// boxes.py's own web UI does in static/self.js (TrayLayoutInit).
//
// This is not decoration: `layout` OVERRIDES sx/sy. boxes.py reads the compartment sizes back out of
// the art, so the moment a layout is present, editing sx/sy changes nothing about the tray you get.
// Without this the two size fields are dead controls that silently disagree with the output.
//
// The starting art arrives already seeded by the sidecar (built by boxes.py's own TrayLayoutFile, so
// it is parseable by construction) — the form works with JS off. This only keeps it honest.
//
// Self-gating: it looks for layout + sx + sy and does nothing unless all three are present, so it is
// harmless on every other generator's form (GridfinityTrayLayout, for one, builds its layout from
// nx/ny/countx/county rather than sx/sy).
export default class extends Controller {
  connect() {
    this.layout = this.element.querySelector('[name="params[layout]"]')
    this.sx = this.element.querySelector('[name="params[sx]"]')
    this.sy = this.element.querySelector('[name="params[sy]"]')
    if (!this.layout || !this.sx || !this.sy) return

    // A layout loaded from a saved box is the user's own work — never regenerate over it unasked.
    this.handEdited = this.layout.dataset.prefilled === "true"
    this.markEdited = () => { this.handEdited = true }
    this.regenerate = () => this.update()
    this.layout.addEventListener("input", this.markEdited)
    // "change" (value committed on blur/Enter), NOT "input" as boxes.py's own page uses. Per
    // keystroke, "40*4" regenerates through its valid prefixes — you watch the tray become one
    // 4mm compartment, then one 40mm one — and on a hand-edited layout it asks for confirmation
    // once per CHARACTER. Caught the moment this ran in a real browser.
    this.sx.addEventListener("change", this.regenerate)
    this.sy.addEventListener("change", this.regenerate)
  }

  disconnect() {
    if (!this.layout) return
    this.layout.removeEventListener("input", this.markEdited)
    this.sx.removeEventListener("change", this.regenerate)
    this.sy.removeEventListener("change", this.regenerate)
  }

  update() {
    const art = this.build()
    if (art === null || art === this.layout.value) return
    if (this.handEdited &&
        !confirm("You've edited this layout by hand. Regenerate it from the new sizes?")) return

    this.layout.value = art // assigning .value fires no "input" event, so this can't self-trigger
    this.handEdited = false
    this.layout.rows = Math.min(24, art.split("\n").length + 1)
  }

  // Mirrors TrayLayoutFile.__str__ byte-for-byte (walls and floors all present), so what the browser
  // writes is what the sidecar would have seeded. Every wall is on; the user removes them by hand,
  // replacing "-"/"|" with a space, or a floor with an "x".
  build() {
    const sx = this.sections(this.sx.value)
    const sy = this.sections(this.sy.value)
    if (!sx || !sy) return null

    let art = sx.map((v, i) => `${" |".repeat(i)} ,> ${v.toFixed(1)}mm\n`).join("")
    for (const v of sy) {
      art += `${"+-".repeat(sx.length)}+\n`
      art += `${"| ".repeat(sx.length)}| ${v.toFixed(1)}mm\n`
    }
    return `${art + "+-".repeat(sx.length)}+\n`
  }

  // Port of boxes.py's argparseSections: "50*3" -> three 50s, "100/4" -> four 25s, "30:40" -> 30,40.
  // Deliberately stricter than the Python original, which accepts anything float() does — returning
  // null on anything unfamiliar (or half-typed) just means the art is left alone, and the server
  // still parses whatever the user actually typed.
  sections(s) {
    const out = []
    for (const part of s.split(/[\s:]/)) {
      const repeat = part.match(/^(\d+(?:\.\d+)?)([*/])(\d+)$/)
      if (repeat) {
        const n = Number(repeat[3])
        if (!n || n > 100) return null // 100 compartments is already far past a usable tray
        out.push(...Array(n).fill(repeat[2] === "/" ? Number(repeat[1]) / n : Number(repeat[1])))
      } else if (/^\d+(?:\.\d+)?$/.test(part)) {
        out.push(Number(part))
      } else {
        return null
      }
    }
    return out.length && out.every((v) => v > 0) ? out : null
  }
}
