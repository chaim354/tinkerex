import { Controller } from "@hotwired/stimulus"

// THE TOP BAR'S BACK (layouts/_topbar.html.erb; spec 2026-11-24-back-button-and-kept-tools-design.md).
// One control on every signed-in page, and it does what the browser's own Back does: one step back
// in this tab's history. That is the whole consistency the button is for. A link to "where this
// page was reached from" is not the same thing: two files that link to each other bounce between
// themselves, because following the link ADDS a history entry and the page it lands on names the
// one just left. Stepping back pops an entry instead, and Turbo restores the page as it was left —
// its scroll, its filter, its open folder, a kept tool (lib/kept_tools.js).
//
// ONLY WHEN THE ENTRY BEHIND IS OURS. `history.back()` from a tab that arrived from a search engine
// leaves the app, and from a fresh tab does nothing at all. The Navigation API answers exactly the
// question: its entries are the same-origin run this entry sits in, so an index above 0 is a page
// of this origin one step back. Where it is missing, Turbo's own count of the entries it pushed
// since this tab's last full load is the next best answer, and it errs toward the link.
//
// OTHERWISE THE LINK IS A LINK. Its href is the server's answer (ShellHelper#topbar_back_path), and
// a click this controller does not take is an ordinary Turbo visit to it. A modified click (a new
// tab, a new window) is always the browser's.
export default class extends Controller {
  // The server draws the control disabled when it has nowhere to point it (Recent, opened cold).
  // It cannot see this tab's history, so a page restored from Turbo's cache, or reloaded, is
  // corrected here.
  connect() {
    if (this.behindIsOurs()) this.element.removeAttribute("aria-disabled")
  }

  go(event) {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    if (this.behindIsOurs()) {
      event.preventDefault()
      window.history.back()
    } else if (this.element.getAttribute("aria-disabled") === "true") {
      event.preventDefault()
    }
  }

  behindIsOurs() {
    const entry = window.navigation?.currentEntry
    if (entry) return entry.index > 0
    return (window.history.state?.turbo?.restorationIndex || 0) > 0
  }
}
