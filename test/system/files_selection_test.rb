require "application_system_test_case"

# A CLICK OPENS THE FILE, A DOUBLE-CLICK OPENS IT IN A NEW TAB, RIGHT-CLICK › DETAILS OPENS THE PANEL
# (2026-10-21, docs/superpowers/specs/2026-10-21-file-click-and-model-page-design.md; until then a
# click selected, structural redesign spec §5.1, slice 3). fileopen_controller.js owns the click and
# the double-click; selection_controller.js owns the panel once Details (or a `?selected=` page)
# opens it. Driven in a browser because only a browser shows the click being delayed, the tab
# opening and the frame loading: the request test (test/integration/web/files_selection_test.rb)
# pins the markup both controllers read and the ids the server honours.
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

  def details_for(selector, name)
    find(selector, text: name).right_click
    find(".file-menu a", text: "Details").click
  end

  test "a click opens the file page" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").click
    assert_current_path file_path(bracket.node_id)
    assert_no_console_errors
  end

  test "a click on a list row opens the file page too" do
    visit files_path(folder: legs.node_id, view: "list")
    find("table.files a", text: "plate.stl").click
    assert_current_path file_path(plate.node_id)
    assert_no_console_errors
  end

  # A PERSON'S DOUBLE-CLICK, NOT SELENIUM'S. Capybara's `double_click` sends its two clicks back to
  # back, faster than even a zero-length timer can run, so it stayed green with fileopen's window set
  # to 0 ms (measured) — it could not tell a working window from none. A person's two clicks land
  # ~100 ms apart: inside the 250 ms window, and long enough for a narrower one to have fired and
  # navigated before the second arrives. ChromeDriver still counts the pair as one double-click
  # (`detail` 2), which the new tab opening proves — fileopen opens one on nothing else. ONE move,
  # then both clicks in place: `click(element)` would move again first, and selenium-webdriver's
  # pointer moves take 250 ms by default, which put the second click outside the window (measured).
  def paced_double_click(el)
    page.driver.browser.action.move_to(el.native).click.pause(duration: 0.1).click.perform
  end

  # THE WAIT IS THE MECHANISM: a double-click must cancel the single click's pending visit. The sleep
  # outlasts fileopen's 250 ms window, so a visit that was NOT cancelled has started by the time the
  # path is asserted.
  test "a double-click opens the file page in a new tab and leaves this one where it was" do
    visit files_path(folder: legs.node_id, view: "grid")
    tab = window_opened_by { paced_double_click(find(".grid-card", text: "plate.stl")) }
    within_window(tab) { assert_current_path file_path(plate.node_id) }
    sleep 0.5
    assert_current_path files_path, ignore_query: true
    assert_selector ".grid-card", text: "bracket.stl"
    tab.close
    assert_no_console_errors
  end

  test "Enter on a focused tile opens it" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "plate.stl").send_keys(:enter)
    assert_current_path file_path(plate.node_id)
    assert_no_console_errors
  end

  # A MODIFIER CLICK IS THE BROWSER'S, so fileopen must not cancel it. Dispatched rather than clicked,
  # because a real Cmd-click opens a tab the test cannot close cleanly; the spy on document runs after
  # the link's own listeners and cancels the navigation itself.
  test "a modifier click is left to the browser" do
    visit files_path(folder: legs.node_id, view: "grid")
    prevented = page.evaluate_script(<<~JS)
      (() => {
        const a = [...document.querySelectorAll(".grid-card")].find((el) => el.textContent.includes("bracket.stl"))
        let seen = null
        document.addEventListener("click", (ev) => { seen = ev.defaultPrevented; ev.preventDefault() }, { once: true })
        a.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, metaKey: true, detail: 1, button: 0 }))
        return seen
      })()
    JS
    assert_equal false, prevented, "fileopen cancelled a Cmd-click"
    assert_no_console_errors
  end

  # IN PLACE IS THE CLAIM, and the visit counter is what can tell: following the menu's details url
  # would ALSO land on this Library with the panel open (the server honours `selected=`), so every
  # other assertion here passes on a navigation too.
  test "right-click › Details opens the panel in place; Escape closes; reload restores" do
    visit files_path(folder: legs.node_id, view: "grid")
    page.execute_script("window.__visits = 0; addEventListener('turbo:before-visit', () => window.__visits++)")
    details_for(".grid-card", "bracket.stl")
    assert_selector ".library.has-inspector .inspector .inspector-name", text: "bracket.stl"
    assert_equal 0, page.evaluate_script("window.__visits"), "Details navigated instead of opening the panel"
    assert_includes page.current_url, "selected=#{bracket.node_id}"
    assert_selector ".grid-card.is-selected", count: 1, text: "bracket.stl"
    assert_current_path files_path, ignore_query: true

    visit page.current_url
    assert_selector ".inspector .inspector-name", text: "bracket.stl"

    find(".grid-card.is-selected").send_keys(:escape)
    assert_no_selector ".library.has-inspector"
    refute_includes page.current_url, "selected="

    # THE REFERER CARRIES THE SELECTION, which is what lets the file page's Back return to the
    # Library with the file still selected (back_target_path is referer-based, files-preview.md).
    # Asked after a Details on THIS page rather than after the reload above, whose URL the server
    # rendered with `selected=` already: only a client-side selection can lose it on the way out.
    details_for(".grid-card", "bracket.stl")
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    find(".inspector a", text: "Open").click
    assert_current_path file_path(bracket.node_id)
    assert_includes find_link("Back")[:href], "selected=#{bracket.node_id}"
    assert_no_console_errors
  end

  test "Details from Recent lands in the Library with the panel open" do
    visit root_path
    details_for(".recent-grid .grid-card", "plate.stl")
    assert_current_path files_path, ignore_query: true
    assert_includes page.current_url, "folder=#{legs.node_id}"
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    assert_no_console_errors
  end

  test "arrow keys move the selection while the panel is open, and only then" do
    visit files_path(folder: legs.node_id, view: "grid")
    find(".grid-card", text: "bracket.stl").send_keys(:arrow_right)
    assert_no_selector ".grid-card.is-selected"
    assert_no_selector ".library.has-inspector"

    visit files_path(folder: legs.node_id, view: "grid", selected: bracket.node_id)
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    find(".grid-card.is-selected").send_keys(:arrow_right)
    assert_selector ".grid-card.is-selected", count: 1, text: "plate.stl"
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    assert_includes page.current_url, "selected=#{plate.node_id}"
    assert_no_console_errors
  end

  # THE PAGE'S OWN LINKS CARRY THE SELECTION THE SERVER SAW (files_query_base), so a Library opened
  # on one file — which is where attaching from the inspector lands — and then switched to another
  # through Details must not switch view, or re-sort, straight back to the first.
  test "a re-sort or view switch after Details keeps the file chosen, not the one the page loaded with" do
    # The sort form's hidden field first ...
    visit files_path(folder: legs.node_id, view: "list", selected: bracket.node_id)
    assert_selector ".inspector .inspector-name", text: "bracket.stl"
    details_for("table.files a", "plate.stl")
    assert_selector ".inspector .inspector-name", text: "plate.stl"
    find("#sort-key").select("Modified")
    assert_selector "#sort-key option[selected]", text: "Modified"
    assert_selector "table.files a.is-selected", text: "plate.stl"

    # ... then the view toggle's links.
    details_for("table.files a", "bracket.stl")
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
    details_for(".grid-card", "bracket.stl")
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
