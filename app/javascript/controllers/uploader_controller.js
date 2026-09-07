import { Controller } from "@hotwired/stimulus"
import { uploadChunkFile } from "lib/chunk_upload"

// Browser-side single-file upload (chunk two-phase). Thin wrapper over lib/chunk_upload so the
// importer and this control share one implementation.
export default class extends Controller {
  static targets = ["input", "status"]
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String, parentNodeId: String }

  async upload() {
    const file = this.inputTarget.files[0]
    if (!file) return
    try {
      this.setStatus(`Uploading ${file.name}…`)
      const { nodeId } = await uploadChunkFile(file, {
        beginUrl: this.beginUrlValue, finalizeUrl: this.finalizeUrlValue, parentNodeId: this.parentNodeIdValue
      })
      if (this.hasAttachUrlValue && this.attachUrlValue) {
        this.setStatus("Attaching…")
        await this.postAttach(nodeId)
      }
      this.setStatus("Done.")
      if (this.hasRedirectUrlValue && this.redirectUrlValue) window.location.href = this.redirectUrlValue
      else window.location.reload()
    } catch (e) {
      this.setStatus(`Upload failed: ${e.message}`); console.error(e)
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
