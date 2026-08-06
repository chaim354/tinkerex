// The folder/file chooser itself — a native-OS-style Miller-columns modal, built on demand and
// appended to <body>. Data comes from a session-authed JSON endpoint (LibraryBrowseController).
//
// PLAIN MODULE, NOT A STIMULUS CONTROLLER, AND THAT IS THE WHOLE POINT OF THE SPLIT. This has two
// callers that cannot share a base class: filechooser_controller.js (a form field on a
// server-rendered page) and addon_controller.js, which hands `ctx.chooseFolder` to an addon BUNDLE.
// A bundle is not a Stimulus controller and must not have to know the host's JS framework
// (addon_controller.js's own header states that contract), so the modal has to be callable as an
// ordinary function. Putting it here rather than importing the controller into the context also
// keeps the addon contract a FUNCTION rather than a module path: bundles never learn the host's
// module layout, so this file can move without a bundle republish.
//
//   mode "folder": pick a destination folder. Descending a folder selects it; the root is always a
//                  valid selection; files are not shown. Footer verb "Choose".
//   mode "file":   pick an existing file. Folders navigate; a file click is the selection. "Open".
export const ROOT_LABEL = "/ (library root)"

export class FileChooser {
  // `label` is the CURRENT selection's path, not decoration — see the note in #open.
  constructor({ mode = "folder", childrenUrl, createUrl, rootLabel = ROOT_LABEL, value = "", label = null } = {}) {
    this.mode = mode
    this.childrenUrl = childrenUrl
    this.createUrl = createUrl
    this.rootLabel = rootLabel
    this.value = value || ""
    this.label = label
    this.cache = {}       // parentId ("" = root) -> entries array
    this.trail = []       // folders descended into (root implicit); each { id, name }
    this.selection = null // { nodeId, kind, path } or null
  }

  // -> Promise<{nodeId, kind, path} | null>. null means the user cancelled (Esc, backdrop, Cancel,
  // the ✕, or the caller calling close()) — a distinct answer from "chose the root", which resolves
  // with nodeId "". A caller that treats cancel as root silently moves the destination on Esc.
  open() {
    this.previouslyFocused = document.activeElement
    // THE SEEDED PATH IS `label`, NOT rootLabel, and the difference is a defect this split fixed.
    // Seeding it with rootLabel while nodeId held a real folder made the two halves of the
    // selection disagree from the first frame: open a field already pointing at /Projects/harbor,
    // press Choose without navigating, and #choose writes nodeId (harbor, unchanged) to the input
    // while the button label becomes "/ (library root)". The form then submits harbor under a label
    // saying root — visibly wrong, and wrong in the direction that looks like it worked.
    this.selection = this.mode === "folder"
      ? { nodeId: this.value, kind: "dir", path: this.label || this.rootLabel }
      : null
    this.buildModal()
    this.render().then(() => this.overlay?.querySelector(".filechooser").focus())
    return new Promise((resolve) => { this.resolve = resolve })
  }

  // Idempotent: `settle` is nulled on the first call, so a Cancel click that also bubbles to the
  // backdrop, or a caller closing an already-closed chooser, cannot resolve the promise twice.
  settle(value) {
    const resolve = this.resolve
    this.resolve = null
    if (this.overlay) { this.overlay.remove(); this.overlay = null }
    if (this.onKeydown) { document.removeEventListener("keydown", this.onKeydown); this.onKeydown = null }
    if (this.previouslyFocused && this.previouslyFocused.focus) this.previouslyFocused.focus()
    if (resolve) resolve(value)
  }

  close() { this.settle(null) }

  buildModal() {
    this.onKeydown = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKeydown)

    const verb = this.mode === "file" ? "a file" : "a destination folder"
    this.overlay = document.createElement("div")
    this.overlay.className = "filechooser-overlay"
    this.overlay.innerHTML = `
      <div class="filechooser" role="dialog" aria-modal="true" aria-label="Choose ${verb}" tabindex="-1">
        <div class="filechooser-head"><span>Choose ${verb}</span>
          <button type="button" class="filechooser-close" aria-label="Close">✕</button></div>
        <div class="filechooser-crumbs"></div>
        <div class="filechooser-cols"></div>
        <div class="filechooser-foot">
          <div class="filechooser-newwrap"><button type="button" class="btn ghost filechooser-new">＋ New Folder</button></div>
          <div class="filechooser-actions">
            <button type="button" class="btn ghost filechooser-back" aria-label="Back">← Back</button>
            <span class="filechooser-sel"></span>
            <button type="button" class="btn ghost filechooser-cancel">Cancel</button>
            <button type="button" class="btn filechooser-choose">Choose</button>
          </div>
        </div>
      </div>`
    document.body.appendChild(this.overlay)

    this.colsEl = this.overlay.querySelector(".filechooser-cols")
    this.crumbsEl = this.overlay.querySelector(".filechooser-crumbs")
    this.selEl = this.overlay.querySelector(".filechooser-sel")
    this.chooseBtn = this.overlay.querySelector(".filechooser-choose")
    this.newWrap = this.overlay.querySelector(".filechooser-newwrap")

    this.overlay.addEventListener("click", (e) => { if (e.target === this.overlay) this.close() })
    this.overlay.querySelector(".filechooser-close").addEventListener("click", () => this.close())
    this.overlay.querySelector(".filechooser-cancel").addEventListener("click", () => this.close())
    this.overlay.querySelector(".filechooser-back").addEventListener("click", () => this.back())
    this.overlay.querySelector(".filechooser-new").addEventListener("click", () => this.newFolder())
    this.chooseBtn.addEventListener("click", () => this.choose())
    if (this.mode === "file") this.chooseBtn.textContent = "Open"
  }

  // ---- data ----------------------------------------------------------------
  async childrenOf(parentId) {
    const key = parentId || ""
    if (this.cache[key]) return this.cache[key]
    const url = new URL(this.childrenUrl, window.location.origin)
    if (parentId) url.searchParams.set("parent", parentId)
    if (this.mode === "file") url.searchParams.set("files", "1")
    let entries = []
    try {
      const res = await fetch(url, { headers: { Accept: "application/json" } })
      if (res.ok) entries = (await res.json()).entries || []
    } catch (_e) { /* transient; show an empty column */ }
    this.cache[key] = entries
    return entries
  }

  // ---- render --------------------------------------------------------------
  async render() {
    if (!this.overlay) return
    this.colsEl.innerHTML = ""
    const levels = [ { id: null, name: this.rootLabel }, ...this.trail ]
    for (let k = 0; k < levels.length; k++) {
      const entries = await this.childrenOf(levels[k].id)
      // Awaiting inside the loop means the modal can be closed mid-render; without this the next
      // append throws on a null colsEl and the promise never settles.
      if (!this.overlay) return
      const descendedId = this.trail[k] ? this.trail[k].id : null // folder opened FROM this column
      this.colsEl.appendChild(this.columnEl(entries, k, descendedId))
    }
    this.colsEl.scrollLeft = this.colsEl.scrollWidth
    this.crumbsEl.textContent = [ this.rootLabel, ...this.trail.map((f) => f.name) ].join("  ›  ")
    if (this.selection) {
      this.selEl.textContent = "Selected: " + this.selection.path
      this.chooseBtn.disabled = false
    } else {
      this.selEl.textContent = this.mode === "file" ? "Select a file" : ""
      this.chooseBtn.disabled = true
    }
  }

  columnEl(entries, depth, descendedId) {
    const col = document.createElement("div")
    col.className = "filechooser-col"
    if (entries.length === 0) {
      const empty = document.createElement("div")
      empty.className = "filechooser-empty"
      empty.textContent = "Empty folder"
      col.appendChild(empty)
    }
    for (const entry of entries) {
      const isFile = entry.kind !== "dir"
      const row = document.createElement("div")
      row.className = "filechooser-row" + (isFile ? " is-file" : "")
      const selected = (!isFile && entry.node_id === descendedId) ||
        (isFile && this.selection && this.selection.kind === "file" && this.selection.nodeId === entry.node_id)
      if (selected) row.classList.add("sel")
      // textContent, never innerHTML: `name` is a user's own filename and this is the one place a
      // library file's bytes-adjacent metadata is drawn into the page.
      row.textContent = (isFile ? "📄 " : "📁 ") + entry.name
      row.addEventListener("click", () => (isFile ? this.pickFile(depth, entry) : this.descend(depth, entry)))
      col.appendChild(row)
    }
    return col
  }

  // ---- navigation ----------------------------------------------------------
  descend(depth, folder) {
    this.trail = this.trail.slice(0, depth).concat([ { id: folder.node_id, name: folder.name } ])
    this.selection = this.mode === "folder"
      ? { nodeId: folder.node_id, kind: "dir", path: this.pathFor(this.trail.length) }
      : null // in file mode, descending leaves nothing selected until a file is clicked
    this.render()
  }

  pickFile(depth, file) {
    this.trail = this.trail.slice(0, depth) // collapse any deeper folder columns
    this.selection = { nodeId: file.node_id, kind: "file", path: this.pathFor(depth) + "/" + file.name }
    this.render()
  }

  back() {
    if (this.trail.length === 0) return
    this.trail.pop()
    if (this.mode === "folder") {
      const last = this.trail[this.trail.length - 1]
      this.selection = last
        ? { nodeId: last.id, kind: "dir", path: this.pathFor(this.trail.length) }
        : { nodeId: "", kind: "dir", path: this.rootLabel }
    }
    this.render()
  }

  // "/" + the names of the first `n` descended folders (n counts levels below root).
  pathFor(n) {
    const parts = this.trail.slice(0, n).map((f) => f.name)
    return parts.length ? "/" + parts.join("/") : this.rootLabel
  }

  // ---- new folder ----------------------------------------------------------
  newFolder() {
    if (this.newWrap.querySelector("form")) return
    this.newWrap.innerHTML = `<form class="filechooser-newform">
      <input type="text" placeholder="Folder name" aria-label="New folder name" />
      <button type="submit" class="btn">Create</button>
      <span class="filechooser-newerr"></span></form>`
    const form = this.newWrap.querySelector("form")
    const input = form.querySelector("input")
    input.focus()
    form.addEventListener("submit", (e) => { e.preventDefault(); this.submitNewFolder(form, input) })
  }

  async submitNewFolder(form, input) {
    const name = input.value.trim()
    if (!name) return
    const parentId = this.trail.length ? this.trail[this.trail.length - 1].id : null
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = new FormData()
    body.set("name", name)
    if (parentId) body.set("parent_node_id", parentId)
    let res
    try {
      res = await fetch(this.createUrl, {
        method: "POST", body,
        headers: token ? { "X-CSRF-Token": token, Accept: "application/json" } : { Accept: "application/json" },
      })
    } catch (_e) {
      form.querySelector(".filechooser-newerr").textContent = "Network error."
      return
    }
    if (res.ok) {
      const node = await res.json()
      delete this.cache[parentId || ""] // this folder's listing is now stale
      this.resetNewButton()
      this.descend(this.trail.length, { node_id: node.node_id, name: node.name }) // step into the new folder
    } else {
      const err = await res.json().catch(() => ({}))
      form.querySelector(".filechooser-newerr").textContent = err.error || "Couldn't create folder."
    }
  }

  resetNewButton() {
    this.newWrap.innerHTML = `<button type="button" class="btn ghost filechooser-new">＋ New Folder</button>`
    this.newWrap.querySelector(".filechooser-new").addEventListener("click", () => this.newFolder())
  }

  // ---- commit --------------------------------------------------------------
  choose() {
    if (!this.selection) return
    const { nodeId, kind, path } = this.selection
    this.settle({ nodeId: nodeId || "", kind, path })
  }
}

// The one-call form, and the shape handed to addon bundles as `ctx.chooseFolder`. Resolves with the
// selection or null; never rejects, because a cancel is not an error.
export function chooseFolder(options = {}) {
  return new FileChooser({ ...options, mode: "folder" }).open()
}
