import { Controller } from "@hotwired/stimulus"

// THE COLUMN'S "FIND A FILE OR FIGURE" (the Shop manual spec §7 and §9; projects/_contents). Typing
// filters the index of files in place; Enter goes to the figure — a number to that figure, a name to
// the first match's; Escape clears the box, puts the index back and drops the selected figure. The
// work is the index's (files_index_controller.js, this controller's outlet): this box only says what
// was typed and reads the answer out in its status line.
//
// CLIENT-SIDE OVER WHAT THE PAGE RENDERED, no endpoint: the index already holds every entry and every
// figure carries its number. Below 960px the column is a sheet over the page, so going to a figure
// closes it first (shell_controller.js#closeColumn), or the figure would be scrolled to under it.
export default class extends Controller {
  static targets = ["input", "status"]
  static outlets = ["files-index"]

  filter() {
    if (!this.hasFilesIndexOutlet) return
    const { matches, total } = this.filesIndexOutlet.filter(this.inputTarget.value)
    this.say(this.inputTarget.value.trim() === "" ? "" : `${matches} of ${total} ${total === 1 ? "file" : "files"}`)
  }

  key(event) {
    if (event.key === "Escape") {
      const typed = this.inputTarget.value !== ""
      this.clear()
      // An Escape that cleared the box is not the column sheet's Escape as well (the aside closes on
      // one, below 960px); a second one, in an empty box, closes the sheet as anywhere else in it.
      if (typed) {
        event.preventDefault()
        event.stopPropagation()
      }
    } else if (event.key === "Enter") {
      event.preventDefault()
      this.go()
    }
  }

  // `go` IS DISPATCHED FIRST: below 960px it closes the column sheet (shell_controller.js), which
  // hands the focus to the strip's Contents button, and that must happen before the scroll to the
  // figure starts, or the focus would pull the window back up to the strip.
  go() {
    if (!this.hasFilesIndexOutlet) return
    this.dispatch("go")
    this.filesIndexOutlet.filter(this.inputTarget.value)
    const sentence = this.filesIndexOutlet.find(this.inputTarget.value)
    if (sentence) this.say(sentence)
  }

  clear() {
    this.inputTarget.value = ""
    if (this.hasFilesIndexOutlet) this.filesIndexOutlet.reset()
    this.say("")
  }

  say(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }
}
