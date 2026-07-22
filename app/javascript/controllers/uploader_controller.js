import { Controller } from "@hotwired/stimulus"

// Browser-side upload that honors the "bytes never through Rails" invariant.
//
// Flow (matches the desktop client's Sync::Commit two-phase commit):
//   1. Hash the file in the browser with SubtleCrypto (SHA-256). For MVP we treat the
//      whole file as a SINGLE content-addressed chunk (hash = sha256(bytes)).
//   2. POST /files/begin_upload with the manifest -> server records a pending commit and
//      returns presigned PUT URLs for ONLY the missing chunks (dedup: an already-stored
//      hash gets no URL, so we skip re-uploading it).
//   3. PUT the chunk bytes straight to the presigned URL (object storage / dev blob) —
//      never through the Rails control plane.
//   4. POST /files/finalize_upload -> server verifies the bytes landed, then creates the
//      immutable version + changelog entry. Reload to show the new file.
export default class extends Controller {
  static targets = ["input", "status"]
  static values  = { beginUrl: String, finalizeUrl: String, attachUrl: String, redirectUrl: String }

  async upload() {
    const file = this.inputTarget.files[0]
    if (!file) return

    try {
      this.setStatus(`Hashing ${file.name}…`)
      const bytes = new Uint8Array(await file.arrayBuffer())
      const hash  = await this.sha256(bytes)

      // MVP: one chunk for the whole file.
      const manifest = [{ hash, offset: 0, length: bytes.length }]

      this.setStatus("Requesting upload URL…")
      const begin = await this.postJSON(this.beginUrlValue, {
        name: file.name, size: bytes.length, manifest
      })

      // Upload only the chunks the server says are missing (dedup).
      const putUrls = begin.put_urls || {}
      for (const [h, url] of Object.entries(putUrls)) {
        this.setStatus("Uploading bytes…")
        const res = await fetch(url, { method: "PUT", body: bytes })
        if (!res.ok) throw new Error(`chunk PUT failed (${res.status})`)
      }

      this.setStatus("Finalizing…")
      await this.postJSON(this.finalizeUrlValue, { commit_id: begin.commit_id })

      // Optional: attach the just-uploaded node to a project/entry, then go there. When no
      // attachUrl is set (the Files page), behavior is unchanged: reload in place.
      if (this.hasAttachUrlValue && this.attachUrlValue) {
        this.setStatus("Attaching…")
        await this.postJSON(this.attachUrlValue, { node_id: begin.node_id })
      }

      this.setStatus("Done.")
      if (this.hasRedirectUrlValue && this.redirectUrlValue) {
        window.location.href = this.redirectUrlValue
      } else {
        window.location.reload()
      }
    } catch (e) {
      this.setStatus(`Upload failed: ${e.message}`)
      console.error(e)
    } finally {
      this.inputTarget.value = ""
    }
  }

  async sha256(bytes) {
    const digest = await crypto.subtle.digest("SHA-256", bytes)
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
  }

  async postJSON(url, body) {
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": this.csrfToken()
      },
      body: JSON.stringify(body)
    })
    const data = await res.json().catch(() => ({}))
    if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
    return data
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
