import { Controller } from "@hotwired/stimulus"

// Reusable folder/file chooser — a native-OS-style Miller-columns modal, built on demand and
// appended to <body>. Data comes from a session-authed JSON endpoint (LibraryBrowseController).
// Used two ways: as a form field (writes the chosen node_id into a hidden input) and as a JS event
// source (fires `filechooser:choose` with {nodeId, kind, path}).
//
//   mode "folder": pick a destination folder. Descending a folder selects it; the root is always a
//                  valid selection; files are not shown. Footer verb "Choose".
//   mode "file":   pick an existing file. Folders navigate; a file click is the selection. "Open".
export default class extends Controller {
  static values = {
    mode: { type: String, default: "folder" },
    childrenUrl: String,
    createUrl: String,
    rootLabel: { type: String, default: "/ (library root)" },
    value: String,
    label: String,
  }
  static targets = ["button", "input"]

  connect() {
    this.cache = {}       // parentId ("" = root) -> entries array
    this.trail = []       // folders descended into (root implicit); each { id, name }
    this.selection = null // { nodeId, kind, path } or null
  }

  disconnect() { this.close() }

  // ---- open / close --------------------------------------------------------
  async open() {
    this.previouslyFocused = document.activeElement
    this.cache = {}
    this.trail = []
    this.selection = this.modeValue === "folder"
      ? { nodeId: (this.hasInputTarget && this.inputTarget.value) || "", kind: "dir", path: this.rootLabelValue }
      : null
    this.buildModal()
    await this.render()
    this.overlay.querySelector(".filechooser").focus()
  }

  close() {
    if (this.overlay) { this.overlay.remove(); this.overlay = null }
    if (this.onKeydown) { document.removeEventListener("keydown", this.onKeydown); this.onKeydown = null }
    if (this.previouslyFocused && this.previouslyFocused.focus) this.previouslyFocused.focus()
  }

  buildModal() {
    this.onKeydown = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this.onKeydown)

    const verb = this.modeValue === "file" ? "a file" : "a destination folder"
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
    if (this.modeValue === "file") this.chooseBtn.textContent = "Open"
  }

  // ---- data ----------------------------------------------------------------
  async childrenOf(parentId) {
    const key = parentId || ""
    if (this.cache[key]) return this.cache[key]
    const url = new URL(this.childrenUrlValue, window.location.origin)
    if (parentId) url.searchParams.set("parent", parentId)
    if (this.modeValue === "file") url.searchParams.set("files", "1")
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
    const levels = [{ id: null, name: this.rootLabelValue }, ...this.trail]
    for (let k = 0; k < levels.length; k++) {
      const entries = await this.childrenOf(levels[k].id)
      const descendedId = this.trail[k] ? this.trail[k].id : null // folder opened FROM this column
      this.colsEl.appendChild(this.columnEl(entries, k, descendedId))
    }
    this.colsEl.scrollLeft = this.colsEl.scrollWidth
    this.crumbsEl.textContent = [this.rootLabelValue, ...this.trail.map((f) => f.name)].join("  ›  ")
    if (this.selection) {
      this.selEl.textContent = "Selected: " + this.selection.path
      this.chooseBtn.disabled = false
    } else {
      this.selEl.textContent = this.modeValue === "file" ? "Select a file" : ""
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
      row.textContent = (isFile ? "📄 " : "📁 ") + entry.name
      row.addEventListener("click", () => (isFile ? this.pickFile(depth, entry) : this.descend(depth, entry)))
      col.appendChild(row)
    }
    return col
  }

  // ---- navigation ----------------------------------------------------------
  descend(depth, folder) {
    this.trail = this.trail.slice(0, depth).concat([{ id: folder.node_id, name: folder.name }])
    this.selection = this.modeValue === "folder"
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
    if (this.modeValue === "folder") {
      const last = this.trail[this.trail.length - 1]
      this.selection = last
        ? { nodeId: last.id, kind: "dir", path: this.pathFor(this.trail.length) }
        : { nodeId: "", kind: "dir", path: this.rootLabelValue }
    }
    this.render()
  }

  // "/" + the names of the first `n` descended folders (n counts levels below root).
  pathFor(n) {
    const parts = this.trail.slice(0, n).map((f) => f.name)
    return parts.length ? "/" + parts.join("/") : this.rootLabelValue
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
      res = await fetch(this.createUrlValue, {
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
    if (this.hasInputTarget) this.inputTarget.value = nodeId || ""
    if (this.hasButtonTarget) {
      const p = this.buttonTarget.querySelector(".ff-path")
      if (p) p.textContent = path
    }
    this.element.dispatchEvent(new CustomEvent("filechooser:choose", {
      bubbles: true, detail: { nodeId: nodeId || "", kind, path },
    }))
    this.close()
  }
}
