import { Controller } from "@hotwired/stimulus"

// A share/s3 library scan is a BACKGROUND job — an unbounded NAS walk or bucket listing, which is
// why library_scan polls every 15 minutes rather than every 15 seconds — so the page that started
// one cannot show the result. This waits for it and then reloads, ONCE.
//
// IT POLLS A REAL "SCAN FINISHED" AS OF STAGE 4, S4-3, AND USED TO GUESS 6000 ms. The guess was
// honest about being one (its own comment said "a large library outlasts it"), and the flash beside
// it had to tell the user to reload again. `users.library_scanned_at` is stamped by
// Library::ScanJob when a pass completes; `sinceValue` is what that column read when this page was
// RENDERED, so "different and present" means a scan finished after the page was built. A scan that
// finished having changed nothing still advances it, and reloading to see nothing new is the honest
// answer to pressing Rescan.
//
// IT NAVIGATES TO A URL RATHER THAN CALLING reload(), AND THAT IS WHAT STOPS IT LOOPING. The page
// renders this element only when ?scanning=1 is present; urlValue is the same page WITHOUT that
// param, so the reloaded page renders no scanreload element and polls nothing. A bare
// location.reload() would carry the param forward and reload forever.
//
// GIVING UP SAYS SOMETHING TRUE FOR ALL THREE ENDINGS. At the deadline the scan may still be
// walking, or it may have REFUSED (Library::Scanner::UnsafeScan stamps nothing, by design — see
// Library::ScanJob#perform), and this page cannot tell those apart. "Still scanning" would be a
// guess again; "nothing yet" is what is actually known.
const NOTHING_YET = "Nothing yet — reload to check again."

export default class extends Controller {
  static values = {
    url: String,
    statusUrl: String,
    since: String,
    interval: { type: Number, default: 2000 },
    timeout: { type: Number, default: 60000 }
  }

  connect() {
    this.deadline = Date.now() + this.timeoutValue
    this.tick()
  }

  // Turbo caches and restores pages, so a poll left running after the user navigates away would
  // yank them back to a page they had left.
  disconnect() {
    clearTimeout(this.timer)
  }

  async tick() {
    if (Date.now() >= this.deadline) return this.giveUp()

    try {
      const res = await fetch(this.statusUrlValue, { headers: { Accept: "application/json" } })
      if (res.ok) {
        const stamp = (await res.json()).scanned_at
        // PRESENT **AND** DIFFERENT. `stamp` alone would reload on a deployment that has scanned
        // before and has not scanned since; `!==` alone would reload forever on a user who has
        // never scanned at all, because null !== "".
        if (stamp && stamp !== this.sinceValue) return window.location.replace(this.urlValue)
      }
    } catch (_e) {
      /* transient; ask again below */
    }

    this.timer = setTimeout(() => this.tick(), this.intervalValue)
  }

  giveUp() {
    this.element.textContent = NOTHING_YET
  }
}
