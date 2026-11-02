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
//
// EVERY WAY A SAVE CAN END SAYS SO (2026-11-02, the UX audit's B4). The save used to be a
// try/finally with no catch: a dropped connection, or an HTML 413/500 that `res.json()` cannot
// parse, threw past the status line and left "Saving…" on screen for good, over an edit that had
// not reached the disk. Now a failure is a sentence that starts "Not saved." and is drawn as an
// inline alert (`.flash.flash-alert`, whose ::before carries the word "Problem" — a status carries
// its word, design-system.md rule 13); `.flash` floats only inside `.flash-stack` (rule 10), so
// here it sits in the bar. The status is a live region, so the outcome is announced, not only drawn.
//
// AN UNSAVED EDIT IS ASKED ABOUT BEFORE IT IS THROWN AWAY. Dirty is "the document differs from the
// last one the server accepted" — compared with CodeMirror's `Text#eq`, so undoing back to the saved
// text is clean again — and while it holds, a full navigation gets the browser's own beforeunload
// prompt and a Turbo visit gets one confirm. Two exits stand the guard down because the maker has
// already chosen to lose the edit: the stale answer's Reload button, and the history panel's
// Restore, whose confirm names the unsaved edit and which announces itself with `editor:discard`.
const MAX_BYTES = 200_000

const LEAVE = "Leave this file without saving your changes?"

export default class extends Controller {
  static targets = ["fallback"]
  static values = { url: String, ext: String, saveUrl: String, baseToken: String }

  async connect() {
    this.disconnected = false
    this.discarded = false
    this.abort = new AbortController()
    this.rest()
    this.guard()

    let res
    try {
      res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
    } catch (_e) {
      if (this.disconnected) return
      this.fallbackTarget.textContent = "This file could not be loaded. Reload the page to try again."
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
    // The token-coloured syntax highlighting, the same in every theme (lib/codemirror_theme.js).
    const extensions = [cm.basicSetup, ...theme.themeExtensions(cm)]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: text, extensions }),
      parent: this.element
    })
    // The document the server last accepted — the one the page loaded with, until a save lands.
    this.cleanDoc = this.view.state.doc
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
    this.status.setAttribute("role", "status")
    this.bar.append(this.button, this.status)
    this.element.append(this.bar)
  }

  async save() {
    const sent = this.view.state.doc
    this.button.disabled = true
    this.report("Saving…")
    try {
      let res
      try {
        res = await fetch(this.saveUrlValue, {
          method: "PATCH",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
          },
          body: JSON.stringify({ content: sent.toString(), base_token: this.baseTokenValue })
        })
      } catch (_e) {
        if (this.disconnected) return
        return this.report("Not saved. The server could not be reached; your edit is still here, so try Save again.",
                           { problem: true })
      }
      // NULL, NOT A THROW, FOR AN ANSWER THAT IS NOT JSON — a proxy's HTML 413 or 502, or a sign-in
      // page a lapsed session was redirected to. Each is a save that did not happen.
      const body = await res.json().catch(() => null)
      if (this.disconnected) return
      if (!res.ok || body?.ok !== true) {
        return this.report(this.refusal(res.status, body), { problem: true, reload: res.status === 409 })
      }

      // THE TOKEN ROLLS FORWARD ON SUCCESS. Without this a second save sends the ORIGINAL token,
      // which the server correctly refuses as stale — so the editor would work exactly once.
      this.baseTokenValue = body.content_token ?? this.baseTokenValue
      // CLEAN AS OF WHAT WAS SENT, not as of now: typing during the save leaves the newer text dirty.
      this.cleanDoc = sent
      this.report(this.view.state.doc.eq(sent) ? "Saved" : "Saved. Your newer changes are not saved yet.")
    } finally {
      this.button.disabled = false
    }
  }

  // WHY A SAVE WAS NOT TAKEN, as a sentence. The server's own refusal is already written for a maker
  // (TextSave's stale and removed answers, the size cap, the library being unreachable), so it is
  // used as it is; only an answer with no sentence in it — a bare status from something in front of
  // Rails — is put into words here, and never as the status number alone.
  //
  // "THE SERVER'S OWN REFUSAL" IS ONE SHAPE: `{ ok: false, error }`, which FilesController#
  // render_save_error always sends. Any other JSON with an `error` key is not a sentence for a maker —
  // with `Accept: application/json` Rails' own exception pages answer `{"status":500,"error":
  // "Internal Server Error"}` and a refused CSRF token `{"status":422,"error":"Unprocessable
  // Content"}` — so it falls through to the status sentences below rather than being printed.
  refusal(status, body) {
    const said = body?.ok === false && body.error ? body.error : null
    if (status === 409 && said) {
      return `Not saved. ${said} Reloading discards the edit you made here.`
    }
    if (said) return `Not saved. ${said}`
    if (status === 413) return "Not saved. The file is larger than this server accepts."
    if (status >= 500) return "Not saved. The server had a problem; your edit is still here, so try Save again in a moment."
    return "Not saved. The server's answer could not be read; your edit is still here, so try Save again."
  }

  report(text, { problem = false, reload = false } = {}) {
    this.status.className = problem ? "editor-status flash flash-alert" : "editor-status"
    this.status.replaceChildren(text)
    if (!reload) return
    // A BUTTON, BECAUSE "RELOAD" IS THE NEXT STEP AND THE SENTENCE SAYS WHAT IT COSTS. Pressing it is
    // the maker choosing to lose the edit, so the leave-guard stands down first.
    const again = document.createElement("button")
    again.type = "button"
    again.className = "linkbtn"
    again.textContent = "Reload"
    again.addEventListener("click", () => {
      this.discarded = true
      window.location.reload()
    })
    this.status.append(" ", again)
  }

  dirty() {
    return !this.discarded && !!this.view && !!this.cleanDoc && !this.view.state.doc.eq(this.cleanDoc)
  }

  guard() {
    this.onBeforeUnload = (event) => {
      if (!this.dirty()) return
      event.preventDefault()
      event.returnValue = ""
    }
    this.onBeforeVisit = (event) => {
      if (this.dirty() && !window.confirm(LEAVE)) event.preventDefault()
    }
    this.onDiscard = () => { this.discarded = true }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    document.addEventListener("editor:discard", this.onDiscard)
  }

  disconnect() {
    this.disconnected = true
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    document.removeEventListener("editor:discard", this.onDiscard)
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
