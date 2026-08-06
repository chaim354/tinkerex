import { Controller } from "@hotwired/stimulus"
import { chooseFolder } from "lib/file_chooser"

// Loads an addon bundle and hands it the host context. Addon-AGNOSTIC by construction: it never
// names an addon, and the bundle's only contract is a default export with mount(element, context).
// The bundle is NOT a Stimulus controller — an addon must not have to know the host's JS framework.
export default class extends Controller {
  static targets = [ "mount" ]
  static values = {
    entry: String, saveUrl: String, serviceUrl: String, statesUrl: String,
    folders: Array, defaultFolder: String, defaultFolderLabel: String,
    childrenUrl: String, createUrl: String,
  }

  async connect() {
    try {
      const module = await import(this.entryValue)
      await module.default.mount(this.mountTarget, {
        saveUrl: this.saveUrlValue,
        serviceUrl: this.serviceUrlValue,
        statesUrl: this.statesUrlValue,
        // THE FLAT LIST STAYS, and removing it is the one change here that would break production
        // without any test noticing. The two repos deploy INDEPENDENTLY — republishing a bundle IS
        // the addon deploy and Rails is never rebuilt (§14c) — so at any moment a bundle built
        // against either context may be running against a host built against the other. Every
        // shipped bundle today builds its own <select> from these two, and `bin/rollback` in the
        // addons repo can put one of those back at any time. `folders` goes when no reachable
        // bundle reads it, which is a decision for that repo, not this one.
        folders: this.foldersValue,
        defaultFolder: this.defaultFolderValue,
        // The default folder's PATH ("/Projects/harbor"), for a bundle that shows a chooser trigger
        // instead of a select. The select got its label from the `folders` pairs; a chooser has no
        // list to look one up in, so the host has to say it.
        defaultFolderLabel: this.defaultFolderLabelValue,
        // THE CHOOSER, AS A FUNCTION RATHER THAN MARKUP OR A MODULE PATH. Markup was the obvious
        // alternative — have Rails render shared/_folder_field into the shell — and it cannot work:
        // the bundle owns its own layout and the host has no idea where in it a destination field
        // belongs. A module specifier was the other, and it would make lib/file_chooser.js's path
        // part of the addon API, unmovable without republishing every bundle.
        //
        // -> Promise<{nodeId, kind, path} | null>. null is CANCEL, and is deliberately not the same
        // answer as choosing the library root ({nodeId: ""}): a bundle that conflates them silently
        // moves the user's destination to root when they press Esc.
        //
        // Absent on an older host, which is exactly why it is worth feature-detecting in the bundle
        // (`typeof ctx.chooseFolder === "function"`) rather than assuming.
        chooseFolder: (options = {}) => chooseFolder({
          childrenUrl: this.childrenUrlValue,
          createUrl: this.createUrlValue,
          value: this.defaultFolderValue,
          label: this.defaultFolderLabelValue,
          ...options,
        }),
        csrfToken: document.querySelector("meta[name=csrf-token]")?.content,
      })
    } catch (e) {
      this.mountTarget.textContent = `This tool failed to load: ${e.message}`
    }
  }
}
