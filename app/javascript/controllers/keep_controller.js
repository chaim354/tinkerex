import { Controller } from "@hotwired/stimulus"
import { keep, take, deadCopy, previewing, pageUrl } from "lib/kept_tools"

// A BUILT-IN TOOL'S PAGE KEEPS ITS PLACE (2026-11-24; lib/kept_tools.js says what a session is and
// how long it lasts). The Material estimate is a server-rendered form whose whole state is in the
// page: its parts ride as hidden fields, its results are the last answer's markup. So keeping it is
// keeping that subtree: disconnect() hands over the live `content`, connect() takes it back and
// puts it where the freshly rendered one is.
//
// An add-on does the same thing through addon_controller.js, which also has a host to suspend. This
// one has nothing but the elements, and the controllers inside them: Stimulus reconnects the same
// controller instances when their elements return to the page.
//
// THE KEPT FORM'S HIDDEN CSRF TOKEN IS NOT WHAT AUTHORISES ITS NEXT SUBMIT. Turbo sends the token of
// the page it is on as a header, and Rails takes either; a session never crosses a sign-out anyway
// (kept_tools.js's owner check).
export default class extends Controller {
  static targets = [ "content", "resumed" ]
  static values = { owner: String }

  connect() {
    this.live = null
    // A preview is a cached copy shown until the real page arrives: its content is a dead copy and
    // must never be kept over the live one.
    if (previewing()) return
    // The line is the page's, so a page restored from Turbo's cache brings back whatever it showed
    // last time. It is true only of the visit that resumes.
    if (this.hasResumedTarget) this.resumedTarget.hidden = true
    const tool = window.location.pathname
    const kept = take({ tool, url: pageUrl(), owner: this.ownerValue, plain: window.location.search === "" })
    if (kept) {
      this.contentTarget.replaceWith(kept.node)
      if (this.hasResumedTarget) this.resumedTarget.hidden = false
    }
    this.live = { tool, url: kept ? kept.url : pageUrl() }
  }

  // The resumed line's button: the page again, as the server renders it. Nothing is kept on the way
  // out, so the page that arrives finds no session.
  startOver() {
    this.live = null
    window.Turbo.visit(window.location.href, { action: "replace" })
  }

  disconnect() {
    if (!this.live) return
    // A dead copy stays where the live content was, for Turbo's snapshot of this page: it is what
    // Back shows once the session has expired, as it always did.
    const node = this.contentTarget
    node.replaceWith(deadCopy(node))
    keep({ ...this.live, owner: this.ownerValue, node })
    this.live = null
  }
}
