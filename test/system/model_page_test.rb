require "application_system_test_case"

# THE MODEL PAGE IN A BROWSER (2026-10-21): the list swaps the pane without reloading the page, the
# URL and the list's mark follow, Back walks the panes, a double-click opens the file page in a new
# tab, and at phone width the pane is scrolled into view. No instructions PDF in this fixture on
# purpose: headless Chrome's PDF handling is not what is under test, and the request suite pins the
# PDF default (model_stage_test.rb).
class ModelPageTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    dir = @root.join("Models/bracket")
    dir.mkpath
    dir.join("bracket.stl").write("solid bracket\nendsolid bracket\n")
    dir.join("notes.txt").write("print it flat\n")
    # TEN MORE PARTS so the list is taller than a phone screen: the phone test needs the pane to start
    # below the fold, or scrolling it into view is a no-op it cannot tell from a missing scroll.
    (1..10).each { |i| dir.join(format("part-%02d.stl", i)).write("solid p\nendsolid p\n") }
    @user = sign_in_as("model-page@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @model = @user.maker_models.create!(title: "Wall Bracket", folder_node_id: node("Models/bracket").node_id)
    @user.nodes.where(parent_node_id: @model.folder_node_id, kind: "file").order(:name).each_with_index do |n, i|
      @model.file_attachments.create!(user: @user, node_id: n.node_id, role: Maker::FileAttachment.role_for(n.name),
                                      position: i)
    end
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def node(path) = @user.nodes.find_by!(storage_path: path)
  def stl = node("Models/bracket/bracket.stl")
  def notes = node("Models/bracket/notes.txt")

  test "a file in the list opens in the pane, the URL and the mark follow, and Back walks back" do
    visit model_path(@model)
    assert_selector "turbo-frame#model_stage .model-details"
    # THE LIST IS NOT RE-RENDERED: a marker on it survives the click, which a full page visit would drop.
    page.execute_script("document.querySelector('.model-index').dataset.marker = 'kept'")

    within(".model-index") { click_link "notes.txt" }
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    assert_includes page.current_url, "file=#{notes.node_id}"
    assert_selector ".model-index a[aria-current='true']", count: 1, text: "notes.txt"
    assert_equal "kept", page.evaluate_script("document.querySelector('.model-index').dataset.marker")

    within(".model-index") { click_link "bracket.stl" }
    assert_selector "turbo-frame#model_stage .model-viewer"
    assert_selector ".model-index a[aria-current='true']", count: 1, text: "bracket.stl"

    page.go_back
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    assert_includes page.current_url, "file=#{notes.node_id}"

    within(".model-index") { click_link "Details" }
    assert_selector "turbo-frame#model_stage .model-details"
    assert_selector ".model-index a.model-index-details[aria-current='true']"
    assert_no_console_errors
  end

  test "a double-click on a list entry opens its file page in a new tab" do
    visit model_path(@model)
    tab = window_opened_by { find(".model-index a", text: "bracket.stl").double_click }
    within_window(tab) { assert_current_path file_path(stl.node_id) }
    sleep 0.5 # outlasts fileopen's window: an uncancelled single click would have swapped the pane
    assert_selector "turbo-frame#model_stage .model-details"
    tab.close
    assert_no_console_errors
  end

  test "at phone width the list stacks, a click scrolls the pane into view, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 500,
                                    deviceScaleFactor: 1, mobile: false)
    visit model_path(@model)
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
           "the model page scrolls sideways"
    # MEASURED AGAINST ITSELF, NOT A LITERAL: whichever element scrolls (the document or the shell),
    # a pane scrolled into view sits higher on screen than it did before the click, and one that was
    # not has not moved — a frame swap replaces the pane's contents, never its position.
    pane_top = "document.querySelector('#model_stage').getBoundingClientRect().top"
    before = page.evaluate_script(pane_top)
    within(".model-index") { click_link "notes.txt" }
    assert_selector "turbo-frame#model_stage [data-controller='codeview']"
    # POLLED, NOT READ ONCE: Turbo's FrameRenderer puts the pane's contents in the DOM and then awaits
    # a repaint before it dispatches turbo:frame-load, which is what scrolls (modelstage_controller.js),
    # so the codeview above can be on screen a frame before the scroll is. A single read here raced
    # it and saw 667px → 667px; polled, the pane settles at the page's furthest scroll and stays there.
    after = before
    deadline = Time.now + 3
    sleep 0.05 until (after = page.evaluate_script(pane_top)) < before - 40 || Time.now > deadline
    assert_operator after, :<, before - 40, "the pane was not scrolled into view (#{before}px → #{after}px)"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
