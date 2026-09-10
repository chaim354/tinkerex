import { Controller } from "@hotwired/stimulus"

// ONE PANE AT A TIME (2026-09-09, tabs; spec §6). The server renders every pane with its heading and
// a bar of ordinary anchors, so without this controller the page reads as sections and nothing is
// hidden (decision 8). This adds `tabs-ready` (the sheet hides the headings under it), shows one
// pane and marks one tab selected, and answers three ways in: a hash naming a pane (`#tab-build`),
// a hash naming an element INSIDE a pane (`#project-tasks`, a panel's own anchor — the head's links
// keep working), and a click, which rewrites the hash with replaceState so a tab is shareable
// without a history entry per click. Left/Right/Home/End follow the ARIA tabs pattern with a roving
// tabindex.
//
// A HIDDEN PANE MEASURES ZERO, and masonry_controller's ResizeObserver reports the change when a
// pane is shown, so the pane re-packs on its own; nothing here talks to it.
//
// `tabs-ready` IS REMOVED AND EVERY PANE UNHIDDEN ON DISCONNECT, for the reason masonry clears its
// spans: Turbo keeps a cached copy of the page it left, and a restored cache showing one pane with
// no controller attached to reveal the others would be a page missing most of itself.
export default class extends Controller {
  static targets = ["tab", "pane"]

  connect() {
    this.element.classList.add("tabs-ready")
    this.onHash = () => this.showFromHash(false)
    window.addEventListener("hashchange", this.onHash)
    this.showFromHash(true)
  }

  disconnect() {
    window.removeEventListener("hashchange", this.onHash)
    this.element.classList.remove("tabs-ready")
    this.paneTargets.forEach((p) => { p.hidden = false })
  }

  select(event) {
    event.preventDefault()
    this.show(this.tabTargets.indexOf(event.currentTarget), true)
  }

  key(event) {
    const i = this.tabTargets.indexOf(event.currentTarget)
    const last = this.tabTargets.length - 1
    const next = { ArrowRight: i === last ? 0 : i + 1, ArrowLeft: i === 0 ? last : i - 1, Home: 0, End: last }[event.key]
    if (next === undefined) return
    event.preventDefault()
    this.show(next, true)
    this.tabTargets[next].focus()
  }

  showFromHash(initial) {
    const hash = decodeURIComponent(window.location.hash.slice(1))
    let i = hash ? this.paneTargets.findIndex((p) => p.id === hash) : -1
    let target = null
    if (i < 0 && hash) {
      // A PANEL'S OWN ANCHOR, not the pane's: `#project-tasks` and a block's `#block:<key>` are ids
      // the page has always carried and the head links to, and they must go on working when the
      // panel they name has moved inside a tab. The element is scrolled to AFTER the pane is shown,
      // because a hidden pane has nowhere to scroll to.
      const el = document.getElementById(hash)
      const pane = el?.closest(".tab-pane")
      if (pane) { i = this.paneTargets.indexOf(pane); target = el }
    }
    // A HASH THAT NAMES NOTHING HERE (a stale slug after a rename, a hidden panel, #publish): the
    // first tab on load, and no change on a later hashchange.
    if (i < 0) { if (!initial) return; i = 0 }
    this.show(i, false)
    if (target) requestAnimationFrame(() => target.scrollIntoView())
  }

  show(i, write) {
    this.tabTargets.forEach((t, j) => {
      const on = i === j
      t.setAttribute("aria-selected", String(on))
      t.tabIndex = on ? 0 : -1
      t.classList.toggle("is-active", on)
    })
    this.paneTargets.forEach((p, j) => { p.hidden = i !== j })
    if (write) history.replaceState(null, "", `#${this.paneTargets[i].id}`)
  }
}
