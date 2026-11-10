import { Controller } from "@hotwired/stimulus"

// Put one string on the clipboard and say so on the button that asked.
//
// WHY A FALLBACK EXISTS AT ALL, AND WHY IT IS NOT BELT AND BRACES. `navigator.clipboard` is gated
// on a SECURE CONTEXT, and this app is routinely self-hosted at a plain-http hostname on a LAN
// (docs/guides/DEPLOY.md) — so on the deployment this button is FOR, the modern API is simply `undefined`.
// A copy button that silently does nothing there is worse than no button. `document.execCommand`
// is deprecated and is still the only thing that works in that context.
//
// THREE OUTCOMES, EACH VISIBLE: the clipboard took it (the button flashes), the fallback took it
// (same flash — the user cannot tell and does not need to), or neither could, in which case the
// text is SELECTED so a manual ⌘C finishes the job. Nothing here fails silently.
//
// S4-4 MOUNTS THIS ON THE PUBLIC URL, so `text` is a value rather than something read off the DOM:
// a caller that has the string does not have to also render it.
const FLASH_MS = 1500

export default class extends Controller {
  static values = { text: String, label: { type: String, default: "Copied" } }
  static targets = ["source"]

  // "COPIED" IS SAID, NOT ONLY SHOWN (UX audit I, 2026-11-02). The button's own text swaps for the
  // eye, but a screen reader does not reliably re-read a focused button whose label changed, so
  // the word also goes into a polite live region. Three things about that region not to undo:
  //   * It is its OWN element, never role="status" on the button: that role would REPLACE the
  //     button's, and the control would stop being announced as something to press.
  //   * It exists from connect(), empty. A live region speaks when text CHANGES inside it; one
  //     inserted with its words already in it is often silent.
  //   * It sits BESIDE the controller's element when that element is the button itself (the layout
  //     drawer's Copy), inside it otherwise, so flash()'s `textContent` swap can never delete it.
  // A restored Turbo snapshot already carries one, so connect() adopts it rather than adding a second.
  connect() {
    this.status = this.findStatus() || this.buildStatus()
    this.status.textContent = ""
  }

  async copy(event) {
    // CAPTURED BEFORE THE AWAIT, AND THE MEASUREMENT IS NARROWER THAN THE OBVIOUS CLAIM.
    // `event.currentTarget` is nulled when DISPATCH finishes, not when the listener returns — the
    // microtask checkpoint runs inside the DOM's "invoke" step, so a continuation resuming after an
    // ALREADY-RESOLVED promise still sees the button. Probed, not assumed: moving this line below
    // the `await` left the browser test green, and `const button = null` in its place turned it red
    // — so the flash assertion carries weight and the ordering claim is the part that does not
    // reproduce under a synchronous stub. What a late read does NOT survive is a `writeText` that
    // genuinely suspends (a permission prompt, a busy compositor), which is the REAL clipboard on
    // the deployment this button is for; the flash then lands on nothing, with no error, on a
    // button that appears to do nothing. One line here removes the whole question.
    const button = event?.currentTarget
    const text = this.textValue
    if (!text) return

    let ok = false
    try {
      if (window.isSecureContext && navigator.clipboard) {
        await navigator.clipboard.writeText(text)
        ok = true
      }
    } catch (_e) {
      ok = false
    }
    if (!ok) ok = this.execCopy(text)
    if (ok) this.flash(button)
    else this.selectSource()
  }

  // The insecure-context path. The textarea must be IN the layout to be selectable — `hidden` and
  // `display:none` cannot be selected, so the copy silently does nothing — hence off-screen and
  // transparent rather than hidden. `readonly` keeps iOS from raising the keyboard.
  execCopy(text) {
    const area = document.createElement("textarea")
    area.value = text
    area.setAttribute("readonly", "")
    area.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0"
    document.body.appendChild(area)
    area.select()
    let ok = false
    try {
      ok = document.execCommand("copy")
    } catch (_e) {
      ok = false
    }
    area.remove()
    return ok
  }

  // Neither door worked: leave the text selected so ⌘C finishes it by hand.
  selectSource() {
    if (!this.hasSourceTarget) return
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  // `original` is captured on the FIRST flash, before the label is replaced, so a second click
  // inside the window restores the real word rather than "Copied".
  flash(button) {
    if (!button) return
    clearTimeout(this.timer)
    this.original ??= button.textContent
    button.textContent = this.labelValue
    this.announce(this.labelValue)
    this.timer = setTimeout(() => {
      button.textContent = this.original
      this.announce("")
    }, FLASH_MS)
  }

  // EMPTIED FIRST, WRITTEN ON THE NEXT FRAME: a second copy inside the flash window would otherwise
  // write "Copied" over "Copied", which is no change, and a live region says nothing about no change.
  announce(text) {
    if (!this.status) return
    this.status.textContent = ""
    if (text) requestAnimationFrame(() => { if (this.status) this.status.textContent = text })
  }

  get standsAlone() {
    return this.element.matches("button, input")
  }

  findStatus() {
    const candidate = this.standsAlone ? this.element.nextElementSibling : this.element.querySelector(":scope > [data-copy-status]")
    return candidate?.matches("[data-copy-status]") ? candidate : null
  }

  // Visually hidden, the way execCopy's textarea is placed: in the layout, so assistive technology
  // reads it, and clipped to nothing, so nobody sees it. `hidden` would silence it.
  buildStatus() {
    const status = document.createElement("span")
    status.setAttribute("role", "status")
    status.dataset.copyStatus = ""
    status.style.cssText = "position:absolute;width:1px;height:1px;margin:-1px;padding:0;border:0;" +
                           "overflow:hidden;clip:rect(0 0 0 0);clip-path:inset(50%);white-space:nowrap"
    if (this.standsAlone) this.element.after(status)
    else this.element.append(status)
    return status
  }

  // A region placed BESIDE a lone button is not removed with it, so it goes when the button does;
  // inside the element it leaves with the element on its own.
  disconnect() {
    clearTimeout(this.timer)
    // Unconditional: a lone button MOVED elsewhere reconnects and builds a new region, so the old
    // one beside its former place would otherwise stay behind.
    if (this.standsAlone) this.status?.remove()
  }
}
