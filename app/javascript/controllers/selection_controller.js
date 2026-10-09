import { Controller } from "@hotwired/stimulus"

// CLICK TO SELECT, DOUBLE-CLICK OR ENTER TO OPEN (structural redesign spec §5.1, slice 3).
// A plain click on a FILE tile selects it: `.is-selected` on the tile, `?selected=<id>` in the URL
// (a REPLACE, never a push, so Back leaves the Library instead of stepping through selections; and
// through Turbo's history so the next page's referer carries the selection — see #replaceUrl), and
// the inspector frame loads that file's panel.
// EVERYTHING ELSE KEEPS THE LINK'S OWN BEHAVIOUR, which is why the tiles stay `<a href=file_path>`:
// a modifier or middle click opens a tab, Enter (a click whose `detail` is 0) opens the page, a
// double-click opens it, the file menu's Open reads the href, and with JavaScript off every tile is
// just a link. Folders are not items and navigate as links.
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

  click(event) {
    if (event.detail === 0 || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    this.select(event.currentTarget)
  }

  open(event) {
    event.preventDefault()
    const href = event.currentTarget.getAttribute("href")
    if (window.Turbo) window.Turbo.visit(href)
    else window.location.assign(href)
  }

  select(item) {
    this.itemTargets.forEach((el) => el.classList.toggle("is-selected", el === item))
    const id = item.dataset.selectionId
    this.replaceUrl((url) => url.searchParams.set("selected", id))
    const src = this.inspectorUrlValue.replace("__ID__", encodeURIComponent(id))
    // The second click of a double-click lands here too; re-assigning the same src would fetch the
    // panel again for a page that is about to be replaced.
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

  // Arrows move the selection in document order and Escape closes — only from a TILE (arrows) or
  // anywhere in the library outside a form control (Escape). The listener is on this element, which
  // holds the inspector too, and the inspector has a project <select> whose own arrow keys must
  // keep choosing a project; elsewhere on the page arrows still scroll.
  keydown(event) {
    if (event.key === "Escape") {
      if (!this.element.classList.contains("has-inspector") || this.isFormControl(event.target)) return
      this.close()
      return
    }
    const step = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }[event.key]
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
