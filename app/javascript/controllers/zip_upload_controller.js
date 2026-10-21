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
export default class extends Controller {
  static targets = ["input", "parent", "status"]
  static values = { createUrl: String, unpackUrl: String, unpackedUrl: String, modelExts: Array }

  async change() {
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    if (!files.some(isZip)) return this.element.requestSubmit()

    this.setStatus("Reading…")
    const split = await splitSelection(files, this.modelExtsValue)
    if (split.zips.length === 0) {
      this.setStatus("")
      return this.element.requestSubmit()
    }

    try {
      const out = await uploadSplit(split, {
        parentNodeId: this.parentTarget.value,
        unpackUrl: this.unpackUrlValue,
        unpackedUrl: this.unpackedUrlValue,
        upload: (file, parentNodeId) => uploadPortFile(file, { createUrl: this.createUrlValue, parentNodeId }),
        setStatus: (text) => this.setStatus(text)
      })
      reportAndLand(out, (text) => this.setStatus(text))
    } finally {
      this.inputTarget.value = ""
    }
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
