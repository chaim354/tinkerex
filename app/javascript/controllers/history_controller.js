import { Controller } from "@hotwired/stimulus"

// What happened to this file, in the repository the maker brought — fetched after the page renders,
// and rendered here.
//
// EVERYTHING THIS PANEL DOES IS SUBORDINATE TO ONE RULE: IT MAY NOT SAY A FILE HAS NO HISTORY
// UNLESS THE SERVER SAID `stopped: "exhausted"`. Path filtering is sparse — 1 of the last 50
// commits touched README.md in the measured repository, against 28 of all 333 (tinkerex#178, spec
// part 3) — and the walk is capped because an uncapped one measured 4,917 ms over the live CIFS
// mount. So an empty `entries` is the ORDINARY answer for a file that has been changed plenty, and
// "this file has no history" is a claim this panel is almost never entitled to make. Every other
// stopping condition gets "no changes in the last N commits" plus a way to look further, which is
// the true statement and also the useful one.
//
// A FAILED FETCH IS NOT AN EMPTY HISTORY EITHER, and that is the same rule wearing a different
// hat: a panel that renders nothing when the request fails tells the maker exactly the lie above,
// with nothing anywhere to contradict it. Every path out of `load` writes a sentence.
//
// IT IS FETCHED RATHER THAN SERVER-RENDERED because the file page must not wait on a git walk —
// ~104 ms cold for a capped one, seconds for a deep one (spec part 3 rule 2). The mount carries
// only URLs; there is nothing here at first paint but "Loading history…".
//
// THE TWO TEMPLATED URLS CARRY A 40-ZERO PLACEHOLDER OID, because both routes constrain `:oid` to
// hex and a route constraint binds URL GENERATION as well as recognition — a readable placeholder
// raises UrlGenerationError when the view renders. Substituting it here is what makes one mount
// serve every row. A node_id is a UUID, whose longest possible run of zeros is 12, so the
// placeholder cannot collide with the id already in the path.

// THE THREE CODES THAT MEAN THE WALK NEVER RAN. Each arrives with a `reason` sentence from
// FilesController#no_history, and not one of them has established anything about this file's
// history — so each renders as that sentence and nothing else. `exhausted` is deliberately NOT a
// member here and must never become one: it is the single code that licenses the empty state below.
const NOT_WALKED = ["no_repo", "no_worktree", "unavailable"]

// A version this panel will not inline. The history endpoint serves a blob as text/plain whatever
// it holds — the panel mounts for ANY file in a repository, not only a text one — so a 40 MB STL
// would otherwise be one View click away from a wedged tab. Checked against Content-Length BEFORE
// the body is read, so the bytes are never pulled at all.
const MAX_INLINE_BYTES = 512 * 1024

export default class extends Controller {
  static targets = ["rows"]
  static values = { url: String, blobUrl: String, restoreUrl: String, workUrl: String }

  connect() {
    this.disconnected = false
    this.abort = new AbortController()
    this.load()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
  }

  // `walkLimit` undefined asks for the server's default; a number is what "Look further" doubles.
  async load(walkLimit) {
    let data
    try {
      const url = walkLimit ? `${this.urlValue}?walk_limit=${walkLimit}` : this.urlValue
      const res = await fetch(url, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal: this.abort.signal
      })
      if (!res.ok) throw new Error(`history failed (${res.status})`)
      data = await res.json()
    } catch (e) {
      if (this.disconnected) return
      // SAYS SO, rather than leaving the panel empty. See the header: an empty panel reads as
      // "this file has no history", which is the one thing this code exists not to claim.
      this.rowsTarget.replaceChildren(this.note(`History could not be loaded (${e.message}).`))
      return
    }
    if (this.disconnected) return

    this.render(data)
  }

  // The whole panel, from one response. Public because these render rules are the thing worth
  // pinning and several of the states below are ones a share deployment cannot produce on demand —
  // repo_history_test.rb feeds this method those responses directly, in a real browser.
  render(data) {
    const entries = data.entries ?? []

    if (NOT_WALKED.includes(data.stopped)) {
      this.rowsTarget.replaceChildren(this.note(data.reason || "History is not available here."))
      return
    }

    const restorable = data.restorable === true
    const list = document.createElement("ul")
    list.className = "history-list"
    for (const entry of entries) list.append(this.rowFor(entry, restorable))

    const parts = []
    if (entries.length) parts.push(list)
    const note = this.noteFor(data, entries.length)
    if (note) parts.push(note)
    this.rowsTarget.replaceChildren(...parts)
  }

  // WHAT THE PANEL IS ENTITLED TO SAY ABOUT WHAT IT DID NOT FIND.
  //
  //   exhausted   — the walk reached the root commit, so silence about older changes is TRUE, and
  //                 this is the only branch that may say the file has none.
  //   limit       — the list filled up. More changes certainly exist and a DEEPER walk would not
  //                 reveal them, because the limit that stopped this one was the list's, not the
  //                 walk's — so no "Look further" here; the repository page is that door.
  //   walk_limit  — we stopped looking. Say how far we looked, and offer to look twice as far.
  //   anything else — an unrecognised code is treated as "we stopped looking" ON PURPOSE: the safe
  //                 direction for a code this panel has not heard of is the modest claim.
  noteFor(data, count) {
    if (data.stopped === "exhausted") {
      return count ? null : this.note("No earlier history for this file.")
    }

    if (data.stopped === "limit") {
      return this.note(`Showing the ${count} most recent changes to this file.`)
    }

    const walked = data.walked ?? 0
    const note = this.note(count
      ? `Only the last ${walked} commits were searched — there may be older changes.`
      : `No changes to this file in the last ${walked} commits.`)
    // DOUBLES WHAT WAS ACTUALLY WALKED rather than incrementing a counter of its own, so a second
    // click reaches four times as far — and the control disappears of its own accord, because once
    // the walk runs out of commits the server answers `exhausted` and this branch is not taken.
    const deeper = document.createElement("button")
    deeper.type = "button"
    deeper.className = "linkbtn"
    deeper.textContent = "Look further"
    deeper.addEventListener("click", () => {
      this.rowsTarget.replaceChildren(this.note("Looking further…"))
      this.load(Math.max(walked, 1) * 2)
    })
    note.append(" ", deeper)
    return note
  }

  rowFor(entry, restorable) {
    const row = document.createElement("li")
    row.className = "history-row"
    row.dataset.oid = entry.oid

    const head = document.createElement("div")
    head.className = "history-row-head"
    head.append(
      this.span("history-oid mono", entry.short_oid),
      this.span("history-subject", entry.subject || "(no message)"),
      this.span("history-meta muted", [entry.author, this.when(entry.time)].filter(Boolean).join(" · "))
    )

    const detail = document.createElement("div")
    detail.className = "history-detail"

    const actions = document.createElement("span")
    actions.className = "history-actions"
    actions.append(
      this.action("View", () => this.toggle(detail, "view", () => this.viewPanel(entry))),
      this.action("Diff", () => this.toggle(detail, "diff", () => this.diffPanel(entry)))
    )
    // HIDDEN, NOT DISABLED, WHEN THE SERVER SAYS THIS FILE CANNOT BE RESTORED. `restorable` answers
    // "is this repository on a filesystem this box can write to and then commit from" — where it is
    // false there is nothing the maker could do to make the button work, and an affordance that can
    // never succeed is worse than no affordance. It is read off the response rather than assumed
    // from the panel having rendered at all, so it stays right if that gate is ever loosened.
    if (restorable) {
      actions.append(this.action("Restore", (button) => this.restore(entry, button, detail)))
    }
    head.append(actions)

    row.append(head, detail)
    return row
  }

  // One detail panel per row, and clicking the same action again closes it.
  async toggle(detail, kind, build) {
    if (detail.dataset.open === kind) {
      detail.dataset.open = ""
      detail.replaceChildren()
      return
    }
    detail.dataset.open = kind
    detail.replaceChildren(this.note("Loading…"))
    const built = await build()
    // The row may have been closed, or another action opened, while this was in flight.
    if (this.disconnected || detail.dataset.open !== kind) return
    detail.replaceChildren(built)
  }

  async viewPanel(entry) {
    let res
    try {
      res = await fetch(this.oidUrl(this.blobUrlValue, entry.oid), {
        credentials: "same-origin", signal: this.abort.signal
      })
      if (!res.ok) throw new Error(`fetch failed (${res.status})`)
    } catch (e) {
      return this.note(`That version could not be loaded (${e.message}).`)
    }

    const tooBig = this.oversize(res)
    if (tooBig) return tooBig

    const text = await res.text()
    // A NUL BYTE IS THE CHEAP, HONEST BINARY TEST — the same one `grep` uses. The endpoint labels
    // every blob text/plain because git records no type, so this is the only place that can
    // notice, and a binary in a <pre> renders as pages of replacement characters.
    if (text.includes("\u0000")) return this.rawLink("This version is binary.", entry)

    const pre = document.createElement("pre")
    pre.className = "history-blob"
    pre.textContent = text
    return pre
  }

  // Hands the diff to diffview_controller — the commit box's own diff, whose "original" side is any
  // URL. Here that is this file's bytes at this commit; there it is HEAD's. Both diff against the
  // SAME working-tree blob endpoint, so the two surfaces cannot disagree about what is on disk.
  //
  // NO `ext` VALUE, so the diff renders as plain text with line numbers: this mount carries URLs
  // and no file name. That is codemirror_languages' own default for an unknown extension, and it is
  // deliberately not guessed at from the page's heading.
  async diffPanel(entry) {
    const res = await fetch(this.oidUrl(this.blobUrlValue, entry.oid), {
      method: "HEAD", credentials: "same-origin", signal: this.abort.signal
    }).catch(() => null)
    if (res?.ok) {
      const tooBig = this.oversize(res)
      if (tooBig) return tooBig
    }

    const mount = document.createElement("div")
    mount.className = "history-diff"
    mount.dataset.controller = "diffview"
    // `head-url` is diffview's name for the ORIGINAL side, and it keeps that spelling because
    // renaming a Stimulus value means editing every view that sets it. What it MEANS is "the older
    // of the two blobs" — see that controller's header.
    mount.dataset.diffviewHeadUrlValue = this.oidUrl(this.blobUrlValue, entry.oid)
    mount.dataset.diffviewWorkUrlValue = this.workUrlValue
    return mount
  }

  async restore(entry, button, detail) {
    button.disabled = true
    try {
      const res = await fetch(this.oidUrl(this.restoreUrlValue, entry.oid), {
        method: "POST",
        credentials: "same-origin",
        // NOT FOLLOWED. A restore answers 302 back to this page, and following it inside the fetch
        // would consume the flash here — so the reload below would land on a page with nothing to
        // say about what just happened. An unfollowed same-origin redirect arrives as an opaque
        // response: type "opaqueredirect", status 0, body unreadable, which is all this needs.
        redirect: "manual",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content ?? ""
        },
        signal: this.abort.signal
      })
      if (res.type === "opaqueredirect" || res.ok) return window.location.reload()

      // A REFUSAL IS A SENTENCE THE SERVER WROTE, and both of its cases are ordinary clicks rather
      // than mistakes: the panel lists HEAD's commit, whose bytes are usually exactly what is on
      // disk, and an old version can be over the editor's size ceiling.
      const body = await res.json().catch(() => ({}))
      detail.dataset.open = "error"
      detail.replaceChildren(this.note(body.error ?? `Restore failed (${res.status}).`))
    } catch (e) {
      if (this.disconnected) return
      detail.dataset.open = "error"
      detail.replaceChildren(this.note(`Restore failed (${e.message}).`))
    } finally {
      button.disabled = false
    }
  }

  // --- small builders ---

  oversize(res) {
    const length = Number(res.headers.get("content-length") ?? 0)
    return length > MAX_INLINE_BYTES ? this.note("That version is too large to show here.") : null
  }

  rawLink(message, entry) {
    const p = this.note(`${message} `)
    const link = document.createElement("a")
    link.href = this.oidUrl(this.blobUrlValue, entry.oid)
    link.textContent = "Open the raw bytes"
    p.append(link)
    return p
  }

  oidUrl(template, oid) {
    return template.replace("0".repeat(40), oid)
  }

  action(label, handler) {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "linkbtn"
    button.textContent = label
    button.addEventListener("click", () => handler(button))
    return button
  }

  span(className, text) {
    const el = document.createElement("span")
    el.className = className
    el.textContent = text ?? ""
    return el
  }

  note(text) {
    const p = document.createElement("p")
    p.className = "muted history-note"
    p.textContent = text
    return p
  }

  // The server sends ISO-8601; the browser knows the reader's locale and this panel does not care
  // about the format. An unparseable value renders as nothing rather than as "Invalid Date".
  when(iso) {
    const at = new Date(iso)
    return Number.isNaN(at.getTime()) ? "" : at.toLocaleString()
  }
}
