import { Controller } from "@hotwired/stimulus"

// ONE GROUP of the commit box's staging panel (repo_commits/show.html.erb).
//
// WHY THERE IS JAVASCRIPT HERE AT ALL. "Select all" is the one control on this page that markup
// cannot express: no HTML element ticks other checkboxes, and no CSS selector writes a `checked`
// property. A `<label>` reaches exactly one input. So this is JS or it is nothing.
//
// THE SCOPE IS `this.element`, AND THAT IS THE WHOLE SAFETY PROPERTY RATHER THAN AN IMPLEMENTATION
// DETAIL. Stimulus attaches one instance per `<section class="commit-group">`, so every query below
// is confined to a single group by CONSTRUCTION — there is no group key to compare, no filter to
// get wrong, and nothing to keep in step when a fourth group appears. Widening any of them to
// `document` makes the control GLOBAL, which is precisely how a maker commits `.DS_Store` by
// accident: the panel's protection is that the two wider groups arrive UNCHECKED and are ticked
// only deliberately (spec part 1), and one global control undoes that for all three at once.
// test/system/repo_staging_test.rb ticks Select all in "Other changes" and then COMMITS, so that
// mutation goes red on the resulting git tree — not merely on a DOM assertion about checkedness.
//
// THE CONTROL IS BUILT HERE RATHER THAN RENDERED BY THE VIEW, which is thumbfallback's argument
// turned around: a server-rendered "Select all" exists whether or not the script that makes it work
// ever arrives, and a checkbox that ticks nothing is worse than no checkbox — it is an affordance
// the page cannot honour, on a form whose entire subject is which paths were chosen. Built on
// connect, it is present exactly when it functions.
//
// IT WRITES NO STYLES. `.commit-group-all` lives in application.css beside the rest of the
// `.commit-*` block, for the reason the .history-panel block gives in as many words: a rule that
// lives in a JS string is one no stylesheet search will ever turn up.
//
// IT GOES INSIDE THE <details>, ABOVE THE ROWS — so a COLLAPSED group cannot be bulk-selected
// without first being opened and looked at. That is deliberate, and it is the kind of thing a later
// tidy-up moves up beside the group heading without noticing what it costs.
export default class extends Controller {
  static values = { label: String }

  connect() {
    this.rows = this.element.querySelector(".commit-rows")
    if (!this.rows || this.boxes.length === 0) return

    this.control = this.buildControl()
    this.rows.parentNode.insertBefore(this.control, this.rows)

    // Stored rather than inlined so disconnect() can remove exactly what connect() added: a
    // Turbo navigation reuses the document, and a listener left on a detached element is a leak
    // that only shows up as a group behaving twice.
    this.onToggle = () => this.applyToAll(this.toggle.checked)
    this.onRowChange = (event) => { if (event.target !== this.toggle) this.sync() }
    this.toggle.addEventListener("change", this.onToggle)
    this.element.addEventListener("change", this.onRowChange)

    this.sync()
  }

  disconnect() {
    this.toggle?.removeEventListener("change", this.onToggle)
    this.element.removeEventListener("change", this.onRowChange)
    this.control?.remove()
    this.control = this.toggle = null
  }

  // EVERY COMMITTABLE ROW IN THIS GROUP AND NOTHING ELSE. Two exclusions come for free and neither
  // is a filter that can drift: a `.gitignore`d row carries no checkbox at all (the view lists it
  // disabled), and this controller's own toggle carries no `name`, so `[name='paths[]']` cannot
  // reach either one.
  get boxes() {
    return Array.from(this.element.querySelectorAll("input[type=checkbox][name='paths[]']"))
  }

  // A LABEL THAT NAMES ITS GROUP, not a bare "Select all". Three of these render on one page and
  // the difference between them is the only thing standing between a maker and a bulk tick they
  // did not mean — so the control says which group it is about, and the invariant is legible on
  // the page rather than only in this comment.
  buildControl() {
    const label = document.createElement("label")
    label.className = "commit-group-all"

    this.toggle = document.createElement("input")
    this.toggle.type = "checkbox"
    // NO `name`, DELIBERATELY. #create intersects whatever arrives with the rows the page could
    // have offered, so a stray value would be dropped rather than committed — but a second input
    // posting into a form about which paths were chosen is a thing to not have at all.
    label.append(this.toggle, `Select all in ${this.labelValue || "this group"}`)
    return label
  }

  applyToAll(checked) {
    // Assigning `.checked` fires no `change`, so this cannot re-enter through onRowChange.
    this.boxes.forEach((box) => { box.checked = checked })
    this.sync()
  }

  sync() {
    const boxes = this.boxes
    const checked = boxes.filter((box) => box.checked).length
    this.toggle.checked = checked > 0 && checked === boxes.length
    // `indeterminate` is a PROPERTY with no attribute and no state selector of its own, and it is
    // the only honest answer for a part-ticked group: without it the control reads "nothing here
    // is selected" over rows that plainly are.
    this.toggle.indeterminate = checked > 0 && checked < boxes.length
  }
}
