import { Controller } from "@hotwired/stimulus"

// A <details class="menu"> is a menu the browser opens and closes for us, with no JavaScript
// and no positioning maths. The one thing native <details> will not do is close when the user
// clicks somewhere else or presses Escape — that is all this controller adds.
export default class extends Controller {
  connect() {
    this.onClick = (event) => { if (!this.element.contains(event.target)) this.element.removeAttribute("open") }
    // ESCAPE RETURNS FOCUS TO THE SUMMARY when it was inside the menu: closing a <details> hides
    // the focused field, and focus would otherwise fall to <body>, leaving a keyboard user nowhere
    // (found in slice 2's review, from the New menu's inline folder field).
    this.onKeydown = (event) => {
      if (event.key !== "Escape" || !this.element.open) return
      const hadFocus = this.element.contains(document.activeElement)
      this.element.removeAttribute("open")
      if (hadFocus) this.element.querySelector("summary")?.focus()
    }
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
  }
}
