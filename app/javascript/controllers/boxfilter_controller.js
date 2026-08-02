import { Controller } from "@hotwired/stimulus"

// Live client-side filter over the grouped generator gallery. Typing in the search box hides
// cards whose terms don't match, then hides any group whose cards are all hidden, and shows a
// "no results" line when every group is hidden. No server round trip; with JS off the full
// grouped list still renders.
//
// Since the groups became collapsible <details>, filtering has to open them too: a match inside a
// collapsed section is a match the user cannot see, which reads exactly like no match at all. The
// state each section was left in is stashed on the first keystroke and put back when the box is
// cleared, so filtering borrows the layout rather than rewriting it.
export default class extends Controller {
  static targets = ["query", "card", "group", "empty", "tocitem"]

  filter() {
    const q = this.queryTarget.value.trim().toLowerCase()
    for (const card of this.cardTargets) {
      card.hidden = q !== "" && !card.dataset.terms.includes(q)
    }
    for (const group of this.groupTargets) {
      group.hidden = this.cardTargets.filter((c) => group.contains(c)).every((c) => c.hidden)
    }
    this.#reveal(q)
    for (const item of this.tocitemTargets) {
      const group = this.groupTargets.find((g) => g.id === item.dataset.section)
      item.hidden = Boolean(group?.hidden)
    }
    if (this.hasEmptyTarget) {
      this.emptyTarget.hidden = this.groupTargets.some((g) => !g.hidden)
    }
  }

  // While a query is live every surviving section is forced open; clearing the box restores whatever
  // was open before the search started. `details` here are the same elements boxsections persists, so
  // this deliberately does NOT write through to storage — a search is a temporary view, not a choice.
  #reveal(q) {
    if (q === "") {
      if (this.prior) {
        for (const group of this.groupTargets) {
          if (this.prior.has(group)) group.open = this.prior.get(group)
        }
        this.prior = null
      }
      return
    }

    this.prior ||= new Map(this.groupTargets.map((g) => [g, g.open]))
    for (const group of this.groupTargets) {
      if (!group.hidden) group.open = true
    }
  }
}
