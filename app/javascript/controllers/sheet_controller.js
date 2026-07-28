import { Controller } from "@hotwired/stimulus"

// Drives the Jspreadsheet grid on a sheet page and debounces its autosave.
//
// The library is a UMD bundle loaded by a classic <script> in the page head (see
// projects/sheets/show.html.erb), so it arrives as a global rather than an import.
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

    this.instance = jss(this.gridTarget, {
      data: cells,
      columns: columns.map((c) => ({ title: c.title, width: c.width || 120 })),
      allowInsertRow: true,
      allowInsertColumn: true,
      allowDeleteRow: true,
      allowDeleteColumn: true,
      onchange: () => this.scheduleSave(),
      oninsertrow: () => this.scheduleSave(),
      ondeleterow: () => this.scheduleSave(),
      oninsertcolumn: () => this.scheduleSave(),
      ondeletecolumn: () => this.scheduleSave()
    })
  }

  disconnect() {
    clearTimeout(this.timer)
    if (this.instance?.destroy) this.instance.destroy()
  }

  scheduleSave() {
    clearTimeout(this.timer)
    this.setStatus("Saving…")
    this.timer = setTimeout(() => this.save(), this.constructor.DEBOUNCE_MS)
  }

  async save() {
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
