import { Controller } from "@hotwired/stimulus"

// THE NAME IS HISTORICAL — see boxpreview_controller.js. This was the Box Generator's gallery
// filter; the Box Generator is now a runtime-loaded ESM bundle and this file serves ONLY
// /tools/openscad. Not renamed, for the reason given there.
//
// Live client-side filter over the generator gallery. Typing in the search box hides cards whose
// terms don't match, then hides a group whose cards are all hidden, and shows a "no results" line
// when every group is hidden. No server round trip; with JS off the full list still renders.
//
// DELETED BY ACCIDENT in 6095b87, same as boxpreview — see that file's header for what a silently
// unresolvable Stimulus identifier costs and which test now catches it.
//
// TRIMMED ON RESTORE, deliberately. The deleted version also forced collapsed <details> sections
// open while a query was live and hid table-of-contents entries, both for the Box Generator's
// grouped, collapsible index. /tools/openscad renders ONE flat `<div class="box-group">` and no
// table of contents, and the `boxsections` controller that owned those <details> went in the same
// commit — so the `tocitem` target and the reveal pass would have come back as dead code whose own
// comment pointed at a controller that no longer exists. Restoring them verbatim would have been
// restoring a lie about the page.
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
