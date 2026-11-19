import { Controller } from "@hotwired/stimulus"

// The theme button in the rail (spec §5.7), and — stage 2, S2-6 — the three-way choice on the
// settings page and in the phone's More sheet. Both write the same three states: light -> dark ->
// system in the rail (cycle), or pick one directly (choose). Either way this stamps the choice on
// <html data-theme> for this page and writes the `theme` cookie so the layout renders the next
// page with it already applied (no flash, no inline script). ShellHelper#ui_theme treats any
// other cookie value as LIGHT, the default since the 2026-10-08 redesign.
//
// EVERY INSTANCE FOLLOWS EVERY CHANGE (UX audit A6). The rail's button and each choice row are
// separate controller instances, and the rail's label used to stay stale until the next page after
// a choice on Settings. `apply` now broadcasts `theme:change` on the document and every instance
// re-renders from it, so a choice anywhere renames the rail button at once.
//
// THE RAIL'S LABEL NAMES THE NEXT STEP, NOT THE STATE: "Switch to dark" while light is on. The words
// come from the server (ShellHelper::THEME_ACTIONS, as `data-theme-actions-value`), keyed by the
// current theme, so they are written once.
const ORDER = ["light", "dark", "system"]
// theme-color mirrors ShellHelper#theme_color_hex: Paper's ground for light and system, Graphite's
// for dark.
const META = { light: ["light", "#f4f2ed"], dark: ["dark", "#141512"], system: ["light dark", "#f4f2ed"] }
const CHANGE = "theme:change"

export default class extends Controller {
  static targets = ["label", "option"]
  static values = { actions: Object }

  connect() {
    this.onChange = (event) => this.render(event.detail.theme)
    document.addEventListener(CHANGE, this.onChange)
    this.render(this.current())
  }

  disconnect() {
    document.removeEventListener(CHANGE, this.onChange)
  }

  cycle() {
    this.apply(ORDER[(ORDER.indexOf(this.current()) + 1) % ORDER.length])
  }

  // The choice rows' three buttons (data-theme-theme-param="dark|light|system"). Guarded
  // against a value outside ORDER rather than trusting the DOM -- cheap, and it keeps this from
  // ever writing a cookie value ShellHelper#ui_theme would then have to treat as light anyway.
  choose(event) {
    const next = event.params.theme
    if (!ORDER.includes(next)) return
    this.apply(next)
  }

  // THE ONE WRITE PATH, shared by cycle and choose: html[data-theme], the cookie, the two metas,
  // then the broadcast every instance (this one included) renders from. Keeping this as the single
  // place that writes the cookie is what a mutation check on `choose` alone can catch -- see
  // test/system/settings_theme_test.rb.
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
    // The rail button: its label, and the aria-label and title that name it in the icon rail, where
    // the label hides. A choice row's element is a role="group" whose label the server wrote, and it
    // has no label target, so this leaves it alone.
    if (this.hasLabelTarget) {
      const action = this.actionsValue[theme] || ""
      this.labelTarget.textContent = action
      this.element.setAttribute("aria-label", action)
      this.element.setAttribute("title", action)
    }
    this.optionTargets.forEach((opt) => {
      opt.setAttribute("aria-pressed", opt.dataset.themeThemeParam === theme ? "true" : "false")
    })
  }
}
