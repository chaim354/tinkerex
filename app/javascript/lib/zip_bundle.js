import JSZip from "jszip"

// A ZIP'S CONTENTS AS THE LIBRARY SHOULD RECEIVE THEM, read in the browser (§15: no zip byte
// reaches Rails). ONE READER for the two pages that unpack a zip — the Import page
// (importer_controller.js) and the top bar's Upload (lib/zip_unpack.js) — so they cannot disagree
// about what a zip holds.
//
// LISTED FIRST, INFLATED ON DEMAND. `listZipBundle` reads the archive's index and answers names and
// folders only; an entry's bytes are decompressed when its `load()` is called. The top bar asks
// "does this zip hold a model?" of EVERY zip in a selection, and most answer no (firmware, Gerbers,
// a source archive) — those are uploaded whole, so inflating them first was memory and time spent
// for nothing. `readZipBundle` is the eager form, for the Import page, which keeps every entry.
//
// Three cleanups, in this order, after `\` separators (old Windows zippers) become `/`:
//   1. CLUTTER IS DROPPED: any path segment starting with "." (macOS's `__MACOSX/._x`, `.DS_Store`,
//      a `.git/` someone zipped) and the `__MACOSX` directory itself. A dot-segment could not
//      become a folder anyway (Library::ReservedNames), so its files would land loose at the root.
//   2. ONE WRAPPER FOLDER IS REMOVED: when every entry sits under the same single top-level
//      directory, that level goes, so `widget.zip` holding `widget/…` does not unpack as
//      `widget/widget/…`.
//   3. TWO SPELLINGS OF ONE PATH ARE ONE ENTRY. JSZip's `files` map is keyed by the stored name, so
//      a name stored twice is already one entry (JSZip keeps the LAST); what reaches this is `a/b`
//      beside `/a/b`, `a//b` or `a\b` — different keys, one `dir/name` — and the first of those is
//      kept. Uploading both would hit the same path twice, and share/s3 refuse the second as a
//      clobber.
const isClutter = (path) => path.split("/").some((seg) => seg.startsWith(".") || seg === "__MACOSX")

// The extension, lower-cased and without the dot ("" for none) — Maker::FileAttachment.role_for's
// own reading (`File.extname(name).downcase.delete(".")`), so a page asking "is this a model?" and
// the server asking the same question read the same three letters.
export const extOf = (name) => {
  const dot = name.lastIndexOf(".")
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ""
}

export const isZip = (file) => file.name.toLowerCase().endsWith(".zip")

// List `file` (a File or Blob) as [{ name, dir, load }] — `dir` is "" at the zip's (unwrapped) root
// and "a/b" below it; `load()` inflates that one entry and resolves to a File carrying the entry's
// own name. Nothing is decompressed here. Throws whatever JSZip throws for a file that is not a
// readable zip; the callers decide what that means.
export async function listZipBundle(file) {
  const zip = await JSZip.loadAsync(file)
  const found = []
  for (const entry of Object.values(zip.files)) {
    const path = entry.name.replace(/\\/g, "/")
    if (entry.dir || isClutter(path)) continue
    const parts = path.split("/").filter(Boolean)
    const name = parts.pop()
    if (!name) continue
    found.push({ parts, name, entry })
  }

  const tops = new Set(found.map((f) => (f.parts.length > 0 ? f.parts[0] : null)))
  const wrapped = found.length > 0 && tops.size === 1 && !tops.has(null)

  const seen = new Set()
  const entries = []
  for (const { parts, name, entry } of found) {
    const dir = (wrapped ? parts.slice(1) : parts).join("/")
    const key = `${dir}/${name}`
    if (seen.has(key)) continue
    seen.add(key)
    entries.push({ name, dir, load: async () => new File([await entry.async("blob")], name) })
  }
  return entries
}

// The same entries with every one inflated up front: [{ name, dir, blob }]. For a caller that keeps
// the whole zip anyway (the Import page); a caller that may not should list and `load()` instead.
export async function readZipBundle(file) {
  const entries = []
  for (const { name, dir, load } of await listZipBundle(file)) entries.push({ name, dir, blob: await load() })
  return entries
}
