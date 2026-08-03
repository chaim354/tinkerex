import { Controller } from "@hotwired/stimulus"

// Loads an addon bundle and hands it the host context. Addon-AGNOSTIC by construction: it never
// names an addon, and the bundle's only contract is a default export with mount(element, context).
// The bundle is NOT a Stimulus controller — an addon must not have to know the host's JS framework.
export default class extends Controller {
  static targets = ["mount"]
  static values = { entry: String, saveUrl: String, folders: Array, defaultFolder: String }

  async connect() {
    try {
      const module = await import(this.entryValue)
      await module.default.mount(this.mountTarget, {
        saveUrl: this.saveUrlValue,
        folders: this.foldersValue,
        defaultFolder: this.defaultFolderValue,
        csrfToken: document.querySelector("meta[name=csrf-token]")?.content,
      })
    } catch (e) {
      this.mountTarget.textContent = `This tool failed to load: ${e.message}`
    }
  }
}
