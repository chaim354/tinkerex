require "application_system_test_case"

# A VERSION STACK OPENS IN PLACE, AND AN OPENED STACK FITS A PHONE (Shop manual spec §9 and §10's
# width guard; design-system.md rule 11). The request tests (version_stacks_pages_test.rb) pin what
# the server draws; this drives what only a browser does: stack_controller.js showing a row's
# members or a figure's opened panel and hiding them again, Close handing the focus back, the Pull
# out button round trip, and the page at 375px with a stack open in the Library's rows, its tiles
# and a project panel.
#
# THE STACK'S NAME IS UNDERSCORE-JOINED, narrow_names_test.rb's reason: an underscore is not a break
# opportunity, so eighty characters are one word whose min-content width is the whole name, the shape
# that pushes a page sideways when a rule forgets `overflow-wrap`. The files carry an extension no
# renderer claims, so the page has no thumbnail to wait for and nothing to log about one.
#
# MEASURED AGAINST clientWidth, NOT innerWidth: CI's Linux Chrome draws a 15px classic scrollbar.
class VersionStacksTest < ApplicationSystemTestCase
  LONG = %w[workshop lampshade bracket revision three exported for big laser cutter final cut].join("_")

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("stacks@example.com")
    @project = @user.maker_projects.create!(name: "Stacked", status: "active", autofile: false)
    folder = project_folder_rows!(@user, @project)
    @laser = @user.nodes.create!(node_id: "d-laser", name: "laser", kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
    @v1 = file!("#{LONG} v1.zzz", 1)
    @v2 = file!("#{LONG} v2.zzz", 2)
    @backup = file!("#{LONG}_backup.zzz", 3)
    file!("game box 2.zzz", 4)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def file!(name, i)
    @user.nodes.create!(node_id: "f-#{i}", name:, kind: "file", parent_node_id: @laser.node_id, size: 100 * i,
                        mtime: 1_700_000_000_000_000_000 + i)
  end

  test "a stack row opens its members in place and closes again" do
    visit files_path(folder: @laser.node_id, view: "list")
    toggle = find("tr.stack-row .stack-toggle")
    assert_equal "false", toggle["aria-expanded"]
    assert_no_selector "tr.stack-member", visible: true
    toggle.click
    assert_selector "tr.stack-member", visible: true, count: 3
    assert_equal "true", toggle["aria-expanded"]
    assert_selector "tr.stack-member .stack-role", text: "latest", count: 1
    # Opening a stack navigates nowhere.
    assert_current_path files_path(folder: @laser.node_id, view: "list")
    toggle.click
    assert_no_selector "tr.stack-member", visible: true
    assert_no_console_errors
  end

  test "a stack figure opens a panel of its members, and Close hands the focus back" do
    visit files_path(folder: @laser.node_id, view: "grid")
    figure = find(".files-grid button.stack")
    figure.click
    assert_selector ".stack-open", visible: true
    assert_selector ".stack-open .stack-member", count: 3
    within(".stack-open") { click_on "Close" }
    assert_no_selector ".stack-open", visible: true
    assert_equal figure["id"], page.evaluate_script("document.activeElement.id")
    assert_no_console_errors
  end

  test "pulling a member out leaves it standing alone with Put back" do
    visit files_path(folder: @laser.node_id, view: "list")
    find("tr.stack-row .stack-toggle").click
    find("button[aria-label='Pull #{@backup.name} out of its stack']").click
    assert_text "Pulled #{@backup.name} out of its stack."
    assert_selector "tr:not(.stack-member)", text: @backup.name
    assert_selector "button", text: "Put back", count: 1
    click_on "Put back"
    assert_text "Put #{@backup.name} back in its stack."
    assert_no_selector "button", text: "Put back"
  end

  test "an opened stack fits a phone in the Library's rows and tiles and in a project panel" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit files_path(folder: @laser.node_id, view: "list")
    find("tr.stack-row .stack-toggle").click
    assert_selector "tr.stack-member", visible: true, count: 3
    assert_no_sideways_scroll "the Library's rows with a stack open"

    visit files_path(folder: @laser.node_id, view: "grid")
    find(".files-grid button.stack").click
    assert_selector ".stack-open", visible: true
    assert_fits ".stack-open h3", "the opened stack's name"
    assert_no_sideways_scroll "the Library's tiles with a stack open"

    visit project_path(@project)
    find("section[id='#{Maker::ProjectKind.folder_key(@laser.node_id)}'] button.stack").click
    assert_selector ".attachments-grid > .stack-open", visible: true
    assert_fits ".attachments-grid > .stack-open h3", "the opened stack's name in a panel"
    assert_no_sideways_scroll "a project panel with a stack open"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def assert_no_sideways_scroll(label)
    scroll, client = page.evaluate_script("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
    assert_operator scroll, :<=, client, "#{label} scrolls sideways at 375px (scrollWidth #{scroll}, clientWidth #{client})"
  end

  def assert_fits(selector, label)
    own, box, right, parent_right = page.evaluate_script(<<~JS)
      (function () {
        var el = document.querySelector(#{selector.to_json});
        return [el.scrollWidth, el.clientWidth, el.getBoundingClientRect().right, el.parentElement.getBoundingClientRect().right];
      })()
    JS
    assert_operator own, :<=, box, "#{label}'s text overflows its own box at 375px (scrollWidth #{own}, clientWidth #{box})"
    assert_operator right, :<=, parent_right + 0.5, "#{label} is wider than its container at 375px"
  end
end
