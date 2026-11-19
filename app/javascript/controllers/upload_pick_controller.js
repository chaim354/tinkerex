import { Controller } from "@hotwired/stimulus"
import { chooseFolder } from "lib/file_chooser"

// THE TOP BAR'S UPLOAD ON A PAGE THAT SHOWS NO FOLDER (structural redesign spec §4.2 and §8, slice 4).
// Recent, Tools, Settings and Search have no "folder you're in", so a click on Upload asks for one with
// the library's own chooser, writes it where the upload flow reads its destination, and only then
// opens the file picker. It never guesses: a cancelled chooser uploads nothing.
//
// IT ASKS ON EVERY CLICK (UX audit A7). The first choice used to stick for every later click on the
// page with nothing on screen saying so: the caption that names it hides below 1100px, so a second
// upload went to the first one's folder unasked. Now each click asks again, opening on the folder
// chosen last, so the same folder is one Choose away and a different one is never a surprise.
//
// TWO FLOWS, TWO PLACES TO WRITE (layouts/_topbar_upload.html.erb): the share/s3 form's hidden
// `parent_node_id` (the `parent` target) or the chunk uploader's `data-uploader-parent-node-id-value`
// (the `uploader` target), which uploader_controller.js reads at upload time.
//
// THE ACTION IS ON THE UPLOAD BUTTON, AND THE FILE INPUT IS ITS SIBLING (UX audit I: Upload was a
// <label> wrapping the input and took no focus). So the input's own click never reaches this action,
// and nothing here has to tell the two apart, as the label version did.
//
// THE FILE PICKER OPENS FROM THE CHOOSER'S OWN CLICK. `input.click()` needs a user activation, and the
// chooser resolves inside its Choose button's click handler, so the activation is still live here.
// The system tests count the click the input receives (topbar_upload_test.rb, phone_topbar_test.rb),
// which proves the call; that a real browser then shows its dialog is the manual check, because
// headless Chrome shows none and Capybara's `attach_file` sets the input's files directly.
export default class extends Controller {
  static targets = [ "input", "parent", "uploader", "caption" ]
  static values = { childrenUrl: String, createUrl: String }

  async pick(event) {
    event.preventDefault()

    const selection = await chooseFolder({ childrenUrl: this.childrenUrlValue, createUrl: this.createUrlValue,
                                           ...this.lastChoice })
    if (!selection) return

    const nodeId = selection.nodeId || ""
    // Seeds the next click's chooser (FileChooser's `value` and `label`, which must agree).
    this.lastChoice = { value: nodeId, label: selection.path }
    if (this.hasParentTarget) this.parentTarget.value = nodeId
    if (this.hasUploaderTarget) this.uploaderTarget.setAttribute("data-uploader-parent-node-id-value", nodeId)
    if (this.hasCaptionTarget) {
      const strong = document.createElement("strong")
      // The SERVER'S spelling (FolderDestination::Destination#caption): root-relative with no leading
      // slash, and "the library root" for the root — not the chooser's own "/cad" and "/ (library root)",
      // so the caption reads the same whichever way the folder was chosen.
      strong.textContent = nodeId ? selection.path.replace(/^\//, "") : "the library root"
      this.captionTarget.replaceChildren("Saves to ", strong)
      this.captionTarget.hidden = false
    }
    this.inputTarget.click()
  }
}
