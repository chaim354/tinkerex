import { Controller } from "@hotwired/stimulus"

// A share/s3 library scan is a BACKGROUND job — an unbounded NAS walk or bucket listing, which is
// why library_scan polls every 15 minutes rather than every 15 seconds — so the page that started
// it cannot show the result. Reload once, after a delay.
//
// IT NAVIGATES TO A URL RATHER THAN CALLING reload(), AND THAT IS WHAT STOPS IT LOOPING. The page
// renders this element only when ?scanning=1 is present; urlValue is the same page WITHOUT that
// param, so the reloaded page renders no scanreload element and schedules nothing. A bare
// location.reload() would carry the param forward and reload forever.
//
// THE DELAY IS A GUESS, KNOWINGLY. A large library outlasts it and the reloaded page will show no
// new files — which is why the flash that accompanies this says a large library takes longer and
// to reload again. A status endpoint to poll is the upgrade path if that proves unsatisfying.
export default class extends Controller {
  static values = {
    url: String,
    delay: { type: Number, default: 6000 }
  }

  connect() {
    this.timer = setTimeout(() => window.location.replace(this.urlValue), this.delayValue)
  }

  // Turbo caches and restores pages, so a timer left running after the user navigates away would
  // yank them back to a project page they had left.
  disconnect() {
    clearTimeout(this.timer)
  }
}
