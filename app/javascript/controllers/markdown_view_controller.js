import { Controller } from "@hotwired/stimulus"

// A MARKDOWN FILE'S RENDERED / SOURCE TOGGLE (2026-11-02, the UX audit's D8; files/_markdown_view).
// The server renders both panes and hides Source; this swaps which one is hidden and keeps the two
// buttons' `aria-pressed` and `active` in step — the attribute is what a screen reader hears, the
// class is the look (the hub's Tiles/List toggles carry the same pair).
//
// CONNECT READS THE PRESSED BUTTON RATHER THAN ASSUMING "rendered": Turbo snapshots the page as it
// was left, so a Back onto a page left on Source restores Source, and the panes must agree with it.
//
// A SAVE IN SOURCE MAKES RENDERED STALE. The editor writes the file without reloading the page and
// announces it (`editor:saved`); pressing Rendered after that loads the page again, so the rendered
// view is of the bytes now on disk. The visit is a Turbo visit, so the editor's own leave-guard
// still asks about anything typed since the save.
export default class extends Controller {
  static targets = ["toggle", "pane"]

  connect() {
    this.stale = false
    const pressed = this.toggleTargets.find((t) => t.getAttribute("aria-pressed") === "true")
    this.apply(pressed?.dataset.markdownViewPaneParam ?? "rendered")
  }

  show(event) {
    const pane = event.params.pane
    if (pane === "rendered" && this.stale) return this.reload()
    this.apply(pane)
  }

  saved() {
    this.stale = true
  }

  apply(pane) {
    this.toggleTargets.forEach((t) => {
      const on = t.dataset.markdownViewPaneParam === pane
      t.setAttribute("aria-pressed", String(on))
      t.classList.toggle("active", on)
    })
    this.paneTargets.forEach((p) => { p.hidden = p.dataset.pane !== pane })
  }

  reload() {
    if (window.Turbo) window.Turbo.visit(window.location.href, { action: "replace" })
    else window.location.reload()
  }
}
