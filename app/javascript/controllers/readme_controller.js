import { Controller } from "@hotwired/stimulus"

// The README editor on the project page (stage 4, S4-4; story 5.3). Upgrades a plain <textarea> to
// CodeMirror and copies the buffer back into it on submit — the form is an ordinary PATCH that
// redirects, so there is no JSON, no error surface and no token roll-forward here. That is the
// difference from editor_controller.js, which must stay on the file page and therefore fetches.
//
// LAZY, ON THE <details> TOGGLE. The bytes are fetched the first time the editor is opened and
// never on a page nobody edits, which is what keeps the project page's port reads (and its query
// budget) exactly where S4-1 left them.
//
// THE FIELDS ARE ENABLED ONLY ONCE THE BUFFER HOLDS THE REAL BYTES. Rendered disabled by the
// partial: a bundle that fails to load, or a fetch that 503s on an unmounted NAS, must not leave a
// Save button that posts an empty document over the file. The server refuses a blank body too —
// this is the courteous half, the same split FilesController::EDITABLE_MAX_BYTES already has.
const MAX_BYTES = 200_000

export default class extends Controller {
  static targets = ["input", "mount", "status", "submit"]
  static values = { url: String }

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
    if (this.urlValue) {
      try {
        const res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
        if (!res.ok) throw new Error(`fetch failed (${res.status})`)
        const text = await res.text()
        if (this.disconnected) return
        if (text.length > MAX_BYTES) {
          this.statusTarget.textContent = "This README is too large to edit here."
          return
        }
        this.inputTarget.value = text
      } catch (e) {
        if (this.disconnected) return
        this.statusTarget.textContent = `Could not load the README: ${e.message}`
        return
      }
    }

    this.inputTarget.disabled = false
    if (this.hasSubmitTarget) this.submitTarget.disabled = false
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
