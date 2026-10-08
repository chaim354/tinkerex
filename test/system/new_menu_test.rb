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
end
