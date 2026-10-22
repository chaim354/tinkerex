import { Controller } from "@hotwired/stimulus"

// THE MODEL PAGE'S LIST AND PANE (2026-10-21). The pane is a Turbo Frame (`model_stage`) the list's
// links target, and the list sits OUTSIDE it so its scroll survives a click — which leaves the list
// to say which entry the pane now shows. The server marks it on a full render; this keeps it true
// across frame loads by reading the `file` param off the URL the frame just loaded, never off which
// link was clicked (a gallery link inside the pane loads it too). On a phone the list stacks above
// the pane (pages/models.css, below 900px), so a load there also scrolls the pane into view.
export default class extends Controller {
  static targets = ["entry", "stage"]

  loaded(event) {
    if (event.target !== this.stageTarget) return
    const shown = new URL(this.stageTarget.src, window.location.href).searchParams.get("file")
    this.entryTargets.forEach((link) => {
      if (new URL(link.href).searchParams.get("file") === shown) link.setAttribute("aria-current", "true")
      else link.removeAttribute("aria-current")
    })
    if (window.matchMedia("(max-width: 899px)").matches) this.reveal()
  }

  // CLEAR OF THE STICKY TOP BAR, which wraps to two rows on a phone: scrolled to the viewport's very
  // top, the pane's own head (its name, Download, "Open file page") sat behind it. The bar's bottom is
  // MEASURED at the moment of the scroll rather than written into CSS, which would have to track every
  // way the bar can wrap.
  reveal() {
    const bar = document.querySelector("header.topbar")
    const clearance = bar ? Math.ceil(bar.getBoundingClientRect().bottom) : 0
    this.stageTarget.style.scrollMarginTop = `${Math.max(0, clearance) + 8}px`
    this.stageTarget.scrollIntoView({ block: "start" })
  }
}
