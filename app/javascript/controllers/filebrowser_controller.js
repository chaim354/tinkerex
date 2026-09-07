import { Controller } from "@hotwired/stimulus"
import { FileChooser } from "lib/file_chooser"

// A REPOSITORY'S FILES, BROWSED FINDER-STYLE INSIDE ITS OWN <details> on the project page — the
// Miller-columns module the boxes addon's folder picker uses (lib/file_chooser.js), mounted inline
// in `browse` mode: folders descend, files are links to their file page. Mounted LAZILY on the first
// open of the enclosing <details>, because a repo section is closed by default (2026-09-07, at the
// user's request) and a browser nobody opened should cost no request.
//
// THE <details> IS AN ANCESTOR, WHICH STIMULUS ACTIONS CANNOT TARGET — `data-action` binds on the
// controller element and its descendants — so the toggle listener is attached by hand here and
// removed on disconnect. (Putting the controller ON the <details> instead was the other option and
// is worse: the partial would then own the section's whole element rather than its own subtree,
// and _file_tree_section already writes that tag.)
//
// TURBO RESTORES A SNAPSHOT WITH THE COLUMNS ALREADY IN IT and then connects a FRESH controller
// that holds nothing for them — `this.chooser` is undefined on the new instance while the DOM still
// shows the old columns, which are inert markup nothing is wired to. So `connect` mounts again when
// the details is already open, and `mount` replaces the container's contents rather than appending.
export default class extends Controller {
  static values = { childrenUrl: String, root: String, rootLabel: String, fileUrlTemplate: String }
  static targets = [ "mount" ]

  connect() {
    this.details = this.element.closest("details")
    this.onToggle = () => this.reveal()
    this.details?.addEventListener("toggle", this.onToggle)
    if (this.details?.open) this.reveal()
  }

  disconnect() {
    this.details?.removeEventListener("toggle", this.onToggle)
    this.chooser?.destroy()
    this.chooser = null
  }

  // Idempotent in both directions: already mounted, or the details closed again (a `toggle` fires
  // on close too, and mounting into a hidden section would spend the fetch this laziness exists to
  // avoid). The columns are NOT torn down on close — reopening a section a maker collapsed by
  // accident should not re-fetch what is already on screen.
  reveal() {
    if (this.chooser || !this.details?.open) return
    this.chooser = new FileChooser({
      mode: "browse",
      childrenUrl: this.childrenUrlValue,
      rootId: this.rootValue,
      rootLabel: this.rootLabelValue,
      fileUrlTemplate: this.fileUrlTemplateValue
    })
    this.chooser.mount(this.mountTarget)
  }
}
