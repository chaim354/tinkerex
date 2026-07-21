import { Controller } from "@hotwired/stimulus"

// Generator tiles hotlink boxes.py's sample photo, but many generators have none (the image 404s).
// Hide the broken <img> so the tile falls back cleanly to its text instead of a broken-image icon.
export default class extends Controller {
  connect() {
    // catch an image that already failed before this controller connected (fast 404 / from cache)
    if (this.element.complete && this.element.naturalWidth === 0) this.hide()
  }

  hide() {
    this.element.classList.add("is-missing")
  }
}
