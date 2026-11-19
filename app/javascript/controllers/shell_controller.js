import { Controller } from "@hotwired/stimulus"

// The signed-in shell (Shop manual spec §7, slice 3), on <body>: the search shortcuts and the left
// column's sheet below 960px. It replaced rail_controller.js with the rail. Turbo swaps the body on
// every visit, so this reconnects with each page and the document listener is detached with the old one.
//
// SEARCH: `/` FROM ANYWHERE NOT TAKING TYPING, AND CTRL/CMD-K FROM ANYWHERE (spec §11.5). Both focus
// the strip's box and select what is in it. `/` is a character a maker types, so it is left alone in
// a form field, a contenteditable, a code or rich-text editor (calculator_controller.js's own test of
// "typing"), with any modifier held, while a dialog or the file chooser is open, and on a page with a
// spreadsheet grid, whose document-wide key handler starts editing a selected cell on any character.
// Below 720px the box is display:none (an icon links to the Search page instead), so neither key does
// anything there.
//
// THE COLUMN'S SHEET: below 960px the column is off-canvas, and the strip's Contents button opens it
// over the page with a scrim. Opening moves focus into it; Escape (on the sheet), a click on the
// scrim, or the button again closes it and hands focus back to the button. The open state is a body
// class, so nothing on the page moves: the sheet and the scrim are fixed, and the column is not in
// the layout's flow below 960px. At 960px and up the column is part of the page and the class draws
// nothing.
export default class extends Controller {
  static targets = [ "column", "contents", "search" ]

  connect() {
    this.onKeydown = (event) => this.shortcut(event)
    document.addEventListener("keydown", this.onKeydown)
  }

  disconnect() {
    document.removeEventListener("keydown", this.onKeydown)
  }

  shortcut(event) {
    if (event.defaultPrevented || event.isComposing || !this.hasSearchTarget) return
    const chord = (event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === "k"
    const slash = event.key === "/" && !event.metaKey && !event.ctrlKey && !event.altKey &&
                  !takesTyping(event.composedPath()[0] || event.target) &&
                  !document.querySelector("dialog[open], .filechooser-overlay, .spreadsheet-grid")
    if (!chord && !slash) return
    // Hidden below 720px: there is no box to focus, and the key keeps its ordinary meaning.
    if (this.searchTarget.getClientRects().length === 0) return
    event.preventDefault()
    this.searchTarget.focus()
    this.searchTarget.select()
  }

  toggleColumn() {
    if (document.body.classList.contains("column-open")) this.closeColumn()
    else this.openColumn()
  }

  openColumn() {
    if (!this.hasColumnTarget) return
    document.body.classList.add("column-open")
    if (this.hasContentsTarget) this.contentsTarget.setAttribute("aria-expanded", "true")
    this.columnTarget.querySelector("a, button, input, summary")?.focus()
  }

  closeColumn() {
    if (!document.body.classList.contains("column-open")) return
    document.body.classList.remove("column-open")
    if (this.hasContentsTarget) {
      this.contentsTarget.setAttribute("aria-expanded", "false")
      this.contentsTarget.focus()
    }
  }
}

// Where a keystroke is someone's typing: any form field, a contenteditable (Lexxy's editor and
// CodeMirror's content are both one), or anything inside a CodeMirror or Lexxy editor. The same test
// calculator_controller.js applies to its own Alt+C.
function takesTyping(element) {
  if (!(element instanceof Element)) return false
  if (element.isContentEditable) return true
  return !!element.closest("input, textarea, select, .cm-editor, lexxy-editor")
}
