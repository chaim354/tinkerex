import { Controller } from "@hotwired/stimulus"
import { alertToast, failureReason, notDoneSentence, postJSON, uploadChunkFile, uploadPortFile } from "lib/chunk_upload"
import { isZip, readZipBundle } from "lib/zip_bundle"

// Import a downloaded model bundle from ONE selection. Unzips any .zip in the browser through
// lib/zip_bundle.js — the reader the top bar's Upload shares, so the two cannot disagree about what
// a zip holds (clutter, a wrapper folder, duplicates) — classifies entries by extension, then
// creates the Model (+ folder map) and uploads every entry through the existing per-backend flow,
// attaching each. No zip bytes ever reach Rails; §15/§10 untouched.
//
// THE REPORT IS READ BEFORE ANYONE LEAVES (2026-11-02, the UX audit's B7). A run that skipped files
// used to write "imported N, skipped M" into the status line and navigate to the model on the very
// next line, so nobody ever saw it. Now a clean run navigates as before; a run that skipped anything
// STAYS, says what landed in the status line (a live region, set in connect() since the view renders
// it bare), names what did not in an alert worded by lib/chunk_upload.js#notDoneSentence, and
// offers the model as a link. A failure is never printed as `e.message`.
const IMAGE_EXT = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "heic", "heif", "tif", "tiff"]
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

  connect() {
    if (this.hasStatusTarget) this.statusTarget.setAttribute("aria-live", "polite")
  }

  async choose() {
    try {
      this.files = []
      for (const f of this.inputTarget.files) {
        if (isZip(f)) {
          for (const entry of await readZipBundle(f)) this.files.push({ ...entry, role: roleFor(entry.name) })
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
      this.setStatus("That zip could not be opened; it may be damaged. Try downloading it again.")
    }
  }

  // Title from the .zip's name if one was selected, else the first MODEL file's name — never an
  // image or PDF (that's how a dropped "resize-img-5848.webp" used to become the title).
  deriveTitle() {
    const zip = [...this.inputTarget.files].find(isZip)
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
          failed.push({ name: f.name, error: e })
        }
      }
      const landed = this.files.length - failed.length
      if (failed.length === 0) {
        this.setStatus("Done.")
        window.location.href = this.created.model_url
        return
      }
      // NOTHING OR PART OF IT: either way the page stays, so the sentence can be read — and the
      // submit stays DISABLED, because the model exists now and a second press would make another.
      const lead = landed === 0 ? "None of the files could be added to the model." : `Imported ${landed} of ${this.files.length} files.`
      const sentence = notDoneSentence(failed, { verb: "added" })
      const shown = alertToast(sentence)
      this.report(`${lead}${shown ? "" : ` ${sentence}`}`, this.created.model_url)
    } catch (e) {
      // THE MODEL ITSELF WAS NOT MADE (the only throw left above is `POST models.json`), so the
      // submit comes back for another go. Its refusal is a sentence the server wrote for a maker — a
      // validation message, or "That name was just taken — try again." — and anything without one
      // is put plainly.
      console.error(e)
      const sentence = this.createFailure(e)
      this.setStatus(alertToast(sentence) ? "" : sentence)
      this.submitTarget.disabled = false
    }
  }

  // WHY `POST models.json` FAILED, as one sentence. The known conditions first, in the upload doors'
  // own words (lib/chunk_upload.js#failureReason): a 503 answers `{ error: "fetch_error" }`, a CODE,
  // which printed as "Import failed: fetch_error". Only then the server's text, and only a 422's that
  // reads as a sentence — ModelsController's validation messages and its "That name was just
  // taken — try again." — never a bare snake_case code.
  createFailure(e) {
    const known = failureReason(e)
    if (known) return `Import failed: ${known.reason}.${known.refused ? "" : " Try again in a moment."}`
    const said = e?.serverError
    if (e?.status === 422 && said && !/^[a-z0-9_]+$/.test(said)) {
      const text = `${said.charAt(0).toLowerCase()}${said.slice(1)}`
      return `Import failed: ${/[.!?]$/.test(text) ? text : `${text}.`}`
    }
    return "Import failed: the model could not be created. Try again in a moment."
  }

  // A status line with the model to go to, for a run that made the model and stays on this page.
  report(text, modelUrl) {
    if (!this.hasStatusTarget) return
    const link = document.createElement("a")
    link.href = modelUrl
    link.textContent = "Open the model"
    this.statusTarget.replaceChildren(`${text} `, link)
  }

  postJSON(url, body) { return postJSON(url, body) }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
