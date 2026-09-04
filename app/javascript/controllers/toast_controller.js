import { Controller } from "@hotwired/stimulus"

// The flash stack (spec §5.5). A notice removes itself after NOTICE_MS; an alert stays until its
// close button is pressed. Timers are cleared on disconnect so a Turbo navigation mid-countdown
// does not remove an element that no longer exists.
const NOTICE_MS = 6000

export default class extends Controller {
  static targets = ["item"]

  connect() {
    this.timers = this.itemTargets
      .filter((item) => item.classList.contains("flash-notice"))
      .map((item) => setTimeout(() => item.remove(), NOTICE_MS))
  }

  disconnect() {
    (this.timers || []).forEach(clearTimeout)
  }

  dismiss(event) {
    event.currentTarget.closest(".flash")?.remove()
  }
}
