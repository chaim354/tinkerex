import { Controller } from "@hotwired/stimulus"

// THE NAME IS HISTORICAL. This was the Box Generator's preview controller; the Box Generator is now
// a runtime-loaded ESM bundle and this file serves ONLY /tools/openscad. It is deliberately not
// renamed: the OpenSCAD addon is itself slated for retirement, and a rename would touch this file,
// boxfilter_controller.js and both views for nothing a user could see.
//
// Live model preview: POST the current form params to the preview endpoint and drop the returned
// image (a server-side raster of the generated 3MF) into the preview <img>.
//
// It renders the generator's defaults on connect — landing on an empty grey panel and having to
// press a button to find out what the generator even makes was the thing to fix — and then
// re-renders on a debounce whenever a param settles. The Preview button stays as the manual retry
// for the case where a render failed and nothing has changed since.
//
// DELETED BY ACCIDENT in 6095b87 (2026-08-03, the boxes migration to a runtime bundle) while
// app/views/tools/openscad/new.html.erb went on declaring it. Stimulus no-ops SILENTLY on an
// identifier it cannot resolve — no throw, no console warning — so the editor opened on an empty
// grey panel for nine days with nothing anywhere to say so. test/stimulus_hygiene_test.rb is the
// guard that now turns that into a red suite instead of a silent regression.
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

  // Only the generator's own params change the drawing — the model's name and its destination folder
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
        this.#status(await this.#refusal(res), true)
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

  // THE SIDECAR'S OWN SENTENCE, NOT A STATUS CODE. Tools::OpenscadController#preview answers every
  // refusal with `render plain: e.message`, and when the sidecar refused a submitted VALUE (422
  // carrying `code: "invalid_params"`, which OpenscadClient turns into InvalidParams) that message is
  // coerce.py's own prose — it names the parameter to fix. "Preview failed (422)" names nothing.
  //
  // BRANCHED ON THE CONTENT TYPE because only the RESCUED errors are text/plain: an unrescued 500
  // answers a whole HTML error page, and emptying that into the status line is worse than the
  // generic sentence. The body is inserted as TEXT by #status, never as markup, either way.
  async #refusal(res) {
    const plain = res.headers.get("content-type")?.startsWith("text/plain")
    const body = plain ? (await res.text()).trim() : ""
    return body || `Preview failed (${res.status})`
  }

  #status(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.hidden = text === ""
    this.statusTarget.classList.toggle("is-error", isError)
  }
}
