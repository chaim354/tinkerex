// One file -> a committed library node_id, via the two-phase presigned flow (bytes go
// browser -> storage, never through Rails; §15). Extracted from uploader_controller so the
// importer and the single-file uploader share exactly one implementation.
export async function sha256Hex(bytes) {
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("")
}

// A REQUEST THAT DID NOT LAND, AND WHAT THE SERVER SAID ABOUT IT. `message` is exactly what these
// doors threw before (the server's sentence, or a status line), so every reader of `e.message` —
// measure_controller.js's readout among them — reads what it always read. `status` and `serverError`
// are what `failureReason` below reads, so the upload doors can say WHY in a maker's words instead
// of printing the message.
export class RequestError extends Error {
  constructor(message, { status = 0, serverError = null } = {}) {
    super(message)
    this.name = "RequestError"
    this.status = status
    this.serverError = serverError ?? null
  }
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
  if (!res.ok) throw new RequestError(data.error || `request failed (${res.status})`, { status: res.status, serverError: data.error })
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
    if (!res.ok) throw new RequestError(`chunk PUT failed (${res.status})`, { status: res.status })
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
  if (!res.ok) throw new RequestError(data.error || `upload failed (${res.status})`, { status: res.status, serverError: data.error })
  if (!data.node_id) throw new RequestError("upload did not return a node id", { status: res.status })
  return { nodeId: data.node_id, notice: data.notice || null }
}

// --- Saying what did not land (2026-11-02, the UX audit's B8) ---------------------------------
//
// A failed upload used to print `e.message` in the status line's 12px muted text — "chunk PUT failed
// (403)", "\"plate.svg\" already exists in that folder", or a browser's "Failed to fetch". Each
// upload door now says it as a sentence, in the app's alert, and these are the one wording.

// WHY ONE FILE DID NOT LAND — { refused, reason } — or null when nothing more specific than "it
// failed" is known. `refused` separates the server saying no (try a different name) from the trip
// failing (try again).
//
// THE CLOBBER IS RECOGNISED BY ITS SENTENCE, because the 422 carries no code: every adapter words it
// "… already exists" (FileLayer::Share/S3#write, ChunkRemote#destination_vacant!), and that is the
// one refusal a maker meets in ordinary use. Anything else the server refuses with is answered by the
// generic line rather than printed — its 422s and 404s are adapter wording ("is not a leaf name",
// "is a reserved path …"), not sentences written for a person.
export function failureReason(error) {
  const said = String(error?.serverError ?? "")
  if (/already exists/i.test(said)) return { refused: true, reason: "the folder already has a file with that name" }
  if (/is not a valid file name/i.test(said)) return { refused: true, reason: "that name cannot be used in the library" }
  if (error?.status === 413) return { refused: true, reason: "it is larger than this server accepts" }
  if (said === "fetch_error" || error?.status === 503) return { refused: false, reason: "the library could not be reached" }
  if (error?.name === "NotReadableError") return { refused: false, reason: "this computer would not let the page read it" }
  if (error instanceof TypeError) return { refused: false, reason: "the connection to the server was lost" }
  return null
}

// `failures` is [{ name, error }] — or [{ name, why }] where the caller already knows the reason in
// words (lib/zip_unpack.js: "nothing in it could be unpacked"); `landed` is how many files of the
// same run DID land. One file that failed alone on a request gets "Upload failed: NAME was refused —
// REASON."; anything else gets "Upload failed." (when nothing landed) and the batch line below.
export function uploadFailureSentence(failures, { landed = 0 } = {}) {
  if (failures.length === 0) return null
  if (landed === 0 && failures.length === 1 && !failures[0].why) {
    const { name, error } = failures[0]
    const why = failureReason(error)
    if (!why) return "Upload failed; try again."
    return why.refused ? `Upload failed: ${name} was refused — ${why.reason}.`
      : `Upload failed: ${name} did not arrive — ${why.reason}. Try again.`
  }
  return `${landed === 0 ? "Upload failed. " : ""}${notDoneSentence(failures)}`
}

// THE SERVER'S OWN BATCH WORDING (ProjectFolderIntake#refused_sentence: "These were not uploaded:
// a (why) and b."), so the share/s3 form and the JS doors say a partial batch one way. `verb` is
// the importer's ("added"), whose files are uploaded AND attached.
export function notDoneSentence(failures, { verb = "uploaded" } = {}) {
  const named = failures.map(({ name, error, why }) => {
    const reason = why || failureReason(error)?.reason
    return reason ? `${name} (${reason})` : name
  })
  const shown = named.slice(0, 3)
  const rest = named.length - shown.length
  const list = rest > 0 ? `${shown.join(", ")} and ${rest} more` : toSentence(shown)
  return `${failures.length === 1 ? `This one was not ${verb}` : `These were not ${verb}`}: ${list}.`
}

function toSentence(items) {
  return items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`
}

// AN ALERT IN THE FLASH STACK, BUILT TO layouts/_flash.html.erb's MARKUP so toast_controller.js
// treats it as one of its own: `role="alert"`, the dismiss button wired to `toast#dismiss`, and an
// alert stays until dismissed (only a notice times out). The stack is the one place a message
// floats (design-system.md rule 10). False when the page has no stack, so the caller can fall back
// to its own status line.
export function alertToast(text) {
  const stack = document.querySelector(".flash-stack")
  if (!stack) return false
  const item = document.createElement("div")
  item.className = "flash flash-alert"
  item.setAttribute("role", "alert")
  item.dataset.toastTarget = "item"
  const words = document.createElement("span")
  words.className = "flash-text"
  words.textContent = text
  const close = document.createElement("button")
  close.type = "button"
  close.className = "flash-close"
  close.setAttribute("aria-label", "Dismiss")
  close.dataset.action = "toast#dismiss"
  close.textContent = "\u00d7"
  item.append(words, close)
  stack.append(item)
  return true
}
