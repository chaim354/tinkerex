import { Controller } from "@hotwired/stimulus"

// FORWARDS A CLICK TO A FILE PICKER, by one of two doors.
//
// `open` — THE PHONE'S "+" CARRIES UPLOAD TOO (structural redesign spec §4.3, slice 7). At ≤719px the
// top bar's Upload button hides and the New menu offers "Upload…", which forwards a click to that
// BUTTON — never to the file input: on a page with no folder the button's click is what
// upload_pick_controller.js handles to ask for a folder first, and an input-targeted click would skip
// it and upload to the library root unasked. Runs inside the tap's own click, so the user activation
// the file picker needs is still live.
//
// `choose` — AN UPLOAD BUTTON OPENS ITS OWN HIDDEN INPUT (UX audit I: Upload was a <label> over the
// input and took no focus, so no keyboard could upload). The button and the input are siblings inside
// one `.uploader` (the share/s3 form or the chunk flow's section), which holds exactly one file
// input, so the button finds it there rather than carrying an id: the build log renders one upload
// control per entry. A page with no folder never wires this; its button asks first (upload-pick).
export default class extends Controller {
  open() {
    document.querySelector("header.topbar .topbar-upload .upload-btn")?.click()
  }

  choose() {
    this.element.closest(".uploader")?.querySelector("input[type=file]")?.click()
  }
}
