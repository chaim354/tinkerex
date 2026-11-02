import { Controller } from "@hotwired/stimulus"

// The wiring table's unsaved-row warning (2026-11-02, the UX audit's C10). Each row is its own form
// (projects/_wiring.html.erb says why: a <form> cannot span table cells), and a Save or a Remove
// reloads the page, so an edit typed into another row was dropped without a word. This marks a row
// "Unsaved" as it is edited, asks before a submit that would drop OTHER rows' edits, and asks before
// leaving the page while any row is unsaved. It saves nothing itself and changes no request: without
// it the table works exactly as before, minus the warnings.
//
// A row is found from its field by `closest("tr")`, and a Save form's row by the `form` attribute
// its fields point at it with — the same id the partial builds, never a second naming scheme.
const LEAVE = "Leave without saving your wiring changes?"

export default class extends Controller {
  static targets = ["row"]

  connect() {
    this.submitting = false
    this.beforeUnload = (event) => {
      if (this.submitting || !this.dirtyRows().length) return
      event.preventDefault()
      event.returnValue = LEAVE
    }
    this.beforeVisit = (event) => {
      if (this.submitting || !this.dirtyRows().length) return
      if (!window.confirm(LEAVE)) event.preventDefault()
    }
    // A submit the maker went through with (any confirm already passed) owns the navigation that
    // follows: the leave-guard must not ask again about the reload it causes.
    this.submitStart = () => { this.submitting = true }
    this.submitEnd = (event) => { if (!event.detail?.success) this.submitting = false }
    window.addEventListener("beforeunload", this.beforeUnload)
    document.addEventListener("turbo:before-visit", this.beforeVisit)
    this.element.addEventListener("turbo:submit-start", this.submitStart)
    this.element.addEventListener("turbo:submit-end", this.submitEnd)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.beforeUnload)
    document.removeEventListener("turbo:before-visit", this.beforeVisit)
    this.element.removeEventListener("turbo:submit-start", this.submitStart)
    this.element.removeEventListener("turbo:submit-end", this.submitEnd)
  }

  edit(event) {
    const row = event.target.closest("tr")
    if (!row || row.dataset.dirty === "true") return
    row.dataset.dirty = "true"
    row.querySelector(".wiring-unsaved")?.removeAttribute("hidden")
  }

  // A Save posts ONE row and a Remove deletes one; both reload the table. If ANOTHER row holds
  // edits, say so and stop unless the maker agrees. Runs on the form itself, before Turbo's own
  // submit listener on the document, which leaves a prevented submit alone.
  save(event) {
    const form = event.target
    const own = form.id ? this.rowTargets.find((row) => row.querySelector(`[form='${form.id}']`)) : form.closest("tr")
    const others = this.dirtyRows().filter((row) => row !== own)
    if (others.length === 0) return

    const which = others.length === 1 ? "Another row has" : `${others.length} other rows have`
    if (!window.confirm(`${which} unsaved changes, and this reloads the table without them. Continue?`)) {
      event.preventDefault()
    }
  }

  dirtyRows() {
    return this.rowTargets.filter((row) => row.dataset.dirty === "true")
  }
}
