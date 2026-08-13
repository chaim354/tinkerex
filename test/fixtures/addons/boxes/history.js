// See boxes.js's import for why this is a static import of the host pin and never a vendored copy.
// `host` is a LIVE BINDING — read through it at call time, never captured at module top level.
import { host } from "@maker/addon-sdk"

// A saved box's revision history: revision number, date, and a click that loads those params back
// into the form. Deliberately thin — no delete, no diff, no annotation (design §2).
//
// FETCHED LAZILY, ON FIRST EXPAND. `state.list()` carries only each box's CURRENT revision number,
// so a rail of forty boxes pays nothing for histories nobody opened; this is the one call that
// pays, for the one box being edited.
//
// EVERY CLASS NAME HERE IS ONE THE HOST ALREADY SHIPS, and that is a constraint rather than a
// preference: publishing a bundle IS the addon deploy and Rails is never rebuilt alongside it, so a
// bundle that invents a class renders unstyled until somebody deploys a stylesheet — which this
// repo cannot do at all. `.box-prior*` is the list directly below this one in the same aside and
// `.box-saved-summary` is the disclosure chevron every fold on this page already uses.
//
// container: where to render. stateId: the box. currentRevision: what the editor is showing now.
// onLoad(params): put those values in the form. Returns {destroy, refresh}.
export function mountHistory(container, { stateId, currentRevision, onLoad }) {
  container.innerHTML = `
    <details class="box-prior">
      <summary class="box-saved-summary">
        <span class="box-saved-name">History</span>
        <span class="box-toc-count" data-role="count"></span>
      </summary>
      <div data-role="body"></div>
    </details>`

  const details = container.querySelector("details")
  const body = container.querySelector('[data-role="body"]')
  const countEl = container.querySelector('[data-role="count"]')

  // WHAT THE BADGE COUNTS IS THE CURRENT REVISION NUMBER, WHICH IS ALSO THE LENGTH OF THE HISTORY —
  // revisions start at 1, step by 1, and there is no delete or prune (design §2), so the two
  // numbers cannot disagree. That is why the badge can be filled in before anything is fetched and
  // still be right once it is.
  let current = currentRevision
  const setCount = (n) => { countEl.textContent = n == null ? "" : String(n) }
  setCount(current)

  // textContent rather than an escaped template: the message below carries the host's own prose,
  // and an escape helper is one more thing to get wrong for a string the DOM already quotes.
  const say = (text) => {
    body.innerHTML = ""
    const p = document.createElement("p")
    p.className = "box-prior-hint muted"
    p.textContent = text
    body.appendChild(p)
  }

  const render = (revisions) => {
    setCount(revisions.length)
    if (!revisions.length) { say("No revisions recorded."); return }

    body.innerHTML = ""
    const ul = document.createElement("ul")
    ul.className = "box-prior-list"
    for (const rev of revisions) {
      const li = document.createElement("li")
      li.className = "box-prior-item"

      const button = document.createElement("button")
      button.type = "button"
      button.className = "linkbtn"
      button.textContent = `v${rev.revision}`
      button.setAttribute("aria-label", `Load revision ${rev.revision}`)
      button.addEventListener("click", () => onLoad(rev.data?.params || {}))

      const date = document.createElement("span")
      date.className = "box-prior-date"
      date.textContent = String(rev.created_at).slice(0, 10)
      li.append(button, date)

      // MARKED IN TEXT, NOT WITH A CLASS. An `is-current` class would need a rule this bundle
      // cannot ship (see the header), so the marker would be invisible — a distinction that renders
      // as nothing at all.
      if (rev.revision === current) {
        const here = document.createElement("span")
        here.className = "box-prior-date"
        here.textContent = "current"
        li.appendChild(here)
      }
      ul.appendChild(li)
    }
    body.appendChild(ul)
  }

  let loaded = false
  let loading = false
  const load = async () => {
    loading = true
    say("Loading…")
    try {
      render(await host.state.revisions(stateId))
      loaded = true
    } catch (e) {
      // A FAILED HISTORY MUST NOT LOOK LIKE AN EMPTY ONE — an empty list is a claim about the box,
      // this is a claim about the request. `loaded` stays false, so closing and reopening retries.
      say(`Couldn't load the history: ${e.message}`)
    } finally {
      loading = false
    }
  }

  // `loading` as well as `loaded`, because closing and reopening while the fetch is in flight would
  // otherwise start a second one.
  const onToggle = () => { if (details.open && !loaded && !loading) load() }
  details.addEventListener("toggle", onToggle)

  return {
    destroy: () => details.removeEventListener("toggle", onToggle),

    // A SAVE HAS JUST APPENDED A REVISION, so everything on screen is one behind. Called by the
    // editor rather than noticed here: this module never sees the save. The number is the editor's
    // optimistic `current + 1`; the next expand refetches and the SERVER's answer wins, which is
    // what covers the one case the arithmetic cannot (a second tab having saved in between).
    refresh: (revision) => {
      current = revision
      setCount(current)
      loaded = false
      if (details.open) load()
    },
  }
}
