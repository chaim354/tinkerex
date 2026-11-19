import { Controller } from "@hotwired/stimulus"

// The three-way theme choice (settings/_theme): on the Settings page and in the strip's account menu
// (Shop manual spec §7). A press stamps the choice on <html data-theme> for this page and writes the
// `theme` cookie so the layout renders the next page with it already applied (no flash, no inline
// script; design-system.md rule 7). ShellHelper#ui_theme treats any other cookie value as LIGHT, the
// default since the 2026-10-08 redesign.
//
// EVERY INSTANCE FOLLOWS EVERY CHANGE (UX audit A6). The Settings row and the account menu's are
// separate controller instances on one page; `apply` broadcasts `theme:change` on the document and
// every instance re-renders from it, so the pressed button moves in both at once. (The rail's cycle
// button, which named its next step, left with the rail in slice 3.)
const ORDER = ["light", "dark", "system"]
// theme-color mirrors ShellHelper#theme_color_hex: Paper's ground for light and system, Graphite's
// for dark.
const META = { light: ["light", "#ffffff"], dark: ["dark", "#111316"], system: ["light dark", "#ffffff"] }
const CHANGE = "theme:change"

export default class extends Controller {
  static targets = ["option"]

  connect() {
    this.onChange = (event) => this.render(event.detail.theme)
    document.addEventListener(CHANGE, this.onChange)
    this.render(this.current())
  }

  disconnect() {
    document.removeEventListener(CHANGE, this.onChange)
  }

  // The choice's three buttons (data-theme-theme-param="dark|light|system"). Guarded against a value
  // outside ORDER rather than trusting the DOM -- cheap, and it keeps this from ever writing a cookie
  // value ShellHelper#ui_theme would then have to treat as light anyway.
  choose(event) {
    const next = event.params.theme
    if (!ORDER.includes(next)) return
    this.apply(next)
  }

  // THE ONE WRITE PATH: html[data-theme], the cookie, the two metas, then the broadcast every
  // instance (this one included) renders from. Keeping this as the single place that writes the
  // cookie is what a mutation check can catch -- see test/system/settings_theme_test.rb.
  apply(next) {
    document.documentElement.dataset.theme = next
    document.cookie = `theme=${next}; path=/; max-age=31536000; samesite=lax`
    document.querySelector("meta[name=color-scheme]")?.setAttribute("content", META[next][0])
    document.querySelector("meta[name=theme-color]")?.setAttribute("content", META[next][1])
    document.dispatchEvent(new CustomEvent(CHANGE, { detail: { theme: next } }))
  }

  current() {
    const value = document.documentElement.dataset.theme
    return ORDER.includes(value) ? value : "light"
  }

  render(theme) {
    this.optionTargets.forEach((opt) => {
      opt.setAttribute("aria-pressed", opt.dataset.themeThemeParam === theme ? "true" : "false")
    })
  }
}
