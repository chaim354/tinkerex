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
end
