import { Controller } from "@hotwired/stimulus"

// THE MATERIAL ESTIMATE PAGE (tools/materials/show; spec 2026-11-22-material-estimate-design.md).
// It submits the one form at the right moments and nothing else — the server does every measurement
// and every sum. A number typed re-figures after a pause; picking files submits them to the measure
// action; a project or a chosen folder or file adds at once.
//
// ONE SUBMISSION AT A TIME, AND IT IS FINISHED WHEN ITS ANSWER IS ON THE PAGE. Two in flight can
// answer out of order, and an older answer landing last would put stale results on screen (Turbo also
// aborts a form's submission when the next one starts). A re-figure or an upload asked for during one
// is held and sent once that one has finished — which is NOT `turbo:submit-end`: Turbo fires that when
// the REQUEST finishes, before it renders a turbo-stream answer, so a submission sent then reads a
// form without the parts that answer is about to add, and its own answer lands last. A stream answer
// has finished when its results have rendered (every stream answer replaces #material-results, after
// the parts list when that changed: update.turbo_stream); any other answer (a page, an error) at
// submit-end. A timeout settles a stream answer whose results never render, so the page cannot be
// left refusing to submit.
//
// WHAT WAS CHANGED IN THE PARTS LIST MEANWHILE IS CARRIED ONTO THE LIST THE ANSWER PUTS BACK: a
// quantity typed, a project or a library item chosen, files picked. The answer was rendered from the
// form as it was sent, so its replace would put the old values back and the held submission would
// send those. Quantities are carried by row, so never across a remove, which renumbers the rows: a
// quantity typed during a remove is lost, and the screen and the results still agree.
//
// The stock is remembered in this browser — a convenience, so every read and write is wrapped: a
// private window or blocked storage must leave the page working.
const STOCK_KEY = "tinkerex.material.stock"
const MM_PER = { mm: 1, in: 25.4 }
const PAUSE_MS = 300
const SETTLE_MS = 2000
const STREAM_TYPE = "text/vnd.turbo-stream.html"
const PARTS_ID = "material-parts"
const RESULTS_ID = "material-results"
const PART_FIELD = /^parts\[\d+\]\[/

export default class extends Controller {
  static targets = [ "sheetWidth", "sheetHeight", "gap", "unit", "rotate", "uploads", "measure", "update" ]

  connect() {
    this.inFlight = false
    this.pending = null // null, "form" (a re-figure) or "upload"
    this.sent = null // the FormSubmission in flight: what it sent, and its submitter
    document.addEventListener("turbo:before-stream-render", this.streamRendering)
    this.restoreStock()
    this.unit = this.unitTarget.value
  }

  disconnect() {
    clearTimeout(this.timer)
    clearTimeout(this.settleTimer)
    document.removeEventListener("turbo:before-stream-render", this.streamRendering)
  }

  // The no-JavaScript buttons, hidden once this controller can do their job. A target callback, not
  // connect(): the parts list is replaced by a stream and its Measure button comes back with it.
  measureTargetConnected(button) { button.hidden = true }
  updateTargetConnected(button) { button.hidden = true }

  refigure() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit("form"), PAUSE_MS)
  }

  stockChanged(event) {
    if (event.target === this.unitTarget) this.convertUnit()
    this.saveStock()
    this.refigure()
  }

  add() {
    clearTimeout(this.timer)
    this.submit("form")
  }

  upload() {
    if (!this.uploadsTarget.files.length) return
    clearTimeout(this.timer)
    this.submit("upload")
  }

  submitStart(event) {
    clearTimeout(this.settleTimer)
    this.inFlight = true
    this.sent = event.detail?.formSubmission ?? null
  }

  submitEnd(event) {
    const type = event.detail?.fetchResponse?.contentType ?? ""
    if (type.startsWith(STREAM_TYPE)) {
      this.settleTimer = setTimeout(() => this.settle(), SETTLE_MS)
    } else {
      this.settle()
    }
  }

  // A document listener: Turbo renders a stream by appending it to <html>, outside this form. The
  // event's `render` is the documented hook, wrapped here to act just before and after the replace.
  streamRendering = (event) => {
    const { newStream, render } = event.detail ?? {}
    if (!this.inFlight || typeof render !== "function") return
    if (newStream?.target === PARTS_ID) {
      event.detail.render = async (stream) => {
        const changed = this.changedSinceSent()
        await render(stream)
        this.carry(changed)
      }
    } else if (newStream?.target === RESULTS_ID) {
      event.detail.render = async (stream) => {
        try { await render(stream) } finally { this.settle() }
      }
    }
  }

  settle() {
    clearTimeout(this.settleTimer)
    if (!this.inFlight) return
    this.inFlight = false
    this.sent = null
    const held = this.pending
    this.pending = null
    if (held) this.submit(held)
  }

  submit(kind) {
    if (this.inFlight) {
      // An upload outranks a held re-figure: it sends the whole form too, and carries something new.
      if (kind === "upload" || this.pending === null) this.pending = kind
      return
    }
    // The Measure button is looked up now, never kept: the parts list it lives in may have been
    // replaced while this was held.
    kind === "upload" ? this.element.requestSubmit(this.measureTarget) : this.element.requestSubmit()
  }

  // The parts list's values that are not what the submission in flight sent, read just before its
  // answer replaces the list; and the files picked for a held upload.
  changedSinceSent() {
    const sent = this.sent?.body
    const removing = this.sent?.submitter?.name === "remove"
    const values = []
    for (const control of document.getElementById(PARTS_ID)?.querySelectorAll("input, select") ?? []) {
      if (control.disabled || control.type === "file" || (removing && PART_FIELD.test(control.name))) continue
      if (control.name && control.value !== String(sent?.get?.(control.name) ?? "")) values.push([ control.name, control.value ])
    }
    return { values, files: this.pending === "upload" ? this.uploadsTarget.files : null }
  }

  carry({ values, files }) {
    const controls = [ ...(document.getElementById(PARTS_ID)?.querySelectorAll("input, select") ?? []) ]
    for (const [ name, value ] of values) {
      const control = controls.find((c) => c.name === name)
      if (control && !control.disabled) control.value = value
    }
    if (files?.length) this.uploadsTarget.files = files
  }

  convertUnit() {
    const from = MM_PER[this.unit]
    const to = MM_PER[this.unitTarget.value]
    if (from && to && from !== to) {
      for (const input of [ this.sheetWidthTarget, this.sheetHeightTarget, this.gapTarget ]) {
        const value = parseFloat(input.value)
        if (Number.isFinite(value)) input.value = String(Math.round((value * from / to) * 1000) / 1000)
      }
    }
    this.unit = this.unitTarget.value
  }

  restoreStock() {
    let saved = null
    try { saved = JSON.parse(localStorage.getItem(STOCK_KEY) || "null") } catch { saved = null }
    if (!saved || typeof saved !== "object") return

    if (saved.unit in MM_PER) this.unitTarget.value = saved.unit
    const fields = [ [ "width", this.sheetWidthTarget ], [ "height", this.sheetHeightTarget ], [ "gap", this.gapTarget ] ]
    for (const [ key, input ] of fields) {
      if (typeof saved[key] === "string" && saved[key] !== "") input.value = saved[key]
    }
    if (typeof saved.rotate === "boolean") this.rotateTarget.checked = saved.rotate
  }

  saveStock() {
    try {
      localStorage.setItem(STOCK_KEY, JSON.stringify({
        unit: this.unitTarget.value, width: this.sheetWidthTarget.value, height: this.sheetHeightTarget.value,
        gap: this.gapTarget.value, rotate: this.rotateTarget.checked,
      }))
    } catch {
      // Storage refused (a private window, blocked site data): the page works without remembering.
    }
  }
}
