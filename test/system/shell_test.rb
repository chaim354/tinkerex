require "application_system_test_case"

# The shell's behaviour only a browser can see (spec §12): the rail's collapse surviving a Turbo
# navigation and a reload, the theme button cycling and persisting, a notice toast leaving on its
# own while an alert waits to be dismissed, Cmd/Ctrl-K reaching the search field, and — the guard
# for the bug that started this rework — no page scrolling sideways at phone width.
class ShellTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("shell@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "collapsing the rail survives a navigation and a reload" do
    visit files_path
    assert_selector "aside.rail"
    assert_no_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_selector "body.rail--collapsed"

    find("aside.rail a.rail-link[title='Projects']").click
    assert_current_path projects_path
    assert_selector "body.rail--collapsed"

    visit projects_path
    assert_selector "body.rail--collapsed"

    find("aside.rail [data-action='rail#toggle']").click
    assert_no_selector "body.rail--collapsed"
    assert_no_console_errors
  end

  test "the theme button cycles dark, light, system and persists" do
    visit files_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "dark", theme.call

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "light", theme.call
    visit files_path
    assert_equal "light", theme.call
    assert_selector "aside.rail [data-action='theme#cycle']", text: "Theme: light"

    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "system", theme.call
    find("aside.rail [data-action='theme#cycle']").click
    assert_equal "dark", theme.call
    visit files_path
    assert_equal "dark", theme.call
    assert_no_console_errors
  end

  test "a notice toast leaves on its own and an alert waits to be dismissed" do
    # sign_in_as landed on /files carrying Devise's "Signed in successfully." notice.
    assert_selector ".flash-stack .flash-notice", text: "Signed in successfully."
    assert_no_selector ".flash-stack .flash-notice", wait: 9

    # THE `assert_current_path` IS NOT DECORATION, for the reason `sign_in_as` gives about the
    # other direction: `.click` returns before the sign-out round trip lands, so the `visit` below
    # can race it, arrive still authenticated, render /files with no alert at all, and fail on the
    # next line looking like a broken toast. Seen for real — this file went green, then red on the
    # same code with a different seed. Waiting for the sign-in page makes the sign-out a fact.
    find("aside.rail button", text: "Sign out").click
    assert_current_path new_user_session_path
    visit files_path
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    sleep 7
    assert_selector ".flash-stack .flash-alert", text: /sign in/i
    find(".flash-stack .flash-alert .flash-close").click
    assert_no_selector ".flash-stack .flash-alert"
  end

  test "command-K focuses the library search" do
    visit projects_path
    find("body").send_keys([ :control, "k" ])
    assert_equal "q", page.evaluate_script("document.activeElement.name")
    assert_no_console_errors
  end

  # MUTATION-CHECKED (§15), AND THE MUTATION THAT WORKS IS NOT THE ONE YOU WOULD REACH FOR.
  # Dropping `pages/files.css`'s column-drop media queries — BOTH of them, so the list keeps Name,
  # Type, Folder, Size and Modified at 375px — leaves this GREEN: the table's min-content is about
  # 181px, well inside the 351px the phone container offers, because `.file-name` carries
  # `overflow-wrap: anywhere` and `.row-actions` wraps. Lengthening the name does not change that
  # either (tried at 235 characters: scrollWidth stayed 375). Those rules buy READABILITY at
  # 480-719px, not overflow safety, and this guard is honest about not covering them.
  # What DOES redden it is the regression it exists for — the shell failing to collapse: making
  # `@media (max-width: 719px)`'s `body.app-shell` keep `var(--rail-width)` and deleting
  # `.rail { display: none }` gives "/files?view=list scrolls sideways at 375px (scrollWidth 393)".
  test "no page scrolls sideways at phone width" do
    project = @user.maker_projects.create!(name: "Desk Lamp", description: "A lamp." * 20)
    long = create_node!(@user, node_id: SecureRandom.uuid, kind: "file",
                        name: "a-very-long-file-name-that-would-push-the-table-out-of-the-viewport-v3-final.stl")
    # THE VIEWPORT IS SET THROUGH CDP, NOT `manage.window.resize_to`, AND THE DIFFERENCE IS THE
    # WHOLE GUARD. Headless Chrome refuses to make a window narrower than 500px: asking for
    # 375x812 through the WebDriver window API and then measuring gave `innerWidth=500` on every
    # page (measured 2026-09-03) — so the guard read green while testing a width no phone has, and
    # `pages/files.css`'s `@media (max-width: 479px)` column drops never ran once. A guard that
    # cannot reach the width it names is the "green suite over something that never worked" shape
    # §15 is about. `Emulation.setDeviceMetricsOverride` sets the LAYOUT viewport and honours 375,
    # and `execute_cdp` is already this suite's house tool (the browser-cache clear in
    # application_system_test_case.rb uses it). Cleared in the ensure because Selenium reuses one
    # Chrome for the whole file.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    begin
      [ files_path(view: "list"), files_path(view: "grid"), project_path(project), file_path(long.node_id),
        tools_path, models_path ].each do |path|
        visit path
        # `nav.tabbar` is display:none above 719px, so finding it VISIBLE is the proof that the
        # phone rules are running at all — without it a viewport that never narrowed would satisfy
        # the overflow assertion for entirely the wrong reason. It is what caught the 500px floor.
        assert_selector "nav.tabbar", visible: true
        assert_selector "form.topbar-project select", visible: true
        assert_no_selector "aside.rail .current-project select"
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
               "#{path} scrolls sideways at 375px (scrollWidth #{page.evaluate_script('document.documentElement.scrollWidth')})"
      end
      assert_no_console_errors
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end
end
