// One file -> a committed library node_id, via the two-phase presigned flow (bytes go
// browser -> storage, never through Rails; §15). Extracted from uploader_controller so the
// importer and the single-file uploader share exactly one implementation.
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content || ""
}

// EXPORTED SINCE STAGE 4, S4-8, so a caller that must POST one more JSON request alongside an
// upload reuses this CSRF header and this error-body reading rather than writing a second `fetch`
// with its own spelling of both. Its FIRST such caller is measure_controller.js#recordSources,
// which records where a saved export came from; the two upload doors below are unchanged.
export async function postJSON(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body)
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
  return data
}

// Upload a File/Blob (with a name) into parentNodeId. Returns { nodeId, notice } — the notice is
// the server's own sentence about what the project-folder sweep then did with it, or null. BOTH
// DOORS ANSWER THE SAME SHAPE (stage 4, S4-3): Save-to-library reads it, and a caller that only
// wants the id destructures the id. A door that answered a bare id here and an object there is the
// one-condition-two-answers divergence §14a forbids, one layer up.
export async function uploadChunkFile(file, { beginUrl, finalizeUrl, parentNodeId }) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const hash = await sha256Hex(bytes)
  const manifest = [{ hash, offset: 0, length: bytes.length }]
  const begin = await postJSON(beginUrl, { name: file.name, size: bytes.length, manifest, parent_node_id: parentNodeId || null })
  for (const [, url] of Object.entries(begin.put_urls || {})) {
    const res = await fetch(url, { method: "PUT", body: bytes })
    if (!res.ok) throw new Error(`chunk PUT failed (${res.status})`)
  }
  const final = await postJSON(finalizeUrl, { commit_id: begin.commit_id })
  return { nodeId: begin.node_id, notice: final.notice || null }
}

// Upload via the share/s3 multipart door (FilesController#create). Returns { nodeId, notice }.
export async function uploadPortFile(file, { createUrl, parentNodeId }) {
  const form = new FormData()
  form.append("file", file, file.name)
  if (parentNodeId) form.append("parent_node_id", parentNodeId)
  const res = await fetch(createUrl, {
    method: "POST", headers: { "Accept": "application/json", "X-CSRF-Token": csrfToken() }, body: form
  })
  const data = await res.json().catch(() => ({}))
  // THE SERVER'S OWN REFUSAL, NOT A STATUS CODE (stage 4, S4-3). A name already taken at the
  // destination is FileLayer::UnsupportedOperation, which FilesController maps to 422 with
  // `{ error: "…" }` — "plate-parts.svg already exists" is actionable and "upload failed (422)"
  // is not. `postJSON` above has always read the body this way; this door did not, so the two
  // doors gave a user two different answers to one condition.
  if (!res.ok) throw new Error(data.error || `upload failed (${res.status})`)
  if (!data.node_id) throw new Error("upload did not return a node id")
  return { nodeId: data.node_id, notice: data.notice || null }
}
