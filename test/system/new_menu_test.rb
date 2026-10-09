require "application_system_test_case"

# The top bar's New ▾ menu loads its tool entries through a LAZY turbo-frame (layouts/_topbar.html.erb),
# so the layout never reads the addon registry (docs/invariants/addons.md). A request test can see
# the frame's `src` and, separately, what the endpoint returns — only a browser can see the two joined:
# that opening the menu actually fetches the frame and the tool link appears, and that it navigates
# the PAGE (`target="_top"`), not the frame.
class NewMenuSystemTest < ApplicationSystemTestCase
  setup do
    @prior = ENV.to_h.slice("ADDON_SOURCE_PATH", "BOXES_SIDECAR_URL")
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    ENV["BOXES_SIDECAR_URL"] = "http://boxes.invalid"
    sign_in_as("new-menu@example.com")
  end

  teardown do
    %w[ADDON_SOURCE_PATH BOXES_SIDECAR_URL].each do |key|
      @prior.key?(key) ? ENV[key] = @prior[key] : ENV.delete(key)
    end
  end

  test "opening New loads the tools, and a tool link navigates the page" do
    visit projects_path
    assert_no_selector "turbo-frame#new-menu-tools a", visible: :all, text: "Box Generator…"

    find("header.topbar .topbar-new > summary").click
    within("header.topbar .topbar-new") do
      assert_selector "turbo-frame#new-menu-tools a.menu-item", text: "Box Generator…"
      click_on "Box Generator…"
    end
    assert_current_path tools_addon_path("boxes")
    assert_no_console_errors
  end

  # Escape from inside the menu closes it AND hands focus back to its summary; without that, closing
  # the <details> hid the focused field and focus fell to <body> (menu_controller.js).
  test "Escape from the folder field closes New and returns focus to it" do
    visit projects_path
    find("header.topbar .topbar-new > summary").click
    find("#new_folder_name").send_keys("jigs", :escape)
    assert_no_selector "header.topbar .topbar-new[open]"
    assert page.evaluate_script(<<~JS), "focus did not return to the New summary"
      document.activeElement === document.querySelector("header.topbar .topbar-new > summary")
    JS
  end

  # AT PHONE WIDTH THE TOP BAR WRAPS and New takes a row of its own. It used to wrap to the LEFT,
  # and the right-anchored menu then opened at x≈-185 — off-screen, with no sideways scroll to
  # betray it, so the 375px sweep in shell_test.rb stayed green. This measures the open menu.
  #
  # 360px TOO, AND AGAINST THE CLIENT WIDTH. Slice 4 put Upload to New's right, and a menu hung off
  # New's right edge then opened at left -1.1 on CI — whose Linux Chrome draws a 15px scrollbar, so
  # 375 there is 360 here — and ~14px off-screen on an ordinary 360px Android phone, while this Mac
  # (no scrollbar) still measured it inside at 375. Asking at 360 makes the local run see what CI and
  # a small phone see; `clientWidth` is the viewport minus any scrollbar, which `innerWidth` is not.
  # The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not
  # make a WebDriver window narrower than 500px).
  test "at phone width the open New menu stays on screen" do
    [ 375, 360 ].each do |phone|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: phone, height: 812, deviceScaleFactor: 1, mobile: false)
      visit projects_path
      find("header.topbar .topbar-new > summary").click
      assert_selector "header.topbar .topbar-new .menu-list"
      left, right, width = page.evaluate_script(<<~JS)
        (() => { const r = document.querySelector("header.topbar .topbar-new .menu-list").getBoundingClientRect();
                 return [r.left, r.right, document.documentElement.clientWidth]; })()
      JS
      assert_operator left, :>=, 0, "at #{phone}px the New menu opens off the left edge (left #{left})"
      assert_operator right, :<=, width, "at #{phone}px the New menu opens off the right edge (right #{right} of #{width})"
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
