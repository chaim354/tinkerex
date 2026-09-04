import { Controller } from "@hotwired/stimulus"

// The rail (spec §5.4): the collapse button toggles `rail--collapsed` on <body> and writes the
// `rail` cookie so the layout renders the next page already collapsed; Cmd/Ctrl-K focuses the
// top-bar search. Listeners attach on connect and detach on disconnect because Turbo swaps the
// rail on every navigation.
export default class extends Controller {
  static targets = ["toggle"]

  connect() {
    this.onKeydown = (event) => this.shortcut(event)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  toggle() {
    const collapsed = document.body.classList.toggle("rail--collapsed")
    document.cookie = `rail=${collapsed ? "collapsed" : "expanded"}; path=/; max-age=31536000; samesite=lax`
    if (this.hasToggleTarget) this.toggleTarget.setAttribute("aria-expanded", String(!collapsed))
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
