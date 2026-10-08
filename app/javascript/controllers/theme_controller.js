import { Controller } from "@hotwired/stimulus"

// The theme button in the rail (spec §5.7), and — stage 2, S2-6 — the three-way choice on the
// settings page. Both write the same three states: light -> dark -> system in the rail (cycle),
// or pick one directly on the settings row (choose). Either way this stamps the choice on
// <html data-theme> for this page and writes the `theme` cookie so the layout renders the next
// page with it already applied (no flash, no inline script). ShellHelper#ui_theme treats any
// other cookie value as LIGHT, the default since the 2026-10-08 redesign. The rail's button and
// the settings row are TWO SEPARATE controller instances (each is its own data-controller="theme"),
// so each renders only its own label/option targets -- the rail's label updates on the rail's own
// next render, not from a click on the settings row.
const ORDER = ["light", "dark", "system"]
// theme-color mirrors ShellHelper#theme_color_hex: Paper's ground for light and system, Graphite's
// for dark.
const META = { light: ["light", "#f4f2ed"], dark: ["dark", "#141512"], system: ["light dark", "#f4f2ed"] }

export default class extends Controller {
  static targets = ["label", "option"]

  connect() {
    this.render(this.current())
  }

  cycle() {
    this.apply(ORDER[(ORDER.indexOf(this.current()) + 1) % ORDER.length])
  }

  // The settings row's three buttons (data-theme-theme-param="dark|light|system"). Guarded
  // against a value outside ORDER rather than trusting the DOM -- cheap, and it keeps this from
  // ever writing a cookie value ShellHelper#ui_theme would then have to treat as light anyway.
  choose(event) {
    const next = event.params.theme
    if (!ORDER.includes(next)) return
    this.apply(next)
  }

  // THE ONE WRITE PATH, shared by cycle and choose: html[data-theme], the cookie, the two metas,
  // then this instance's own render. Keeping this as the single place that writes the cookie is
  // what a mutation check on `choose` alone can catch -- see test/system/settings_theme_test.rb.
  apply(next) {
    document.documentElement.dataset.theme = next
    document.cookie = `theme=${next}; path=/; max-age=31536000; samesite=lax`
    document.querySelector("meta[name=color-scheme]")?.setAttribute("content", META[next][0])
    document.querySelector("meta[name=theme-color]")?.setAttribute("content", META[next][1])
    this.render(next)
  }

  current() {
    const value = document.documentElement.dataset.theme
    return ORDER.includes(value) ? value : "light"
  }

  render(theme) {
    // The element's own label is the RAIL BUTTON's (the button is the element there). The settings
    // row's element is a role="group" whose label the server wrote; leave that one alone.
    if (this.optionTargets.length === 0) this.element.setAttribute("aria-label", `Theme: ${theme}`)
    if (this.hasLabelTarget) this.labelTarget.textContent = `Theme: ${theme}`
    this.optionTargets.forEach((opt) => {
      opt.setAttribute("aria-pressed", opt.dataset.themeThemeParam === theme ? "true" : "false")
    })
  }
}
