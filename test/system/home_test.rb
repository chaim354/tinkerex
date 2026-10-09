require "application_system_test_case"

# The Home page (stage 2, S2-1), the things only a browser can see: the Files row's CSS
# containment (`overflow-x: auto`) is a rendered-layout question no request test can ask at all.
# (The current-project hero's two browser tests — its rail select and its upload round trip — went
# with the current project in slice 4 of the 2026-10-08 redesign.) Content and bounded-list
# correctness (empty states, archived-project handling) are already covered at the request level in
# test/integration/web/home_test.rb and are deliberately NOT repeated here (README: "Does not
# qualify -- keep these at the request level").
class HomeTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("home@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # MUTATION-CHECKED (see test/system/README.md): removing `overflow-x: auto` from `.tile-row` in
  # app/assets/stylesheets/pages/home.css. The DESKTOP-width assertion below stays green under this
  # mutation, correctly -- it measures the row's raw content width, which `overflow-x` never
  # changes -- and it is the 375px assertion that turns red:
  #   home scrolls sideways at 375px (scrollWidth 1312)
  # Reverted immediately after; also caught by shell_test.rb's phone sweep (see its own comment).
  test "the Files row scrolls inside itself, not the page" do
    9.times do |i|
      create_node!(@user, node_id: SecureRandom.uuid, kind: "file", name: "scroll-file-#{i}.stl")
    end

    visit root_path
    assert_selector ".home-files .grid-card", count: HomeController::RECENT_FILES

    # AT THE DEFAULT (DESKTOP) WINDOW: prove the row's OWN content is wider than its OWN box first
    # -- otherwise the 375px assertion below could pass for the wrong reason, since a row that
    # never overflows is contained either way. Nine nodes exist so the RECENT_FILES cap (8) is
    # reached with a spare rather than by an exact count that a future off-by-one in the query
    # would silently undercut; only 8 tiles ever render either way. MEASURED on this box
    # (screen_size [1400, 1400], window.innerWidth 1400): 8 tiles at 150px with a 14px gap is
    # 1298px of content against a `.home-files .tile-row` clientWidth of 1164px (the 1212px column
    # `main.container` leaves after the 188px rail, minus its own 24px+24px padding), and the
    # observed scrollWidth was 1302 (the row's own 2px+2px padding accounts for the last 4px).
    # 1302 > 1164 confirms the overflow is real, not assumed.
    client_width, scroll_width = page.evaluate_script(<<~JS)
      (function () {
        var row = document.querySelector('.home-files .tile-row')
        return [row.clientWidth, row.scrollWidth]
      })()
    JS
    assert scroll_width > client_width,
           "the tile row does not overflow its own box at the default window width " \
           "(clientWidth #{client_width}, scrollWidth #{scroll_width}) -- the scroll-containment " \
           "assertion below would pass without measuring anything"

    # AT PHONE WIDTH: the PAGE must not scroll sideways even though the ROW's content does not fit
    # -- containment, not absence of overflow. Same CDP mechanism as shell_test.rb's phone sweep,
    # for the same reason: WebDriver's window-resize API refuses to go below 500px (measured
    # there), and Emulation.setDeviceMetricsOverride honours 375. Cleared in the ensure because
    # Selenium reuses one Chrome for the whole file. MEASURED: window.innerWidth 375,
    # documentElement.scrollWidth 360 -- the row's own overflow above never reaches the page.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit root_path
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
             "home scrolls sideways at 375px (scrollWidth " \
             "#{page.evaluate_script('document.documentElement.scrollWidth')})"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    assert_no_console_errors
  end
end
