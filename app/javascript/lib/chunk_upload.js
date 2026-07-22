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

async function postJSON(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body)
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(data.error || `request failed (${res.status})`)
  return data
}

// Upload a File/Blob (with a name) into parentNodeId. Returns the new node_id.
export async function uploadChunkFile(file, { beginUrl, finalizeUrl, parentNodeId }) {
  const bytes = new Uint8Array(await file.arrayBuffer())
  const hash = await sha256Hex(bytes)
  const manifest = [{ hash, offset: 0, length: bytes.length }]
  const begin = await postJSON(beginUrl, { name: file.name, size: bytes.length, manifest, parent_node_id: parentNodeId || null })
  for (const [, url] of Object.entries(begin.put_urls || {})) {
    const res = await fetch(url, { method: "PUT", body: bytes })
    if (!res.ok) throw new Error(`chunk PUT failed (${res.status})`)
  }
  await postJSON(finalizeUrl, { commit_id: begin.commit_id })
  return begin.node_id
}

// Upload via the share/s3 multipart door (FilesController#create). Returns the new node_id.
export async function uploadPortFile(file, { createUrl, parentNodeId }) {
  const form = new FormData()
  form.append("file", file, file.name)
  if (parentNodeId) form.append("parent_node_id", parentNodeId)
  const res = await fetch(createUrl, {
    method: "POST", headers: { "Accept": "application/json", "X-CSRF-Token": csrfToken() }, body: form
  })
  if (!res.ok) throw new Error(`upload failed (${res.status})`)
  const data = await res.json().catch(() => ({}))
  if (!data.node_id) throw new Error("upload did not return a node id")
  return data.node_id
}
