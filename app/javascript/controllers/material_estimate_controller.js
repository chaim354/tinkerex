import { Controller } from "@hotwired/stimulus"

// THE MATERIAL ESTIMATE PAGE (tools/materials/show; spec 2026-11-22-material-estimate-design.md).
// It submits the one form at the right moments and nothing else — the server does every measurement
// and every sum. A number typed re-figures after a pause; picking files submits them to the measure
// action; a project or a chosen folder or file adds at once.
//
// ONE SUBMISSION AT A TIME. Two in flight can answer out of order, and an older answer landing last
// would put stale results on screen. A re-figure asked for during one is held and sent once it ends.
//
// The stock is remembered in this browser — a convenience, so every read and write is wrapped: a
// private window or blocked storage must leave the page working.
const STOCK_KEY = "tinkerex.material.stock"
const MM_PER = { mm: 1, in: 25.4 }
const PAUSE_MS = 300

export default class extends Controller {
  static targets = [ "sheetWidth", "sheetHeight", "gap", "unit", "rotate", "uploads", "measure", "update" ]

  connect() {
    this.inFlight = false
    this.pending = null
    this.restoreStock()
    this.unit = this.unitTarget.value
  }

  disconnect() { clearTimeout(this.timer) }

  // The no-JavaScript buttons, hidden once this controller can do their job. A target callback, not
  // connect(): the parts list is replaced by a stream and its Measure button comes back with it.
  measureTargetConnected(button) { button.hidden = true }
  updateTargetConnected(button) { button.hidden = true }

  refigure() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.submit(null), PAUSE_MS)
  }

  stockChanged(event) {
    if (event.target === this.unitTarget) this.convertUnit()
    this.saveStock()
    this.refigure()
  }

  add() {
    clearTimeout(this.timer)
    this.submit(null)
  }

  upload() {
    if (!this.uploadsTarget.files.length) return
    clearTimeout(this.timer)
    this.submit(this.measureTarget)
  }

  submitStart() { this.inFlight = true }

  submitEnd() {
    this.inFlight = false
    if (this.pending === null) return
    const submitter = this.pending === "form" ? null : this.pending
    this.pending = null
    this.submit(submitter)
  }

  submit(submitter) {
    if (this.inFlight) {
      // An upload outranks a held re-figure: it is the one carrying something new.
      if (submitter || this.pending === null) this.pending = submitter || "form"
      return
    }
    submitter ? this.element.requestSubmit(submitter) : this.element.requestSubmit()
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
