require "application_system_test_case"

# Recent, the app's front door (structural redesign §7, slice 6; the Home page until then), the things
# only a browser can see: that the recently-changed grid WRAPS — a rendered-layout question no request
# test can ask at all. Content and bounded-list correctness (the one empty state, archived-project
# handling, the tiles' links) are covered at the request level in test/integration/web/home_test.rb and
# are deliberately NOT repeated here (README: "Does not qualify -- keep these at the request level").
class HomeTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("home@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # THE GRID WRAPS, AND THE PAGE NEVER SCROLLS SIDEWAYS. Until slice 6 this page was a row of tiles
  # that scrolled inside its own box; sixteen tiles are a page of their own, so they wrap instead.
  #
  # Seventeen files so the RECENT_FILES cap (16) is reached with one to spare. The wrap is measured
  # as GEOMETRY — a tile whose top sits below the first tile's — because a grid that stopped wrapping
  # (`display: flex` with no wrap, or `grid-auto-flow: column`) puts every tile on one line, wider
  # than the panel, which is the old row without its scroller.
  #
  # THE 375px HALF MEASURES AGAINST `document.documentElement.clientWidth`, NOT `innerWidth`: CI's
  # Linux Chrome draws a 15px classic scrollbar, so `innerWidth` (375) counts a strip the page cannot
  # lay content in, and a page 10px too wide would still read as fitting.
  #
  # MUTATION-CHECKED (see test/system/README.md), three in app/assets/stylesheets/pages/home.css, each
  # run and restored:
  #   1. `.recent-grid` as `display: flex` (one line, no wrap): the tiles shrink rather than overflow,
  #      so only the geometry catches it —
  #        the recently changed tiles sit on one line (first top 173, last top 173) — the grid does not wrap
  #   2. `minmax(340px, 1fr)` tracks, wider than a phone's panel:
  #        Recent scrolls sideways at 375px (scrollWidth 369, clientWidth 360)
  #      — 369 is UNDER `innerWidth` (375), so the old `<= innerWidth` comparison passed it.
  #   3. A bare `minmax(160px, 1fr)` (the `min()` dropped):
  #        Recent's grid is one column at 375px (first tile top 223, second 565)
  test "the recently changed grid wraps, and the page never scrolls sideways" do
    17.times do |i|
      create_node!(@user, node_id: SecureRandom.uuid, kind: "file", name: "grid-file-#{i}.stl")
    end

    visit root_path
    assert_selector ".home-files .recent-grid .grid-card", count: HomeController::RECENT_FILES

    first_top, last_top, grid_width, grid_scroll = page.evaluate_script(<<~JS)
      (function () {
        var grid = document.querySelector('.home-files .recent-grid')
        var tiles = grid.querySelectorAll('.grid-card')
        return [tiles[0].getBoundingClientRect().top, tiles[tiles.length - 1].getBoundingClientRect().top,
                grid.clientWidth, grid.scrollWidth]
      })()
    JS
    assert_operator last_top, :>, first_top,
                    "the recently changed tiles sit on one line (first top #{first_top}, last top #{last_top}) — the grid does not wrap"
    assert_operator grid_scroll, :<=, grid_width,
                    "the recently changed grid is wider than its own box (clientWidth #{grid_width}, scrollWidth #{grid_scroll})"

    # AT PHONE WIDTH, through CDP for the reason shell_test.rb's phone sweep gives: WebDriver's
    # window-resize API refuses to go below 500px, and Emulation.setDeviceMetricsOverride honours 375.
    # Cleared in the ensure because Selenium reuses one Chrome for the whole file.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      visit root_path
      assert_selector ".home-files .recent-grid .grid-card", count: HomeController::RECENT_FILES
      scroll_width, client_width, first_top, second_top = page.evaluate_script(<<~JS)
        (function () {
          var tiles = document.querySelectorAll('.home-files .recent-grid .grid-card')
          return [document.documentElement.scrollWidth, document.documentElement.clientWidth,
                  tiles[0].getBoundingClientRect().top, tiles[1].getBoundingClientRect().top]
        })()
      JS
      assert_operator scroll_width, :<=, client_width,
                      "Recent scrolls sideways at 375px (scrollWidth #{scroll_width}, clientWidth #{client_width})"
      # NEVER FEWER THAN TWO A ROW (pages/home.css): a bare `minmax(160px, 1fr)` fits one 302px column
      # here, and sixteen of those stack 5,400px deep.
      assert_equal first_top, second_top,
                   "Recent's grid is one column at 375px (first tile top #{first_top}, second #{second_top})"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    assert_no_console_errors
  end
end
