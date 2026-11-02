import { Controller } from "@hotwired/stimulus"

// The rail (spec §5.4): the collapse button and Cmd/Ctrl-K, which focuses the top-bar search.
// Listeners attach on connect and detach on disconnect because Turbo swaps the rail on every
// navigation.
//
// THE BUTTON FLIPS WHAT IS DRAWN, AND WRITES THAT CHOICE (UX audit A2). The `rail` cookie has three
// states (ShellHelper#rail_expanded?): absent follows the width, icons below 1100px; `collapsed` and
// `expanded` are explicit and beat the width. So a click reads the rail AS DRAWN — the icon rail is
// its 56px track, the full rail its 216px one — and writes the opposite: from icons it expands,
// even at 1024px, where it used to flip a cookie the media query then ignored. The body carries
// the matching class so the change shows without a reload; both classes set only the grid track
// (shell.css), and the icon rail follows the width through its container query.
//
// THE BUTTON'S WORDS AND aria-expanded FOLLOW THE DRAWN RAIL TOO, on connect and on every resize: the
// server can only render the cookie's answer, and with no cookie below 1100px the rail is icons
// whatever it guessed.
const ICON_RAIL_MAX = 120 // px; the threshold the `@container rail` block in shell.css uses

export default class extends Controller {
  static targets = ["toggle", "toggleLabel"]

  connect() {
    this.onKeydown = (event) => this.shortcut(event)
    document.addEventListener("keydown", this.onKeydown)
    this.resizeObserver = new ResizeObserver(() => this.sync())
    this.resizeObserver.observe(this.element)
    this.sync()
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
    this.resizeObserver?.disconnect()
  }

  toggle() {
    const next = this.iconRail() ? "expanded" : "collapsed"
    document.body.classList.toggle("rail--collapsed", next === "collapsed")
    document.body.classList.toggle("rail--expanded", next === "expanded")
    document.cookie = `rail=${next}; path=/; max-age=31536000; samesite=lax`
    this.sync()
  }

  // Drawn width, not the cookie: the rail is a size container whose width is its grid track.
  iconRail() {
    return this.element.getBoundingClientRect().width <= ICON_RAIL_MAX
  }

  sync() {
    if (!this.hasToggleTarget) return
    // A hidden rail (below 720px) measures 0 wide; leave the button as it was rendered.
    if (this.element.getBoundingClientRect().width === 0) return
    const icons = this.iconRail()
    const words = icons ? "Expand navigation" : "Collapse navigation"
    this.toggleTarget.setAttribute("aria-expanded", String(!icons))
    this.toggleTarget.setAttribute("aria-label", words)
    this.toggleTarget.setAttribute("title", words)
    if (this.hasToggleLabelTarget) this.toggleLabelTarget.textContent = icons ? "Expand" : "Collapse"
  }

  shortcut(event) {
    if (!(event.metaKey || event.ctrlKey) || event.key.toLowerCase() !== "k") return
    const field = document.querySelector(".topbar-search input[type=search]")
    if (!field) return
    event.preventDefault()
    field.focus()
    field.select()
  }
}
