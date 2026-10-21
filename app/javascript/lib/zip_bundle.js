import JSZip from "jszip"

// A ZIP'S CONTENTS AS THE LIBRARY SHOULD RECEIVE THEM, read in the browser (§15: no zip byte
// reaches Rails). ONE READER for the two pages that unpack a zip — the Import page
// (importer_controller.js) and the top bar's Upload (lib/zip_unpack.js) — so they cannot disagree
// about what a zip holds.
//
// Three cleanups, in this order:
//   1. CLUTTER IS DROPPED: any path segment starting with "." (macOS's `__MACOSX/._x`, `.DS_Store`,
//      a `.git/` someone zipped) and the `__MACOSX` directory itself. A dot-segment could not
//      become a folder anyway (Library::ReservedNames), so its files would land loose at the root.
//   2. ONE WRAPPER FOLDER IS REMOVED: when every entry sits under the same single top-level
//      directory, that level goes, so `widget.zip` holding `widget/…` does not unpack as
//      `widget/widget/…`.
//   3. DUPLICATES ARE DROPPED by `dir/name`, keeping the first — a duplicated entry would upload to
//      the same path twice, and share/s3 refuse the second as a clobber.
const isClutter = (path) => path.split("/").some((seg) => seg.startsWith(".") || seg === "__MACOSX")

// The extension, lower-cased and without the dot ("" for none) — Maker::FileAttachment.role_for's
// own reading (`File.extname(name).downcase.delete(".")`), so a page asking "is this a model?" and
// the server asking the same question read the same three letters.
export const extOf = (name) => {
  const dot = name.lastIndexOf(".")
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ""
}

export const isZip = (file) => file.name.toLowerCase().endsWith(".zip")

// Read `file` (a File or Blob) into [{ name, dir, blob }] — `dir` is "" at the zip's (unwrapped)
// root and "a/b" below it, `blob` a File carrying the entry's own name. Throws whatever JSZip throws
// for a file that is not a readable zip; the callers decide what that means.
export async function readZipBundle(file) {
  const zip = await JSZip.loadAsync(file)
  const found = []
  for (const entry of Object.values(zip.files)) {
    if (entry.dir || isClutter(entry.name)) continue
    const parts = entry.name.split("/").filter(Boolean)
    const name = parts.pop()
    if (!name) continue
    found.push({ parts, name, entry })
  }

  const tops = new Set(found.map((f) => (f.parts.length > 0 ? f.parts[0] : null)))
  const wrapped = found.length > 0 && tops.size === 1 && !tops.has(null)

  const seen = new Set()
  const entries = []
  for (const f of found) {
    const dir = (wrapped ? f.parts.slice(1) : f.parts).join("/")
    const key = `${dir}/${f.name}`
    if (seen.has(key)) continue
    seen.add(key)
    const blob = await f.entry.async("blob")
    entries.push({ name: f.name, dir, blob: new File([blob], f.name) })
  }
  return entries
}
