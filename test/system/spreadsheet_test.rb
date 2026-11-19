require "application_system_test_case"
require "support/xlsx_fixture"

# THE WORKBOOK VIEWER IN A REAL BROWSER — the only tier that can see it. A request test proves the
# page carries the right attributes and the door takes the right operations; whether jspreadsheet
# loads from the injected script tags, whether a keystroke becomes a `set` and an Add row an
# `insert_rows`, and whether Save reaches the file are invisible from there (§14d: a controller that
# resolves to nothing is a silent no-op).
#
# SHARE BACKEND, ASSIGNED DIRECTLY, on code_viewer_test.rb's precedent and for its reason: the save
# must land in REAL BYTES the test can read back. Not a backend-coverage test — the three backends
# are driven through the door in test/integration/web/spreadsheet_test.rb.
class SpreadsheetViewerTest < ApplicationSystemTestCase
  include XlsxFixture

  setup do
    @root = Pathname.new(Dir.mktmpdir("xlsx"))
    @root.join("bom.xlsx").binwrite(xlsx_bytes)
    @root.join("plain.xlsx").binwrite(xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false)))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    @user = sign_in_as("xlsx@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def open_file(name)
    @node = @user.nodes.find_by!(storage_path: name)
    visit file_path(@node.node_id)
    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet", wait: 10
  end

  # What the live jspreadsheet worksheet holds — the grid's own model, not the DOM, because rows
  # past the first hundred are not rendered at all (lazyLoading).
  def grid_value(x, y)
    page.evaluate_script(<<~JS)
      document.querySelector(".spreadsheet-pane:not([hidden]) .spreadsheet-grid").spreadsheet.worksheets[0].getValueFromCoords(#{x}, #{y})
    JS
  end

  def cell(x, y) = find(".spreadsheet-pane:not([hidden]) td[data-x='#{x}'][data-y='#{y}']")
  def saved_rows(name) = Maker::Xlsx::Workbook.new(Maker::Xlsx::Package.open(@root.join(name).binread)).payload[:sheets][0][:rows]

  STATUS = ".spreadsheet-status".freeze
  LEAVE = "Leave without saving your changes to this workbook?".freeze

  # An ordinary edit: select the cell, type, Enter.
  def type_into(x, y, text)
    cell(x, y).click
    page.send_keys(text, :enter)
  end

  def grid_rows
    page.evaluate_script(<<~JS)
      document.querySelector(".spreadsheet-pane:not([hidden]) .spreadsheet-grid").spreadsheet.worksheets[0].options.data.length
    JS
  end

  # A SLOW NETWORK, AND NOTHING ELSE: Save is pressed and its request waits at the door until the
  # test lets it through. The grid, the controller and the server are all the real ones. "Saving…"
  # is written in the same breath the request is made, so seeing it means the request is waiting.
  def save_and_hold
    page.execute_script(<<~JS)
      const real = window.fetch.bind(window)
      const held = window.__held = []
      window.fetch = async (url, options = {}) => {
        if (options.method === "PATCH") await new Promise((go) => held.push(go))
        return real(url, options)
      }
    JS
    click_on "Save"
    assert_selector STATUS, text: "Saving…"
  end

  def release_save = page.execute_script("window.__held.shift()()")

  # A FAILING NETWORK, ONCE: the next save (PATCH) or the next read of the workbook (GET) is answered
  # with `status` and no message instead of reaching the app. Matched on the page's own two URLs, so
  # a link Turbo prefetches on the way past cannot use the failure up.
  def fail_next(method, status)
    page.execute_script(<<~JS, method, status)
      const [ method, status ] = arguments
      const door = document.querySelector("[data-controller~='spreadsheet']").dataset
      const target = method === "GET" ? door.spreadsheetUrlValue : door.spreadsheetSaveUrlValue
      const real = window.fetch.bind(window)
      let pending = true
      window.fetch = async (url, options = {}) => {
        if (!pending || (options.method || "GET") !== method || String(url) !== target) return real(url, options)
        pending = false
        return new Response("{}", { status, headers: { "Content-Type": "application/json" } })
      }
    JS
  end

  # The grid's own paste at a cell, which is what ⌘V reaches with the clipboard's text (a headless
  # browser has no clipboard to hand it). One line of `text` per row, starting at the cell.
  def paste_at(x, y, text)
    cell(x, y).click
    page.execute_script(<<~JS, x, y, text)
      document.querySelector(".spreadsheet-pane:not([hidden]) .spreadsheet-grid").spreadsheet.worksheets[0].paste(...arguments)
    JS
  end

  # What the browser raises when a page is about to go, without the page going. Cancelling it is
  # what makes a browser ask "Leave site?", and a cancelled event is what dispatchEvent reports.
  def leaving_asks? = page.evaluate_script("!window.dispatchEvent(new Event('beforeunload', { cancelable: true }))")

  # The file moves on behind the open page: the same workbook with 21 nuts in place of 20, written
  # where a desktop edit would write it. The catalog has not scanned it, so it is the store's own
  # answer that refuses the save (Maker::TextSave's second arm).
  def change_file_elsewhere(name)
    rows = parts_rows_xml.sub("<v>20</v>") { "<v>21</v>" }
    @root.join(name).binwrite(xlsx_bytes(parts_sheet: parts_sheet_xml(ext: false, rows:)))
  end

  test "a workbook opens as a grid, one tab per sheet, showing the values Excel stored" do
    open_file("bom.xlsx")

    assert_selector ".spreadsheet-tabs .tab-link", count: 2
    assert_selector ".spreadsheet-tabs .tab-link[aria-selected='true']", text: "Parts"
    assert_equal "Bolt M3", grid_value(0, 1)
    assert_equal "27.7%", grid_value(3, 5)
    assert_selector ".spreadsheet-note", text: /Excel extensions/
    assert_selector "[data-spreadsheet-target=addRow][disabled]"

    find(".spreadsheet-tabs .tab-link", text: "Notes").click
    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet"
    assert_equal "Hardware store", grid_value(1, 0)
    assert_no_console_errors
  end

  # THE GRID IS PAINTED IN TOKENS, so an open one follows a theme switch with nothing to repaint
  # (design-system.md, "the viewers follow the theme"). Read off the computed colours — the table's
  # background (the cells are transparent over it) and a cell's text: the vendored jspreadsheet.css
  # alone would leave the table white in both themes.
  test "the open grid follows a theme switch" do
    open_file("bom.xlsx")
    look = -> { page.evaluate_script(<<~JS) }
      (() => { const grid = document.querySelector(".spreadsheet-pane:not([hidden]) .jss_worksheet")
               const td = grid.querySelector("td[data-x='0'][data-y='1']")
               return [ getComputedStyle(grid).backgroundColor, getComputedStyle(td).color ] })()
    JS

    page.execute_script("document.documentElement.dataset.theme = 'light'")
    light = look.call
    page.execute_script("document.documentElement.dataset.theme = 'dark'")
    dark = look.call

    assert_not_equal light, dark
    assert_not_equal "rgb(255, 255, 255)", dark[0], "the dark grid is still jspreadsheet's white"
  end

  test "a cell typed over is saved into the same file, and the formula beside it shows on select" do
    open_file("bom.xlsx")

    cell(3, 1).click
    assert_selector ".spreadsheet-cell", text: "D2  =B2*C2"
    cell(1, 1).click
    page.send_keys("12", :enter)
    assert_selector ".spreadsheet-status", text: "Unsaved changes"
    click_on "Save"

    assert_selector ".spreadsheet-status", text: /\ASaved/, wait: 10
    rows = saved_rows("bom.xlsx")
    assert_equal "12", rows[1][1]
    assert_equal "1.2", rows[1][3], "the formula cell keeps its stored result until Excel recalculates"
    assert_equal @node.node_id, @user.nodes.find_by!(storage_path: "bom.xlsx").node_id
    assert_no_console_errors
  end

  test "Add row inserts below the selected row and the save moves the rows below it" do
    open_file("plain.xlsx")

    cell(0, 2).click
    click_on "Add row"
    cell(0, 3).click
    page.send_keys("Washer", :enter)
    click_on "Save"

    assert_selector ".spreadsheet-status", text: /\ASaved/, wait: 10
    assert_equal [ "Nut M3", "Washer", "Spacer 5mm", "Total" ], saved_rows("plain.xlsx")[2..5].map(&:first)
    cell(1, 5).click
    assert_selector ".spreadsheet-cell", text: "B6  =SUM(B2:B5)"
    assert_no_console_errors
  end

  test "Delete row removes the selected row and an edit below it lands on the right row" do
    open_file("plain.xlsx")

    cell(0, 2).click
    click_on "Delete row"
    cell(2, 2).click # Spacer's unit cost, now on grid row 3
    page.send_keys("2.5", :enter)
    click_on "Save"

    assert_selector ".spreadsheet-status", text: /\ASaved/, wait: 10
    rows = saved_rows("plain.xlsx")
    assert_equal [ "Part", "Bolt M3", "Spacer 5mm", "Total", "Summary" ], rows.map(&:first).first(5)
    assert_equal "2.5", rows[2][2]
    cell(1, 3).click
    assert_selector ".spreadsheet-cell", text: "B4  =SUM(B2:B3)"
    # The row that moved up kept its own formula: the diff compared it with ITSELF, not with the
    # row that used to sit there (whose cached 1 would have overwritten B3*C3 with a constant).
    cell(3, 2).click
    assert_selector ".spreadsheet-cell", text: "D3  =B3*C3"
    assert_no_console_errors
  end

  # UNDO WOULD DESYNC THE LOG: jspreadsheet replays history with its events suppressed, so an undone
  # insert leaves a logged insert the grid no longer shows, and the save inserts a row nobody sees.
  # History is off, so Ctrl+Z changes nothing and the grid keeps showing what the save will write.
  test "undo does not take back a row the log has already recorded" do
    open_file("plain.xlsx")

    cell(0, 2).click
    click_on "Add row"
    assert_equal "", grid_value(0, 3)
    cell(1, 1).click
    page.send_keys([ :control, "z" ])
    page.send_keys([ :command, "z" ])

    assert_equal "", grid_value(0, 3), "the inserted row was undone behind the log's back"
    assert_equal "Spacer 5mm", grid_value(0, 4)
  end

  # A SNAPSHOT TURBO RESTORES HOLDS THE LAST RENDER'S TABLES, WIRED TO NOTHING — the controller must
  # rebuild rather than reconnect over them, files-preview.md's "both code viewers rest too".
  test "Back to the page rebuilds one live grid" do
    open_file("bom.xlsx")

    back_through_turbo_cache

    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet", wait: 10
    assert_selector ".spreadsheet-grid .jss_worksheet", count: 1
    assert_selector ".spreadsheet-tabs .tab-link", count: 2
    assert page.evaluate_script("!!document.querySelector('.spreadsheet-grid').spreadsheet"), "the grid is not live"
    assert_no_console_errors
  end

  # WHAT WAS TYPED WHILE A SAVE WAS ON ITS WAY WAS THROWN AWAY, AND THE PAGE SAID "Saved". A save
  # sends the operations gathered when Save was pressed and, once the file has taken them, rebuilds
  # the grid from the file. The grid went on taking edits in between: none of them was in the
  # request, the rebuild dropped them, and the leave warning was already off. A slow save is the
  # ordinary case on a NAS or a bucket, which is what the held request stands in for.
  #
  # THREE WAYS IN, because the grid has no single door: typing over a selected cell, double-clicking
  # into one, and Delete. jspreadsheet asks one switch before each (options.editable, read at the
  # moment of the keystroke); the last lines prove the same grid takes typing again once it is over.
  test "a cell does not take an edit while a save is on its way, and takes one again after" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")
    save_and_hold

    type_into(1, 2, "99")
    cell(2, 1).double_click
    page.send_keys("7", :enter)
    cell(0, 1).click
    page.send_keys(:delete)

    assert_equal [ "Bolt M3", "0.12", "20" ], [ grid_value(0, 1), grid_value(2, 1), grid_value(1, 2) ],
                 "the grid took an edit the save on its way cannot carry"
    assert_selector STATUS, text: "Saving…"
    assert_button "Save", disabled: true
    release_save
    assert_selector STATUS, text: /\ASaved/
    assert_equal [ [ "Bolt M3", "12", "0.12" ], [ "Nut M3", "20", "0.05" ] ], saved_rows("plain.xlsx")[1..2].map { |row| row.first(3) }

    type_into(1, 2, "21")
    assert_selector STATUS, text: "Unsaved changes"
    assert_equal "21", grid_value(1, 2)
    assert_no_console_errors
  end

  # THE ROW DOORS ARE NOT THE CELL DOORS. The two toolbar buttons were already off during a save;
  # the right-click menu was not, and neither is the grid's own habit of adding a row when Enter is
  # pressed on its last one, which asks a different switch from the one that guards a cell
  # (options.allowInsertRow). A row added then is logged after the request left, so the save never
  # carried it. The menu is shown to be on offer first, so its absence later is not a wrong selector.
  test "no row is added while a save is on its way" do
    open_file("plain.xlsx")
    cell(0, 2).right_click
    assert_text "Insert row above"
    type_into(1, 1, "12")
    assert_no_text "Insert row above"
    rows = grid_rows
    save_and_hold

    cell(0, 2).right_click
    assert_no_text "Insert row above"
    cell(0, rows - 1).click
    page.send_keys(:enter)

    assert_equal rows, grid_rows, "a row went into the grid behind a save that cannot carry it"
    release_save
    assert_selector STATUS, text: /\ASaved/
    assert_equal [ "Part", "Bolt M3", "Nut M3", "Spacer 5mm", "Total", "Summary" ], saved_rows("plain.xlsx").map(&:first).first(6)
    assert_no_console_errors
  end

  # THE LOCK TURNS THE GRID'S ROW SWITCH OFF AND BACK ON, AND "ON" IS ONLY EVER WHAT THE SHEET ALLOWS.
  # A paste longer than the sheet adds the rows it needs where rows can be added, and the save
  # carries them. On a sheet whose rows Edit cannot move (bom.xlsx keeps an Excel extension) the
  # same paste stops at the last row, before a save and after the rebuild that follows one; a switch
  # that came back on there would log a row operation the door refuses, and take the cell edits
  # made beside it down with the refused save.
  test "a paste past the last row adds the rows it needs, and the save carries them" do
    open_file("plain.xlsx")
    rows = grid_rows

    paste_at(0, rows - 1, "a\nb\nc")

    assert_equal rows + 2, grid_rows
    click_on "Save"
    assert_selector STATUS, text: /\ASaved/
    assert_equal %w[a b c], saved_rows("plain.xlsx")[(rows - 1)..(rows + 1)].map(&:first)
    assert_no_console_errors
  end

  test "a paste past the last row adds none on a sheet that cannot take row operations" do
    open_file("bom.xlsx")
    rows = grid_rows

    paste_at(0, rows - 1, "a\nb\nc")

    assert_equal rows, grid_rows
    click_on "Save"
    assert_selector STATUS, text: /\ASaved/
    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet"
    rows = grid_rows
    paste_at(0, rows - 1, "d\ne\nf")
    assert_equal rows, grid_rows
    assert_equal "d", grid_value(0, rows - 1), "the paste never reached the grid, so it proved nothing"
  end

  # A SHEET IS BUILT THE FIRST TIME ITS TAB IS SHOWN, so a grid can come into being in the middle of
  # a save. It was built ready to type into, and what it took went the same way: not in the request,
  # gone at the rebuild.
  test "a sheet first opened while a save is on its way does not take an edit either" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")
    save_and_hold

    find(".spreadsheet-tabs .tab-link", text: "Notes").click
    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet"
    type_into(1, 0, "Online")

    assert_equal "Hardware store", grid_value(1, 0)
    release_save
    assert_selector STATUS, text: /\ASaved/
    assert_no_console_errors
  end

  # A SAVE REFUSED BECAUSE THE FILE MOVED ON CAN NEVER SUCCEED FROM THIS PAGE: its token is the old
  # file's. The page offered Reload, then left Save pressable (every press refused again) and let the
  # next keystroke write "Unsaved changes" over the Reload button, which left no way forward but the
  # browser's own reload. The edits are still only in the grid, so leaving still asks.
  test "a save the file has moved on from offers Reload, keeps offering it, and takes nothing more" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")
    change_file_elsewhere("plain.xlsx")
    click_on "Save"

    assert_selector STATUS, text: Maker::TextSave::STALE
    assert_button "Reload"
    assert_button "Save", disabled: true
    assert_button "Add row", disabled: true
    type_into(1, 3, "99")
    assert_equal "5", grid_value(1, 3), "the grid took an edit no save from this page can carry"
    assert_button "Reload"
    assert leaving_asks?, "the edits the file never took were left without a word"

    accept_confirm("Reload the workbook? Your unsaved changes will be lost.") { click_on "Reload" }

    assert_selector ".spreadsheet-pane:not([hidden]) .spreadsheet-grid .jss_worksheet"
    assert_equal %w[10 21], [ grid_value(1, 1), grid_value(1, 2) ], "Reload did not show the file as it now is"
    assert_no_button "Reload"
    refute leaving_asks?, "a workbook just reloaded asked before leaving"
    type_into(1, 3, "6")
    assert_selector STATUS, text: "Unsaved changes"
  end

  # THE SAVE LANDED AND THE READ-BACK DID NOT. The page shows why and offers the download, but the
  # grids it had just taken off the page were still held, so Add row and Delete row lit up again
  # over nothing: a press logged a row operation against a grid nobody could see, and the next Save
  # was refused as stale.
  test "a workbook that saved but could not be read back offers nothing to press" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")
    fail_next("GET", 503)
    click_on "Save"

    assert_selector STATUS, text: /\ASaved/
    assert_selector ".spreadsheet-error", text: "The workbook could not be loaded (HTTP 503)."
    assert_button "Add row", disabled: true
    assert_button "Delete row", disabled: true
    assert_button "Save", disabled: true
    refute leaving_asks?, "a saved workbook asked before leaving"
    assert_equal "12", saved_rows("plain.xlsx")[1][1]
  end

  # A REFUSAL THAT IS NOT ABOUT THE FILE HAVING MOVED ON leaves everything as it was: the edits stay
  # in the grid, more can be made, and the same Save carries all of them once the network is back.
  test "a save the network dropped can be added to and tried again" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")
    fail_next("PATCH", 503)
    click_on "Save"

    assert_selector "#{STATUS}.is-error", text: "Not saved: the server refused it (HTTP 503)."
    assert_no_button "Reload"
    assert leaving_asks?, "edits a failed save left behind were dropped without a word"
    type_into(1, 2, "21")
    click_on "Save"

    assert_selector STATUS, text: /\ASaved/
    assert_equal %w[12 21], saved_rows("plain.xlsx")[1..2].map { |row| row[1] }
    assert_no_console_errors
  end

  # LEAVING ASKS FOR AS LONG AS THE GRID HOLDS AN EDIT THE FILE DOES NOT, which includes the whole
  # time a save is on its way: a request cut off by the page going may never have arrived.
  test "leaving asks from the first edit until the file has taken it" do
    open_file("plain.xlsx")
    refute leaving_asks?, "a workbook nobody touched asked before leaving"

    type_into(1, 1, "12")
    assert leaving_asks?, "an unsaved edit did not ask"
    save_and_hold
    assert leaving_asks?, "a save still on its way did not ask"
    release_save

    assert_selector STATUS, text: /\ASaved/
    refute leaving_asks?, "a saved workbook asked before leaving"
  end

  test "a link out of the page asks first while an edit is unsaved, and staying keeps the edit" do
    open_file("plain.xlsx")
    type_into(1, 1, "12")

    dismiss_confirm(LEAVE) { find("header.strip a.strip-place[href='#{files_path}']").click }

    assert_current_path file_path(@node.node_id)
    assert_equal "12", grid_value(1, 1)
  end
end
