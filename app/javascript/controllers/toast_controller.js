import { Controller } from "@hotwired/stimulus"

// The flash stack (spec §5.5). A notice removes itself after NOTICE_MS; an alert stays until its
// close button is pressed. Timers are cleared on disconnect so a Turbo navigation mid-countdown
// does not remove an element that no longer exists.
//
// A NOTICE WAITS WHILE SOMEONE IS READING IT (UX audit A5): its countdown pauses while the pointer is
// over it or focus is inside it, and resumes with what was left, never less than RESUME_MIN_MS, so
// moving the pointer off a toast does not snatch it away mid-glance. Escape dismisses the toast that
// holds focus, notice or alert.
//
// ANY `[data-toast-target="item"]` IS MANAGED, including one a script appends after the page loads
// (the page-layout editor's toasts): Stimulus calls `itemTargetConnected` for each, so a caller adds
// the element with that attribute and a `data-action="toast#dismiss"` close button, and the timing,
// the pause and Escape come with it.
const NOTICE_MS = 6000
const RESUME_MIN_MS = 2000

export default class extends Controller {
  static targets = ["item"]

  initialize() {
    this.timers = new Map()
  }

  // Timers stop here; the map is NOT cleared, because Stimulus calls itemTargetDisconnected for each
  // target after this, and that is where each item's listeners come off and its entry goes.
  disconnect() {
    this.timers.forEach((state) => clearTimeout(state.timer))
  }

  itemTargetConnected(item) {
    if (!item.classList.contains("flash-notice")) return
    const state = { remaining: NOTICE_MS, startedAt: 0, timer: null, hovered: false, focused: false }
    this.timers.set(item, state)
    state.listeners = {
      mouseenter: () => { state.hovered = true; this.pause(item) },
      mouseleave: () => { state.hovered = false; this.resume(item) },
      focusin: () => { state.focused = true; this.pause(item) },
      focusout: (event) => {
        if (item.contains(event.relatedTarget)) return
        state.focused = false
        this.resume(item)
      }
    }
    Object.entries(state.listeners).forEach(([name, fn]) => item.addEventListener(name, fn))
    this.start(item)
  }

  itemTargetDisconnected(item) {
    const state = this.timers.get(item)
    if (!state) return
    clearTimeout(state.timer)
    Object.entries(state.listeners).forEach(([name, fn]) => item.removeEventListener(name, fn))
    this.timers.delete(item)
  }

  start(item) {
    const state = this.timers.get(item)
    if (!state || state.timer) return
    state.startedAt = Date.now()
    state.timer = setTimeout(() => item.remove(), state.remaining)
  }

  pause(item) {
    const state = this.timers.get(item)
    if (!state || !state.timer) return
    clearTimeout(state.timer)
    state.timer = null
    state.remaining = Math.max(0, state.remaining - (Date.now() - state.startedAt))
  }

  resume(item) {
    const state = this.timers.get(item)
    if (!state || state.hovered || state.focused) return
    state.remaining = Math.max(state.remaining, RESUME_MIN_MS)
    this.start(item)
  }

  dismiss(event) {
    event.currentTarget.closest(".flash")?.remove()
  }

  // keydown.esc on the stack (layouts/_flash.html.erb): the toast that holds focus goes, and focus
  // moves to the next toast's close button if one is left, rather than falling to <body>.
  escape(event) {
    const item = event.target.closest(".flash")
    if (!item || !this.element.contains(item)) return
    event.preventDefault()
    item.remove()
    this.itemTargets[0]?.querySelector(".flash-close")?.focus()
  }
}
