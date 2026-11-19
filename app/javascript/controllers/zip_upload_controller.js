import { Controller } from "@hotwired/stimulus"
import { uploadPortFile } from "lib/chunk_upload"
import { isZip, reportAndLand, splitSelection, uploadSplit } from "lib/zip_unpack"

// THE SHARE/S3 TOP-BAR UPLOAD (layouts/_topbar_upload.html.erb), WHICH UNPACKS A MODEL ZIP
// (2026-10-21; spec docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md).
//
// THE FORM IS STILL THE DOOR for every selection without a model zip: `change` submits it exactly
// as the inline `onchange="this.form.requestSubmit()"` it replaced did — one multipart POST to
// FilesController#create, its batch notice, project intake filing a plain zip into archives/. Only
// a selection holding a zip with a model-role entry is taken over: unpacked in the browser through
// lib/zip_unpack.js, every file — the zip's entries and the rest of the selection — sent through the
// JSON door (uploadPortFile) one at a time.
//
// A SELECTION WITH NO .zip NEVER REACHES JSZip, so the ordinary upload pays nothing for this.
//
// ONE RUN AT A TIME: a second selection made while a zip is being read or unpacked is ignored, not
// raced against the first — the per-file doors' clobber check is a check, not a lock (CLAUDE.md
// §14a), and the first run's navigation would cut the second off part-way.
//
// THE FORM PATH SAYS IT IS WORKING (2026-11-02, the UX audit's B8). It is a plain browser POST
// (`turbo: false`) that holds the page until the server answers, and for a large selection over a
// slow link that is many seconds of an unchanged page — only the presigned flow said "Uploading x…".
// The line is set just before the submit and lives until the next page replaces it; the status span
// is a live region (set here, since the view renders it bare), so it is announced as well as drawn.
//
// A FORM WITH NO UNPACK DOOR ONLY SUBMITS. A mount that passes no `unpack-url` (an upload-and-attach
// form, whose server attaches what it receives and must get the zip as it is) still gets the
// "Uploading…" line and the live region, and never reaches JSZip or the per-file JSON door.
export default class extends Controller {
  static targets = ["input", "parent", "status"]
  static values = { createUrl: String, unpackUrl: String, unpackedUrl: String, modelExts: Array }

  connect() {
    if (this.hasStatusTarget) this.statusTarget.setAttribute("aria-live", "polite")
  }

  async change() {
    if (this.busy) return
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    if (!this.unpackUrlValue || !files.some(isZip)) return this.submit(files)

    this.busy = true
    let unpacking = false
    try {
      this.setStatus("Reading…")
      const split = await this.sortSelection(files)
      if (!split || split.zips.length === 0) return this.submit(files)

      // The input is cleared only on THIS path: the form path above posts the input's own files.
      unpacking = true
      const out = await uploadSplit(split, {
        parentNodeId: this.parentTarget.value,
        unpackUrl: this.unpackUrlValue,
        unpackedUrl: this.unpackedUrlValue,
        upload: (file, parentNodeId) => uploadPortFile(file, { createUrl: this.createUrlValue, parentNodeId }),
        setStatus: (text) => this.setStatus(text)
      })
      reportAndLand(out, (text) => this.setStatus(text))
    } finally {
      this.busy = false
      if (unpacking) this.inputTarget.value = ""
    }
  }

  // A READER FAILURE NEVER BLOCKS AN ORDINARY UPLOAD: null sends the selection through the form as
  // it is, exactly as it went before this controller existed.
  async sortSelection(files) {
    try {
      return await splitSelection(files, this.modelExtsValue)
    } catch (e) {
      console.warn("could not read the selection's zips; uploading it as it is:", e)
      return null
    }
  }

  // The form's own POST, with the line that says so. `requestSubmit`, as the inline `onchange` this
  // controller replaced used — never `submit()`, which skips the form's validation and its events.
  submit(files) {
    this.setStatus(files.length === 1 ? `Uploading ${files[0].name}…` : `Uploading ${files.length} files…`)
    this.element.requestSubmit()
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
