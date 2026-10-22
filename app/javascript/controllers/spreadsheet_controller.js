import { Controller } from "@hotwired/stimulus"

// AN .xlsx FILE AS A GRID, ONE TAB PER WORKSHEET, AND ITS SAVE (2026-10-21; files/viewers/_spreadsheet,
// Files::SpreadsheetsController, Maker::Xlsx).
//
// THE GRID IS jspreadsheet CE, LOADED HERE AND NOWHERE ELSE ON THIS PAGE. jsuites and jspreadsheet
// are UMD bundles that publish globals, so they go in as classic <script> tags, in order, once per
// document; their stylesheets go in BEFORE vendor-overrides.css so the token skin there wins
// (design-system.md's cascade), marked data-turbo-track="dynamic" so Turbo drops them on a page that
// has no grid. One jspreadsheet workbook per worksheet pane, built the first time its tab is shown.
//
// A SAVE SENDS OPERATIONS, NEVER THE GRID (Maker::Xlsx::Edit). Row inserts and deletes are LOGGED
// as they happen, in order, across every sheet; cell values are DIFFED at Save against what was
// loaded, through `ids` (each grid row's original row, null for an inserted one), so a paste, a fill
// or a typed value all become the same `set`. The log is exact only because jspreadsheet's undo
// and redo are switched off: they run with events suppressed (`ignoreEvents`), so an undone insert
// would leave a logged insert the grid no longer has. `ignoreHistory = true` keeps history empty.
//
// THE GRID DOES NOT EVALUATE FORMULAS (`parseFormulas: false`): it shows the values Excel stored,
// and a typed `=…` stays text in the grid and is saved as a formula Excel calculates on open.
const loading = new Map()

function loadScript(src) {
  if (!loading.has(src)) {
    loading.set(src, new Promise((resolve, reject) => {
      const tag = document.createElement("script")
      tag.src = src
      tag.async = false
      tag.dataset.spreadsheetAsset = src
      tag.onload = () => resolve()
      tag.onerror = () => { loading.delete(src); reject(new Error(`could not load ${src}`)) }
      document.head.append(tag)
    }))
  }
  return loading.get(src)
}

function loadStyles(hrefs) {
  const anchor = document.querySelector('link[rel="stylesheet"][href*="vendor-overrides"]')
  for (const href of hrefs) {
    if (document.querySelector(`link[data-spreadsheet-asset="${href}"]`)) continue
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = href
    link.dataset.spreadsheetAsset = href
    link.dataset.turboTrack = "dynamic"
    anchor ? anchor.before(link) : document.head.append(link)
  }
}

function columnName(index) {
  let name = ""
  for (let n = index + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + ((n - 1) % 26)) + name
  return name
}

export default class extends Controller {
  static targets = ["tabs", "panes", "note", "cell", "status", "save", "addRow", "deleteRow", "loading"]
  static values = { url: String, saveUrl: String, downloadUrl: String, scripts: Array, styles: Array }

  async connect() {
    this.disconnected = false
    this.abort = new AbortController()
    this.active = 0
    this.onBeforeUnload = (event) => { if (this.dirty) { event.preventDefault(); event.returnValue = "" } }
    this.onBeforeVisit = (event) => {
      if (this.dirty && !window.confirm("Leave without saving your changes to this workbook?")) event.preventDefault()
    }
    window.addEventListener("beforeunload", this.onBeforeUnload)
    document.addEventListener("turbo:before-visit", this.onBeforeVisit)
    this.rest()

    try {
      loadStyles(this.stylesValue)
      for (const src of this.scriptsValue) await loadScript(src)
    } catch (error) {
      console.warn("[spreadsheet]", error)
      if (!this.disconnected) this.fail("The grid could not load.")
      return
    }
    if (this.disconnected) return
    await this.load()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    window.removeEventListener("beforeunload", this.onBeforeUnload)
    document.removeEventListener("turbo:before-visit", this.onBeforeVisit)
    this.destroyGrids()
  }

  // A page Turbo restored from its cache holds the last render's tabs and tables, wired to nothing;
  // start from the resting state every time (files-preview.md, "both code viewers rest too").
  rest() {
    this.destroyGrids()
    this.sheets = []
    this.log = []
    this.dirty = false
    this.tabsTarget.replaceChildren()
    this.panesTarget.replaceChildren(this.hasLoadingTarget ? this.loadingTarget : this.loadingParagraph())
    this.noteTarget.hidden = true
    this.cellTarget.textContent = ""
    this.setStatus("")
    this.refreshButtons()
  }

  loadingParagraph() {
    const p = document.createElement("p")
    p.className = "muted"
    p.dataset.spreadsheetTarget = "loading"
    p.textContent = "Loading workbook…"
    return p
  }

  async load() {
    let response, body
    try {
      response = await fetch(this.urlValue, {
        headers: { Accept: "application/json" }, credentials: "same-origin", signal: this.abort.signal
      })
      body = await response.json().catch(() => ({}))
    } catch (error) {
      if (!this.disconnected) this.fail("The workbook could not be loaded. Check your connection and reload.")
      return
    }
    if (this.disconnected) return
    if (!response.ok) return this.fail(body.error || `The workbook could not be loaded (HTTP ${response.status}).`)

    this.token = body.content_token
    this.build(body.sheets || [])
  }

  fail(message) {
    const p = document.createElement("p")
    p.className = "spreadsheet-error"
    p.textContent = `${message} `
    if (this.hasDownloadUrlValue) {
      const link = document.createElement("a")
      link.href = this.downloadUrlValue
      link.textContent = "Download it"
      p.append(link, " to open it in Excel or LibreOffice.")
    }
    this.panesTarget.replaceChildren(p)
    this.tabsTarget.replaceChildren()
    this.refreshButtons()
  }

  build(sheets) {
    this.destroyGrids()
    this.log = []
    this.dirty = false
    this.sheets = sheets.map((sheet) => ({ ...sheet, pane: null, workbook: null, instance: null }))
    this.tabsTarget.replaceChildren(...this.sheets.map((sheet, i) => {
      const tab = document.createElement("button")
      tab.type = "button"
      tab.className = "tab-link"
      tab.setAttribute("role", "tab")
      tab.textContent = sheet.hidden ? `${sheet.name} (hidden)` : sheet.name
      tab.addEventListener("click", () => this.show(i))
      return tab
    }))
    this.panesTarget.replaceChildren()
    if (this.sheets.length === 0) return this.fail("This workbook has no sheets to show.")
    this.show(Math.min(this.active, this.sheets.length - 1))
    this.setStatus("")
    this.refreshButtons()
  }

  show(index) {
    this.active = index
    const sheet = this.sheets[index]
    Array.from(this.tabsTarget.children).forEach((tab, i) => tab.setAttribute("aria-selected", String(i === index)))
    this.sheets.forEach((s, i) => { if (s.pane) s.pane.hidden = i !== index })
    if (!sheet.pane) this.mount(sheet)
    this.describe(sheet)
    this.cellTarget.textContent = ""
    this.refreshButtons()
  }

  editable(sheet) { return this.hasSaveUrlValue && !!this.saveUrlValue && !sheet.read_only_reason }
  rowOps(sheet) { return this.editable(sheet) && !sheet.row_ops_reason }

  mount(sheet) {
    sheet.pane = document.createElement("div")
    sheet.pane.className = "spreadsheet-pane"
    sheet.pane.setAttribute("role", "tabpanel")
    this.panesTarget.append(sheet.pane)
    if (sheet.kind !== "worksheet" || sheet.skipped) {
      const p = document.createElement("p")
      p.className = "muted"
      p.textContent = sheet.read_only_reason || "This sheet is not shown here."
      sheet.pane.append(p)
      return
    }

    const editable = this.editable(sheet)
    // Room to type past the data — but only where the sheet really ends there. Past a cut sheet the
    // spare rows would be the file's own hidden rows, and typing into them would overwrite cells
    // nobody could see.
    const rows = Math.max(sheet.shown_rows, 1) + (editable && !sheet.more_rows ? 20 : 0)
    const cols = Math.max(sheet.shown_cols, 1) + (editable && !sheet.more_cols ? 3 : 0)
    sheet.original = Array.from({ length: rows }, (_, y) => sheet.rows[y] || [])
    sheet.ids = Array.from({ length: rows }, (_, y) => y)
    const columns = Array.from({ length: cols }, (_, x) => ({ width: sheet.widths[x] || 80, type: "text", readOnly: !editable }))
    const rowOps = this.rowOps(sheet)

    const grid = document.createElement("div")
    grid.className = "spreadsheet-grid"
    sheet.pane.append(grid)
    sheet.grid = grid
    window.jspreadsheet(grid, {
      worksheets: [ {
        data: sheet.rows.map((row) => row.slice()),
        minDimensions: [ cols, rows ],
        columns,
        editable,
        allowInsertRow: rowOps,
        allowManualInsertRow: rowOps,
        allowDeleteRow: rowOps,
        allowInsertColumn: false,
        allowManualInsertColumn: false,
        allowDeleteColumn: false,
        allowRenameColumn: false,
        allowComments: false,
        columnSorting: false,
        columnDrag: false,
        rowDrag: false,
        search: false,
        filters: false,
        wordWrap: false,
        lazyLoading: true,
        tableOverflow: true,
        tableWidth: "100%",
        tableHeight: "60vh"
      } ],
      parseFormulas: false,
      allowExport: false,
      contextMenu: (worksheet, x, y, event, items, section) => this.menu(sheet, worksheet, y, section),
      onchange: () => this.changed(),
      onpaste: () => this.changed(),
      oninsertrow: (worksheet, inserted) => this.inserted(sheet, inserted),
      ondeleterow: (worksheet, removed) => this.deleted(sheet, removed),
      onselection: (worksheet, x1, y1, x2, y2) => this.selected(sheet, x1, y1, x2, y2),
      onload: (workbook) => {
        const worksheet = workbook.worksheets[0]
        worksheet.ignoreHistory = true
        sheet.instance = worksheet
        sheet.rowCount = worksheet.options.data.length
        for (const key of sheet.locked || []) {
          const [ y, x ] = key.split(",").map(Number)
          worksheet.setReadOnly(`${columnName(x)}${y + 1}`, true)
        }
        this.refreshButtons()
      }
    })
  }

  destroyGrids() {
    for (const sheet of this.sheets || []) {
      if (sheet.grid && window.jspreadsheet?.destroy) window.jspreadsheet.destroy(sheet.grid, true)
    }
  }

  // What the page says about the sheet in front of the maker: how much of it is shown, and why
  // some of it cannot be changed here.
  describe(sheet) {
    const notes = []
    if (sheet.more_rows) {
      const of = sheet.total_rows ? ` of ${sheet.total_rows.toLocaleString()}` : ""
      notes.push(`Showing the first ${sheet.shown_rows.toLocaleString()}${of} rows; the rest are kept as they are.`)
    }
    if (sheet.more_cols) notes.push(`Showing the first ${sheet.shown_cols} columns; the rest are kept as they are.`)
    if (this.hasSaveUrlValue && this.saveUrlValue) {
      if (sheet.read_only_reason) notes.push(sheet.read_only_reason)
      else if (sheet.row_ops_reason) notes.push(sheet.row_ops_reason)
    }
    this.noteTarget.textContent = notes.join(" ")
    this.noteTarget.hidden = notes.length === 0
  }

  // The rows are remembered rather than asked for later: a click on the toolbar is outside the
  // table, and jspreadsheet may clear its own selection on that mousedown before Add row runs.
  selected(sheet, x1, y1, x2, y2) {
    const x = Number(x1)
    const y = Number(y1)
    const y2n = Number(y2 ?? y1)
    sheet.selection = [ Math.min(y, y2n), Math.max(y, y2n) ]
    const name = `${columnName(x)}${y + 1}`
    const id = sheet.ids?.[y]
    const value = sheet.instance?.getValueFromCoords?.(x, y) ?? ""
    const untouched = id != null && String(value ?? "") === String(sheet.original?.[id]?.[x] ?? "")
    const formula = untouched ? sheet.formulas?.[`${id},${x}`] : null
    this.cellTarget.textContent = formula ? `${name}  ${formula}` : name
  }

  menu(sheet, worksheet, y, section) {
    if (!this.rowOps(sheet) || (section !== "cell" && section !== "row")) return false
    const row = Number(y)
    return [
      { title: "Insert row above", onclick: () => worksheet.insertRow(1, row, true) },
      { title: "Insert row below", onclick: () => worksheet.insertRow(1, row) },
      { title: "Delete row", onclick: () => this.deleteSelected(sheet, row) }
    ]
  }

  addRow() {
    const sheet = this.sheets[this.active]
    if (!sheet?.instance || !this.rowOps(sheet)) return
    const after = sheet.selection ? sheet.selection[1] : sheet.instance.options.data.length - 1
    sheet.instance.insertRow(1, after)
  }

  deleteRows() {
    const sheet = this.sheets[this.active]
    if (!sheet?.instance || !this.rowOps(sheet)) return
    this.deleteSelected(sheet, null)
  }

  deleteSelected(sheet, fallback) {
    const [ first, last ] = sheet.selection || (fallback == null ? [] : [ fallback, fallback ])
    if (first == null) return this.setStatus("Select a row to delete.")
    sheet.instance.deleteRow(first, last - first + 1)
  }

  inserted(sheet, inserted) {
    const at = Math.min(...inserted.map((r) => Number(r.row)))
    sheet.ids.splice(at, 0, ...inserted.map(() => null))
    sheet.rowCount = sheet.instance?.options.data.length ?? sheet.rowCount + inserted.length
    this.log.push({ sheet: sheet.index, op: "insert_rows", at, count: inserted.length })
    this.changed()
  }

  // The count is what the grid really lost, not what was asked for: jspreadsheet keeps its last
  // row rather than delete it, and still reports the row it kept.
  deleted(sheet, removed) {
    const now = sheet.instance.options.data.length
    const count = sheet.rowCount - now
    sheet.rowCount = now
    if (count <= 0) return
    const at = Math.min(...removed.map(Number))
    sheet.ids.splice(at, count)
    this.log.push({ sheet: sheet.index, op: "delete_rows", at, count })
    this.changed()
  }

  changed() {
    this.dirty = true
    this.setStatus("Unsaved changes")
    this.refreshButtons()
  }

  // Every row operation in the order it was made, then every cell whose value differs from what was
  // loaded — in the grid's final coordinates, which is the order Maker::Xlsx::Edit applies them.
  operations() {
    const sets = []
    for (const sheet of this.sheets) {
      if (!sheet.instance) continue
      sheet.instance.getData(false, false).forEach((row, y) => {
        const id = sheet.ids[y]
        const before = id == null ? [] : sheet.original[id]
        row.forEach((value, x) => {
          const now = value == null ? "" : String(value)
          if (now !== String(before[x] ?? "")) sets.push({ sheet: sheet.index, op: "set", row: y, col: x, value: now })
        })
      })
    }
    return [ ...this.log, ...sets ]
  }

  async save() {
    const ops = this.operations()
    if (ops.length === 0) {
      this.dirty = false
      this.setStatus("Nothing to save")
      return this.refreshButtons()
    }

    this.saving = true
    this.refreshButtons()
    this.setStatus("Saving…")
    try {
      const response = await fetch(this.saveUrlValue, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content ?? ""
        },
        body: JSON.stringify({ base_token: this.token, ops })
      })
      const body = await response.json().catch(() => ({}))
      if (!response.ok) {
        this.setStatus(body.error || `Not saved: the server refused it (HTTP ${response.status}).`, true)
        if (response.status === 409) this.offerReload()
        return
      }
      this.dirty = false
      await this.load()
      if (!this.disconnected) this.setStatus("Saved")
    } catch (error) {
      this.setStatus("Not saved. Check your connection and try again.", true)
    } finally {
      this.saving = false
      this.refreshButtons()
    }
  }

  // A save refused because the file moved on cannot succeed on retry; reloading is the way forward,
  // and it throws the edits away, so it asks first.
  offerReload() {
    const button = document.createElement("button")
    button.type = "button"
    button.className = "linkbtn"
    button.textContent = "Reload"
    button.addEventListener("click", () => {
      if (!window.confirm("Reload the workbook? Your unsaved changes will be lost.")) return
      this.dirty = false
      this.rest()
      this.load()
    })
    this.statusTarget.append(" ", button)
  }

  refreshButtons() {
    const sheet = this.sheets?.[this.active]
    if (this.hasSaveTarget) this.saveTarget.disabled = this.saving || !this.dirty
    const rowOps = !!sheet?.instance && this.rowOps(sheet) && !this.saving
    if (this.hasAddRowTarget) this.addRowTarget.disabled = !rowOps
    if (this.hasDeleteRowTarget) this.deleteRowTarget.disabled = !rowOps
  }

  setStatus(text, isError = false) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.classList.toggle("is-error", isError)
  }
}
