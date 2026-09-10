import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile } from "lib/chunk_upload"

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
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String }

  async upload() {
    const files = Array.from(this.inputTarget.files || [])
    if (files.length === 0) return
    const failed = []
    let done = 0
    try {
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
    } finally {
      this.inputTarget.value = ""
    }
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
