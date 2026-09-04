import { Controller } from "@hotwired/stimulus"

// The theme button in the rail (spec §5.7). Cycles dark -> light -> system, stamps the choice on
// <html data-theme> for this page and writes the `theme` cookie so the layout renders the next
// page with it already applied (no flash, no inline script). ShellHelper#ui_theme treats any
// other cookie value as dark.
const ORDER = ["dark", "light", "system"]
const META = { dark: ["dark", "#15181d"], light: ["light", "#f4f5f7"], system: ["light dark", "#15181d"] }

export default class extends Controller {
  static targets = ["label"]

  connect() {
    this.render(this.current())
  }

  cycle() {
    const next = ORDER[(ORDER.indexOf(this.current()) + 1) % ORDER.length]
    document.documentElement.dataset.theme = next
    document.cookie = `theme=${next}; path=/; max-age=31536000; samesite=lax`
    document.querySelector("meta[name=color-scheme]")?.setAttribute("content", META[next][0])
    document.querySelector("meta[name=theme-color]")?.setAttribute("content", META[next][1])
    this.render(next)
  }

  current() {
    const value = document.documentElement.dataset.theme
    return ORDER.includes(value) ? value : "dark"
  }

  render(theme) {
    this.element.setAttribute("aria-label", `Theme: ${theme}`)
    if (this.hasLabelTarget) this.labelTarget.textContent = `Theme: ${theme}`
  }
}
