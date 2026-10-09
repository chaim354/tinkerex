import { Controller } from "@hotwired/stimulus"

// THE PHONE'S "+" CARRIES UPLOAD TOO (structural redesign spec §4.3, slice 7). At ≤719px the top bar's
// upload label hides and the New menu offers "Upload…", which forwards a click to that LABEL — never to
// the file input, and never through a `<label for>`: on a page with no folder the label's click is what
// upload_pick_controller.js intercepts to ask for a folder first, and an input-targeted click is the one
// it deliberately lets through, so either shortcut would upload to the library root unasked. Runs inside
// the tap's own click, so the user activation the file picker needs is still live.
export default class extends Controller {
  open() {
    document.querySelector("header.topbar .topbar-upload label.upload-btn")?.click()
  }
}
