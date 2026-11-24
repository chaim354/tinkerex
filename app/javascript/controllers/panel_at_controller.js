import { Controller } from "@hotwired/stimulus"

// EVERY PANEL'S OPEN FOLDER, AS THE PAGE'S URL HAS IT NOW (2026-11-24, click-through panels). Each
// folder panel's open folder lives in the URL as `?at[<panel folder id>]=<node id>`, and every folder
// link and view button is rendered carrying ALL panels' `at` as of that render
// (ProjectsHelper#panel_at over @panel_at). But a folder link redraws only its own panel's frame, so
// every OTHER panel's links and buttons keep the `at` of the render that drew them. Open `itx` in
// `out` (`?at[d-out]=d-itx`), then a subfolder in `docs`: that link was drawn before the first
// click, so the URL became `?at[d-docs]=…` with `d-out` gone while `out` still showed `itx` — and a
// reload or a shared link put `out` back at its own folder. A view switch in `docs` dropped it too.
//
// SO THE LINK OR THE FORM TAKES THE OTHER PANELS FROM `window.location` AT THE MOMENT IT IS USED,
// which is the one place that knows: Turbo writes each promoted frame visit there. Mounted once, on
// the element in projects/show that holds every panel and that no frame swap or stream replaces,
// so an action inside a panel swapped in later still finds it.
//
//   * `follow` (a folder tile, a List-view folder row, a path-bar link): THIS link's own panel keeps
//     what the link says — present, or absent for a path-bar link back to the panel's own folder —
//     and every other panel's entry comes from the URL, the link's stale ones dropped. The panel is
//     `data-panel-at-panel`, read RAW: a Stimulus `-param` is JSON-typecast, and a node id is a
//     string whatever it looks like.
//   * `carry` (each view button's form): the form's `at` inputs become the URL's, all of them. A view
//     switch changes no folder, so the page's URL is the whole answer.
//
// ON THE ELEMENT'S OWN LISTENER, AND SYNCHRONOUSLY. Turbo reads a link's href in its click observer
// on the window's BUBBLE phase, and builds a form's FormData in its submit observer on the
// document's bubble phase; both run after the element's own listener has returned, so whatever this
// writes is what Turbo sends. The server-rendered href and inputs are unchanged, so with no
// JavaScript the page still works, stale at most. Every entry stays a STRING the server re-validates
// against the walk (ProjectsController#panel_paths), so nothing here can open what the page could not.
const AT = /^at\[.+\]$/

const isAt = ([name]) => AT.test(name)
const encoded = (pair) => new URLSearchParams([ pair ]).toString()

// The `at` entries of the page's URL, as [name, value] pairs.
function currentAt() {
  return [ ...new URL(window.location.href).searchParams ].filter(isAt)
}

export default class extends Controller {
  follow(event) {
    const link = event.currentTarget
    const panel = link.dataset.panelAtPanel
    if (!panel) return

    const own = `at[${panel}]`
    const url = new URL(link.href)
    const pairs = [ ...url.searchParams ]
    const at = pairs.filter((pair) => isAt(pair) && pair[0] === own)
      .concat(currentAt().filter(([ name ]) => name !== own))
    // SORTED AS RAILS SORTS A QUERY (Hash#to_query), so one state is one URL whichever panel moved
    // last, and the same URL the server renders for it.
    at.sort((a, b) => (encoded(a) < encoded(b) ? -1 : encoded(a) > encoded(b) ? 1 : 0))
    url.search = new URLSearchParams(pairs.filter((pair) => !isAt(pair)).concat(at)).toString()
    link.setAttribute("href", url.pathname + url.search + url.hash)
  }

  carry(event) {
    const form = event.currentTarget
    for (const input of form.querySelectorAll("input[type=hidden]")) {
      if (AT.test(input.name)) input.remove()
    }
    for (const [ name, value ] of currentAt()) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = name
      input.value = value
      form.append(input)
    }
  }
}
