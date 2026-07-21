import { Controller } from "@hotwired/stimulus"

// Live box preview: POST the current form params to the preview endpoint and drop the returned
// image (a rasterized PNG of the generated SVG) into the preview <img>.
export default class extends Controller {
  static values = { url: String }
  static targets = ["form", "image"]

  async preview() {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    try {
      const res = await fetch(this.urlValue, {
        method: "POST",
        body: new FormData(this.formTarget),
        headers: token ? { "X-CSRF-Token": token } : {},
      })
      if (!res.ok) return
      const blob = await res.blob()
      this.imageTarget.src = URL.createObjectURL(blob)
    } catch (_e) {
      /* transient; the user can click Preview again */
    }
  }
}
