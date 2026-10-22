import { Controller } from "@hotwired/stimulus"
import { generate, validate } from "lib/compose_file"

// THE COMPOSE GENERATOR'S PAGE (/install/compose, 2026-10-21). Reads the inputs, shows or hides the
// folder and share fields, validates, and rebuilds the preview on every keystroke; Download hands the
// same text to the browser as a file. lib/compose_file.js does the building and holds the rules.
//
// NOTHING LEAVES THE TAB. There is no <form> on the page (so Enter cannot submit the values into a
// query string, even with this script missing), no fetch and no navigation: the values go into
// `generate` and the preview, and Download is a Blob URL the browser saves locally. Copy is
// copy_controller.js on the same element, which reads `data-copy-text-value`; this controller keeps
// that attribute equal to the preview, and empty while the inputs are invalid.
//
// THE FIELDS ARE READ BY NAME. Identifiers, ports and paths are trimmed, because a stray space would
// end up inside the file; the two passwords are taken exactly as typed.
const FILENAME = "docker-compose.yml"

export default class extends Controller {
  static targets = ["preview", "download", "copy", "folder", "share", "credentials", "status"]
  static values = { template: Object, guide: String }

  connect() {
    this.update()
  }

  field(name) {
    return this.element.querySelector(`[name="${name}"]`)
  }

  text(name) {
    return (this.field(name)?.value ?? "").trim()
  }

  choices() {
    return {
      library: this.element.querySelector('[name="library"]:checked')?.value ?? "folder",
      folderPath: this.text("folderPath"),
      shareServer: this.text("shareServer"),
      shareName: this.text("shareName"),
      shareGuest: !!this.field("shareGuest")?.checked,
      shareUser: this.text("shareUser"),
      sharePassword: this.field("sharePassword")?.value ?? "",
      shareVersion: this.text("shareVersion"),
      puid: this.text("puid"),
      pgid: this.text("pgid"),
      port: this.text("port"),
      tag: this.text("tag"),
      tools: !!this.field("tools")?.checked,
      forceSsl: !!this.field("forceSsl")?.checked,
      smtpAddress: this.text("smtpAddress"),
      appHost: this.text("appHost"),
      smtpPort: this.text("smtpPort"),
      smtpUser: this.text("smtpUser"),
      smtpPassword: this.field("smtpPassword")?.value ?? "",
      smtpAuthentication: this.text("smtpAuthentication"),
      smtpStarttls: !!this.field("smtpStarttls")?.checked,
      smtpDomain: this.text("smtpDomain"),
      mailFrom: this.text("mailFrom")
    }
  }

  update() {
    const choices = this.choices()
    this.folderTarget.hidden = choices.library !== "folder"
    this.shareTarget.hidden = choices.library !== "share"
    this.credentialsTarget.hidden = choices.shareGuest

    const errors = validate(choices)
    this.showErrors(errors)
    let yaml = ""
    let status = ""
    if (Object.keys(errors).length > 0) {
      status = "Fix the highlighted fields to see the file."
    } else {
      try {
        yaml = generate(this.templateValue, choices, { source: `${location.origin}${location.pathname}`, guide: this.guideValue })
      } catch (error) {
        status = `This server's docker-compose.yml could not be read: ${error.message}`
      }
    }
    this.yaml = yaml
    this.previewTarget.textContent = yaml
    this.previewTarget.hidden = !yaml
    this.statusTarget.textContent = status
    this.statusTarget.hidden = !status
    this.downloadTarget.disabled = !yaml
    this.copyTarget.disabled = !yaml
    this.element.setAttribute("data-copy-text-value", yaml)
  }

  // One message element per input name, marked `data-compose-error="<name>"`.
  showErrors(errors) {
    for (const el of this.element.querySelectorAll("[data-compose-error]")) {
      const name = el.dataset.composeError
      const message = errors[name] ?? ""
      el.textContent = message
      el.hidden = !message
      const input = this.field(name)
      if (!input) continue
      if (message) input.setAttribute("aria-invalid", "true")
      else input.removeAttribute("aria-invalid")
    }
  }

  // A Blob URL, saved under the one name compose looks for. Revoked later rather than at once: the
  // click starts the download asynchronously, and revoking first can cancel it.
  download() {
    if (!this.yaml) return
    const url = URL.createObjectURL(new Blob([this.yaml], { type: "application/yaml" }))
    const link = document.createElement("a")
    link.href = url
    link.download = FILENAME
    link.hidden = true
    document.body.append(link)
    link.click()
    link.remove()
    setTimeout(() => URL.revokeObjectURL(url), 10_000)
  }
}
