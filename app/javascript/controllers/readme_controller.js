import { Controller } from "@hotwired/stimulus"
import { chooseFile } from "lib/file_chooser"

// The README editor on the project page (stage 4, S4-4; story 5.3). Upgrades a plain <textarea> to
// CodeMirror and copies the buffer back into it on submit — the form is an ordinary PATCH that
// redirects, so there is no JSON and no token roll-forward here. That is the difference from
// editor_controller.js, which must stay on the file page and therefore fetches. A REFUSED save
// comes back as this editor again (Projects::ReadmesController, 2026-11-02), open, with the error
// rendered in it and the DRAFT in the textarea: `draft` is true then, and the README is not
// fetched, because the bytes it would fetch are the ones the draft was refused against.
//
// LAZY, ON THE <details> TOGGLE. The bytes are fetched the first time the editor is opened and
// never on a page nobody edits, which is what keeps the project page's port reads (and its query
// budget) exactly where S4-1 left them.
//
// THE FIELDS ARE ENABLED ONLY ONCE THE BUFFER HOLDS THE REAL BYTES. Rendered disabled by the
// partial: a bundle that fails to load, or a fetch that 503s on an unmounted NAS, must not leave a
// Save button that posts an empty document over the file. The server refuses a blank body too —
// this is the courteous half, the same split FilesController::EDITABLE_MAX_BYTES already has.
//
// LIVE REGIONS (2026-11-05; spec §7). A fetched README has its regions COLLAPSED to their opening
// line before it reaches the buffer: the bodies are generated (Maker::Readme::Live), editing them is
// wasted, and the server regenerates them on Save whatever was posted — so the collapse is a
// courtesy, not a rule, and a draft (already the maker's own text) is left alone. The Insert bar
// writes a region at the cursor: opener, blank line, closer; the Save fills it. Image opens the
// Miller-columns chooser ROOTED AT THE PROJECT FOLDER, so a pick cannot leave the project.
const MAX_BYTES = 200_000
// The grammar, mirrored from Maker::Readme::Live (OPEN_RE / CLOSE_RE): an opener, then a closer
// before the next opener closes the region; an opener with no such closer is the opener line alone.
const OPEN = /^[ \t]*<!--[ \t]*tinkerex:[a-z]+(?:[ \t]+[^\n]*?)?[ \t]*-->[ \t]*\r?$/
const CLOSE = /^[ \t]*<!--[ \t]*\/tinkerex[ \t]*-->[ \t]*\r?$/

export function collapseRegions(text) {
  const lines = text.split("\n")
  const out = []
  for (let i = 0; i < lines.length; i++) {
    out.push(lines[i])
    if (!OPEN.test(lines[i])) continue
    let j = i + 1
    while (j < lines.length && !OPEN.test(lines[j]) && !CLOSE.test(lines[j])) j++
    if (j < lines.length && CLOSE.test(lines[j])) i = j // skip the body and the closer
  }
  return out.join("\n")
}

export default class extends Controller {
  static targets = ["input", "mount", "status", "submit", "insert"]
  static values = { url: String, draft: Boolean, childrenUrl: String, folderId: String, folderName: String }

  connect() {
    this.loaded = false
    this.disconnected = false
    this.abort = new AbortController()
    // An editor left open by a Turbo restore must still load its bytes.
    if (this.element.open) this.reveal()
  }

  async reveal() {
    if (!this.element.open || this.loaded) return
    this.loaded = true

    // A DECLARED-BUT-EMPTY VALUE IS THE "no README yet" CASE, and `hasUrlValue` is true for it —
    // Stimulus reports a declared String value as present however empty. The template is already
    // in the textarea then, so there is nothing to fetch.
    if (this.urlValue && !this.draftValue) {
      try {
        const res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
        if (!res.ok) throw new Error(`fetch failed (${res.status})`)
        const text = await res.text()
        if (this.disconnected) return
        if (text.length > MAX_BYTES) {
          this.statusTarget.textContent = "This README is too large to edit here."
          return
        }
        this.inputTarget.value = collapseRegions(text)
      } catch (e) {
        if (this.disconnected) return
        // NOT LOADED AFTER ALL: `loaded` went true at the top so a second toggle during the fetch
        // could not start a second one; a failed fetch hands the flag back, so closing and
        // re-opening the editor retries (an unmounted NAS answers 503 for a while, then not).
        this.loaded = false
        this.statusTarget.textContent = `Could not load the README: ${e.message}. Open again to retry.`
        return
      }
    }

    this.inputTarget.disabled = false
    if (this.hasSubmitTarget) this.submitTarget.disabled = false
    if (this.hasInsertTarget) this.insertTarget.hidden = false
    await this.mountEditor()
  }

  async mountEditor() {
    let cm, languages, theme
    try {
      ;[cm, languages, theme] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages"),
        import("lib/codemirror_theme")
      ])
    } catch (e) {
      // The plain textarea is already editable and already holds the bytes; that IS the degraded
      // state, and it is a working one. Same posture codeview/editor take with their <pre>.
      console.warn("[readme] keeping the plain textarea:", e)
      return
    }
    if (this.disconnected) return

    // `languageFor("md")` is already `cm.markdown()` — the bundle exports @codemirror/lang-markdown
    // (vendor/javascript/codemirror-entry.js). NO NEW PIN AND NO REBUILD: CodeMirror is ONE bundle
    // and exactly one importmap pin (§14d).
    const extensions = [cm.basicSetup, ...theme.themeExtensions(cm)]
    const language = languages.languageFor("md", cm)
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: this.inputTarget.value, extensions }),
      parent: this.mountTarget
    })
    this.inputTarget.hidden = true
  }

  // --- the Insert bar ---------------------------------------------------------------------------

  insertFiles(event) {
    this.insertRegion("files", event.currentTarget.dataset.path)
    this.element.querySelector(".readme-insert details.menu")?.removeAttribute("open")
  }

  insertDirective(event) {
    this.insertRegion(event.currentTarget.dataset.directive, "")
  }

  async insertImage() {
    const picked = await chooseFile({
      childrenUrl: this.childrenUrlValue,
      rootId: this.folderIdValue || null,
      rootLabel: this.folderNameValue || "Project folder"
    })
    if (!picked || picked.kind !== "file") return
    const name = picked.path.split("/").pop()
    this.insertRegion("image", `${picked.nodeId} ${name}`)
  }

  insertRegion(directive, args) {
    const opener = `<!-- tinkerex:${directive}${args ? " " + args : ""} -->`
    this.insertText(`${opener}\n\n<!-- /tinkerex -->`)
  }

  // At the cursor, on a line of its own, with a blank line after it; the textarea gets the same at
  // its selection end when CodeMirror never mounted.
  insertText(text) {
    if (this.view) {
      const pos = this.view.state.selection.main.to
      const line = this.view.state.doc.lineAt(pos)
      const before = pos === line.from ? "" : "\n"
      const snippet = `${before}${text}\n`
      this.view.dispatch({ changes: { from: pos, insert: snippet }, selection: { anchor: pos + snippet.length } })
      this.view.focus()
      return
    }
    const field = this.inputTarget
    const at = field.selectionEnd ?? field.value.length
    const before = at === 0 || field.value[at - 1] === "\n" ? "" : "\n"
    const snippet = `${before}${text}\n`
    field.value = field.value.slice(0, at) + snippet + field.value.slice(at)
    field.selectionStart = field.selectionEnd = at + snippet.length
    field.focus()
  }

  // THE BUFFER GOES BACK INTO THE FIELD THE FORM ACTUALLY POSTS. Without this the form submits
  // whatever the textarea held when CodeMirror mounted — every edit silently discarded, with a
  // successful save and a redirect to prove it worked.
  sync() {
    if (this.view) this.inputTarget.value = this.view.state.doc.toString()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
