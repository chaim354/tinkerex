require "application_system_test_case"

# The Home page (stage 2, S2-1), the things only a browser can see: the rail's current-project
# <select> auto-submits through a bare `onchange="this.form.requestSubmit()"` rather than a submit
# button (test/system/README.md's "Form-control semantics" and "Rendered-HTML -> JS contracts"
# bullets -- an integration test can PATCH current_project directly and never prove the markup's
# onchange attribute is what a real click-and-choose does), the hero's own upload control drives
# the identical real multipart round trip a file-input change event triggers, and the Files row's
# CSS containment (`overflow-x: auto`) is a rendered-layout question no request test can ask at
# all. Content and bounded-list correctness (empty states, stats, archived-project handling) are
# already covered at the request level in test/integration/web/home_test.rb and are deliberately
# NOT repeated here (README: "Does not qualify -- keep these at the request level").
class HomeTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("home@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
    FileUtils.remove_entry(@attach_dir) if @attach_dir
  end

  test "sign-in lands on Home and the hero follows the current project" do
    # sign_in_as already asserted the post-login path is "/" (root_path). No project exists yet.
    assert_selector ".home-hero", text: /No current project/

    project = @user.maker_projects.create!(name: "Desk Lamp")
    # Created through ActiveRecord, not the browser -- the already-rendered rail's <select> has no
    # way to learn about it without a reload.
    visit root_path
    select project.name, from: "project_id"

    # THE SELECT HAS NO SUBMIT BUTTON -- app/views/layouts/_rail.html.erb's `onchange:
    # "this.form.requestSubmit()"` is what turns a Capybara `select` into a real `PATCH
    # current_project`, and `data: { turbo: false }` is what makes that a full page reload rather
    # than a Turbo visit. Capybara's `select` dispatches a real change event (already relied on by
    # box_revisions_test.rb's and addon_bundle_test.rb's own use of this exact rail form), so what
    # this proves is the JS contract, not the server-side PATCH -- an integration test can drive
    # the PATCH directly without ever touching the onchange attribute at all.
    assert_selector ".home-hero h2", text: project.name
    assert_no_console_errors
  end

  # MUTATION-CHECKED (see test/system/README.md): changing `redirect_url: root_path` to
  # `redirect_url: project_path(@project)` in app/views/home/_project_hero.html.erb turns
  # `assert_current_path root_path` red:
  #   expected "/projects/desk-lamp" to equal "/"
  # Reverted immediately after.
  test "an upload from the hero returns to Home with the file in the row and the count in the stats" do
    project = @user.maker_projects.create!(name: "Desk Lamp")
    visit root_path
    select project.name, from: "project_id"
    assert_selector ".home-hero h2", text: project.name

    file = Rails.root.join("test/fixtures/files/sample.txt")
    # Copied to a Dir.mktmpdir, not attached from its own path under ~/Desktop -- macOS TCC gates
    # that behind per-app consent a synthetic Selenium attach never satisfies (test/system/README.md;
    # uploader_test.rb hits the identical trap on this same checkout and explains it at length).
    @attach_dir = Dir.mktmpdir("home_test")
    attach_path = File.join(@attach_dir, file.basename.to_s)
    FileUtils.cp(file, attach_path)

    # No locator needed: the share backend (set in setup) makes capabilities.port_writable? true,
    # so the hero renders projects/_upload_control.html.erb's plain-multipart-form branch -- ONE
    # `input[type=file]`, and it is the only file input anywhere on Home. make_visible: true, not a
    # CSS-selector String (the latter silently sets nothing -- test/system/README.md).
    attach_file(attach_path, make_visible: true)

    # The form has no submit button either -- `f.file_field :file, onchange:
    # "this.form.requestSubmit()", hidden: true` is what a real file choice submits, and
    # `data: { turbo: false }` makes this a full page load rather than a Turbo visit.
    #
    # Back on "/": the hero passes `redirect_url: root_path`, so an upload from Home returns to the
    # same URL the rail links. Home has ONE route on purpose -- a `/home` alias existed for a few
    # commits while the page and its landing were built side by side, and left with them.
    assert_current_path root_path
    assert_selector ".home-hero .project-stats", text: /1 file/
    assert_selector ".home-files .grid-card .grid-name", text: "sample.txt"
    assert_no_console_errors
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
