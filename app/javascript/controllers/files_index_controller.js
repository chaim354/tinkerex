import { Controller } from "@hotwired/stimulus"

// THE INDEX OF FILES, AND THE WAY TO A FIGURE (the Shop manual spec §9; projects/_files_index). The
// server renders every entry, A to Z, each with the figure number the page drew it with; this filters
// them in place and goes to a figure. The column's find box (figure_find_controller.js) drives both
// through this controller as its outlet, so the index and the box are one behaviour on two elements
// in two parts of the page — the column and `main` share no element a single controller could sit on.
//
// A FIGURE IS AN ELEMENT CARRYING `data-fig` (ProjectsHelper#figure_data): a tile, a stack, a list
// row, a photo, the cover. `data-fig-repeat` marks a second look that numbers nothing (Recently
// changed, a build-log photo), so the way to Fig. N is the FIRST element in the document drawing N
// that is not a repeat — which is where the page's walk numbered it (Maker::ProjectFigures), and
// figure_numbers_test.rb holds the two to one order.
//
// GOING TO A FIGURE opens what hides it (a closed Backups group, a tab that is not shown), marks it
// the selected figure (`aria-current="true"`: the 2px red outline, components.css and
// pages/projects.css) and scrolls it to the middle of the window. A press on an entry's number also
// moves the focus to the figure's own link, as following an anchor would; the find box keeps it.
//
// NO JAVASCRIPT: the index is a list of names linking to their pages, every entry shown, with the
// numbers to read; "Show all" is the only control that does nothing, and it says what it would show.
export default class extends Controller {
  static targets = ["entry", "empty", "more"]

  connect() {
    this.collapsed = this.hasMoreTarget
  }

  // FILTERS IN PLACE AND SAYS HOW MANY MATCH. Every entry is searched, past "Show all" too: by name,
  // by folder and by kind, and a number also finds the entry with that figure. An empty query puts
  // the list back as it was.
  filter(query) {
    const q = normalise(query)
    const number = numberIn(q)
    let matches = 0
    for (const entry of this.entryTargets) {
      const hit = q === "" ? !(this.collapsed && entry.dataset.beyond) : matchesEntry(entry, q, number)
      entry.hidden = !hit
      if (hit) matches++
    }
    if (this.hasEmptyTarget) this.emptyTarget.hidden = q === "" || matches > 0
    if (this.hasMoreTarget) this.moreTarget.hidden = q !== "" || !this.collapsed
    return { matches, total: this.entryTargets.length, number }
  }

  showAll(event) {
    event?.preventDefault()
    this.collapsed = false
    this.filter("")
    // Focus the first entry that was hidden, so the keyboard carries on where the list grew.
    const first = this.entryTargets.find((e) => e.dataset.beyond)
    first?.querySelector("a")?.focus()
  }

  // WHAT ENTER IN THE FIND BOX GOES TO: Fig. N for a number the page draws, else the best matching
  // entry's figure — a name that starts with what was typed, then one with a word that does, then the
  // first match A to Z, so "robber" is robber.3mf and not "dice robber holder" — else that entry
  // itself. Returns a sentence for the box's status line.
  find(query) {
    const q = normalise(query)
    if (q === "") return ""
    const number = numberIn(q)
    if (number && this.figure(number)) {
      this.go(number, { focus: false })
      return `Fig. ${number}`
    }
    const entry = bestMatch(this.entryTargets.filter((e) => !e.hidden), q)
    if (!entry) return "No file matches."
    const name = entry.querySelector(".files-index-name")?.firstChild?.textContent?.trim() || ""
    const fig = Number(entry.dataset.entryFig)
    if (fig && this.figure(fig)) {
      this.go(fig, { focus: false })
      return `${name}, Fig. ${fig}`
    }
    this.select(entry)
    entry.scrollIntoView({ block: "center", behavior: smooth() })
    return `${name} has no figure on this page.`
  }

  // An entry's number, pressed.
  jump(event) {
    event.preventDefault()
    this.go(Number(event.currentTarget.dataset.figJump), { focus: true })
  }

  figure(number) {
    return document.querySelector(`[data-fig="${number}"]:not([data-fig-repeat])`)
  }

  go(number, { focus }) {
    const figure = this.figure(number)
    if (!figure) return null
    reveal(figure)
    this.select(figure)
    figure.scrollIntoView({ block: "center", behavior: smooth() })
    if (focus) {
      const target = figure.matches("a[href], button") ? figure : figure.querySelector("a[href], button")
      target?.focus({ preventScroll: true })
    }
    return figure
  }

  // ONE SELECTED FIGURE ON THE PAGE, and one entry: the last one gone to.
  select(element) {
    for (const old of document.querySelectorAll('[data-fig][aria-current="true"], .files-index-entry[aria-current="true"]')) {
      old.removeAttribute("aria-current")
    }
    element.setAttribute("aria-current", "true")
  }

  // Escape in the find box: the list as it was, and no figure selected.
  reset() {
    this.filter("")
    for (const old of document.querySelectorAll('[data-fig][aria-current="true"], .files-index-entry[aria-current="true"]')) {
      old.removeAttribute("aria-current")
    }
  }
}

function normalise(text) {
  return String(text || "").trim().toLowerCase()
}

// "7", "fig 7", "fig. 7", "#7" all ask for Fig. 7.
function numberIn(q) {
  const m = q.match(/^(?:fig\.?\s*|#)?(\d+)$/)
  return m ? Number(m[1]) : null
}

function bestMatch(entries, q) {
  const name = (e) => e.dataset.name || ""
  return entries.find((e) => name(e).startsWith(q)) ||
    entries.find((e) => name(e).split(/[^\p{L}\p{N}]+/u).some((word) => word.startsWith(q))) ||
    entries[0]
}

function matchesEntry(entry, q, number) {
  if (number && Number(entry.dataset.entryFig) === number) return true
  const { name = "", folder = "", kind = "" } = entry.dataset
  return name.includes(q) || folder.includes(q) || kind === q
}

// A figure inside a closed <details> (the Files panel's Backups) or a tab that is not shown.
function reveal(figure) {
  for (let details = figure.closest("details:not([open])"); details; details = details.parentElement?.closest("details:not([open])")) {
    details.open = true
  }
  const pane = figure.closest(".tab-pane")
  if (pane?.hidden) document.getElementById(pane.getAttribute("aria-labelledby"))?.click()
}

function smooth() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth"
}
