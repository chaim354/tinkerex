require "application_system_test_case"

# THE LEFT COLUMN AT EVERY WIDTH (Shop manual spec §7, slice 3; design-system.md rule 8). From 960px it
# sits beside the page; below, it is a sheet the strip's Contents button opens over the page. Only a
# browser sees where the column is drawn, that opening the sheet moves nothing on the page, where
# focus goes, and that Escape and the scrim close it.
#
# The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not make
# a WebDriver window narrower than 500px).
#
# MUTATION-CHECKED (2026-11-19; each reverted, and the file re-run green after):
#   1. Deleting `body.column-open .column { transform: none; visibility: visible; }` (shell.css): the
#      sheet test red, the sheet never on screen.
#   2. Deleting `data-action="keydown.esc->shell#closeColumn"` from the aside (layouts/application):
#      the sheet test red, Escape leaves it open.
#   3. Dropping the focus move from shell_controller.js#openColumn: the sheet test red on the focused
#      element.
#   4. The ≤959px block keeping the grid's column track (`.shell-body--column` left at
#      `var(--column-width) minmax(0, 1fr)`): the sheet test red, main shifted by the column's width.
class ShellColumnTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("shell-column@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "from 960px the column sits beside the page, 220px on the raised ground, and no Contents button shows" do
    width!(960)
    visit files_path(folder: @cad.node_id)
    column, main = boxes("aside.column", "main#main")
    assert_equal 220, column["width"].round, "the column is not 220px wide (#{column.inspect})"
    assert_operator main["left"], :>=, column["right"] - 1, "main does not start after the column (#{main.inspect})"
    assert_equal raised_colour, page.evaluate_script("getComputedStyle(document.querySelector('aside.column')).backgroundColor")
    assert_selector "header.strip .strip-contents", visible: :hidden
    assert_selector "aside.column a.column-row[aria-current='page']", text: "cad"
    assert_no_console_errors
  end

  test "below 960px Contents opens the column as a sheet over the page, and Escape and the scrim close it" do
    width!(900)
    visit files_path(folder: @cad.node_id)
    contents = find("header.strip button.strip-contents[aria-expanded='false']")
    assert_selector "aside.column", visible: :hidden
    main_before = boxes("main#main").first
    assert_operator main_before["left"], :<, 40, "main keeps the column's track below 960px (#{main_before.inspect})"

    contents.click
    assert_selector "header.strip button.strip-contents[aria-expanded='true']"
    assert_selector "aside.column", visible: true
    sheet, main_after = boxes("aside.column", "main#main")
    assert_equal 0, sheet["left"].round, "the sheet does not open at the left edge (#{sheet.inspect})"
    assert_operator sheet["height"], :>=, 899, "the sheet does not span the viewport's height (#{sheet.inspect})"
    assert_equal main_before, main_after, "opening the sheet moved the page"
    assert page.evaluate_script("document.activeElement.closest('aside.column') !== null"), "focus did not move into the sheet"
    assert_selector ".column-scrim", visible: true

    find("aside.column a.column-row", text: "Library").send_keys(:escape)
    assert_selector "aside.column", visible: :hidden
    assert_selector "header.strip button.strip-contents[aria-expanded='false']"
    assert page.evaluate_script("document.activeElement === document.querySelector('header.strip .strip-contents')"),
           "focus did not return to Contents"

    contents.click
    assert_selector "aside.column", visible: true
    # The scrim is under the sheet at the left, so it is clicked where the page shows through it.
    page.driver.browser.action.move_to_location(850, 600).click.perform
    assert_selector "aside.column", visible: :hidden
    assert_no_console_errors
  end

  test "a row in the sheet goes where it says" do
    width!(900)
    visit files_path(folder: @cad.node_id)
    find("header.strip button.strip-contents").click
    within("aside.column") { click_link "Trash" }
    assert_current_path trash_index_path
    assert_selector "aside.column", visible: :hidden
    assert_no_console_errors
  end

  private

    def width!(width)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width:, height: 900, deviceScaleFactor: 1, mobile: false)
    end

    def boxes(*selectors)
      page.evaluate_script(<<~JS, selectors)
        arguments[0].map((s) => { const r = document.querySelector(s).getBoundingClientRect();
                                   return { left: r.left, right: r.right, width: r.width, height: r.height }; })
      JS
    end

    def raised_colour
      page.evaluate_script(<<~JS)
        (() => { const probe = document.createElement("i"); probe.style.background = "var(--raised)";
                 document.body.append(probe); const colour = getComputedStyle(probe).backgroundColor;
                 probe.remove(); return colour })()
      JS
    end
end
