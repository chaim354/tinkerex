import { Controller } from "@hotwired/stimulus"

// THE MATERIAL ESTIMATE PAGE (tools/materials/show; spec 2026-11-22-material-estimate-design.md).
// It submits the one form at the right moments and nothing else — the server does every measurement
// and every sum. A number typed re-figures after a pause; picking files submits them to the measure
// action; a project or a chosen folder or file adds at once.
//
// ONE SUBMISSION AT A TIME, AND IT IS FINISHED WHEN ITS ANSWER IS ON THE PAGE. Two in flight can
// answer out of order, and an older answer landing last would put stale results on screen; Turbo also
// aborts a submission still waiting for its answer when the next one starts. So a re-figure, an
// upload or a remove asked for during one is held and sent once that one has finished — the page's
// own and a NATIVE submit alike: Enter (which presses the hidden default button) and a Remove click
// are cancelled by the form's `submit` action before Turbo sees them, and held. Finished is NOT
// `turbo:submit-end`: Turbo fires that when the answer's HEADERS arrive, and renders a turbo-stream
// answer only once the whole body is read and a frame has passed, so a submission sent at submit-end
// reads a form without the parts that answer is about to add, and its own answer lands last. A stream
// answer has finished when its results have rendered (every stream answer replaces #material-results,
// after the parts list when that changed: update.turbo_stream); any other answer (a page, an error) at
// submit-end. A timeout, started once the body has been read, settles a stream answer whose results
// never render, so the page cannot be left refusing to submit. An ABORTED submission (a visit stops
// it) drops what is held: sending it would cancel the visit, and the page is being left.
//
// WHAT IS HELD IS SENT ONE AT A TIME: an upload first, since it carries files nothing else can and its
// answer only appends rows; then each held remove, one per answer; a re-figure only when nothing else
// is held, since every submission sends the whole form anyway.
//
// WHAT WAS CHANGED IN THE PARTS LIST MEANWHILE IS CARRIED ONTO THE LIST THE ANSWER PUTS BACK: a
// quantity typed, a project or a library item chosen, files picked. The answer was rendered from the
// form as it was sent, so its replace would put the old values back and the held submission would
// send those. ROW NUMBERS FOLLOW THEIR ROWS: an answer only appends rows, except a remove, which moves
// every row below the removed one up one, so a carried quantity and a held remove's row number move
// up with their row (a held remove of the very row removed is dropped). A held remove whose button is
// gone by the time it is sent goes as a plain re-figure.
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
const PART_FIELD = /^parts\[(\d+)\](\[.*)$/

export default class extends Controller {
  static targets = [ "sheetWidth", "sheetHeight", "gap", "unit", "rotate", "uploads", "measure", "update" ]

  connect() {
    this.inFlight = false
    this.sent = null // the FormSubmission in flight: what it sent, and its submitter
    this.dropHeld()
    document.addEventListener("turbo:before-stream-render", this.streamRendering)
    this.restoreStock()
    this.unit = this.unitTarget.value
  }

  disconnect() {
    clearTimeout(this.timer)
    clearTimeout(this.settleTimer)
    this.inFlight = false
    this.dropHeld()
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

  // EVERY SUBMIT OF THIS FORM PASSES HERE FIRST (the form's `submit->` action), and Turbo acts on one
  // only if nothing cancelled it. While a submission is in flight the browser's own — Enter, a Remove
  // click — is cancelled and held, keeping what its button meant. This controller's own requestSubmit
  // is never in flight when it fires: submit() holds first.
  gateSubmit(event) {
    if (!this.inFlight) return
    event.preventDefault()
    const button = event.submitter
    const row = button?.name === "remove" ? Number.parseInt(button.value, 10) : NaN
    if (Number.isInteger(row)) this.hold({ remove: row })
    else this.hold(this.hasMeasureTarget && button === this.measureTarget ? "upload" : "form")
  }

  submitStart(event) {
    clearTimeout(this.settleTimer)
    this.inFlight = true
    this.sent = event.detail?.formSubmission ?? null
  }

  submitEnd(event) {
    const { formSubmission, fetchResponse, success } = event.detail ?? {}
    if (!fetchResponse && success === undefined) {
      // ABORTED: no answer and no error (turbo.js swallows the AbortError, so nothing set a result).
      this.dropHeld()
      this.settle()
    } else if (fetchResponse?.contentType?.startsWith(STREAM_TYPE)) {
      // Only the headers are in. The timeout counts from the body, and only for this submission.
      const arm = () => {
        if (this.inFlight && this.sent === formSubmission) this.settleTimer = setTimeout(() => this.settle(), SETTLE_MS)
      }
      fetchResponse.responseHTML.then(arm, arm)
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
        this.held.removes = this.held.removes.map((row) => this.rowAfterAnswer(row)).filter((row) => row !== null)
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
    const next = this.takeHeld()
    if (next) this.send(next)
  }

  submit(kind) {
    this.inFlight ? this.hold(kind) : this.send(kind)
  }

  // `kind` is "form" (a re-figure), "upload", or { remove: row }.
  hold(kind) {
    if (kind === "upload") this.held.upload = true
    else if (kind?.remove !== undefined) {
      if (!this.held.removes.includes(kind.remove)) this.held.removes.push(kind.remove)
    } else this.held.refigure = true
  }

  takeHeld() {
    const held = this.held
    if (held.upload) {
      held.upload = held.refigure = false
      return "upload"
    }
    if (held.removes.length) {
      held.refigure = false
      return { remove: held.removes.shift() }
    }
    if (held.refigure) {
      held.refigure = false
      return "form"
    }
    return null
  }

  dropHeld() { this.held = { upload: false, removes: [], refigure: false } }

  // Every button is looked up now, never kept: the parts list it lives in may have been replaced
  // while this was held.
  send(kind) {
    if (kind === "upload") return this.element.requestSubmit(this.measureTarget)
    const remove = kind?.remove !== undefined && this.element.querySelector(`button[name="remove"][value="${kind.remove}"]`)
    remove ? this.element.requestSubmit(remove) : this.element.requestSubmit()
  }

  // Where row `row` of the list as it was sent sits in the list its answer returns: an answer only
  // appends, except a remove, which takes its row out (null) and moves the rows below it up one.
  rowAfterAnswer(row) {
    const button = this.sent?.submitter
    const removed = button?.name === "remove" ? Number.parseInt(button.value, 10) : NaN
    if (!Number.isInteger(removed) || row < removed) return row
    return row === removed ? null : row - 1
  }

  // The parts list's values that are not what the submission in flight sent, read just before its
  // answer replaces the list, each under the name its row has in that answer; and the files picked
  // for a held upload.
  changedSinceSent() {
    const sent = this.sent?.body
    const values = []
    for (const control of document.getElementById(PARTS_ID)?.querySelectorAll("input, select") ?? []) {
      if (!control.name || control.disabled || control.type === "file") continue
      if (control.value === String(sent?.get?.(control.name) ?? "")) continue
      const name = this.nameAfterAnswer(control.name)
      if (name) values.push([ name, control.value ])
    }
    return { values, files: this.held.upload ? this.uploadsTarget.files : null }
  }

  nameAfterAnswer(name) {
    const part = PART_FIELD.exec(name)
    if (!part) return name
    const row = this.rowAfterAnswer(Number(part[1]))
    return row === null ? null : `parts[${row}]${part[2]}`
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
