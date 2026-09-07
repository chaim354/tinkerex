import { Controller } from "@hotwired/stimulus"

// Put one string on the clipboard and say so on the button that asked.
//
// WHY A FALLBACK EXISTS AT ALL, AND WHY IT IS NOT BELT AND BRACES. `navigator.clipboard` is gated
// on a SECURE CONTEXT, and this app is routinely self-hosted at a plain-http hostname on a LAN
// (docs/DEPLOY.md) — so on the deployment this button is FOR, the modern API is simply `undefined`.
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
    this.timer = setTimeout(() => { button.textContent = this.original }, FLASH_MS)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
