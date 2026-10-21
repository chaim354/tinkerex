import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile } from "lib/chunk_upload"
import { isZip, reportAndLand, splitSelection, uploadSplit } from "lib/zip_unpack"

// Browser-side upload (chunk two-phase). Thin wrapper over lib/chunk_upload so the importer and
// this control share one implementation.
//
// ACCEPTS A SELECTION, NOT A FILE (slice 0, 2026-09-10). It read `files[0]` and ignored the rest,
// so a maker with a dozen project files opened the picker a dozen times. The share/s3 branch of
// the same two controls posts a batch in one multipart request; this is the chunk branch's half.
//
// SEQUENTIAL, AND ONE FILE'S FAILURE DOES NOT ABANDON THE REST — the same rule the server-side
// UploadBatch follows. Parallel uploads would race the port's clobber check, which is a
// head-then-put CHECK and not a lock (CLAUDE.md §14a), so two same-named files in one selection
// could silently overwrite instead of the second losing with a message. The page reloads ONCE at
// the end rather than per file, so a batch is one navigation.
export default class extends Controller {
  static targets = ["input", "status"]
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String,
                     unpackUrl: String, unpackedUrl: String, modelExts: Array }

  async upload() {
    // ONE ZIP RUN AT A TIME: a selection made while one is being read or unpacked is ignored, not
    // raced against it — the port's clobber check is not a lock (see the header), and the run's
    // navigation would cut the second off part-way.
    if (this.busy) return
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    try {
      // THE TOP BAR UNPACKS A MODEL ZIP (2026-10-21; spec docs/superpowers/specs/
      // 2026-10-20-zip-upload-unpacks-models-design.md). Only where the view passed the unpack doors
      // — the top bar does, the build log's "Upload & attach" does not — and only for a selection
      // holding a .zip, so every other upload takes the loop below exactly as before.
      // NEVER WITH AN ATTACH URL: the unpack skips postAttach and redirectUrl, which that control needs.
      if (this.unpackUrlValue && !this.attachUrlValue && files.some(isZip)) {
        this.busy = true
        if (await this.unpack(files)) return
      }
      await this.uploadEach(files)
    } finally {
      this.busy = false
      this.inputTarget.value = ""
    }
  }

  // True when the selection was unpacked; false sends it to uploadEach as it is — no model zip in
  // it, or A READER FAILURE, which must never block an ordinary upload.
  async unpack(files) {
    this.setStatus("Reading…")
    let split
    try {
      split = await splitSelection(files, this.modelExtsValue)
    } catch (e) {
      console.warn("could not read the selection's zips; uploading it as it is:", e)
      return false
    }
    if (split.zips.length === 0) return false

    const out = await uploadSplit(split, {
      parentNodeId: this.parentNodeIdValue,
      unpackUrl: this.unpackUrlValue,
      unpackedUrl: this.unpackedUrlValue,
      upload: (file, parentNodeId) => uploadChunkFile(file, {
        beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId
      }),
      setStatus: (text) => this.setStatus(text)
    })
    reportAndLand(out, (text) => this.setStatus(text))
    return true
  }

  async uploadEach(files) {
    const failed = []
    let done = 0
    for (const file of files) {
      const progress = files.length > 1 ? ` (${done + 1} of ${files.length})` : ""
      try {
        this.setStatus(`Uploading ${file.name}…${progress}`)
        const { nodeId } = await uploadChunkFile(file, {
          beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: this.parentNodeIdValue
        })
        if (this.hasAttachUrlValue && this.attachUrlValue) {
          this.setStatus(`Attaching ${file.name}…${progress}`)
          await this.postAttach(nodeId)
        }
        done += 1
      } catch (e) {
        // Recorded and carried past, not rethrown: losing files 4 and 5 because file 3 hit a
        // name that was already taken is the failure this loop exists to avoid.
        failed.push(`${file.name} (${e.message})`); console.error(e)
      }
    }

    if (done === 0) {
      this.setStatus(`Upload failed: ${failed.join(", ")}`)
      return
    }
    this.setStatus(failed.length ? `Uploaded ${done}; failed: ${failed.join(", ")}` : "Done.")
    if (this.hasRedirectUrlValue && this.redirectUrlValue) window.location.href = this.redirectUrlValue
    else window.location.reload()
  }

  async postAttach(nodeId) {
    // "Accept": "application/json" is load-bearing, not decoration: Projects::AttachmentsController
    // and Projects::EntryPhotosController both `respond_to { |f| f.html {...}; f.json {...} }` with
    // html registered FIRST, so a request with no Accept header (fetch's default) gets a 302 HTML
    // redirect instead of JSON. fetch() follows that redirect by default, silently GETting the
    // target page — which reads (and thereby discards) the flash notice the redirect just set, so
    // the real navigation below shows no "Attached ..." message. The res.ok check matches the
    // pre-refactor postJSON behavior: a failed attach (e.g. 404 not_found) must throw here, or this
    // method would swallow it and the caller would report "Done." for an attach that never happened.
    const res = await fetch(this.attachUrlValue, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content || ""
      },
      body: JSON.stringify({ node_id: nodeId })
    })
    if (!res.ok) throw new Error(`attach failed (${res.status})`)
  }

  setStatus(text) { if (this.hasStatusTarget) this.statusTarget.textContent = text }
}
