import { postJSON } from "lib/chunk_upload"
import { extOf, isZip, listZipBundle } from "lib/zip_bundle"

// THE TOP BAR'S UPLOAD WHEN THE SELECTION HOLDS A MODEL ZIP (2026-10-21; spec
// docs/superpowers/specs/2026-10-20-zip-upload-unpacks-models-design.md). Shared by both upload
// flows — zip_upload_controller.js (share/s3) and uploader_controller.js (chunk_remote) — which
// differ only in the per-file door, passed in as `upload(file, parentNodeId)` resolving to
// { nodeId } or throwing.
//
// NOTHING IS INFLATED TO DECIDE. A zip is LISTED (lib/zip_bundle.js#listZipBundle) and judged by
// its entry names alone, so a firmware or Gerber zip that holds no model is uploaded whole without
// ever being decompressed in the page. A model zip is then inflated ONE ENTRY AT A TIME, each just
// before its own upload, so the page never holds a whole unpacked archive in memory.

export { isZip }

// Sort a selection into MODEL ZIPS (unpacked) and everything else (uploaded as it is). Each .zip is
// listed once, never inflated here. "Model" is the server's vocabulary — `modelExts` is
// Maker::FileAttachment::MODEL_EXTS, rendered into the page — never a list kept here. A zip JSZip
// cannot open is "everything else": it uploads as a file, exactly as it did before this existed,
// and its name is reported.
export async function splitSelection(files, modelExts) {
  const zips = []
  const rest = []
  const unreadable = []
  for (const file of files) {
    if (!isZip(file)) { rest.push(file); continue }
    let entries
    try {
      entries = await listZipBundle(file)
    } catch (e) {
      console.warn(`could not open ${file.name}:`, e)
      unreadable.push(file.name)
      rest.push(file)
      continue
    }
    const firstModel = entries.find((e) => modelExts.includes(extOf(e.name)))
    if (firstModel) zips.push({ file, entries })
    else rest.push(file)
  }
  return { zips, rest, unreadable }
}

// Unpack ONE model zip: the folder map from the server, every entry inflated (`load()`) and sent
// through `upload` one at a time, then the catalog nudge. The inflate is INSIDE the per-entry try:
// a failed entry — an unreadable member as much as a refused name — is recorded as `dir/name` (two
// `readme.txt` in different folders must stay two lines) and passed over, the importer's rule: one
// bad entry must not lose the other seventeen. THROWS only when the folder itself could not be made.
async function unpackZip({ file, entries }, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus }) {
  const made = await postJSON(unpackUrl, {
    parent_node_id: parentNodeId || null,
    name: file.name.replace(/\.zip$/i, ""),
    dirs: [...new Set(entries.map((e) => e.dir).filter(Boolean))]
  })
  const failed = []
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i]
    const path = entry.dir ? `${entry.dir}/${entry.name}` : entry.name
    setStatus(`Unpacking ${file.name} — ${i + 1}/${entries.length}`)
    try {
      const blob = await entry.load()
      await upload(blob, made.folder_map[entry.dir] ?? made.folder_map[""])
    } catch (e) {
      console.warn(`skipped ${path}:`, e)
      failed.push(path)
    }
  }
  const landed = entries.length - failed.length
  // BEST-EFFORT: the 15-minute sweep catalogues the folder anyway, so a lost nudge only delays the
  // model card. Never thrown — the files are already in the library by now.
  if (landed > 0) {
    try {
      await postJSON(unpackedUrl, { folder_node_id: made.folder_node_id })
    } catch (e) {
      console.warn("catalog nudge failed:", e)
    }
  }
  return { folderUrl: made.folder_url, landed, failed }
}

// Unpack every model zip in `split`, then upload the rest one at a time — SEQUENTIAL, for
// uploader_controller.js's reason: parallel uploads race the port's clobber check. `landing` is the
// one folder to open, set only when the selection was ONE model zip and nothing else — the only
// case with a single obvious place to go.
export async function uploadSplit(split, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus }) {
  const unpacked = []
  const failed = []
  for (const zip of split.zips) {
    try {
      const r = await unpackZip(zip, { parentNodeId, unpackUrl, unpackedUrl, upload, setStatus })
      if (r.landed > 0) {
        unpacked.push({ name: zip.file.name, folderUrl: r.folderUrl })
        failed.push(...r.failed.map((name) => `${name} (in ${zip.file.name})`))
      } else {
        failed.push(`${zip.file.name} (nothing could be unpacked)`)
      }
    } catch (e) {
      console.error(e)
      failed.push(`${zip.file.name} (${e.message})`)
    }
  }

  let uploaded = 0
  const restFailed = new Set()
  for (let i = 0; i < split.rest.length; i++) {
    const file = split.rest[i]
    setStatus(`Uploading ${file.name}…${split.rest.length > 1 ? ` (${i + 1} of ${split.rest.length})` : ""}`)
    try {
      await upload(file, parentNodeId)
      uploaded += 1
    } catch (e) {
      console.error(e)
      restFailed.add(file.name)
      failed.push(`${file.name} (${e.message})`)
    }
  }

  const landing = split.zips.length === 1 && split.rest.length === 0 && unpacked.length === 1
    ? unpacked[0].folderUrl : null
  // `unreadable` NAMES ONLY THE ZIPS THAT THEN UPLOADED AS THEY ARE. One whose own upload failed is
  // already in `failed`, with the reason; listing it in both would report it uploaded and not.
  const unreadable = split.unreadable.filter((name) => !restFailed.has(name))
  return { unpacked, uploaded, failed, unreadable, landing }
}

// The end of a run, the same for both flows. ANYTHING THAT WENT WRONG STAYS ON SCREEN — a reload
// would wipe the one line that says what failed. A clean run navigates: to the unpacked folder, or
// a reload of this page so the new files show.
export function reportAndLand(out, setStatus) {
  if (out.unpacked.length === 0 && out.uploaded === 0) {
    setStatus(out.failed.length > 0 ? `Upload failed: ${out.failed.join(", ")}` : "Nothing was uploaded.")
    return
  }
  if (out.failed.length > 0 || out.unreadable.length > 0) {
    const parts = []
    if (out.unpacked.length > 0) parts.push(`unpacked ${out.unpacked.map((u) => u.name).join(", ")}`)
    if (out.uploaded > 0) parts.push(`uploaded ${out.uploaded} ${out.uploaded === 1 ? "file" : "files"}`)
    if (out.unreadable.length > 0) {
      const asIs = out.unreadable.length === 1 ? "it as it is" : "them as they are"
      parts.push(`couldn't open ${out.unreadable.join(", ")}, so uploaded ${asIs}`)
    }
    if (out.failed.length > 0) parts.push(`failed: ${out.failed.join(", ")}`)
    const line = parts.join("; ")
    setStatus(`${line.charAt(0).toUpperCase()}${line.slice(1)}. Reload to see them.`)
    return
  }
  setStatus("Done.")
  if (out.landing) window.location.href = out.landing
  else window.location.reload()
}
