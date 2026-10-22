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

# A PROMOTED FRAME VISIT NEEDS THE PAGE'S OWN <head>. Before Turbo records an advanced pane as
# rendered it compares the response's tracked head elements with the page's (PageRenderer
# #shouldRender); a pane answered with no head — no layout, or turbo-rails' own turbo_rails/frame,
# which carries only the CSRF tags — fails that check, so Turbo never moves lastRenderedLocation
# off the first URL and sets view.forceReloaded for the rest of the tab. Every later snapshot is
# then filed under the wrong URL (Back shows the wrong pane) and every later visit stops scrolling.
# The first Back below is the snapshot cache's; the second is the one the stale location broke.
test "a pane switch keeps Turbo's history true: Back through the file page returns pane by pane" do
  visit model_path(@model)
  open_in_pane "notes.txt"
  assert_equal false, page.evaluate_script("Turbo.session.view.forceReloaded"),
               "Turbo refused the pane's head and stopped handling scroll for this tab"
  open_in_pane "bracket.stl"
  find(".model-stage-head a", text: "Open file page").click
  assert_current_path file_path(stl.node_id)

  page.go_back
  assert_selector "turbo-frame#model_stage .model-stage-name", text: "bracket.stl"
  assert_includes page.current_url, "file=#{stl.node_id}"
  page.go_back
  assert_selector "turbo-frame#model_stage .model-stage-name", text: "notes.txt"
  assert_includes page.current_url, "file=#{notes.node_id}"
  assert_no_console_errors
end

# A PANE SWITCH IS TWO STEPS IN TURBO: the frame paints its contents, then a few ticks later the
# promoted visit records the URL as rendered (FrameController#loadResponse → fetchResponseLoaded →
# session.visit). The next click is made only once the second has happened — a person cannot click
# inside those few milliseconds, a test can, and a visit started inside them cancels the recording
# and files the next snapshot under the previous URL. That race is the TEST's, not the page's.
def open_in_pane(name)
  within(".model-index") { click_link name }
  assert_selector "turbo-frame#model_stage .model-stage-name", text: name
  rendered = "Turbo.session.view.lastRenderedLocation.href"
  deadline = Time.now + 3
  sleep 0.05 until page.evaluate_script(rendered) == page.current_url || Time.now > deadline
  assert_equal page.current_url, page.evaluate_script(rendered), "Turbo never recorded #{name}'s pane as rendered"
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
    # …AND NOT UNDER THE STICKY TOP BAR, which wraps to two rows on a phone: scrolled to the viewport's
    # very top, the pane's own head (its name, Download, "Open file page") sits behind the bar. Asked
    # of Details, the one pane here tall enough for the page to scroll it all the way up — notes.txt's
    # is not, the page bottoms out first, so the bar check above it could not fail.
    within(".model-index") { click_link "Details" }
    assert_selector "turbo-frame#model_stage .model-details"
    settled = nil
    deadline = Time.now + 3
    loop do
      sleep 0.15
      top = page.evaluate_script(pane_top)
      break if top == settled || Time.now > deadline
      settled = top
    end
    bar_bottom = page.evaluate_script("document.querySelector('header.topbar').getBoundingClientRect().bottom")
    assert_operator settled, :>=, bar_bottom - 1, "the pane's head is under the top bar (#{settled}px < #{bar_bottom}px)"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
