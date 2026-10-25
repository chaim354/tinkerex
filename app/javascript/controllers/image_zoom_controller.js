import { Controller } from "@hotwired/stimulus"
import { installPanZoom } from "lib/svg_pan_zoom"

// A FILE PAGE'S PICTURE, OPENED BIG AND ZOOMABLE (2026-10-25). Mounted by files/viewers/_zoomable,
// which every resting picture on both file pages renders: a plain image, the server-rendered
// poster of a thumbnail format, and the posters at rest in the Measure, 3D and board viewers.
// Clicking the picture (or Enter / Space on it) opens a native <dialog> the size of the window.
//
// THE PAN AND ZOOM ARE lib/svg_pan_zoom's, THE MEASURE VIEW'S AND THE BOARD'S, NEVER A FOURTH COPY
// (docs/invariants/files-preview.md). That module moves an SVG viewBox, so the picture is put on
// the stage as an SVG <image> whose user space is the poster's own box, and the module is handed
// that box as `home`. Wheel about the cursor, drag, pinch, the clamp and Reset all come with it;
// the stage CSS supplies `touch-action: none`, without which a pinch never reaches it.
//
// THE PICTURE IS READ OFF THE POSTER AT OPEN, never passed in, so the overlay shows what the page
// shows: the 3D viewer's "Use this view as preview" swaps its poster's src, and this follows it.
// An <image> is a replaced element exactly as the <img> is, so an SVG file's own poster runs no
// script here either (§15's rule for user SVG is about inlining markup, which this never does).
//
// A NATIVE <dialog> OPENED WITH showModal(), as the calculator is: the page goes inert, Tab stays
// inside, Esc closes it, and focus goes back to the picture. Closing empties the stage, so the next
// open re-reads the poster.
//
// CONNECT RESTS THE ELEMENT, the three viewers' rule (files-preview.md). A Back or Forward with the
// overlay open (a phone's back gesture) leaves Turbo a snapshot whose dialog carries `open` and a
// drawn stage; restored, that clone would sit open INLINE, in the card, with nothing driving it.
const SVG_NS = "http://www.w3.org/2000/svg"
// One + or − press: two and a half wheel notches (1.15 each), so a few presses cross the range.
const BUTTON_STEP = 1.4

export default class extends Controller {
  static targets = ["source", "dialog", "stage"]

  connect() {
    this.rest()
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  disconnect() {
    this.rest()
  }

  async open(event) {
    // Space on a role="button" would otherwise scroll the page as well.
    if (event?.type === "keydown") event.preventDefault()
    if (this.dialogTarget.open) return

    const img = this.sourceTarget
    const src = img.currentSrc || img.getAttribute("src")
    // A PICTURE THAT DID NOT LOAD HAS NOTHING TO ENLARGE, and `decode()` is what says so: it rejects
    // for a broken image and waits for one still loading. A natural size of 0 x 0 cannot say it,
    // because the HTML spec gives an SVG with only a viewBox no natural size either.
    if (!src || !(await img.decode().then(() => true, () => false))) return
    const box = this.sourceBox(img)
    if (!box || this.dialogTarget.open) return

    const svg = document.createElementNS(SVG_NS, "svg")
    // lib/svg_pan_zoom's letterbox maths assumes exactly this; it says so, and sets nothing itself.
    svg.setAttribute("preserveAspectRatio", "xMidYMid meet")
    svg.setAttribute("role", "img")
    svg.setAttribute("aria-label", img.alt)
    const image = document.createElementNS(SVG_NS, "image")
    image.setAttribute("href", src)
    image.setAttribute("width", box.width)
    image.setAttribute("height", box.height)
    svg.append(image)
    this.stageTarget.replaceChildren(svg)

    this.returnFocus = document.activeElement
    this.dialogTarget.showModal()
    this.panZoom = installPanZoom(svg, { home: [ 0, 0, box.width, box.height ] })
  }

  close() {
    if (this.dialogTarget.open) this.dialogTarget.close()
  }

  // The dialog's own `close` event, whichever way it closed: Esc, the Close button, connect().
  closed() {
    this.rest()
    const target = this.returnFocus
    this.returnFocus = null
    if (target && target.isConnected && typeof target.focus === "function") target.focus()
  }

  reset() {
    this.panZoom?.reset()
  }

  zoomIn() {
    this.panZoom?.zoomBy(1 / BUTTON_STEP)
  }

  zoomOut() {
    this.panZoom?.zoomBy(BUTTON_STEP)
  }

  rest() {
    this.panZoom?.destroy()
    this.panZoom = null
    if (this.hasStageTarget) this.stageTarget.replaceChildren()
  }

  // THE USER SPACE IS THE POSTER'S LAID-OUT BOX, NOT ITS NATURAL SIZE. Any box with the picture's
  // shape would do (the stage scales it to fit), and the laid-out one has that shape however a
  // browser sizes an SVG with only a viewBox: Chrome reports one of 100 x 160 as 94 x 150 natural
  // (measured), close enough here, where the spec's answer is no natural size at all.
  sourceBox(img) {
    const rect = img.getBoundingClientRect()
    return rect.width > 0 && rect.height > 0 ? { width: rect.width, height: rect.height } : null
  }
}
