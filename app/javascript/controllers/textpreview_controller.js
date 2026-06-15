import { Controller } from "@hotwired/stimulus"

// Fetch a text file's bytes from the (presigned) blob endpoint and show them inline.
export default class extends Controller {
  static values = { url: String }

  async connect() {
    try {
      const res = await fetch(this.urlValue)
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
      let text = await res.text()
      if (text.length > 200_000) text = text.slice(0, 200_000) + "\n… (truncated)"
      this.element.textContent = text
    } catch (e) {
      this.element.textContent = `Could not load preview: ${e.message}`
    }
  }
}
