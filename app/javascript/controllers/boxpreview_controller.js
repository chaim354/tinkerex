import { Controller } from "@hotwired/stimulus"

// Live box preview: POST the current form params to the preview endpoint and drop the returned
// image (a rasterized PNG of the generated SVG) into the preview <img>.
//
// It renders the generator's defaults on connect — landing on an empty grey panel and having to
// press a button to find out what the generator even makes was the thing to fix — and then
// re-renders on a debounce whenever a param settles. The Preview button stays as the manual retry
// for the case where a render failed and nothing has changed since.
export default class extends Controller {
  static values = { url: String, delay: { type: Number, default: 600 } }
  static targets = ["form", "image", "status"]

  connect() {
    this.seq = 0
    this.objectUrl = null
    this.formTarget.addEventListener("input", this.#onEdit)
    this.formTarget.addEventListener("change", this.#onEdit)
    this.preview()
  }

  disconnect() {
    clearTimeout(this.timer)
    this.controller?.abort()
    this.formTarget.removeEventListener("input", this.#onEdit)
    this.formTarget.removeEventListener("change", this.#onEdit)
    if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
  }

  // Only the generator's own params change the drawing — the box's name and its destination folder
  // do not, and re-rendering while someone types a name is a sidecar call per keystroke for nothing.
  #onEdit = (event) => {
    if (!event.target.name?.startsWith("params[")) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.preview(), this.delayValue)
  }

  async preview() {
    clearTimeout(this.timer)
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    // An edit made mid-render must win, however the two requests happen to land: abort the one in
    // flight AND stamp this one, so a slow earlier response can't overwrite a newer image.
    this.controller?.abort()
    this.controller = new AbortController()
    const mine = ++this.seq
    this.#status("Rendering…")

    try {
      const res = await fetch(this.urlValue, {
        method: "POST",
        body: new FormData(this.formTarget),
        headers: token ? { "X-CSRF-Token": token } : {},
        signal: this.controller.signal,
      })
      if (mine !== this.seq) return
      if (!res.ok) {
        // boxes.py's own complaint ("traylayout requires --layout, …") is the most useful thing we
        // can show — it names the param to fix. It is inserted as TEXT, never as markup.
        this.#status((await res.text()).trim() || `Preview failed (${res.status})`, true)
        return
      }
      const blob = await res.blob()
      if (mine !== this.seq) return
      if (this.objectUrl) URL.revokeObjectURL(this.objectUrl)
      this.objectUrl = URL.createObjectURL(blob)
      this.imageTarget.src = this.objectUrl
      this.element.classList.add("has-preview")
      this.#status("")
    } catch (e) {
      if (e.name === "AbortError" || mine !== this.seq) return
      this.#status("Preview unavailable — check the connection, then press Preview.", true)
    }
  }

  #status(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.hidden = text === ""
    this.statusTarget.classList.toggle("is-error", isError)
  }
}
