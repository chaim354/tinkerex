// A TOOL KEEPS ITS PLACE FOR 15 MINUTES AFTER ITS PAGE IS LEFT (2026-11-24; spec
// docs/superpowers/specs/2026-11-24-back-button-and-kept-tools-design.md). The owner's words: "tools
// should have some permanence so you can jump back and forth when working on it". Leaving a tool to
// check a file used to cost everything typed into it.
//
// THE TOOL ITSELF IS KEPT, NOT A COPY OF ITS VALUES. A page hands over the live subtree it was
// showing — the elements, with every listener and all the JavaScript state behind them — and takes
// it back when the maker returns. So what comes back is exactly what was left: the fields, the open
// generator, a loaded file, the preview, undo. Serialising values was the alternative, and it can
// only restore what a tool's author wrote a restore for; this needs nothing from a bundle.
//
// IT LIVES IN THIS MODULE'S MEMORY, which lasts as long as the document does. A Turbo visit keeps
// the document, so moving around the app keeps the tool; a browser reload or a new tab starts it
// fresh. That is the stated trade, and it is also the maker's way out besides Start over.
//
// ONE SESSION PER TOOL, NEVER TWO. A bundle is an ES module evaluated once per page, so two live
// mounts of one tool would share its module-level state, which every bundle was written believing
// it owns. `take` therefore ENDS a kept session it does not hand back: a visit either resumes the
// tool's session or mounts the tool with none left alive behind it.
//
// NEVER ACROSS ACCOUNTS. The tab outlives a sign-out. Each session records who it belongs to and a
// mismatch ends it; submitting a form marked `data-kept-tools="discard"` (the two Sign out forms)
// ends them all, so nothing of the account is left running behind the sign-in page.
export const KEEP_MS = 15 * 60 * 1000
const LIMIT = 5

let sessions = [] // oldest first

function end(session) {
  clearTimeout(session.timer)
  try { session.release?.() } catch { /* a release that throws must not strand the others */ }
}

function endWhere(test) {
  const ending = sessions.filter(test)
  sessions = sessions.filter((session) => !test(session))
  ending.forEach(end)
}

// `node` is the live subtree, already out of the document. `release` is what ends the session for
// good — for an add-on, firing its host's teardown handlers — and runs at most once. Anything else
// the page hands over (an add-on's host) rides along and comes back from `take`.
export function keep({ tool, url, owner, node, release, ...rest }) {
  endWhere((session) => session.tool === tool)
  const session = { ...rest, tool, url, owner, node, release, expiresAt: Date.now() + KEEP_MS }
  // The timer frees the tool on time when nobody returns. `take` asks the clock again, because a
  // sleeping laptop delays timers and a session must not come back late.
  session.timer = setTimeout(() => endWhere((kept) => kept === session), KEEP_MS)
  sessions.push(session)
  while (sessions.length > LIMIT) end(sessions.shift())
}

// The session this visit resumes, or null. `url` is the page's path and query; `plain` says the
// visit named nothing in particular (no query), which resumes whatever the tool was last doing. A
// visit that names a different saved item, file or folder gets null, and the kept session ends.
export function take({ tool, url, owner, plain }) {
  const now = Date.now()
  endWhere((session) => session.expiresAt <= now || session.owner !== owner)
  const session = sessions.find((kept) => kept.tool === tool)
  if (!session) return null
  if (session.url !== url && !plain) {
    endWhere((kept) => kept === session)
    return null
  }
  sessions = sessions.filter((kept) => kept !== session)
  clearTimeout(session.timer)
  return session
}

export function discardAll() { endWhere(() => true) }

// What a kept subtree leaves in its place: a dead copy, so the page Turbo snapshots on the way out
// is the page it would have snapshotted anyway (the copy is what a later Back shows once the session
// has expired). `cloneNode` carries an input's value and checkedness but not a select's choice,
// which is the one thing Turbo's own snapshot clone also has to put back by hand.
export function deadCopy(node) {
  const copy = node.cloneNode(true)
  const live = node.querySelectorAll("select")
  copy.querySelectorAll("select").forEach((select, i) => {
    Array.from(live[i].options).forEach((option, j) => { select.options[j].selected = option.selected })
  })
  return copy
}

// A Turbo preview is a cached copy shown for a moment before the real page arrives. It must neither
// take a session (the real page is about to ask for it) nor keep one (its subtree is the dead copy).
export function previewing() { return document.documentElement.hasAttribute("data-turbo-preview") }

// The page as a session knows it: path and query, never the fragment (a bundle's own table of
// contents rewrites the fragment as the maker reads).
export function pageUrl() { return window.location.pathname + window.location.search }

document.addEventListener("submit", (event) => {
  if (event.target instanceof HTMLFormElement && event.target.dataset.keptTools === "discard") discardAll()
}, true)
