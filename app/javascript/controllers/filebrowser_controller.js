import { Controller } from "@hotwired/stimulus"
import { FileChooser } from "lib/file_chooser"

// A FOLDER'S FILES, BROWSED FINDER-STYLE — the Miller-columns module the boxes addon's folder
// picker uses (lib/file_chooser.js), mounted inline in `browse` mode: folders descend, files are
// links to their file page.
//
// IT HAS TWO HOSTS AND THE LAZINESS BELONGS TO ONE OF THEM (2026-09-08, folder panels). A
// repository NESTED below depth one is a closed <details> inside its parent panel
// (projects/_file_tree_section), so its browser mounts LAZILY on the first open — a browser nobody
// opened should cost no request. A DEPTH-ONE folder is a PANEL now (projects/_folder_panel), and a
// panel has no <details> around it at all: it is on screen the moment the page is, so it mounts on
// `connect`.
//
// THE ENCLOSING <details> IS WHAT DECIDES, AND ITS ABSENCE MEANS "MOUNT", NEVER "WAIT". Written as
// `if (this.details?.open)` alone — which is how this shipped — a browser with no <details> above it
// evaluates `undefined`, returns, and mounts NOTHING: the server writes the div, Stimulus connects
// the controller, and the panel is permanently empty with no error and no console warning. That is
// §14d's silent-no-op shape exactly, and it is why `hostOpen()` names the two cases rather than
// leaning on optional chaining to mean one of them.
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
    if (this.hostOpen()) this.reveal()
  }

  // No <details> above it — a folder panel — is ALWAYS open; one that is there answers for itself.
  hostOpen() { return this.details ? this.details.open : true }

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
    if (this.chooser || !this.hostOpen()) return
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
