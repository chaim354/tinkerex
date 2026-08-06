import { Controller } from "@hotwired/stimulus"
import { FileChooser, ROOT_LABEL } from "lib/file_chooser"

// The FORM-FIELD face of the chooser: a trigger button plus a hidden input (shared/_folder_field).
// The modal itself lives in lib/file_chooser.js, because the other caller — an addon bundle, via
// addon_controller.js's `ctx.chooseFolder` — is not a Stimulus controller and must not have to
// become one. Everything specific to being a form field is here and nothing else is.
//
// Two reuse contracts, and they are separate on purpose: in a form this writes the chosen node_id
// into the hidden input, and for non-form consumers it fires `filechooser:choose` with
// {nodeId, kind, path}. A caller may use either without the other.
export default class extends Controller {
  static values = {
    mode: { type: String, default: "folder" },
    childrenUrl: String,
    createUrl: String,
    rootLabel: { type: String, default: ROOT_LABEL },
    value: String,
    label: String,
  }
  static targets = [ "button", "input" ]

  // Closes an open modal if the element goes away (a Turbo navigation mid-choose). The chooser
  // resolves with null, so #open's own `if (!selection) return` handles it — there is no second
  // cancel path to keep in step.
  disconnect() { this.chooser?.close() }

  async open() {
    this.chooser = new FileChooser({
      mode: this.modeValue,
      childrenUrl: this.childrenUrlValue,
      createUrl: this.createUrlValue,
      rootLabel: this.rootLabelValue,
      // The FIELD is the source of truth for what is currently chosen, not the initial `value:`
      // local: after one choose-and-reopen the input has moved on and the local has not.
      value: (this.hasInputTarget && this.inputTarget.value) || "",
      label: this.currentLabel(),
    })
    const selection = await this.chooser.open()
    this.chooser = null
    if (!selection) return

    if (this.hasInputTarget) this.inputTarget.value = selection.nodeId
    if (this.hasButtonTarget) {
      const path = this.buttonTarget.querySelector(".ff-path")
      if (path) path.textContent = selection.path
    }
    this.element.dispatchEvent(new CustomEvent("filechooser:choose", {
      bubbles: true, detail: { ...selection },
    }))
  }

  // Read back off the button for the same reason `value` is read off the input: the rendered label
  // is what a previous choose updated, and `labelValue` is only ever the initial render's.
  currentLabel() {
    const path = this.hasButtonTarget && this.buttonTarget.querySelector(".ff-path")
    return (path && path.textContent.trim()) || this.labelValue || this.rootLabelValue
  }
}
