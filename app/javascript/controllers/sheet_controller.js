import { Controller } from "@hotwired/stimulus"

// The same question the other editors ask (dirty_form_controller.js, layout_editor_controller.js).
const LEAVE = "Leave without saving your changes?"

// Chrome finishes a `keepalive` request after its page is gone, and rejects one before sending it
// when the bodies of the page's open keepalive requests would pass 64 KiB together. Under this, the
// save sent from a closing page goes that way; over it, it goes as an ordinary request, which the
// browser may cut off. ONLY that save is marked: the allowance is shared, so an ordinary save
// marked the same way could still be open, holding it, when the closing one needs it.
const KEEPALIVE_BYTES = 60000

// What `write` answers when the server says there is no such sheet (404): deleted in another tab,
// or by this page's own Delete a moment ago.
const GONE = Symbol("gone")

// THE SAVE STATE OF ONE CONNECTED GRID: TWO COUNTERS AND ONE REQUEST AT A TIME.
//
// `edited` goes up by one for every change the grid reports, and `acked` is the highest `edited`
// the server has confirmed. "Is anything unsaved" is that one comparison, and the status line, the
// leave guards and the debounce all read it, so none of them can believe something the others do
// not. It used to be spread over a timer, whichever request answered last and a status string:
// an edit waiting on the timer died when the page was left, two requests could be open at once and
// land in the wrong order (each posts the WHOLE grid and the server keeps the last to arrive), and
// an older answer wrote "Saved" over an edit that had gone nowhere.
//
// ONE PER CONNECT, NEVER RESET. Stimulus hands a re-attached element the same controller, so state
// kept on the controller would let a request from before a disconnect acknowledge edits made after
// the reconnect (the hazard modelviewer_controller.js records for its own token). A request that
// outlives its grid finishes against the object it started with.
class Autosave {
  // `delay` -> ms, asked each time; `read` -> the grid as a payload; `write(payload)` -> a promise
  // of null once the server has taken it, of the sentence to show when it has refused, or of GONE;
  // `show(text, isError)` draws the status.
  constructor({ delay, read, write, show }) {
    Object.assign(this, { delay, read, write, show })
    this.edited = 0
    this.acked = 0
    this.draining = null
    this.gone = false
  }

  get unsaved() {
    return !this.gone && this.edited > this.acked
  }

  touch() {
    // Nothing is being saved once the sheet is gone, and the status already says so.
    if (this.gone) return
    this.edited += 1
    this.show("Saving…")
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.flush(), this.delay())
  }

  // Send what is waiting, now. -> a promise of true once everything edited is acknowledged, or of
  // false when a save was refused. A flush asked for while one is running is the SAME flush: the
  // loop below picks the newer edit up when the open request comes back, which is what keeps it to
  // one request at a time.
  flush() {
    clearTimeout(this.timer)
    this.draining ||= this.drain().finally(() => { this.draining = null })
    return this.draining
  }

  async drain() {
    while (this.unsaved) {
      const sending = this.edited
      const answer = await this.write(this.read())
      // NOTHING LEFT TO SAVE INTO. No later try will go differently, so nothing is unsaved from
      // here on and no way out asks about it: the page's own Delete redirects through a visit this
      // controller holds for a save, and that visit must be let go.
      if (answer === GONE) {
        this.gone = true
        this.show("Not saved — this sheet no longer exists", true)
        return true
      }
      if (answer) {
        this.show(answer, true)
        return false
      }
      this.acked = sending
      if (!this.unsaved) this.show("Saved")
    }
    return true
  }

  // THE GRID IS GOING AWAY. What is waiting goes out now, behind whatever is already open; an edit
  // behind an open request is read when that request answers, which works because jspreadsheet
  // still answers for a grid it has destroyed (sheet_grid_test.rb pins that). The status element is
  // going with the grid, so nothing is drawn from here on.
  close() {
    if (this.unsaved) this.flush()
    this.show = () => {}
  }

  // The person chose to leave without them.
  discard() {
    this.acked = this.edited
  }
}

// Drives the Jspreadsheet grid on a sheet page and autosaves it.
//
// The library is a UMD bundle loaded by a classic <script> in the page head (see
// projects/sheets/show.html.erb, which also explains why that page marks the tags
// data-turbo-track="reload" — a Turbo Drive visit, not just a hard load, has to be accounted for).
//
// LEAVING NEVER DROPS AN EDIT QUIETLY, and each way out gets what that way out allows:
//   - A Turbo visit (a link, the strip, a redirect) WAITS: `turbo:before-visit` is held until the
//     save has landed and then made again. Only a save that was refused asks.
//   - The page's own Rename reloads the page from the database, so the save goes before it
//     (`saveFirst`); its CSV link is a download, and the file should hold what the grid shows
//     (`saveThenFollow`). Its Delete needs nothing here: the redirect is held like any visit, the
//     save is answered "no such sheet", and that answer lets the visit go (`GONE`).
//   - Back, a closed tab, a typed address cannot be made to wait and raise no Turbo event. The page
//     asks (`beforeunload`) and sends the edit on the spot in the form the browser finishes after
//     the page is gone. Every real way out of this page ENDS in a full load (show.html.erb), so
//     this listener also fires after a visit that already waited, and then has nothing to ask.
//   - A render nobody asked this page about disconnects the controller: `Autosave#close`.
export default class extends Controller {
  static targets = ["grid", "status"]
  static values = { url: String, data: Object }

  // Long enough that typing across a row is one save. It is no longer what stands between an edit
  // and a closed browser: leaving sends what is waiting (above).
  static DEBOUNCE_MS = 1000

  connect() {
    const jss = window.jspreadsheet
    if (!jss) {
      this.setStatus("Grid failed to load", true)
      return
    }

    const columns = this.dataValue?.columns || []
    const cells = this.dataValue?.cells || []

    // jspreadsheet-ce 5's top-level factory is a WORKBOOK api, not a single-sheet one, and it is
    // ASYNCHRONOUS — this whole shape was verified live against the actual vendored bundle
    // (vendor/javascript/jspreadsheet.js), not assumed from docs. Two load-bearing facts that
    // aren't obvious from the outside:
    //
    // 1. `jspreadsheet(el, options)` returns an EMPTY array SYNCHRONOUSLY and populates it only
    //    after an internal promise resolves. The per-sheet config MUST be nested under a top-level
    //    `worksheets: [...]` array — calling it with a flat `{data, columns}` (no `worksheets` key)
    //    throws "JSS: worksheets are not defined" *inside that promise chain*, which has no
    //    `.catch()`, so it surfaces only as an unhandled rejection — never as a normal synchronous
    //    exception at the call site, and never touches the `if (!jss)` guard above. The grid just
    //    renders empty, silently, with no visible error at all: worse than a crash, because it looks
    //    like a blank sheet rather than a broken one. `onload` is the library's own designed
    //    ready-signal, firing once the async build finishes; its argument is the WORKBOOK, and
    //    `workbook.worksheets[0]` is the actual usable per-sheet instance (`.getData`, `.getHeaders`,
    //    `.getWidth`, …) — confirmed live: the returned array IS `workbook.worksheets` by reference,
    //    so it fills in in place, but reading `onload`'s own argument is the documented path rather
    //    than relying on that aliasing.
    //
    // 2. Where each option goes is NOT uniform. Verified live with two probes that isolate the two
    //    directions of getting this wrong:
    //    - An `onchange` NESTED inside `worksheets[0]` never fires; only a TOP-LEVEL `onchange`
    //      (sibling to `worksheets`/`onload`) does. Every worksheet's dispatch escalates straight to
    //      its PARENT (the workbook)'s `.config` — verified in the bundle's dispatch function,
    //      `r = t.parent ? t.parent : t`, which for a worksheet always takes the `t.parent` branch
    //      and so never even looks at the worksheet's own `.options`.
    //    - `allowInsertRow`/`allowInsertColumn`/`allowDeleteRow`/`allowDeleteColumn` are the
    //      opposite: every call site in the bundle reads them as `worksheet.options.allow…`
    //      directly, so they belong NESTED inside the worksheets[0] entry, alongside `data`/
    //      `columns`. Putting them at the top level wouldn't error — it would just leave every
    //      insert/delete action silently blocked, since the worksheet-level default is closed.
    const autosave = this.autosave = new Autosave({
      delay: () => this.constructor.DEBOUNCE_MS,
      read: () => this.payload(),
      write: (payload) => this.write(payload),
      show: (text, isError) => this.setStatus(text, isError)
    })
    const touch = () => autosave.touch()

    jss(this.gridTarget, {
      worksheets: [ {
        data: cells,
        // DEFENCE IN DEPTH, NOT THE GUARD. `Maker::Sheet#columns` is now element-wise —
        // `.grep(Hash)` — so a null/scalar/Array entry can no longer reach here through
        // show.html.erb, which is `dataValue`'s only source. This filter is kept anyway because the
        // failure it catches is the one this page already shipped once: `c.title` throwing left a
        // blank page with the status still reading "Saved" (see show.html.erb).
        //
        // It is also STRICTLY WEAKER than the model's check and must not be mistaken for an equal
        // one: `typeof [] === "object"`, so an Array entry passes this filter and yields a blank
        // header, where `grep(Hash)` drops it. If these two ever disagree, the model is right.
        columns: columns
          .filter((c) => c && typeof c === "object")
          .map((c) => ({ title: c.title, width: c.width || 120 })),
        allowInsertRow: true,
        allowInsertColumn: true,
        allowDeleteRow: true,
        allowDeleteColumn: true
      } ],
      onchange: touch,
      oninsertrow: touch,
      ondeleterow: touch,
      oninsertcolumn: touch,
      ondeletecolumn: touch,
      onload: (workbook) => { this.instance = workbook.worksheets[0] }
    })

    this.onBeforeVisit = (event) => {
      if (!autosave.unsaved) return
      event.preventDefault()
      const { url } = event.detail
      autosave.flush().then((saved) => {
        // Saved: make the visit again. An edit typed while the save was out meets this listener a
        // second time. Refused: the status line says why, and going is the person's call; an
        // answer of yes stands every guard down, so the full load that follows does not ask again.
        if (!saved) {
          if (!window.confirm(LEAVE)) return
          autosave.discard()
        }
        window.Turbo.visit(url)
      })
    }
    this.onBeforeUnload = (event) => {
      if (!autosave.unsaved) return
      this.closing = true
      // A request already open cannot be waited for and the edit behind it has gone nowhere, so
      // the grid as it stands goes out beside it: the one place two are open at once, because the
      // alternative is losing that edit for certain. Otherwise this is an ordinary flush.
      const sent = autosave.draining ? this.write(this.payload()) : autosave.flush()
      // For the person who is asked and stays: the saves that follow are ordinary ones again.
      sent.finally(() => { this.closing = false })
      event.preventDefault()
      event.returnValue = ""
    }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
  }

  disconnect() {
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    this.autosave?.close()
    this.autosave = null
    // There is no per-instance destroy() on a worksheet or workbook — grepping the bundle for
    // "destroy" turns up only `destroyMerge` (undoing merged cells, unrelated) and the one real
    // teardown entry point: the STATIC `jspreadsheet.destroy(container, removeGlobalEvents)`, keyed
    // off the CONTAINER element (factory.spreadsheet stashes the workbook at `container.spreadsheet`
    // for exactly this reason). Passing `true` also removes the document-level mouseup/mousedown/
    // keydown listeners jspreadsheet installs on load — otherwise those stay bound to a page that,
    // under Turbo, may no longer even be in the DOM. Guarded on `hasGridTarget`/the library still
    // being present, and `jspreadsheet.destroy` itself no-ops if `container.spreadsheet` was never
    // set (e.g. disconnecting before `onload` ever fired), so this is safe to call unconditionally.
    if (window.jspreadsheet?.destroy && this.hasGridTarget) {
      window.jspreadsheet.destroy(this.gridTarget, true)
    }
  }

  // THE PAGE'S OWN RENAME. It reloads this page from the database, so what the grid has not saved
  // goes first; otherwise the page comes back without it and the next save posts a grid that never
  // had it. Bound on the form, so it runs before Turbo's listener on the document, which leaves a
  // prevented submit alone (wiring_controller.js's `save` rests on the same order).
  saveFirst(event) {
    const autosave = this.autosave
    if (!autosave?.unsaved) return
    event.preventDefault()
    const form = event.target
    const submitter = event.submitter
    autosave.flush().then((saved) => { if (saved) form.requestSubmit(submitter) })
  }

  // THE PAGE'S CSV LINK, AND ANY OTHER LINK TURBO LEAVES TO THE BROWSER. A download raises no Turbo
  // event and leaves the page where it is, so `beforeunload` would ask "Leave site?" about going
  // nowhere, and the file would lack the edit. The link waits for the save and is then followed.
  saveThenFollow(event) {
    const autosave = this.autosave
    if (!autosave?.unsaved) return
    event.preventDefault()
    const { href } = event.currentTarget
    autosave.flush().then((saved) => { if (saved) window.location.assign(href) })
  }

  // -> the grid as the server stores it.
  //
  // Verified against the vendored bundle (vendor/javascript/jspreadsheet.js) rather than assumed:
  // the real signature is getData(highlighted, processed, csvDelimiter, asDictionary).
  //   - `highlighted` (1st arg): restrict to the highlighted range only. false/omitted = every cell.
  //   - `processed` (2nd arg): true reads `record.element.innerHTML` (the rendered DOM, i.e. a
  //     formula's CURRENT COMPUTED RESULT); false/omitted reads `options.data[row][col]` instead —
  //     the underlying data model.
  // updateCell() (internal) sets `options.data[row][col] = <the raw typed string>` BEFORE it ever
  // calls the formula evaluator (parseValue -> executeFormula), and that evaluator's result is
  // assigned only to the DOM element for display — it never writes back into `options.data`. So a
  // cell holding "=A1+B1" is stored in `options.data` as that literal string, untouched by whatever
  // it currently evaluates to. getData(false) already takes this raw branch — passing 2 (`t`) as
  // undefined is falsy, identical to passing false explicitly — but both args are spelled out below
  // so nobody has to re-derive that from omission. Passing anything truthy for the 2nd arg would
  // persist the computed number instead and silently destroy every formula on the next page load.
  payload() {
    return {
      columns: this.instance.getHeaders
        ? this.instance.getHeaders(true).map((title, i) => ({ title, width: this.instance.getWidth(i) }))
        : this.dataValue.columns,
      cells: this.instance.getData(false, false)
    }
  }

  // -> null once the server has taken the payload, the sentence to show when it has refused, or
  // GONE when it has no such sheet.
  async write(payload) {
    const token = document.querySelector('meta[name="csrf-token"]')?.content
    const body = JSON.stringify({ sheet: { data: payload } })

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": token || ""
        },
        body,
        keepalive: this.closing === true && new Blob([ body ]).size <= KEEPALIVE_BYTES
      })
      if (response.ok) return null
      if (response.status === 404) return GONE
      // We DID reach the server and it refused. A 422 carries a reason the user can act on
      // ("data is too large…"), and a connection message would be an actively wrong diagnosis:
      // this will not succeed on the next attempt either. Answering here is what keeps the catch
      // below meaning only one thing.
      const reason = await response.json().then((b) => b.error).catch(() => null)
      return `Not saved — ${reason || `the server refused it (HTTP ${response.status})`}`
    } catch (error) {
      // We never reached a response, so this is a transport failure. An earlier draft told the two
      // cases apart by sniffing error.message for an "HTTP " prefix; that routed the server's
      // refusals correctly but then showed the user their BROWSER'S jargon for an actual outage
      // ("Failed to fetch" / "Load failed" / "NetworkError when attempting to fetch resource") —
      // regressing the one scenario this wording exists for. Handling !response.ok above and
      // answering there removes the need to guess.
      return "Not saved — check your connection"
    }
  }

  setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("sheet-status-error", isError)
  }
}
