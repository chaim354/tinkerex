import { Controller } from "@hotwired/stimulus"

// A/B SLIDER OVER TWO RENDERS OF THE SAME FILE — the compare surface for a POINTER version, where
// a text diff would be worthless (Maker::Git::Tracking, and Projects::HistoryController::Comparison
// for why the two halves exist at all).
//
// THE AFTER IMAGE IS CLIPPED, NOT FADED OR TOGGLED. Both renders sit in the same stacking box at
// the same size; the slider moves a vertical seam and the AFTER image is clipped to the right of
// it. That is what makes a small geometry change visible: the two shapes stay in register and the
// eye compares edges across one line rather than two pictures.
//
// THE SERVER ALREADY SET THE OPENING CLIP, INLINE, AND THAT IS DELIBERATE. This controller only
// has to keep the seam in step with the input from then on. A page whose JavaScript never arrives
// therefore shows a real 50/50 comparison rather than the after image covering the before one —
// which is the failure a viewer would read as "the compare is broken" with nothing to say so.
export default class extends Controller {
  static targets = ["before", "after", "slider"]

  connect() {
    // TOLERATES A HALF-BUILT PANEL ON PURPOSE. The section declares this controller whenever the
    // comparison is visual, including while one side's render is still `pending` or was never kept
    // — those states draw a placeholder and no slider, so there is nothing here to drive.
    if (!this.hasBeforeTarget || !this.hasAfterTarget || !this.hasSliderTarget) return
    this.update()
  }

  update() {
    if (!this.hasBeforeTarget || !this.hasAfterTarget || !this.hasSliderTarget) return

    const pct = this.position
    this.afterTarget.style.clipPath = `inset(0 0 0 ${pct}%)`
    // The seam itself is drawn in CSS off this custom property, so the handle and the clip can
    // never disagree about where the boundary is.
    this.element.style.setProperty("--compare-position", `${pct}%`)
    // A fully clipped image is not on screen, so it should not be in the accessibility tree either
    // — at the extremes this panel is showing exactly one of the two renders.
    this.beforeTarget.setAttribute("aria-hidden", pct >= 100 ? "true" : "false")
    this.afterTarget.setAttribute("aria-hidden", pct <= 0 ? "true" : "false")
    this.sliderTarget.setAttribute("aria-valuetext", `${pct}% of the newer version`)
  }

  // CLAMPED AND GUARDED BECAUSE `input.value` IS A STRING FROM THE DOM. An empty range input reads
  // "" and `Number("")` is 0, not NaN — so the seam would silently jump to one edge rather than
  // failing in a way anyone would notice.
  get position() {
    const raw = Number(this.sliderTarget.value)
    if (!Number.isFinite(raw)) return 50
    return Math.min(100, Math.max(0, raw))
  }
}
