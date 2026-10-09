require "application_system_test_case"

# CLICK TO SELECT, DOUBLE-CLICK OR ENTER TO OPEN (structural redesign spec §5.1, slice 3), driven in
# a browser because every one of these is selection_controller.js's: the request test
# (test/integration/web/files_selection_test.rb) pins the markup it reads and the ids the server
# honours, and only a browser can show the click being intercepted, the URL being rewritten and the
# frame loading.
#
# SCANNED INTO PLACE, as code_theme_test.rb does, so the tiles are the real ones a library produces.
class FilesSelectionTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @root.join("legs").mkpath
    @root.join("legs/bracket.stl").write("solid bracket\nendsolid bracket\n")
    @root.join("legs/plate.stl").write("solid plate\nendsolid plate\n")
    @root.join("legs/side.jpg").write("not really a jpeg")
    @user = sign_in_as("files-selection@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def legs = @user.nodes.find_by!(storage_path: "legs")
  def bracket = @user.nodes.find_by!(storage_path: "legs/bracket.stl")
  def plate = @user.nodes.find_by!(storage_path: "legs/plate.stl")

  test "click selects and opens the inspector, Escape closes, reload restores" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_selector ".library.has-inspector .inspector .inspector-name", text: "bracket.stl"
    assert_includes page.current_url, "selected=#{bracket.node_id}"
    assert_selector ".grid-card.is-selected", count: 1
    assert_selector ".grid-card.is-selected", text: "bracket.stl"
    # A click that selects does not navigate.
    assert_current_path files_path, ignore_query: true

    visit page.current_url
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    assert_selector ".grid-card.is-selected", text: "bracket.stl"

    find(".grid-card", text: "bracket.stl").send_keys(:escape)
    assert_no_selector ".library.has-inspector"
    assert_no_selector ".grid-card.is-selected"
    refute_includes page.current_url, "selected="
    assert_no_console_errors
  end

  test "double-click opens the page, and Enter on a focused tile opens it too" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").double_click
    assert_current_path file_path(plate.node_id)
    # THE REFERER CARRIES THE SELECTION, which is what lets the file page's Back return to the
    # Library with the file still selected (back_target_path is referer-based, files-preview.md).
    assert_includes find_link("Back")[:href], "selected=#{plate.node_id}"

    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").send_keys(:enter)
    assert_current_path file_path(plate.node_id)
    assert_no_console_errors
  end

  test "arrow keys move the selection" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    find(".grid-card.is-selected").send_keys(:arrow_right)
    assert_selector ".grid-card.is-selected", count: 1
    assert_selector ".grid-card.is-selected", text: "plate.stl"
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    assert_includes page.current_url, "selected=#{plate.node_id}"
    assert_no_console_errors
  end

  # THE PAGE'S OWN LINKS CARRY THE SELECTION THE SERVER SAW (files_query_base), so a Library opened
  # on one file — which is where attaching from the inspector lands — and then clicked to another
  # must not switch view, or re-sort, straight back to the first.
  test "a re-sort or view switch after a click keeps the file clicked, not the one the page loaded with" do
    # The sort form's hidden field first ...
    visit files_path(folder: legs.node_id, view: "list", selected: bracket.node_id)
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    find("table.files a", text: "plate.stl").click
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    find("#sort-key").select("Modified")
    assert_selector "#sort-key option[selected]", text: "Modified"
    assert_selector "table.files a.is-selected", text: "plate.stl"

    # ... then the view toggle's links.
    find("table.files a", text: "bracket.stl").click
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    within(".view-toggle") { click_link "Grid" }
    assert_selector ".grid-card.is-selected", text: "bracket.stl"
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    assert_no_console_errors
  end

  # THE INSPECTOR SITS INSIDE THE CONTROLLER'S ELEMENT, so its keydown listener hears the panel's own
  # controls; an arrow in the project picker must choose a project, not move the selection.
  test "arrow keys inside the inspector stay with the control" do
    @user.maker_projects.create!(name: "Shop Stool")
    @user.maker_projects.create!(name: "Workbench")
    visit files_path(folder: legs.node_id, view: "grid", selected: bracket.node_id)
    find(".inspector form.attach-form select").send_keys(:arrow_down)
    assert_selector ".grid-card.is-selected", text: "bracket.stl"
    assert_includes page.current_url, "selected=#{bracket.node_id}"
    assert_no_console_errors
  end

  test "at phone width the inspector is a sheet that closes, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812,
                                    deviceScaleFactor: 1, mobile: false)
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
           "the sheet scrolls the page sideways"
    # A SHEET: it covers the listing edge to edge. Measured against the viewport's CLIENT width, never
    # a literal 375: a fixed box with left/right 0 ends where the scrollbar begins, and the Linux CI
    # runners draw a classic 15px scrollbar (360) where macOS overlays one (375).
    left, right, edge = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector('.inspector').getBoundingClientRect();
               return [r.left, r.right, document.documentElement.clientWidth]; })()
    JS
    assert_equal [ 0, edge ], [ left.round, right.round ]
    # The close is a LINK (the no-JavaScript door), so with the controller it must not also follow
    # it. turbo:before-visit fires inside the click's own dispatch, so the count is settled here.
    page.execute_script("window.__visits = 0; addEventListener('turbo:before-visit', () => window.__visits++)")
    find(".inspector-close").click
    assert_no_selector ".library.has-inspector"
    assert_equal 0, page.evaluate_script("window.__visits"), "closing the panel followed the link"
    # The close button hides with the panel, so focus is handed back to the tile the panel
    # described rather than dropped to <body>. Asked of the active element ITSELF: a querySelector
    # from it would answer for <body> too, since the first tile in the document is this one.
    assert_equal bracket.node_id, page.evaluate_script("document.activeElement.dataset.selectionId")
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
