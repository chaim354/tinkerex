import { Controller } from "@hotwired/stimulus"
import { chooseFolder } from "lib/file_chooser"

// THE TOP BAR'S UPLOAD ON A PAGE THAT SHOWS NO FOLDER (structural redesign spec §4.2 and §8, slice 4).
// Home, Tools, Settings and Search have no "folder you're in", so the first click asks for one with the
// library's own chooser, writes it where the upload flow reads its destination, and only then opens
// the file picker. It never guesses: a cancelled chooser uploads nothing.
//
// TWO FLOWS, TWO PLACES TO WRITE (layouts/_topbar_upload.html.erb): the share/s3 form's hidden
// `parent_node_id` (the `parent` target) or the chunk uploader's `data-uploader-parent-node-id-value`
// (the `uploader` target), which uploader_controller.js reads at upload time.
//
// THE FILE PICKER OPENS FROM THE CHOOSER'S OWN CLICK. `input.click()` needs a user activation, and the
// chooser resolves inside its Choose button's click handler, so the activation is still live here.
// NO AUTOMATED TEST SEES THAT HAPPEN: Capybara's `attach_file` sets the input's files directly, so
// deleting the `click()` below leaves every test green. A human clicking Upload on Home, then Choose,
// is the only check that the picker opens.
export default class extends Controller {
  static targets = [ "input", "parent", "uploader", "caption" ]
  static values = { childrenUrl: String, createUrl: String }

  async pick(event) {
    // The programmatic click below bubbles back through this label; let it through, and let every
    // click after a folder is chosen open the picker directly.
    if (this.chosen || event.target === this.inputTarget) return
    event.preventDefault()

    const selection = await chooseFolder({ childrenUrl: this.childrenUrlValue, createUrl: this.createUrlValue })
    if (!selection) return

    const nodeId = selection.nodeId || ""
    if (this.hasParentTarget) this.parentTarget.value = nodeId
    if (this.hasUploaderTarget) this.uploaderTarget.setAttribute("data-uploader-parent-node-id-value", nodeId)
    if (this.hasCaptionTarget) {
      const strong = document.createElement("strong")
      strong.textContent = selection.path
      this.captionTarget.replaceChildren("Saves to ", strong)
      this.captionTarget.hidden = false
    }
    this.chosen = true
    this.inputTarget.click()
  }
}
