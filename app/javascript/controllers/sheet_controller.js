import { Controller } from "@hotwired/stimulus"

// Drives the Jspreadsheet grid on a sheet page and debounces its autosave.
//
// The library is a UMD bundle loaded by a classic <script> in the page head (see
// projects/sheets/show.html.erb, which also explains why that page marks the tags
// data-turbo-track="reload" — a Turbo Drive visit, not just a hard load, has to be accounted for).
export default class extends Controller {
  static targets = ["grid", "status"]
  static values = { url: String, data: Object }

  // Long enough that typing across a row is one save, short enough that a browser closed right
  // after an edit has already persisted it.
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
    jss(this.gridTarget, {
      worksheets: [ {
        data: cells,
        // The model's `columns` reader guards the OUTER shape only (is `data["columns"]` an Array
        // at all) — it does not, and cannot, validate every element inside an otherwise-valid array.
        // A blob written by a hostile or buggy client can still smuggle a null/non-object entry
        // through, and `c.title` on that entry throws, breaking the whole page. Filter here too.
        columns: columns
          .filter((c) => c && typeof c === "object")
          .map((c) => ({ title: c.title, width: c.width || 120 })),
        allowInsertRow: true,
        allowInsertColumn: true,
        allowDeleteRow: true,
        allowDeleteColumn: true
      } ],
      onchange: () => this.scheduleSave(),
      oninsertrow: () => this.scheduleSave(),
      ondeleterow: () => this.scheduleSave(),
      oninsertcolumn: () => this.scheduleSave(),
      ondeletecolumn: () => this.scheduleSave(),
      onload: (workbook) => { this.instance = workbook.worksheets[0] }
    })
  }

  disconnect() {
    clearTimeout(this.timer)
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

  scheduleSave() {
    clearTimeout(this.timer)
    this.setStatus("Saving…")
    this.timer = setTimeout(() => this.save(), this.constructor.DEBOUNCE_MS)
  }

  async save() {
    if (!this.instance) return

    const token = document.querySelector('meta[name="csrf-token"]')?.content

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
    const payload = {
      columns: this.instance.getHeaders
        ? this.instance.getHeaders(true).map((title, i) => ({ title, width: this.instance.getWidth(i) }))
        : this.dataValue.columns,
      cells: this.instance.getData(false, false)
    }

    try {
      const response = await fetch(this.urlValue, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": token || ""
        },
        body: JSON.stringify({ sheet: { data: payload } })
      })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      this.setStatus("Saved")
    } catch (error) {
      // An autosave that fails silently is indistinguishable from one that worked, which is the
      // whole risk of choosing autosave over a Save button.
      this.setStatus("Not saved — check your connection", true)
    }
  }

  setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("sheet-status-error", isError)
  }
}
