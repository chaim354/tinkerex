import { Controller } from "@hotwired/stimulus"
import { evaluate, formatInches } from "lib/calc"

// THE CALCULATOR MODAL (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md), mounted
// ONCE by layouts/_calculator.html.erb on every signed-in page. The arithmetic is lib/calc.js — a
// hand-written parser, never `eval` or `new Function` (the CSP nonces script-src, and an expression
// box is exactly where neither belongs). This file is only the dialog around it.
//
// ONE DELEGATED OPENER, NOT A CONTROLLER PER BUTTON. Anything on the page carrying
// `data-calculator-open` opens the modal — the rail's pinned link, the Tools card, a saved
// calculation's "Open in calculator" — with `data-calculator-expression` and
// `data-calculator-fraction` to start from. The openers sit outside this element (the rail, a
// project panel), where a Stimulus action cannot reach it, so `click@document` is the one door.
// The keyboard's door is Alt+C (⌥C), `keydown@document` (#shortcut, 2026-10-22).
//
// ENTER EVALUATES; IT DOES NOT EVALUATE AS YOU TYPE. A half-typed `3 +` is an error on every key,
// and a calculator that flashes red while you write is one nobody trusts. Typing only marks the last
// answer stale.
//
// HISTORY AND THE INCH DISPLAY ARE PER BROWSER (localStorage), every read and write in try/catch: a
// private window or blocked storage costs the history and nothing else. The SIDEBAR PIN is not here
// — it is the maker's, so it lives on the user with every pinned tool (Maker::ToolPins).
const HISTORY_KEY = "tinkerex:calculator:history"
const FRACTION_KEY = "tinkerex:calculator:fraction"
const HISTORY_MAX = 20
const DENOMINATORS = [0, 16, 32]

export default class extends Controller {
  static targets = ["dialog", "input", "result", "alt", "error", "fractionChoice", "saveDetails", "saveFrame",
                    "saveHint", "saveExpression", "saveResult", "saveUnit", "saveFraction", "saveWhat",
                    "recent", "history"]
  static values = { saveUrl: String }

  connect() {
    this.answer = null
    this.denominator = readFraction()
    this.renderFractionChoice()
    this.renderHistory()
  }

  // --- Opening and closing ---

  openFrom(event) {
    const opener = event.target.closest?.("[data-calculator-open]")
    if (!opener || event.defaultPrevented) return
    // A modified click on the rail's link is the browser's (a new tab onto /tools), not ours.
    if (opener.tagName === "A" && (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button > 0)) return
    event.preventDefault()
    this.open({ expression: opener.dataset.calculatorExpression, fraction: opener.dataset.calculatorFraction, opener })
  }

  open({ expression, fraction, opener } = {}) {
    // Already open (the shortcut, pressed again from a button inside it), focus goes back to the
    // input and the place to return to on close stays the one the maker opened it from.
    if (!this.dialogTarget.open) {
      this.returnFocus = opener || document.activeElement
      this.dialogTarget.showModal()
    }
    // A saved calculation reopens at the display it was saved with (an empty attribute is decimal);
    // the rail and the card carry no attribute and keep this browser's own choice.
    if (fraction !== undefined) this.setDenominator(Number(fraction) || 0)
    if (expression) {
      this.inputTarget.value = expression
      this.calculate()
    }
    this.inputTarget.focus()
    this.inputTarget.select()
  }

  // THE KEYBOARD SHORTCUT, Alt+C (⌥C on a Mac), from anywhere on a signed-in page that is not taking
  // typing (2026-10-22). Alt rather than Ctrl/⌘: Ctrl+Shift+C is the browsers' inspect-element key
  // and nearly every Ctrl/⌘ letter is taken, while Alt+C is unbound in Chrome, Firefox, Edge and
  // Safari, and jspreadsheet's grid ignores Alt-chords where it would start editing on a bare key.
  // A bare key was ruled out because a single-character shortcut must be possible to turn off
  // (WCAG 2.1.4) and `=` starts a formula in a selected sheet cell. Never in a field, a contenteditable
  // (Lexxy) or a CodeMirror editor, so it can never eat a typed character: on a Mac ⌥C types ç.
  shortcut(event) {
    if (event.defaultPrevented || event.repeat || event.isComposing) return
    if (!event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return
    // The letter C on whatever layout; on a Mac, where ⌥ turns the key into ç, the physical C key.
    if (!(/^c$/i.test(event.key) || (!/^[a-z]$/i.test(event.key) && event.code === "KeyC"))) return
    if (takesTyping(event.composedPath()[0] || event.target)) return
    event.preventDefault()
    this.open()
  }

  // KEYS AND CLIPBOARD EVENTS INSIDE THE CALCULATOR STOP AT THE DIALOG. A page-wide listener cannot
  // tell them from the page's own: jspreadsheet puts its key, paste, copy and cut handlers on
  // `document`, and a cell stays selected under a keyboard-opened calculator (a click elsewhere
  // would have deselected it). Measured: Backspace typed here CLEARED THE CELL. Read from
  // vendor/javascript/jspreadsheet.js: the arrows and Enter move the grid's selection and swallow
  // the key, a paste lands in the cell, and a cut clears it. The shortcut is offered first, so Alt+C
  // from a button in the dialog still brings focus back to the input.
  contain(event) {
    if (event.type === "keydown") this.shortcut(event)
    event.stopPropagation()
  }

  close() {
    if (this.hasDialogTarget && this.dialogTarget.open) this.dialogTarget.close()
  }

  // The dialog's own `close` event, whichever way it closed — Esc, the × button, the backdrop.
  closed() {
    const target = this.returnFocus
    this.returnFocus = null
    if (target && target.isConnected && typeof target.focus === "function") target.focus()
  }

  // A click on the ::backdrop is a click on the <dialog> itself, outside its box.
  backdrop(event) {
    if (event.target !== this.dialogTarget) return
    const box = this.dialogTarget.getBoundingClientRect()
    const inside = event.clientX >= box.left && event.clientX <= box.right &&
                   event.clientY >= box.top && event.clientY <= box.bottom
    if (!inside) this.close()
  }

  // --- Calculating ---

  submit(event) {
    event.preventDefault()
    const answer = this.calculate()
    if (answer) this.remember(answer)
  }

  edited() {
    this.resultTarget.classList.add("stale")
    this.errorTarget.hidden = true
  }

  calculate() {
    const expression = this.inputTarget.value.trim()
    const result = evaluate(expression)
    this.resultTarget.classList.remove("stale")
    if (!result.ok) {
      this.answer = null
      this.resultTarget.textContent = ""
      this.altTarget.textContent = ""
      this.errorTarget.textContent = result.error
      this.errorTarget.hidden = false
      this.fractionChoiceTarget.hidden = true
      this.renderSaveWhat()
      return null
    }
    this.answer = { expression, ...result }
    this.errorTarget.hidden = true
    this.renderAnswer()
    this.renderSaveWhat()
    return this.answer
  }

  renderAnswer() {
    const answer = this.answer
    if (!answer) return
    this.fractionChoiceTarget.hidden = !answer.fractionable
    const fraction = this.fractionText(answer)
    if (fraction) {
      this.resultTarget.textContent = fraction
      this.altTarget.textContent = answer.text
    } else {
      this.resultTarget.textContent = answer.text
      this.altTarget.textContent = ""
    }
  }

  // `≈ 3 3/16 in` for an inch answer while 1/16 or 1/32 is chosen, else null.
  fractionText(answer) {
    if (!answer.fractionable || !this.denominator) return null
    const { text, exact } = formatInches(answer.value, this.denominator)
    return exact ? text : `≈ ${text}`
  }

  chooseFraction(event) {
    this.setDenominator(Number(event.params.denominator))
    writeStorage(FRACTION_KEY, String(this.denominator))
    this.renderAnswer()
    this.renderSaveWhat()
  }

  setDenominator(value) {
    this.denominator = DENOMINATORS.includes(value) ? value : 0
    this.renderFractionChoice()
  }

  renderFractionChoice() {
    this.fractionChoiceTarget.querySelectorAll("button").forEach((button) => {
      const on = Number(button.dataset.calculatorDenominatorParam) === this.denominator
      button.classList.toggle("active", on)
      button.setAttribute("aria-pressed", on ? "true" : "false")
    })
  }

  // --- Recent results ---

  remember(answer) {
    const history = readHistory().filter((item) => item.expression !== answer.expression)
    history.unshift({ expression: answer.expression, text: answer.text })
    writeStorage(HISTORY_KEY, JSON.stringify(history.slice(0, HISTORY_MAX)))
    this.renderHistory()
  }

  renderHistory() {
    const history = readHistory()
    this.recentTarget.hidden = history.length === 0
    this.historyTarget.replaceChildren(...history.map((item) => {
      const li = document.createElement("li")
      const button = document.createElement("button")
      button.type = "button"
      button.className = "calculator-history-item"
      const expression = document.createElement("code")
      expression.textContent = item.expression
      const text = document.createElement("span")
      text.className = "calculator-history-result"
      text.textContent = `= ${item.text}`
      button.append(expression, text)
      button.addEventListener("click", () => {
        this.inputTarget.value = item.expression
        this.calculate()
        this.inputTarget.focus()
      })
      li.append(button)
      return li
    }))
  }

  clearHistory() {
    writeStorage(HISTORY_KEY, "[]")
    this.renderHistory()
    this.inputTarget.focus()
  }

  // --- Save to project ---

  // The frame's src is set the first time the section opens, so a page view that never saves never
  // asks the server for its projects (CalculationsController#new).
  saveToggled() {
    if (!this.saveDetailsTarget.open) return
    if (!this.saveFrameTarget.getAttribute("src")) this.saveFrameTarget.setAttribute("src", this.saveUrlValue)
    this.renderSaveWhat()
  }

  // THE FRAME CAME BACK WITHOUT ITS FORM — a session that expired since the page loaded answers
  // with the sign-in page — and Turbo's own answer is "Content missing". Say what to do instead.
  // The src is cleared, so the next time Save to project opens it asks the server again.
  saveMissing(event) {
    event.preventDefault()
    const note = document.createElement("p")
    note.className = "calculator-save-error"
    note.textContent = "Couldn't load your projects. Reload the page, signing in again if asked, then try again."
    this.saveFrameTarget.replaceChildren(note)
    this.saveFrameTarget.removeAttribute("src")
  }

  // WHAT IS SAVED IS WHAT IS ON SCREEN: the four hidden fields are filled here, at submit, from the
  // current answer — never from whatever the form held when it rendered.
  // An expression edited since the last Enter is calculated now, so the answer saved is the one
  // for the text in the box — never the stale one still greyed out under it.
  prepareSave(event) {
    if (this.answer?.expression !== this.inputTarget.value.trim()) {
      const answer = this.calculate()
      if (answer) this.remember(answer)
    }
    if (!this.answer || !this.hasSaveExpressionTarget) {
      event.preventDefault()
      this.saveHintTarget.hidden = false
      this.inputTarget.focus()
      return
    }
    this.saveHintTarget.hidden = true
    this.saveExpressionTarget.value = this.answer.expression
    this.saveResultTarget.value = String(this.answer.value)
    this.saveUnitTarget.value = this.answer.unit
    this.saveFractionTarget.value = this.answer.fractionable && this.denominator ? String(this.denominator) : ""
  }

  // The form arrives in a frame, after connect, and again after every save (the stream replaces it).
  saveWhatTargetConnected() {
    this.renderSaveWhat()
  }

  renderSaveWhat() {
    if (this.answer) this.saveHintTarget.hidden = true
    if (!this.hasSaveWhatTarget) return
    this.saveWhatTarget.textContent = this.answer
      ? `Saves ${this.fractionText(this.answer) || this.answer.text}`
      : "Press Enter to calculate first."
  }
}

// Where a keystroke is someone's typing: any form field, a contenteditable (Lexxy's editor and
// CodeMirror's content are both one), or anything inside a CodeMirror or Lexxy editor.
function takesTyping(element) {
  if (!(element instanceof Element)) return false
  if (element.isContentEditable) return true
  return !!element.closest("input, textarea, select, .cm-editor, lexxy-editor")
}

function readStorage(key) {
  try { return window.localStorage.getItem(key) } catch { return null }
}

function writeStorage(key, value) {
  try { window.localStorage.setItem(key, value) } catch { /* private window or blocked storage */ }
}

function readHistory() {
  try {
    const parsed = JSON.parse(readStorage(HISTORY_KEY) || "[]")
    return Array.isArray(parsed)
      ? parsed.filter((item) => item && typeof item.expression === "string" && typeof item.text === "string").slice(0, HISTORY_MAX)
      : []
  } catch {
    return []
  }
}

function readFraction() {
  const value = Number(readStorage(FRACTION_KEY))
  return DENOMINATORS.includes(value) ? value : 0
}
