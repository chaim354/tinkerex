import { Controller } from "@hotwired/stimulus"

// A CLICK OPENS THE FILE, A DOUBLE-CLICK OPENS IT IN A NEW TAB (2026-10-21,
// docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md). Mounted ONCE, on the
// signed-in layout's <main>; a file link opts in through FilesHelper#file_open_data, which appends
// `click->fileopen#click` to whatever action the link already carries.
//
// A BROWSER CANNOT TELL A CLICK FROM THE FIRST HALF OF A DOUBLE-CLICK UNTIL THE SECOND ONE ARRIVES OR
// DOES NOT, so a single click waits WINDOW_MS and then re-issues itself with `link.click()`. That
// synthetic click has `detail === 0`, which the first line below lets straight through, so Turbo
// follows it with every data-turbo-* attribute the link carries — the model page's frame links
// included — and this controller never reimplements navigation. Turbo has no isTrusted check
// (LinkClickObserver#clickEventIsSignificant reads `which`, the modifiers and defaultPrevented), and
// Turbo 8 prefetches a link's page on hover, so the wait is usually spent with the response in hand.
//
// EVERYTHING ELSE IS THE LINK'S: a modifier or middle click, Enter (a click whose `detail` is 0), and
// with JavaScript off every tile is a plain link. A slow double-click — the second click after the
// timer already fired — opens the page here, once; it never opens it here AND in a new tab.
const WINDOW_MS = 250

export default class extends Controller {
  disconnect() {
    this.cancel()
  }

  click(event) {
    if (event.detail === 0 || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    const link = event.currentTarget
    event.preventDefault()
    if (event.detail === 1) {
      this.cancel()
      this.pending = link
      this.timer = setTimeout(() => {
        this.timer = null
        this.pending = null
        link.click()
      }, WINDOW_MS)
    } else if (event.detail === 2 && this.timer && this.pending === link) {
      this.cancel()
      window.open(link.dataset.fileopenNewTabUrl || link.href, "_blank", "noopener")
    }
    // Anything else — a triple click, or a second click after the timer fired — is swallowed.
  }

  cancel() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.pending = null
  }
}
