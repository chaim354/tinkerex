require "application_system_test_case"

# TABS, DRIVEN (2026-09-09; spec §8). The server tests prove the markup; only a browser proves that
# Add tab mints a separator from the template, that a panel dragged under it lands in its group, that
# one pane shows at a time, that a deep link opens the right pane, and that a pane opened by click is
# packed.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!), for the reason page_blocks_test's header gives:
# the editor and the page read `nodes` and fetch no bytes, so this fixture runs on all three backend
# legs. Nothing here puts a picture on a page, so `assert_no_console_errors` costs nothing.
class PageTabsTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("page-tabs@example.com")
    @project = @user.maker_projects.create!(name: "Lamp", description: "A lamp.")
    @folder = project_folder_rows!(@user, @project)
    @project.tasks.create!(user: @user, title: "Print the shade")
  end

  def slot(k) = "div.panel-slot[data-key='#{k}']"
  def tab_slot = "div.panel-slot--tab[data-key^='tab:new-']"
  def tk(hex) = Maker::ProjectKind.tab_key(hex)
  def slot_keys = all("div.panel-slot").map { |s| s["data-key"] }

  def open_editor
    visit edit_layout_project_path(@project)
    assert_selector ".layout-bar", text: "Editing page layout"
  end

  # The viewport centre of the first match, as a pair of floats. `getBoundingClientRect` rather than
  # Capybara's `#rect`, which reports DOCUMENT coordinates (Selenium adds the scroll offsets) while
  # a pointer moves in viewport ones.
  def centre(selector)
    page.evaluate_script("(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2] })()")
  end

  # SLICE 1'S POINTER SEQUENCE WITH THE ELEMENT ORIGINS TAKEN OUT, AND THE REMOVAL IS THE POINT.
  # Sortable runs `forceFallback: true`, so `drag_to`'s HTML5 events move nothing and a drag has to
  # be real pointer events; the `move_by(0, 40)` is what passes `fallbackTolerance`. What differs
  # from page_blocks_test's helper is that the target is reached by a MEASURED PIXEL DELTA rather
  # than by `move_to(target.native)`.
  #
  # MEASURED, because the element-origin version dropped every drop silently: chromedriver resolves
  # an element origin by scrolling that element into view FIRST, and that scroll moves every other
  # rect underneath the drag. `window.scrollY` went 934 -> 754 between the two performs, so the
  # pointer came to rest 183px ABOVE the separator — over the dragged slot itself — and Sortable
  # rightly did nothing, three runs out of three, with nothing raised anywhere. Both centres are read
  # AFTER the drag has begun (so any scroll `click_and_hold` caused is already in them) and the
  # pointer then moves by pixels alone, which cannot scroll. The second, tiny `move_by` gives
  # Sortable one more `_onTouchMove` at the destination before the release.
  def drag(handle_selector, target_selector)
    browser = page.driver.browser
    browser.action.click_and_hold(find(handle_selector).native).move_by(0, 40).perform
    hx, hy = centre(handle_selector)
    tx, ty = centre(target_selector)
    browser.action.move_by((tx - hx).round, (ty - hy - 40).round).move_by(0, 2).release.perform
  end

  test "Add tab lands an empty tab above Publish; a panel dragged under it is in its group after Save" do
    # TASKS IS PUT LAST SO THE DRAG IS ONE STEP. Add tab lands the separator immediately above the
    # pinned Publish, so with Tasks second-to-last the two are adjacent in the order and on screen
    # together, and "Tasks ended up after the separator" is a claim about one move rather than about
    # how far a ghost travelled.
    order = @project.panel_layout.order - %w[tasks publish]
    @project.update!(panels: { "order" => order + %w[tasks publish] })

    open_editor
    click_on "Add tab"
    assert_selector tab_slot
    keys = slot_keys
    assert_equal "publish", keys.last
    assert_equal "tab:new-1", keys[-2], "the new tab sits just above Publish: #{keys.inspect}"
    within(tab_slot) do
      assert_selector ".tab-slot-count", text: "empty"
      # THE PLACEHOLDER, NOT THE `aria-label`: `Capybara.enable_aria_label` defaults to false and
      # this repo deliberately does not set it (o3dv_test and measure_print_test both record why),
      # so "Tab name" locates nothing however correct the attribute is.
      fill_in "Name this tab", with: "Build"
    end

    # Tasks is dragged onto the separator. The separator sits immediately after it in the order, so
    # SortableJS's own rule ("the dragged element is before the target, therefore insert after it")
    # puts Tasks inside the tab.
    drag("#{slot('tasks')} .panel-strip-handle", tab_slot)
    keys = slot_keys
    assert_operator keys.index("tasks"), :>, keys.index("tab:new-1"), keys.inspect
    within(tab_slot) { assert_selector ".tab-slot-count", text: "1 panel" }

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_selector "nav.tab-bar a.tab-link", text: "Build"
    assert_selector "section.tab-pane#tab-build section.tasks-panel"
    # ONE Tasks panel on the page, and it is inside the pane — the honest form of "it left the top
    # grid". A bare `div.project-panels > div.panel-slot > section.tasks-panel` would match the
    # pane's OWN grid, which is a `.project-panels` too, and so could never fail.
    assert_selector "section.tasks-panel", count: 1
    panels = @project.reload.panels
    tab = panels["order"].find { |k| k.start_with?("tab:") }
    assert_match(/\Atab:[0-9a-f]{12}\z/, tab)
    assert_equal "Build", panels["titles"][tab]
    assert_operator panels["order"].index("tasks"), :>, panels["order"].index(tab)
    assert_no_console_errors
  end

  test "one pane at a time: clicking a tab shows its pane, packs it, and writes the hash; deep links open the right pane" do
    a, b = tk("3f9a1b2c4d5e"), tk("a0c4d8e2f611")
    tall = @project.blocks.create!(user: @user, kind: "text", body: (1..30).map { |i| "line #{i}" }.join("\n\n"))
    short = @project.blocks.create!(user: @user, kind: "text", body: "short")
    third = @project.blocks.create!(user: @user, kind: "text", body: "third")
    # EVERY KEY IS NAMED, and that is not tidiness: a panel the stored order does not mention is
    # appended by the layout and so joins the LAST tab, which would put six more panels in the Notes
    # pane and make the span sweep below a claim about them rather than about the blocks.
    top = Maker::Project::PANELS - %w[tasks publish]
    @project.update!(panels: {
      "order" => top + [ a, "tasks", b, tall.layout_key, short.layout_key, third.layout_key, "publish" ],
      "titles" => { a => "Build", b => "Notes" },
      "widths" => { tall.layout_key => "half", short.layout_key => "half", third.layout_key => "half" } })

    visit project_path(@project)
    assert_selector "div.tabs.tabs-ready"
    assert_selector "section.tab-pane#tab-build section.tasks-panel"
    assert_no_selector "section.tab-pane#tab-notes section.block--text"
    # THE HEADINGS ARE STILL RENDERED AND MERELY HIDDEN, which is decision 8's whole mechanism: a
    # page whose script never ran shows both. `visible: :hidden` is the claim; `assert_no_selector`
    # with the default visibility is "nothing on screen".
    assert_no_selector "h2.tab-heading"
    assert_selector "h2.tab-heading", visible: :hidden, count: 2
    assert_selector "section#publish"

    history_before = page.evaluate_script("history.length")
    click_on "Notes"
    assert_selector "section.tab-pane#tab-notes section.block--text", count: 3
    assert_no_selector "section.tab-pane#tab-build section.tasks-panel"
    assert_equal "#tab-notes", page.evaluate_script("window.location.hash")
    # NO HISTORY ENTRY PER CLICK (spec §6): replaceState, not pushState — Back leaves the page rather
    # than walking through every tab that was looked at (found in review: nothing asserted it).
    assert_equal history_before, page.evaluate_script("history.length"), "a tab click must not push a history entry"
    assert_selector "section.tab-pane#tab-notes div.project-panels.masonry"
    spans = page.evaluate_script("Array.from(document.querySelectorAll('#tab-notes .panel-slot')).map((s) => s.style.gridRowEnd)")
    assert_equal 3, spans.size, "the pane's own slots: #{spans.inspect}"
    # A HIDDEN PANE MEASURES ZERO AND STILL READS `span 16` (masonry's GAP floor), so "not span 1" is
    # true before the click too (found in review). The tall block is what proves the re-pack.
    assert_operator spans.map { |s| s[/\d+/].to_i }.max, :>, 200, "the opened pane is packed after the click: #{spans.inspect}"

    # A HASH NAMING NOTHING HERE, ON AN OPEN PAGE, CHANGES NOTHING (spec §7): a stale slug or a link to
    # a hidden panel must not yank the reader back to the first tab (found in review: every deep
    # link in this suite was a full load, so the hashchange arm was never driven).
    page.execute_script("window.location.hash = '#nowhere'")
    assert_selector "section.tab-pane#tab-notes section.block--text", count: 3
    assert_no_selector "section.tab-pane#tab-build section.tasks-panel"

    # THE KEYBOARD, ONCE: Left from the second tab lands on the first, selected and shown.
    find("a.tab-link[aria-selected='true']").send_keys(:arrow_left)
    assert_selector "section.tab-pane#tab-build section.tasks-panel"
    assert_selector "a.tab-link[href='#tab-build'][aria-selected='true']"
    assert_equal "#tab-build", page.evaluate_script("window.location.hash")

    # A FULL LOAD EACH TIME, not a fragment change: `visit` to a URL differing only in its hash is a
    # same-document navigation, which exercises `hashchange` and never `connect`. The trip through
    # the index is what makes the next visit a real page load.
    visit projects_path
    visit project_path(@project, anchor: "tab-notes")
    assert_selector "section.tab-pane#tab-notes section.block--text"
    assert_no_selector "section.tab-pane#tab-build section.tasks-panel"

    # A HASH NAMING AN ELEMENT INSIDE A PANE, not the pane: a block's section carries its layout key
    # as its id, the same anchor the page head links to, and it must open the tab it now lives in.
    visit projects_path
    visit "#{project_path(@project)}##{short.layout_key}"
    assert_selector "section.tab-pane#tab-notes section.block--text"
    assert_no_selector "section.tab-pane#tab-build section.tasks-panel"
    assert_no_console_errors
  end

  test "Delete merges a tab's panels into the group above; Save with a blank tab name is refused and loses nothing" do
    a = tk("3f9a1b2c4d5e")
    @project.update!(panels: { "order" => [ "attachments", "photos", a, "tasks", "publish" ], "titles" => { a => "Build" } })
    open_editor
    # `build_log` rather than `photos`: photos is in Maker::ProjectKind::ALWAYS, so its strip offers
    # no Hide at all.
    # HIDDEN PANELS STILL COUNT IN THE TAB'S HINT: build_log is in this tab (the layout appends the
    # unnamed panels after Tasks), and hiding it must not change "n panels" (found in review).
    count = within(slot(a)) { find(".tab-slot-count").text }
    within(slot("build_log")) { click_on "Hide" }
    within(slot(a)) { assert_selector ".tab-slot-count", text: count }
    within(slot(a)) { fill_in "Name this tab", with: "" }
    click_on "Save"
    assert_selector ".flash-notice", text: "Not saved: a tab needs a name"
    assert_current_path edit_layout_project_path(@project)
    assert_no_selector ".flash-alert"
    assert_selector "#{slot('build_log')}.panel-slot--hidden"

    within(slot(a)) { click_on "Delete" }
    assert_no_selector slot(a)
    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_no_selector "div.tabs"
    assert_selector "div.project-panels > div.panel-slot > section.tasks-panel"
    panels = @project.reload.panels
    assert_empty panels["order"].grep(/\Atab:/)
    assert_includes panels["hidden"], "build_log"
  end

  # "+ ADD PANEL" INTO A TAB (slice 6): an empty BOM alone in the second tab leaves no pane and no bar
  # link for it, and the menu's link lands on `#project-bom` — a panel's own anchor, which
  # tabs_controller.js resolves to the pane it sits in. Without that, the link would open the first
  # tab and the panel the maker just asked for would be on the page but out of sight.
  test "+ Add panel opens an empty panel in its tab, and the tab is shown" do
    a, b = tk("3f9a1b2c4d5e"), tk("a0c4d8e2f611")
    top = Maker::Project::PANELS - %w[tasks bom publish]
    @project.update!(panels: { "order" => top + [ a, "tasks", b, "bom", "publish" ],
                               "titles" => { a => "Build", b => "Parts" } })

    visit project_path(@project)
    assert_selector "a.tab-link", count: 1
    assert_no_selector "a.tab-link", text: "Parts"
    find("details.add-panel > summary", text: "+ Add panel").click
    click_link "Bill of materials"

    assert_selector "a.tab-link[href='#tab-parts'][aria-selected='true']", text: "Parts"
    assert_selector "section.tab-pane#tab-parts section.bom-panel.panel--quiet#project-bom", visible: true
    assert_no_selector "section.tab-pane#tab-build section.tasks-panel"
    assert_no_console_errors
  end

  test "Apply mints a separator slot for a tab the pasted text creates" do
    open_editor
    click_on "Edit as YAML"
    # A textarea's VALUE is not its text node, so no Capybara matcher can wait on the server's
    # answer arriving; poll it (slice 1's suite records the same).
    wait_until(message: "the drawer never filled") { find("textarea.layout-yaml").value.include?("layout: 1") }
    find("textarea.layout-yaml").set("layout: 1\npanels:\n  - panel: attachments\n  - tab: Pasted\n  - panel: tasks\n")
    click_on "Apply"

    assert_no_selector ".layout-note--error"
    assert_selector tab_slot
    within(tab_slot) { assert_field "Name this tab", with: "Pasted" }
    keys = slot_keys
    minted = keys.find { |k| k.start_with?("tab:new-") }
    assert_operator keys.index("tasks"), :>, keys.index(minted), keys.inspect
  end
end
