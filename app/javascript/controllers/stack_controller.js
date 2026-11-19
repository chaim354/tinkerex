import { Controller } from "@hotwired/stimulus"

// A VERSION STACK OPENS IN PLACE (Shop manual spec §9). Mounted on whatever holds a listing's stacks
// (the Library's table and grid, a project panel's files), it answers the stack's own button: the
// button's `aria-controls` names what opens — every member row of a stack row, or the opened panel
// after a stack figure — and the button's `aria-expanded` says whether it is open. Nothing is
// fetched: the server drew the members, hidden, beside the stack, so opening is showing them.
//
// NOT A <details>: a row's members are sibling rows of a table and a figure's panel spans the plate
// after it, and neither can sit inside the element that opens it.
export default class extends Controller {
  toggle(event) {
    const button = event.currentTarget
    this.set(button, button.getAttribute("aria-expanded") !== "true")
  }

  // The opened panel's Close names the stack's button by id (`data-stack-toggle-param`), and hands
  // the focus back to it: the panel it was in is about to be hidden.
  close(event) {
    const button = document.getElementById(event.params.toggle)
    if (!button) return
    this.set(button, false)
    button.focus({ preventScroll: true })
  }

  set(button, open) {
    button.setAttribute("aria-expanded", String(open))
    for (const id of (button.getAttribute("aria-controls") || "").split(/\s+/)) {
      const el = id && document.getElementById(id)
      if (el) el.hidden = !open
    }
    button.closest("tr, .grid-item, .plate-figure")?.classList.toggle("is-open", open)
  }
}
