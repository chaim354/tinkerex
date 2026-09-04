import { Controller } from "@hotwired/stimulus"

// A <details class="menu"> is a menu the browser opens and closes for us, with no JavaScript
// and no positioning maths. The one thing native <details> will not do is close when the user
// clicks somewhere else or presses Escape — that is all this controller adds.
export default class extends Controller {
  connect() {
    this.onClick = (event) => { if (!this.element.contains(event.target)) this.element.removeAttribute("open") }
    this.onKeydown = (event) => { if (event.key === "Escape") this.element.removeAttribute("open") }
    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onKeydown)
  }
}
