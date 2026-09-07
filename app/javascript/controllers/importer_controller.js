import { Controller } from "@hotwired/stimulus"
import JSZip from "jszip"
import { uploadChunkFile, uploadPortFile } from "lib/chunk_upload"

// Import a downloaded model bundle from ONE selection. Unzips any .zip in the browser, classifies
// entries by extension, then creates the Model (+ folder map) and uploads every file through the
// existing per-backend flow, attaching each. No zip bytes ever reach Rails; §15/§10 untouched.
const IMAGE_EXT = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
const MODEL_EXT = ["stl", "3mf", "obj", "step", "stp"]
const roleFor = (name) => {
  const ext = name.split(".").pop().toLowerCase()
  if (IMAGE_EXT.includes(ext)) return "image"
  if (MODEL_EXT.includes(ext)) return "model"
  if (ext === "pdf") return "instructions"
  if (ext === "gcode" || ext === "gco") return "gcode"
  if (ext === "zip") return "source_archive"
  return "other"
}

export default class extends Controller {
  static targets = ["input", "title", "sourceUrl", "summary", "submit", "status"]
  static values  = { createUrl: String, beginUrl: String, finalizeUrl: String, portCreateUrl: String, portWritable: Boolean }

  // Files collected from the selection: { name, dir, blob, role }.
  files = []
  // The create-model response ({ slug, model_url, attach_url, port_writable, folder_map }), kept
  // on the instance (not a local) so a mid-loop failure can still point at the model it made.
  created = null

  async choose() {
    try {
      this.files = []
      for (const f of this.inputTarget.files) {
        if (f.name.toLowerCase().endsWith(".zip")) {
          const zip = await JSZip.loadAsync(f)
          for (const entry of Object.values(zip.files)) {
            if (entry.dir) continue
            const blob = await entry.async("blob")
            const parts = entry.name.split("/")
            const name = parts.pop()
            if (!name || name.startsWith(".")) continue
            this.files.push({ name, dir: parts.join("/"), blob: new File([blob], name), role: roleFor(name) })
          }
        } else {
          this.files.push({ name: f.name, dir: "", blob: f, role: roleFor(f.name) })
        }
      }

      // De-dupe by target path (dir/name). The same file arriving twice — a zip that also contains
      // the PDF/image you dropped alongside it, or a duplicated zip entry — would otherwise upload
      // to the same path twice and CLOBBER itself: current-state backends (share/s3) refuse an
      // overwrite with 422, which used to fail the whole import. Keep the first occurrence.
      const seen = new Set()
      this.files = this.files.filter((f) => {
        const key = `${f.dir}/${f.name}`
        if (seen.has(key)) return false
        seen.add(key)
        return true
      })

      if (!this.titleTarget.value) {
        const t = this.deriveTitle()
        if (t) this.titleTarget.value = t
      }
      this.renderSummary()
    } catch (e) {
      console.error(e)
      this.files = []
      this.renderSummary()
      this.setStatus(`Couldn't read that file: ${e.message}`)
    }
  }

  // Title from the .zip's name if one was selected, else the first MODEL file's name — never an
  // image or PDF (that's how a dropped "resize-img-5848.webp" used to become the title).
  deriveTitle() {
    const zip = [...this.inputTarget.files].find((f) => f.name.toLowerCase().endsWith(".zip"))
    const model = this.files.find((f) => f.role === "model")
    const src = (zip && zip.name) || (model && model.name) ||
                (this.inputTarget.files[0] && this.inputTarget.files[0].name) || ""
    return src.replace(/\.[^.]+$/, "").replace(/[_-]+/g, " ").trim()
  }

  renderSummary() {
    const n = (r) => this.files.filter((f) => f.role === r).length
    const other = this.files.length - n("model") - n("image") - n("instructions")
    this.summaryTarget.textContent =
      `${n("model")} model files · ${n("image")} images · ${n("instructions")} PDF` +
      (other > 0 ? ` · ${other} other` : "")
    this.submitTarget.disabled = this.files.length === 0
  }

  // The first image is the cover; else the first model file (its rendered thumbnail becomes cover).
  coverIndex() {
    const img = this.files.findIndex((f) => f.role === "image")
    return img >= 0 ? img : this.files.findIndex((f) => f.role === "model")
  }

  async submit(event) {
    event.preventDefault()
    if (this.files.length === 0) return
    this.submitTarget.disabled = true
    try {
      const dirs = [...new Set(this.files.map((f) => f.dir).filter(Boolean))]
      this.setStatus("Creating model…")
      this.created = await this.postJSON(this.createUrlValue, {
        title: this.titleTarget.value, source_url: this.sourceUrlTarget.value, dirs
      })
      const cover = this.coverIndex()
      // Per-file resilience: a single file that can't be added (e.g. a name already taken on a
      // current-state backend) is SKIPPED and reported — it must not fail the whole import when
      // every other file landed. Only if NOTHING lands do we treat the import as failed.
      const failed = []
      for (let i = 0; i < this.files.length; i++) {
        const f = this.files[i]
        const parent = this.created.folder_map[f.dir] ?? this.created.folder_map[""]
        this.setStatus(`Uploading ${f.name} (${i + 1}/${this.files.length})…`)
        try {
          const { nodeId } = this.portWritableValue
            ? await uploadPortFile(f.blob, { createUrl: this.portCreateUrlValue, parentNodeId: parent })
            : await uploadChunkFile(f.blob, { beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: parent })
          await this.postJSON(this.created.attach_url, { node_id: nodeId, cover: i === cover })
        } catch (e) {
          console.warn(`skipped ${f.name}:`, e)
          failed.push(f.name)
        }
      }
      if (failed.length === this.files.length) {
        throw new Error(`no files could be added (${failed.length} failed — they may already exist)`)
      }
      this.setStatus(failed.length ? `Done — imported ${this.files.length - failed.length}, skipped ${failed.length} (already present).` : "Done.")
      window.location.href = this.created.model_url
    } catch (e) {
      const partial = this.created?.model_url ? ` — partial import saved at ${this.created.model_url}` : ""
      this.setStatus(`Import failed: ${e.message}${partial}`)
      console.error(e); this.submitTarget.disabled = false
    }
  }

  async postJSON(url, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json",
                 "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || "" },
      body: JSON.stringify(body)
    })
    const data = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
    return data
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
