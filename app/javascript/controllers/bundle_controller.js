import { Controller } from "@hotwired/stimulus"
import JSZip from "jszip"

// THE BUNDLE IS BUILT HERE, IN THE VISITOR'S BROWSER, from the same public file route the page
// links — never by Rails zipping bytes (CLAUDE.md §15; on s3 that route REDIRECTS to the store, so
// a server-side zip would pull every byte through the app just to hand it straight back out).
// Sequential fetches, so a folder of large STLs does not open a hundred connections at once; a
// failed fetch stops the build and NAMES THE FILE, which on the s3 deployment is the CSP follow-up
// S3-2 recorded (`default-src 'self'` with no `connect-src` blocks the presigned redirect).
export default class extends Controller {
  static targets = ["status"]
  static values = { manifest: String, name: String }
  // A CEILING ON WHAT A TAB WILL SURVIVE, not on what the project may hold. JSZip assembles the
  // whole archive in memory, so a 4 GB folder does not fail slowly — it takes the tab down, with
  // no message. Saying so before the first fetch is the honest answer; the files are still there
  // one at a time.
  static MAX_BYTES = 500 * 1024 * 1024

  async build(event) {
    event.preventDefault()
    // Captured synchronously: `event.currentTarget` is null once this function has awaited
    // anything, so reading it in the `finally` below would throw instead of re-enabling.
    const button = event.currentTarget
    button.disabled = true
    try {
      const manifest = await (await fetch(this.manifestValue, { headers: { Accept: "application/json" } })).json()
      const total = manifest.files.reduce((n, f) => n + (f.size || 0), 0)
      if (total > this.constructor.MAX_BYTES) {
        this.say(`Too large to bundle in the browser (${this.mb(total)} MB).`)
        return
      }
      const zip = new JSZip()
      let done = 0
      for (const file of manifest.files) {
        this.say(`Fetching ${++done} of ${manifest.files.length}: ${file.path}`)
        const res = await fetch(file.url)
        if (!res.ok) throw new Error(`${file.path}: ${res.status}`)
        zip.file(file.path, await res.blob())
      }
      // BEST-EFFORT, UNLIKE THE FILES ABOVE: a project with no BOM still bundles, and a bom.csv
      // that failed to fetch is not worth discarding a hundred megabytes of models over.
      const bom = await fetch(manifest.bom_csv_url)
      if (bom.ok) zip.file("bom.csv", await bom.blob())
      this.say("Compressing…")
      const blob = await zip.generateAsync({ type: "blob" })
      const a = document.createElement("a")
      a.href = URL.createObjectURL(blob)
      a.download = `${this.nameValue}-bundle.zip`
      a.click()
      // The blob is the whole archive; revoking frees it. Not immediately — the download has to
      // start reading from the URL first.
      setTimeout(() => URL.revokeObjectURL(a.href), 60_000)
      this.say(`Bundled ${manifest.files.length} files (${this.human(blob.size)}).`)
    } catch (e) {
      this.say(`Could not build the bundle — ${e.message}. Files can still be downloaded one at a time.`)
    } finally {
      button.disabled = false
    }
  }

  say(text) { this.statusTarget.textContent = text }
  mb(bytes) { return (bytes / 1048576).toFixed(1) }
  // A 28 KB zip read as "0.0 MB" on the dev server; say the unit the number deserves.
  human(bytes) {
    if (bytes >= 1048576) return `${this.mb(bytes)} MB`
    if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KB`
    return `${bytes} bytes`
  }
}
