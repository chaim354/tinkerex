import { Controller } from "@hotwired/stimulus"
import { chooseFolder, chooseFile } from "lib/file_chooser"
import { keep, take, deadCopy, previewing, pageUrl } from "lib/kept_tools"
import { initHost, suspendHost, resumeHost, endHost } from "@maker/addon-sdk"

// Loads an addon bundle and hands it the host context. Addon-AGNOSTIC by construction: it never
// names an addon, and the bundle's only contract is a default export with mount(element, context).
// The bundle is NOT a Stimulus controller — an addon must not have to know the host's JS framework.
//
// A WORKING TOOL IS KEPT WHEN ITS PAGE IS LEFT, AND TAKEN BACK WHEN THE MAKER RETURNS (2026-11-24;
// lib/kept_tools.js says what a session is and how long it lasts). disconnect() hands over the live
// mount and suspends its host instead of tearing it down; connect() asks for a kept session before
// it imports anything, and a resumed tool is the same elements and the same JavaScript it was, so
// the bundle is not mounted a second time and learns nothing happened.
export default class extends Controller {
  // `loading`, `failure`, `detail` and `resumed` are the host's own markup around the mount
  // (tools/addons/show.html.erb), never the bundle's: a bundle is handed `mount` and nothing else.
  static targets = [ "mount", "loading", "failure", "detail", "resumed" ]
  static values = {
    entry: String, saveUrl: String, serviceUrl: String, statesUrl: String,
    folders: Array, defaultFolder: String, defaultFolderLabel: String,
    childrenUrl: String, createUrl: String, ctx: Object, owner: String,
  }

  async connect() {
    this.disposed = false
    this.host = null // the Host this page bound: what disconnect() ends, or keeps
    this.live = null // { tool, url } once a bundle is working here: what makes the mount worth keeping
    // A preview is a cached copy shown until the real page arrives. Mounting into it was always
    // wasted work, and taking a kept session for it would hand the tool to a page about to go.
    if (previewing()) return
    // The line is the page's, so a page restored from Turbo's cache brings back whatever it showed
    // last time. It is true only of the visit that resumes.
    if (this.hasResumedTarget) this.resumedTarget.hidden = true
    try {
      // THE TOOL AS IT WAS LEFT, IF IT WAS LEFT WITHIN THE LAST 15 MINUTES. Asked before the host
      // is initialized, because a kept session brings its own host and must not meet a new one:
      // `take` either returns the session or has ended it, so from here on this tool has exactly
      // one live mount. The tool is its page's path; a query names what it was opened for.
      const tool = window.location.pathname
      const kept = take({ tool, url: pageUrl(), owner: this.ownerValue, plain: window.location.search === "" })
      if (kept) {
        this.mountTarget.replaceWith(kept.node)
        this.host = resumeHost(kept.host)
        this.live = { tool, url: kept.url }
        if (this.hasResumedTarget) this.resumedTarget.hidden = false
        return
      }

      const chooser = (options = {}) => chooseFolder({
        childrenUrl: this.childrenUrlValue,
        createUrl: this.createUrlValue,
        value: this.defaultFolderValue,
        label: this.defaultFolderLabelValue,
        ...options,
      })
      // THE FILE-MODE SIBLING, AND IT SHARES NONE OF chooser's SEEDING ON PURPOSE. `value`/`label`
      // seed a FOLDER selection; in file mode the chooser starts with nothing selected by design
      // (lib/file_chooser.js's #open), because there is no "current file" for a picker to resume
      // from and pre-selecting one would answer a question the user has not been asked.
      const filePicker = (options = {}) => chooseFile({
        childrenUrl: this.childrenUrlValue,
        createUrl: this.createUrlValue,
        ...options,
      })
      const csrfToken = document.querySelector("meta[name=csrf-token]")?.content

      // INITIALIZED BEFORE THE BUNDLE IS IMPORTED, and the order is the contract: a bundle's
      // top-level code runs at import time, so `host` must already be bound by then. The two
      // members added here are the ones the server cannot serialize — a function, and a token
      // that already lives in a meta tag and must not be duplicated into a second DOM node.
      //
      // CAUGHT ON ITS OWN, SEPARATE FROM THE IMPORT/MOUNT BELOW: this.ctxValue re-parses the
      // data-addon-ctx-value JSON attribute on every read, and everything initHost can throw is
      // about the HOST's own wiring, not the bundle. Falling through to the outer catch would
      // report a malformed ctx blob as the addon's own error when the bundle never got a chance to
      // be the problem. The page's sentence is the same either way ("Could not load NAME"), since
      // the maker can do nothing different about the two; the folded-away detail says which half.
      try {
        this.host = initHost({ ...this.ctxValue, chooseFolder: chooser, chooseFile: filePicker, csrfToken })
      } catch (e) {
        this.fail(`The host failed to initialize: ${e.message}`)
        return
      }

      const module = await import(this.entryValue)
      // A Turbo navigation can disconnect() this controller while the import above is still in
      // flight — disconnect() has already ended the host (every host read throws again) by
      // the time this resolves. Calling mount() anyway would hand the bundle a torn-down host: if
      // the bundle registers a window/document listener or timer BEFORE its first host touch,
      // mount() aborts on that host-read error before the bundle ever reaches
      // host.on("teardown", …) to remove it — an orphaned listener with nothing left to clean it
      // up. Bail before mount() ever runs.
      if (this.disposed) return
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
        chooseFolder: chooser,
        // ADDED, NEVER SUBSTITUTED FOR ANYTHING. §10.1's compatibility rule is about what may not
        // be REMOVED; a new key is free, and the raw-ctx path stays a supported path (§10.2), so
        // a bundle that never adopts the SDK still gets the picker. Same contract as chooseFolder
        // above: -> Promise<{nodeId, kind, path} | null>, null meaning CANCEL.
        chooseFile: filePicker,
        csrfToken,
      })
      // Every shipped bundle replaced the loading line as its first act; one that appends instead
      // would leave it standing over a working tool. A target that has left the DOM is not found.
      if (this.hasLoadingTarget) this.loadingTarget.remove()
      // ONLY NOW IS THERE A TOOL TO KEEP: a mount that failed, or one a navigation overtook, is
      // ended on the way out as it always was.
      if (!this.disposed) this.live = { tool, url: pageUrl() }
    } catch (e) {
      this.fail(e?.message || String(e))
    }
  }

  // "Could not load NAME", with the raw message folded into a <details> for whoever reports it —
  // never the page's own sentence, which is the maker's (UX audit G3). Not after disconnect():
  // a torn-down page has nothing to say.
  fail(detail) {
    if (this.disposed) return
    this.mountTarget.replaceChildren()
    if (this.hasFailureTarget) {
      if (this.hasDetailTarget) this.detailTarget.textContent = detail
      this.failureTarget.hidden = false
    } else {
      this.mountTarget.textContent = detail
    }
  }

  // The resumed line's button: this tool again, from nothing. The host is ended here, so the
  // disconnect() the visit causes finds no tool to keep, and the page that arrives mounts fresh.
  startOver() {
    this.live = null
    endHost(this.host)
    this.host = null
    window.Turbo.visit(window.location.href, { action: "replace" })
  }

  disconnect() {
    this.disposed = true
    const host = this.host
    this.host = null
    if (!this.live || !suspendHost(host)) {
      // Nothing worth keeping: a failed mount, one still loading, a preview, or a host another
      // page already took over. Ended BY INSTANCE, so leaving this page can never tear down
      // another tool's kept host that happens to be the one bound.
      endHost(host)
      this.live = null
      return
    }
    // THE LIVE MOUNT LEAVES WITH ITS HOST; A DEAD COPY STAYS. The copy is what Turbo's snapshot of
    // this page holds either way (it clones the page as it is replaced), and without one a snapshot
    // taken after this ran would have no mount target for the next connect() to find.
    const node = this.mountTarget
    node.replaceWith(deadCopy(node))
    keep({ ...this.live, owner: this.ownerValue, node, host, release: () => endHost(host) })
    this.live = null
  }
}
