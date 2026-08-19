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
  constructor({ mode = "folder", childrenUrl, createUrl, rootLabel = ROOT_LABEL, value = "", label = null,
                extensions = null } = {}) {
    this.mode = mode
    this.childrenUrl = childrenUrl
    this.createUrl = createUrl
    this.rootLabel = rootLabel
    this.value = value || ""
    this.label = label
    // FILTERED IN THE BROWSER, NOT BY THE SERVER, AND THAT IS THE DELIBERATE HALF OF `pickFile`.
    // /library/children already answers one folder's children — a bounded list this modal has
    // entirely in hand — so a server-side filter would buy no round trips and no bytes worth
    // counting. What it would cost is a second definition of "which extensions count" living on a
    // shared endpoint (filechooser_controller.js's form field uses the same one), i.e. exactly the
    // extension-vocabulary duplication §14d records. It is also honest about what the filter IS:
    // a convenience for the human picking, never a restriction on the addon — a bundle can pass
    // any node id to `host.files.read` regardless of what the picker showed it.
    //
    // Normalized here, once: lower-cased and dot-prefixed, so a caller may write "svg" or ".SVG".
    // An empty or absent list means no filtering at all.
    this.extensions = normalizeExtensions(extensions)
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

  // FOLDERS ARE NEVER FILTERED, only files. A filter that hid folders would hide the path TO a
  // matching file, which is the one thing a Miller-columns picker cannot recover from.
  visible(entries) {
    if (!this.extensions) return entries
    return entries.filter((e) => e.kind === "dir" || this.extensions.some((ext) => endsWithExt(e.name, ext)))
  }

  columnEl(allEntries, depth, descendedId) {
    const entries = this.visible(allEntries)
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
      ? { nodeId: folder.node_id, kind: "dir", path: this.pathPrefix(this.trail.length) }
      : null // in file mode, descending leaves nothing selected until a file is clicked
    this.render()
  }

  pickFile(depth, file) {
    this.trail = this.trail.slice(0, depth) // collapse any deeper folder columns
    this.selection = { nodeId: file.node_id, kind: "file", path: this.pathPrefix(depth) + "/" + file.name }
    this.render()
  }

  back() {
    if (this.trail.length === 0) return
    this.trail.pop()
    if (this.mode === "folder") {
      const last = this.trail[this.trail.length - 1]
      this.selection = last
        ? { nodeId: last.id, kind: "dir", path: this.pathPrefix(this.trail.length) }
        : { nodeId: "", kind: "dir", path: this.rootLabel }
    } else {
      // FILE MODE CLEARS, exactly as `descend` does one method up, and the asymmetry used to run
      // the other way: this branch did not exist, so popping a level left the footer reading
      // "Selected: /a/b/x.svg" with Open live while the crumbs read "/ › a". Popping removes the
      // COLUMN THE PICKED FILE WAS IN — `pickFile` already collapsed the trail to that file's own
      // depth — so after a Back there is nothing on screen the stale selection corresponds to, and
      // Open would commit a file the user can no longer see.
      //
      // This is a modal-INTERNAL null, not a resolved one: `choose` returns early on it, so the
      // promise's null keeps meaning cancel and only cancel (file mode has no "chose the root"
      // answer). The folder arm above is untouched and must stay so — it names the root with the
      // caller's own `rootLabel`, which is a label by design and not the path this file's
      // `pathPrefix` builds.
      this.selection = null
    }
    this.render()
  }

  // "/" + the names of the first `n` descended folders (n counts levels below root), or "" at the
  // root. TOTAL OVER PATHS AND NEVER A LABEL — that is the whole point of the name, and it used to
  // be false: this returned `rootLabel` at n === 0, so the one caller that can pass 0 composed a
  // display label into a path. `pickFile` builds `pathPrefix(depth) + "/" + name`, so a file picked
  // in the ROOT column came back as "Choose automatically/hero.png" — the project form's own
  // root_label — where it means "/hero.png". The other two callers never reach 0 (`descend` calls
  // this after a `.concat`, `back` inside `if (last)`), so the label branch was reachable from
  // exactly one call site and wrong at all of it.
  //
  // The same conflation as the seeding defect recorded at #open, one method away. A caller that
  // WANTS the root's label supplies it literally — #open at the seed, `back`'s root arm — because
  // only the caller knows whether it is composing a path or naming the root, and folder mode
  // deliberately names the root with the caller's own word for it.
  pathPrefix(n) {
    const parts = this.trail.slice(0, n).map((f) => f.name)
    return parts.length ? "/" + parts.join("/") : ""
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

// -> [".svg", …] lower-cased and dot-prefixed, or null for "no filtering". A non-array, or an
// array with nothing usable in it, is null rather than a filter matching nothing: a typo in an
// addon's `extensions` must show the user their files, not an empty picker they cannot explain.
function normalizeExtensions(extensions) {
  if (!Array.isArray(extensions)) return null
  const cleaned = extensions
    .filter((e) => typeof e === "string" && e.trim() !== "")
    .map((e) => { const t = e.trim().toLowerCase(); return t.startsWith(".") ? t : `.${t}` })
  return cleaned.length ? cleaned : null
}

// Compared against a LOWER-CASED name, because a NAS is full of `.STL` and `.Lbrn2`. Deliberately
// not a regex: a filename is user data and an extension is an addon-supplied string, so building a
// pattern out of either is a needless escaping problem.
function endsWithExt(name, ext) {
  return String(name).toLowerCase().endsWith(ext)
}

// The one-call form, and the shape handed to addon bundles as `ctx.chooseFolder`. Resolves with the
// selection or null; never rejects, because a cancel is not an error.
export function chooseFolder(options = {}) {
  return new FileChooser({ ...options, mode: "folder" }).open()
}

// The file-mode sibling, handed to bundles as `ctx.chooseFile` and reached through the SDK as
// `host.files.pickFile`. Same resolution contract, and the CANCEL half of it is the part worth
// stating twice: null means the user cancelled and is NOT the same answer as any selection —
// there is no "chose the root" in file mode at all, because a directory is never a valid
// selection here, so a caller conflating null with a value has nothing sensible to fall back to.
//
// `mode` is forced rather than defaulted, exactly as chooseFolder forces its own: these two
// functions ARE the mode, and an options bag that could quietly flip it would make the export name
// a lie.
export function chooseFile(options = {}) {
  return new FileChooser({ ...options, mode: "file" }).open()
}
