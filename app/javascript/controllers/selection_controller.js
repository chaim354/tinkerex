import { Controller } from "@hotwired/stimulus"

// DETAILS OPENS THE PANEL; A CLICK OPENS THE FILE (2026-10-21,
// docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md; before that a click
// selected, structural redesign spec §5.1, slice 3). The panel opens from the file menu's Details
// (filemenu_controller.js dispatches `filemenu:details` on the tile, answered by #details below) or
// from a page the server rendered with `?selected=`. Once open, the selection is what it always was:
// `.is-selected` on the tile (the ink ring), `?selected=<id>` in the URL (a REPLACE, never a push, so
// Back leaves the Library instead of stepping through selections; and through Turbo's history so the
// next page's referer carries the selection — see #replaceUrl), the inspector frame loading that
// file's panel, the arrows moving it while the panel is open, and Escape closing it.
// A CLICK AND A DOUBLE-CLICK ARE fileopen_controller.js's, NOT THIS CONTROLLER'S: a click opens the
// file and a double-click opens it in a new tab. The tiles stay `<a href=file_path>` for the same
// reasons as before: that click, the file menu's Open, a modifier or middle click, Enter (a click
// whose `detail` is 0) and no-JavaScript all rely on the href. Folders are not items and navigate as
// links.
export default class extends Controller {
  static targets = ["item", "frame"]
  static values = { inspectorUrl: String }

  connect() {
    this.onKeydown = (event) => this.keydown(event)
    this.element.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.onKeydown)
  }

  // RIGHT-CLICK › DETAILS (filemenu_controller.js) asks the tile through a cancelable
  // `filemenu:details` event. On the Library the answer is this panel, opened in place, and the cancel
  // is what tells the menu not to navigate to its details url.
  details(event) {
    event.preventDefault()
    this.select(event.currentTarget)
  }

  select(item) {
    this.itemTargets.forEach((el) => el.classList.toggle("is-selected", el === item))
    const id = item.dataset.selectionId
    this.replaceUrl((url) => url.searchParams.set("selected", id))
    const src = this.inspectorUrlValue.replace("__ID__", encodeURIComponent(id))
    // Details on the tile already selected lands here too; re-assigning the same src would fetch the
    // panel it is already showing.
    if (this.frameTarget.getAttribute("src") !== src) this.frameTarget.src = src
    this.element.classList.add("has-inspector")
    item.focus({ preventScroll: true })
  }

  close(event) {
    // The close control is a link to the listing without ?selected= (the no-JavaScript door).
    event?.preventDefault()
    const selected = this.itemTargets.find((el) => el.classList.contains("is-selected"))
    this.itemTargets.forEach((el) => el.classList.remove("is-selected"))
    this.replaceUrl((url) => url.searchParams.delete("selected"))
    this.frameTarget.removeAttribute("src")
    this.frameTarget.replaceChildren()
    this.element.classList.remove("has-inspector")
    // The close button is hidden with the panel, which would drop focus to <body>; hand it back to
    // the tile the panel described.
    if (selected) selected.focus({ preventScroll: true })
  }

  // THROUGH TURBO'S OWN HISTORY, NOT A BARE history.replaceState. A Turbo Drive visit sends as its
  // referrer the location Turbo last RECORDED (Navigator#startVisit's `referrer: this.location`),
  // so a bare replaceState leaves that stale and the next page's referer has no `selected=` —
  // measured: the file page's Back (back_target_path, referer-based) returned to the Library with
  // the selection gone (files_selection_test.rb). `replace` with the CURRENT restoration id keeps
  // this history entry's snapshot and scroll data; without Turbo, the plain call is the same thing.
  replaceUrl(change) {
    const url = new URL(window.location.href)
    change(url)
    const turboHistory = window.Turbo?.session?.history
    if (turboHistory?.replace) turboHistory.replace(url, turboHistory.restorationIdentifier)
    else history.replaceState(history.state, "", url)
    this.syncPageLinks(url.searchParams.get("selected"))
  }

  // THE PAGE'S OWN LINKS CARRY THE SELECTION THE SERVER SAW (FilesController#files_query_base: the
  // view toggle, the sort headers and form, the pager), so a client-side change must reach them
  // too — or a Library opened on file A (where attaching from the inspector lands), with B then
  // clicked, switches view straight back to A. Only links to THIS page that already carry the
  // param are rewritten: a page rendered with no selection has none to keep in step, and a re-sort
  // from it arrives with no selection, which is never the WRONG file.
  syncPageLinks(id) {
    document.querySelectorAll("a[href*='selected=']").forEach((link) => {
      const url = new URL(link.href)
      if (url.origin !== window.location.origin || url.pathname !== window.location.pathname) return
      if (id) url.searchParams.set("selected", id)
      else url.searchParams.delete("selected")
      link.setAttribute("href", url.pathname + url.search + url.hash)
    })
    document.querySelectorAll("form[method='get'] input[type='hidden'][name='selected']").forEach((input) => {
      if (id) input.value = id
      else input.remove()
    })
  }

  // Arrows move the selection in document order and Escape closes — only while the panel is OPEN,
  // and only from a TILE (arrows) or anywhere in the library outside a form control (Escape). With
  // the panel closed the arrows are the browser's: a click no longer selects (2026-10-21), so a
  // focused tile with no panel is just a link, and an arrow that opened the panel would be a second,
  // hidden door to Details. The listener is on this element, which holds the inspector too, and the
  // inspector has a project <select> whose own arrow keys must keep choosing a project; elsewhere on
  // the page arrows still scroll.
  keydown(event) {
    if (event.key === "Escape") {
      if (!this.element.classList.contains("has-inspector") || this.isFormControl(event.target)) return
      this.close()
      return
    }
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key]
    if (!this.element.classList.contains("has-inspector")) return
    if (!step || event.metaKey || event.ctrlKey || event.altKey) return
    const items = this.itemTargets
    if (!items.includes(event.target)) return
    const current = items.findIndex((el) => el.classList.contains("is-selected"))
    const next = items[Math.min(items.length - 1, Math.max(0, current === -1 ? items.indexOf(event.target) : current + step))]
    event.preventDefault()
    this.select(next)
    next.scrollIntoView({ block: "nearest" })
  }

  isFormControl(el) {
    return el.matches("input, select, textarea, [contenteditable]") || el.isContentEditable
  }
}
