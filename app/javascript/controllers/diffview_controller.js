import { Controller } from "@hotwired/stimulus"

// Inline diff of one file's working-tree bytes against an OLDER version of the same file. Two
// surfaces mount it: the commit box, where the older side is HEAD's blob, and the file page's
// history panel, where it is that file's bytes at some commit further back.
//
// NEITHER SIDE IS FIXED, AND `head-url` IS THIS CONTROLLER'S NAME FOR "THE OLDER ONE" RATHER THAN
// FOR HEAD. It was named when the commit box was its only caller. The value is a URL and this
// controller never builds one, so generalising it took no code — but the NAME is the part a reader
// trips on, hence this paragraph: read `headUrlValue` as "the original side". Do not add an
// `original-url` value beside it, which would be one input with two spellings and a branch to pick
// between them; renaming it outright means editing every view that sets the attribute, which is a
// change to make in one go or not at all.
//
// THE VOCABULARY IS INVERTED HERE AND IT IS EASY TO SHIP BACKWARDS. CM6's merge extension is
// worded for merging a change IN: `original` is what you had, the document is what is proposed.
// Here `original` is the OLDER, already-committed side and the document is the maker's working
// tree, so REJECTING a chunk means REVERTING it — CM6's own `rejectChunk` tags its transaction
// `userEvent: "revert"`, which is the library agreeing. Anything this view ever labels for that
// control must therefore say "Revert hunk" and never "Reject"; a screenshot cannot show the
// difference, because both spellings render an identical diff and only the word says which way the
// file moves.
//
// WHICH IS WHY `mergeControls` IS FALSE, AND THAT IS A DEPARTURE FROM THE PLAN WITH A MEASUREMENT
// BEHIND IT. Read @codemirror/merge's two handlers before turning it on:
//
//   rejectChunk  dispatches `{changes: …, userEvent: "revert"}` — a DOCUMENT change, and a
//                programmatic dispatch is NOT gated by EditorState.readOnly. So the button would
//                work: it would rewrite the BUFFER. Nothing would reach the working tree, because
//                nothing here posts. The maker clicks "Revert hunk", watches the lines come back,
//                commits — and the file on disk still carries the change they just watched
//                disappear. The commit box exists to not lie about the repository (§14a); a
//                control that reverts only on screen is the purest form of that lie.
//   acceptChunk  dispatches an EFFECT that moves `original` to match the document — it edits
//                HEAD's side of the diff, not the file. In this vocabulary "Accept" means "stop
//                showing me this difference", which is not a thing the maker wants to be offered
//                next to a Commit button.
//
// So the diff is a REVIEW surface: it shows what will be committed and offers no action. Making
// revert real means posting the reverted buffer back through PATCH /files/:id with its
// base_token — the editor's own door — and that is a feature, not a flag flip. When someone
// builds it, the label rule above is the one to carry over, and CM6's supported way to set it is
// the phrase facet (`EditorState.phrases.of({ Reject: "Revert hunk" })`), because the extension
// renders those buttons through `state.phrase()` and re-renders them whenever the chunks change —
// so rewriting their textContent after the mount goes stale on the first edit.
//
// TWO BLOBS OVER THE WIRE, AND THE SERVER DIFFS NEITHER. The older side comes from
// /repos/:root_id/head_blob or /files/:id/history/:oid depending on the caller, and the working
// tree's from the same /files/:id/blob the viewer uses, so the diff is computed in the browser.
// That is what deletes the server-side text diff tinkerex#161 built (spec part 13). Both callers
// point the working side at that ONE endpoint on purpose: two surfaces disagreeing about what is
// currently on disk would be worse than either of them being absent.
//
// DYNAMIC import(), like codeview and editor: Stimulus eager-imports controller MODULES at
// startup, so a top-level import would ship the CodeMirror bundle site-wide.
export default class extends Controller {
  static values = { headUrl: String, workUrl: String, ext: String }

  async connect() {
    this.disconnected = false
    this.abort = new AbortController()

    let original, work
    try {
      ;[original, work] = await Promise.all([
        this.fetchText(this.headUrlValue),
        this.fetchText(this.workUrlValue)
      ])
    } catch (e) {
      if (this.disconnected) return
      // The row above still names the path and its +/− counts, so a failed diff degrades to the
      // list the commit box was before this controller existed — never to a broken page.
      console.warn("[diffview] no diff for this row:", e)
      return
    }
    if (this.disconnected) return

    let cm, languages
    try {
      ;[cm, languages] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages")
      ])
    } catch (e) {
      console.warn("[diffview] keeping the row without a diff:", e)
      return
    }
    if (this.disconnected) return

    this.mount(cm, languages, original, work)
  }

  mount(cm, languages, original, work) {
    const language = languages.languageFor(this.extValue, cm)
    const extensions = [
      cm.basicSetup,
      cm.unifiedMergeView({ original, mergeControls: false }),
      // BOTH FACETS, and neither is redundant — codeview_controller's rule, for its reason:
      // readOnly refuses a document change and editable removes the caret and IME. A
      // contenteditable that merely looks disabled still takes focus.
      cm.EditorState.readOnly.of(true),
      cm.EditorView.editable.of(false)
    ]
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: work, extensions }),
      parent: this.element
    })
  }

  async fetchText(url) {
    const res = await fetch(url, { credentials: "same-origin", signal: this.abort.signal })
    if (!res.ok) throw new Error(`fetch failed (${res.status}) for ${url}`)
    return res.text()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
