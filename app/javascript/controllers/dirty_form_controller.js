import { Controller } from "@hotwired/stimulus"

// A FORM THAT ASKS BEFORE ITS TYPED INPUT IS THROWN AWAY (2026-11-02, the UX audit's B1). Mounted on
// the edit area's Details form (projects/_form) and its Publishing form (projects/_publish); the
// Page layout tab has its own guard (layout_editor_controller.js) and the file editor has one too
// (editor_controller.js). Same question, same two exits, same shape as theirs.
//
// "DIRTY" IS THE FORM AGAINST THE ONE THE PAGE LOADED WITH, serialized as it would be posted, so
// typing a name and then deleting it again is not a change. It is COMPARED WHEN ASKED, not tracked
// on `input`/`change`: the cover chooser (shared/_folder_field) writes its hidden input from script,
// which fires neither event, and a change it missed would be lost without a question.
//
// WHILE DIRTY, LEAVING ASKS: a Turbo visit (`turbo:before-visit`) — which is Done, Cancel, the edit
// area's other two tabs, the rail and every other link, with one listener rather than a confirm per
// control — gets one confirm, and a full navigation (a reload, a closed tab, a typed address) gets
// the browser's own `beforeunload` prompt.
//
// THE FORM'S OWN SUBMIT STANDS THE GUARD DOWN, so Save never asks: `submit`, and Turbo's
// `turbo:submit-start` for a submission that did not come through a submit event. A submission that
// FAILS without an answer (`turbo:submit-end`, not successful) stands it back up; a refused save is a
// 422 that re-renders the form with what was typed, and the server says so with `dirty` (the
// reasons are on the page, so the typed input is unsaved from the first moment).
//
// ANOTHER FORM ON THE PAGE (Archive, a new unlisted link) IS NOT A SAVE OF THIS ONE: its redirect is
// a Turbo visit like any link, so it meets the question too.
//
// EXEMPT FROM TURBO'S SNAPSHOT CACHE, the page editor's reason: a snapshot clones the typed values,
// so Back after leaving would show the abandoned input as if it had been saved, and this guard,
// connecting over it, would read it as clean.
const LEAVE = "Leave without saving your changes?"

export default class extends Controller {
  static values = { dirty: Boolean }

  connect() {
    this.leaving = false
    this.clean = this.serialize()
    this.onBeforeUnload = (event) => {
      if (!this.dirty()) return
      event.preventDefault()
      event.returnValue = ""
    }
    // AN ANSWERED QUESTION STANDS THE GUARD DOWN. A visit the maker agreed to can still end in a
    // full load — the Page layout tab carries `turbo-visit-control: reload` — and `beforeunload`
    // would then ask the same thing a second time.
    this.onBeforeVisit = (event) => {
      if (!this.dirty()) return
      if (window.confirm(LEAVE)) this.leaving = true
      else event.preventDefault()
    }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    window.Turbo?.cache?.exemptPageFromCache?.()
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
  }

  disarm() {
    this.leaving = true
  }

  submitted(event) {
    if (!event.detail?.success) this.leaving = false
  }

  dirty() {
    return !this.leaving && (this.dirtyValue || this.serialize() !== this.clean)
  }

  serialize() {
    return new URLSearchParams(new FormData(this.element)).toString()
  }
}
