import { Controller } from "@hotwired/stimulus"

// Live client-side filter over the grouped generator gallery. Typing in the search box hides
// cards whose terms don't match, then hides any group whose cards are all hidden. No server round
// trip; with JS off the full grouped list still renders.
export default class extends Controller {
  static targets = ["query", "card", "group"]

  filter() {
    const q = this.queryTarget.value.trim().toLowerCase()
    for (const card of this.cardTargets) {
      card.hidden = q !== "" && !card.dataset.terms.includes(q)
    }
    for (const group of this.groupTargets) {
      const cards = group.querySelectorAll("[data-boxfilter-target='card']")
      group.hidden = Array.from(cards).every((c) => c.hidden)
    }
  }
}
