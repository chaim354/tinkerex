import { Controller } from "@hotwired/stimulus"
import { darkThemeActive } from "lib/ui_theme"

// KICANVAS' OWN TWO THEMES, ONE PER APP THEME (2026-10-21). It ships "kicad" (KiCad's own colours:
// a schematic on light paper, which is Paper's ground almost exactly) and "witchhazel", a dark one.
// Left alone it read its global preference, which defaults to witchhazel, so every schematic was a
// dark purple panel on the light page. Nothing in the app's stylesheet reaches inside its shadow
// DOM, so this is the one viewer whose theme JavaScript picks.
//
// THE PREFERENCE IS WRITTEN, NOT THE EMBED'S `theme` ATTRIBUTE. The embed declares a `theme`
// property, but this vendored build does not hand it to the viewer it renders (measured: the
// attribute set, `kc-schematic-app` rendered without one, Witch Hazel painted). What the viewer does
// read is the global preference, `kc:prefs:theme` in localStorage as `{"val": name}`, which the
// module loads ONCE, at import. So the value is written before the import below, and the cost of
// "once" is stated rather than hidden: a theme switch, or a Turbo visit after one (Turbo keeps the
// imported module), shows the schematic in the theme its page loaded with until the next full load.
// Every other viewer repaints live (design-system.md rule 5).
const KICANVAS_THEME = { light: "kicad", dark: "witchhazel" }
const PREFERENCE_KEY = "kc:prefs:theme"
function choosePreference() {
  try {
    window.localStorage.setItem(PREFERENCE_KEY, JSON.stringify({ val: KICANVAS_THEME[darkThemeActive() ? "dark" : "light"] }))
  } catch {
    // Storage refused (a private window, blocked site data): KiCanvas keeps its default theme.
  }
}

// KiCad schematics and boards, rendered in the browser (stage 3, S3-2). The KiCanvas module is
// ONE vendored build (bin/build-kicanvas, importmap pin "kicanvas") and it is imported LAZILY here,
// on connect, so a page without a KiCad file never downloads it. The embed fetches `urlValue`
// itself — a `named_blob_file_path`, NOT the plain blob URL the 3D viewer's loaders use: KiCanvas
// decides what it just fetched from the URL's OWN trailing extension, so it has to be the one
// carrying `.kicad_sch`/`.kicad_pcb` (see files/show.html.erb's comment on that route; measured
// against the vendored module, not guessed). On s3 that fetch follows a presigned redirect to the
// bucket — cross-origin, so it reads only under the bucket's CORS rule (docs/DEPLOY.md) and a
// connect-src the port names for the CSP (FileLayer#presigned_origin), exactly as the 3D
// viewer's fetch does.
export default class extends Controller {
  static values = { url: String, controls: { type: String, default: "basic" } }
  static targets = ["stage", "status"]

  async connect() {
    try {
      choosePreference()
      await import("kicanvas")
      const embed = document.createElement("kicanvas-embed")
      embed.setAttribute("src", this.urlValue)
      embed.setAttribute("controls", this.controlsValue)
      this.stageTarget.replaceChildren(embed)
      // The status line is a SIBLING of the stage, not inside it — replaceChildren above only
      // touches the stage, so without this "Loading the viewer…" would sit above a working embed
      // forever.
      if (this.hasStatusTarget) this.statusTarget.remove()
      this.element.dataset.kicanvasState = "ready"
    } catch (e) {
      this.element.dataset.kicanvasState = "failed"
      if (this.hasStatusTarget) this.statusTarget.textContent = "The viewer could not load."
    }
  }
}
