import { Controller } from "@hotwired/stimulus"

// Live client-side filter over the grouped generator gallery. Typing in the search box hides
// cards whose terms don't match, then hides any group whose cards are all hidden, and shows a
// "no results" line when every group is hidden. No server round trip; with JS off the full
// grouped list still renders.
export default class extends Controller {
  static targets = ["query", "card", "group", "empty"]

  filter() {
    const q = this.queryTarget.value.trim().toLowerCase()
    for (const card of this.cardTargets) {
      card.hidden = q !== "" && !card.dataset.terms.includes(q)
    }
    for (const group of this.groupTargets) {
      group.hidden = this.cardTargets.filter((c) => group.contains(c)).every((c) => c.hidden)
    }
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = this.groupTargets.some((g) => !g.hidden)
    }
  }
}
