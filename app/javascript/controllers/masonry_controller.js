import { Controller } from "@hotwired/stimulus"

// NO GAPS BETWEEN HALF-WIDTH PANELS (2026-09-09, content blocks; spec §7). A CSS grid aligns rows,
// so a short half-width panel leaves empty space under itself until its taller neighbour ends — the
// defect slice 1's Full/Half switch made visible. On the two-column layout this turns the grid's
// rows into one-pixel units with no row gap and gives every direct child a row span of its measured
// height plus the gap, so the next child starts right under the shorter one. Below the breakpoint,
// and with no JavaScript at all, the grid is the page exactly as it was: this adds no class and
// measures nothing.
//
// ONE MECHANISM ON ALL THREE RENDERS — the maker's page, edit mode, the visitor's page — because a
// gap under a short panel is the same gap wherever it is drawn.
//
// MEASURE THE CHILD, NOT ITS CONTENT, and only because `align-items: start` (pages/projects.css)
// stops a child stretching to fill its span. Without it the span would feed the next measurement
// and every panel would grow without end.
//
// THREE THINGS RE-MEASURE, and each answers a different way the page moves after first paint: a
// ResizeObserver on every child (a thumbnail or a 3D preview arriving late), a MutationObserver on
// the grid (a block added, deleted or dragged), and the media query itself (a window crossing the
// breakpoint, where the answer is to clear every span rather than to recompute one).
const GAP = 16
const MIN_WIDTH = 900

export default class extends Controller {
  connect() {
    this.media = window.matchMedia(`(min-width: ${MIN_WIDTH}px)`)
    this.relayout = () => this.layout()
    this.media.addEventListener("change", this.relayout)
    this.resizer = new ResizeObserver(this.relayout)
    this.mutations = new MutationObserver(() => { this.observe(); this.layout() })
    this.mutations.observe(this.element, { childList: true })
    this.observe()
    this.layout()
  }

  // EVERY SPAN IS REMOVED ON THE WAY OUT: a Turbo visit that leaves this page keeps the DOM around
  // in its cache, and a cached grid restored with stale inline spans would draw its panels at
  // whatever height they happened to have when it left.
  disconnect() {
    this.media.removeEventListener("change", this.relayout)
    this.resizer.disconnect()
    this.mutations.disconnect()
    this.clear()
  }

  observe() {
    this.resizer.disconnect()
    for (const child of this.element.children) this.resizer.observe(child)
  }

  layout() {
    if (!this.media.matches) { this.clear(); return }

    this.element.classList.add("masonry")
    for (const child of this.element.children) {
      const span = `span ${Math.max(1, Math.ceil(child.getBoundingClientRect().height + GAP))}`
      if (child.style.gridRowEnd !== span) child.style.gridRowEnd = span
    }
  }

  clear() {
    this.element.classList.remove("masonry")
    for (const child of this.element.children) child.style.gridRowEnd = ""
  }
}
