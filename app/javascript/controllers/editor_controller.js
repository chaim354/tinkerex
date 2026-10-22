import { Controller } from "@hotwired/stimulus"

// Editable source view. The read-only sibling is codeview_controller.
//
// WHERE THIS ONE MOUNTS CHANGED ON 2026-09-10: it used to be "inside a working tree", where git was
// the undo; FilesController#show now says `@kind == :text && editable?(@node)`, so any text file
// under the server's cap gets it and the trade is named on the page instead
// (shared/_no_history_note). codeview is what an OVER-CAP file and a visitor's public page get.
//
// THE FETCH RUNS FIRST AND THE BUNDLE LOADS SECOND, exactly as codeview does: the bytes are what
// the user came for, and a failed bundle load leaves the <pre> holding the file's text.
//
// A TRUNCATED BUFFER IS NEVER EDITABLE. Saving one would truncate the file. The server refuses it
// too (FilesController::EDITABLE_MAX_BYTES) — this is the courteous half of that rule, not the
// enforcing half.
const MAX_BYTES = 200_000

export default class extends Controller {
  static targets = ["fallback"]
  static values = { url: String, ext: String, saveUrl: String, baseToken: String }

  async connect() {
    this.disconnected = false
    this.abort = new AbortController()
    this.rest()

    let res
    try {
      res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
    } catch (e) {
      if (this.disconnected) return
      this.fallbackTarget.textContent = `Could not load file: ${e.message}`
      return
    }
    const text = await res.text()
    if (this.disconnected) return
    this.fallbackTarget.textContent = text

    if (text.length > MAX_BYTES) return // stays a read-only <pre>; the server refuses the save too

    let cm, languages, theme
    try {
      ;[cm, languages, theme] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages"),
        import("lib/codemirror_theme")
      ])
    } catch (e) {
      console.warn("[editor] keeping the plain preview:", e)
      return
    }
    if (this.disconnected) return

    this.mount(cm, languages, theme, text)
  }

  // CONNECT RESTS THE ELEMENT, codeview_controller.js#rest's rule (docs/invariants/files-preview.md).
  // A page Turbo restores from its cache has no fallback, because mount() removed the <pre>, so
  // connect threw "Missing target element" and the file never appeared — measured: no `.cm-content`
  // at all after Back — while the Save bar addSaveBar appended survived as a button wired to nothing.
  // Whatever is left of the last editor goes (both selectors, in case its DOM did survive), a fresh
  // fallback takes its place, and the load below runs as on a first visit: the file is fetched again,
  // so the editor holds what is on disk now, and a save still carries the base token, which
  // FilesController#update refuses if the file moved on meanwhile.
  rest() {
    if (this.hasFallbackTarget) return
    this.element.querySelectorAll(".cm-editor, .editor-bar").forEach((el) => el.remove())
    const pre = document.createElement("pre")
    pre.className = "preview-text"
    pre.dataset.editorTarget = "fallback"
    pre.textContent = "Loading…"
    this.element.prepend(pre)
  }

  mount(cm, languages, theme, text) {
    const language = languages.languageFor(this.extValue, cm)
    // NO EditorState.readOnly AND NO EditorView.editable HERE — codeview sets both, and this
    // controller exists precisely because unsetting them on that one is not a flag flip: a page
    // that is sometimes editable needs a different mount, not a mutated one.
    // The dark editor theme, or nothing under the light one (lib/codemirror_theme.js).
    const extensions = [cm.basicSetup, ...theme.themeExtensions(cm)]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: text, extensions }),
      parent: this.element
    })
    this.fallbackTarget.remove()
    this.addSaveBar()
  }

  addSaveBar() {
    this.bar = document.createElement("div")
    this.bar.className = "editor-bar"
    this.button = document.createElement("button")
    this.button.type = "button"
    this.button.textContent = "Save"
    this.button.addEventListener("click", () => this.save())
    this.status = document.createElement("span")
    this.status.className = "editor-status"
    this.bar.append(this.button, this.status)
    this.element.append(this.bar)
  }

  async save() {
    this.button.disabled = true
    this.status.textContent = "Saving…"
    try {
      const res = await fetch(this.saveUrlValue, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        body: JSON.stringify({
          content: this.view.state.doc.toString(),
          base_token: this.baseTokenValue
        })
      })
      const body = await res.json()
      if (!res.ok) { this.status.textContent = body.error ?? `Save failed (${res.status})`; return }

      // THE TOKEN ROLLS FORWARD ON SUCCESS. Without this a second save sends the ORIGINAL token,
      // which the server correctly refuses as stale — so the editor would work exactly once.
      this.baseTokenValue = body.content_token ?? this.baseTokenValue
      this.status.textContent = "Saved"
    } finally {
      this.button.disabled = false
    }
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
