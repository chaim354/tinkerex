require "application_system_test_case"

# THE RAIL AT A LAPTOP'S WIDTH (UX audit A2). Below 1100px the rail is icons by default, and it was
# icons whatever the maker did: the Collapse button flipped a cookie the viewport's media query then
# ignored, its arrow pointed left in both states, and the eight projects and every pinned folder had
# no icon, so they simply vanished. Now the `rail` cookie's `expanded` is an explicit choice that beats
# the width default, the button reads the rail AS DRAWN and offers the other state, its arrow turns
# with it, and projects and pins stay as monogram tiles in the icon rail.
#
# COMPUTED STYLE AND BOXES, at a CDP viewport (shell_test.rb records why not resize_to), because only a
# browser resolves the container query the icon rail is.
#
# MUTATION-CHECKED (2026-11-02; each reverted, and the file re-run green after):
#   1. The ≤1099px track rule back to a bare `body.app-shell` (no `:where(:not(.rail--expanded))`):
#      the first test red, the expanded rail still 56px wide at 1024px.
#   2. rail_controller.js#toggle writing the cookie's opposite instead of the drawn rail's
#      (`body.classList.contains("rail--collapsed") ? "expanded" : "collapsed"`): the first test red,
#      the click at 1024px collapsing an icon rail into the same icon rail.
#   3. Deleting `.rail-monogram { display: inline-flex; }` from the icon-rail block: the monogram test
#      red, no tile drawn.
#   4. Deleting `.rail-collapse .rail-icon { transform: scaleX(-1); }`: the first test red on the arrow.
#   5. Dropping `body.app-shell.rail--collapsed` from the ≤719px one-column rule: the phone test red,
#      the page laid out in the rail's 56px track.
class ShellRailTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("shell-rail@example.com")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "at 1024px the button expands the icon rail, says so, and the choice survives a page" do
    @user.maker_projects.create!(name: "Desk Lamp")
    viewport!(1024, 768)
    visit files_path
    assert_equal icon_rail("Expand"), rail_state, "the default rail at 1024px"

    find("aside.rail .rail-collapse").click
    assert_selector "body.rail--expanded"
    assert_equal full_rail("Collapse"), rail_state, "the expanded rail at 1024px"
    assert_equal "expanded", page.driver.browser.manage.cookie_named("rail")[:value]

    # A NEW PAGE RENDERS IT: the server reads the cookie (ShellHelper#rail_expanded?).
    visit projects_path
    assert_selector "body.rail--expanded"
    assert_equal full_rail("Collapse"), rail_state, "the expanded rail after a navigation"

    find("aside.rail .rail-collapse").click
    assert_selector "body.rail--collapsed"
    assert_no_selector "body.rail--expanded"
    assert_equal icon_rail("Expand"), rail_state, "the collapsed rail at 1024px"
    assert_equal "collapsed", page.driver.browser.manage.cookie_named("rail")[:value]
    assert_no_console_errors
  end

  # PROJECTS AND PINNED FOLDERS STAY IN THE ICON RAIL, AS A TILE WITH THE FIRST LETTER OF THE NAME, and
  # the link's title still carries the whole name, which is its accessible name there. A pinned
  # folder's glyph gives way to its letter: every pin wears the same glyph.
  test "the icon rail shows projects and pinned folders as monogram tiles" do
    @root.join("laser").mkpath
    Library::ScanJob.perform_now(user_id: @user.id)
    laser = @user.nodes.present.find_by!(name: "laser", kind: "dir")
    @user.maker_pins.create!(node_id: laser.node_id)
    @user.maker_projects.create!(name: "desk lamp")
    @user.maker_projects.create!(name: "3D printer enclosure")
    viewport!(1024, 768)
    visit files_path(folder: laser.node_id)
    tiles = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll("aside.rail a.rail-project, aside.rail a.rail-pin")).map((a) => {
        const tile = a.querySelector(".rail-monogram"), box = tile.getBoundingClientRect();
        const glyph = a.querySelector(".folder-glyph");
        return { title: a.title, letter: getComputedStyle(tile, "::before").content,
                 drawn: box.width > 0 && box.height > 0, glyph: glyph ? getComputedStyle(glyph).display : null,
                 hidden: a.getAttribute("aria-hidden"), lit: a.getAttribute("aria-current") };
      })
    JS
    assert_equal [ { "title" => "3D printer enclosure", "letter" => '"3"', "drawn" => true, "glyph" => nil, "hidden" => nil, "lit" => nil },
                   { "title" => "desk lamp", "letter" => '"D"', "drawn" => true, "glyph" => nil, "hidden" => nil, "lit" => nil },
                   { "title" => "laser", "letter" => '"L"', "drawn" => true, "glyph" => "none", "hidden" => nil, "lit" => "page" } ],
                 tiles.sort_by { |t| t["title"] }
    # The full rail draws no tile: the name is there.
    find("aside.rail .rail-collapse").click
    assert_selector "body.rail--expanded"
    assert_equal [ "none" ], page.evaluate_script(<<~JS).uniq
      Array.from(document.querySelectorAll("aside.rail .rail-monogram")).map((t) => getComputedStyle(t).display)
    JS
  end

  # BELOW 720px THERE IS NO RAIL, SO NO TRACK MAY BE KEPT FOR ONE. With the collapse cookie set,
  # `body.app-shell.rail--collapsed` outranked the phone block's one-column `body.app-shell`, and the
  # whole page was laid out in the rail's 56px column.
  test "on a phone the page takes the whole width whatever the rail cookie says" do
    %w[collapsed expanded].each do |state|
      visit root_path
      page.driver.browser.manage.add_cookie(name: "rail", value: state, path: "/")
      viewport!(375, 812)
      visit files_path
      main, client = page.evaluate_script(
        "[document.querySelector('.shell-main').getBoundingClientRect().width, document.documentElement.clientWidth]")
      assert_in_delta client, main, 1, "with rail=#{state} the page is #{main}px of #{client}px at 375px"
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  private

    def viewport!(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width:, height:, deviceScaleFactor: 1, mobile: false)
    end

    # What a maker sees of the rail and its button: the rail's width, whether a label shows, and the
    # button's words, state and arrow.
    def rail_state
      page.evaluate_script(<<~JS)
        (() => {
          const rail = document.querySelector("aside.rail"), btn = rail.querySelector(".rail-collapse");
          return { width: Math.round(rail.getBoundingClientRect().width),
                   labels: getComputedStyle(rail.querySelector(".rail-label")).display !== "none",
                   expanded: btn.getAttribute("aria-expanded"), name: btn.getAttribute("aria-label"),
                   title: btn.getAttribute("title"),
                   arrow: getComputedStyle(btn.querySelector(".rail-icon")).transform };
        })()
      JS
    end

    def icon_rail(verb)
      { "width" => 56, "labels" => false, "expanded" => "false", "name" => "#{verb} navigation",
        "title" => "#{verb} navigation", "arrow" => "matrix(-1, 0, 0, 1, 0, 0)" }
    end

    def full_rail(verb)
      { "width" => 216, "labels" => true, "expanded" => "true", "name" => "#{verb} navigation",
        "title" => "#{verb} navigation", "arrow" => "none" }
    end
end
