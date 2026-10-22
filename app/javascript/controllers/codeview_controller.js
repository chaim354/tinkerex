import { Controller } from "@hotwired/stimulus"

// Read-only source viewer. Replaces textpreview_controller, which rendered a bare <pre>.
//
// THE FETCH RUNS FIRST AND THE BUNDLE LOADS SECOND, deliberately. The bytes are the thing the
// user came for; if the 933 KB bundle fails to load — offline, a CSP change, a bad deploy — the
// <pre> fallback already holds the file's text and the page degrades to exactly what it used to
// be. Loading the bundle first would trade a working page for a spinner.
//
// DYNAMIC import(), like modelviewer_controller does for Three.js: a page with no text file never
// downloads the bundle at all. (Stimulus eager-imports controller MODULES at startup, so a
// top-level import would ship CodeMirror site-wide.)
//
// EDITING IS OUT OF SCOPE. The state is read-only by two separate facts — see #mount.

// The cap, in BYTES rather than characters, because it now bounds a TRANSFER and not just a
// string. 200,000 is what textpreview sliced at; for the ASCII a source file mostly is, the two
// are the same number.
const MAX_BYTES = 200_000

export default class extends Controller {
  static targets = ["fallback"]
  static values = { url: String, ext: String }

  async connect() {
    this.disconnected = false
    this.abort = new AbortController()
    this.rest()

    let head
    try {
      head = await this.fetchHead()
    } catch (e) {
      if (this.disconnected) return
      this.fallbackTarget.textContent = `Could not load preview: ${e.message}`
      return
    }
    if (this.disconnected) return

    // The text is on the page BEFORE the bundle is asked for. Everything after this point is an
    // upgrade; every failure below leaves this <pre> exactly as textpreview left it.
    this.fallbackTarget.textContent = head.text

    let cm, languages, theme
    try {
      ;[cm, languages, theme] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages"),
        import("lib/codemirror_theme")
      ])
    } catch (e) {
      console.warn("[codeview] keeping the plain preview:", e)
      return // the <pre> above is already showing the file; that is the degraded state
    }
    if (this.disconnected) return

    this.mount(cm, languages, theme, head.text)
  }

  // CONNECT RESTS THE ELEMENT, as the 3D, board and Measure viewers' do (files-preview.md). A page Turbo
  // restores from its cache has no fallback, because mount() removed the <pre> — so connect found no
  // target, threw "Missing target element", and the code area stayed blank (measured: no
  // `.cm-content` after Back). Reachable by Back to any source file's page (code_viewer_test.rb) and
  // through the model page's pane (model_page_test.rb). Anything left of the last editor goes, a fresh
  // fallback takes its place, and the load below runs as on a first visit.
  rest() {
    if (this.hasFallbackTarget) return
    this.element.querySelectorAll(".cm-editor").forEach((el) => el.remove())
    const pre = document.createElement("pre")
    pre.className = "preview-text"
    pre.dataset.codeviewTarget = "fallback"
    pre.textContent = "Loading…"
    this.element.prepend(pre)
  }

  mount(cm, languages, theme, text) {
    const language = languages.languageFor(this.extValue, cm)
    const extensions = [
      cm.basicSetup,
      // The token-coloured syntax highlighting, the same in every theme (lib/codemirror_theme.js);
      // a theme switch repaints it through CSS. Above the read-only facets so the pair below still
      // reads as a unit.
      ...theme.themeExtensions(cm),
      // BOTH, and neither is redundant. readOnly refuses document changes; editable removes the
      // caret and IME. A contenteditable that merely looks disabled still takes focus and still
      // accepts an IME composition.
      cm.EditorState.readOnly.of(true),
      cm.EditorView.editable.of(false)
    ]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: text, extensions }),
      parent: this.element
    })
    this.fallbackTarget.remove()
  }

  // Fetch AT MOST MAX_BYTES of the file, and stop the transfer there — which is the half that
  // actually saves anything, because MEASURED, ONLY ONE BACKEND HONOURS A Range HEADER:
  //
  //   share        `send_file` -> Rails' own FileBody. No Range middleware is in this app's stack
  //                (Rack::Sendfile/Static/Propshaft handle asset paths only), so a Range request
  //                answers 200 with the WHOLE body and no Accept-Ranges. Driven: 1,000,000 bytes
  //                asked and 1,000,000 bytes returned, with and without the header.
  //   chunk_remote `self.response_body = enum` through that same stack — the same 200, and here
  //                the bytes also stream through Puma (§14a: presignable is false), so the cost
  //                is a HELD REQUEST THREAD for the whole transfer, not just wire time.
  //   s3           a 302 to a presigned URL, unaffected by the header (driven), whose signature
  //                covers `host` alone — so the Range the browser then sends to the store is not
  //                part of the signature and the store answers it. Not verified against a live
  //                bucket from here.
  //
  // So the header is sent because it is free where it is ignored and saves the store real egress
  // where it is not — but the STREAM CANCEL below is what bounds the other two. Reading the body
  // through a reader and cancelling closes the connection, which is the only lever a client has
  // over a server that will not range.
  //
  // ASKS FOR ONE BYTE MORE THAN IT KEEPS, and that is what makes "truncated" exact rather than a
  // guess: receiving more than MAX_BYTES is the whole test, and it is true both of a 206 that
  // filled the extra byte and of a 200 we cut off. Reading Content-Range instead would fail on
  // the s3 path, where a cross-origin response exposes no such header and every file — however
  // small — would be labelled truncated.
  async fetchHead() {
    const res = await fetch(this.urlValue, {
      credentials: "same-origin",
      headers: { Range: `bytes=0-${MAX_BYTES}` },
      signal: this.abort.signal
    })
    if (!res.ok) throw new Error(`fetch failed (${res.status})`) // 206 is ok too

    if (!res.body) { // no streaming body: behave exactly as textpreview did
      const whole = await res.text()
      return { text: whole.slice(0, MAX_BYTES), truncated: whole.length > MAX_BYTES }
    }

    const reader = res.body.getReader()
    const chunks = []
    let bytes = 0
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      chunks.push(value)
      bytes += value.length
      if (bytes > MAX_BYTES) {
        await reader.cancel() // stops the transfer, and releases the Puma thread on chunk_remote
        break
      }
    }

    const buf = new Uint8Array(bytes)
    let at = 0
    for (const chunk of chunks) { buf.set(chunk, at); at += chunk.length }

    const truncated = bytes > MAX_BYTES
    // TextDecoder resolves a multi-byte sequence cut by the cap to U+FFFD rather than throwing,
    // which is the right answer for a preview: one replacement character at the very end, under
    // a line that already says the file was truncated.
    const text = new TextDecoder().decode(buf.subarray(0, MAX_BYTES))
    return { text: truncated ? `${text}\n… (truncated)` : text, truncated }
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort() // a navigation away must not go on pulling bytes for a page nobody sees
    this.view?.destroy()
    this.view = null
  }
}
