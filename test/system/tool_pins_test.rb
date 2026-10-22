require "application_system_test_case"

# PINNING A TOOL IS A RIGHT CLICK (2026-10-22; toolmenu_controller.js). The request tests
# (test/integration/web/tool_pins_test.rb, calculator_shell_test.rb) see the data each tool carries
# and what the door does with a POST; only a browser can see the two joined — that a right click on
# a card opens the menu, that its entry says what it will do, that choosing it pins the tool, and
# that the same right click on the pinned link in the rail takes it away again.
class ToolPinsSystemTest < ApplicationSystemTestCase
  setup do
    @prior = ENV.to_h.slice("ADDON_SOURCE_PATH", "BOXES_SIDECAR_URL")
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    ENV["BOXES_SIDECAR_URL"] = "http://boxes.invalid"
    sign_in_as("tool-pins@example.com")
  end

  teardown do
    %w[ADDON_SOURCE_PATH BOXES_SIDECAR_URL].each do |key|
      @prior.key?(key) ? ENV[key] = @prior[key] : ENV.delete(key)
    end
  end

  def card = find("a.addon-card", text: "Box Generator")

  test "a right click on an addon's card pins it, and a right click on its rail link unpins it" do
    visit tools_path
    assert_no_selector "aside.rail a.rail-tool-pin"

    # `right_click`, NOT `click(:left, ctrl: true)`: through this driver a ctrl+click arrives as a
    # plain left click with no `contextmenu` at all (box_revisions_test.rb measured it).
    card.right_click
    assert_selector ".file-menu[role=menu] button[role=menuitem]", count: 1
    find(".file-menu button", text: "Pin to sidebar").click

    assert_current_path tools_path
    assert_selector ".flash", text: "Box Generator pinned to the sidebar."
    assert_selector "aside.rail a.rail-tool-pin[href=\"#{tools_addon_path("boxes")}\"]", text: "Box Generator"
    assert_no_selector ".file-menu"

    # The card now offers the opposite.
    card.right_click
    assert_selector ".file-menu button", text: "Unpin from sidebar"
    find("body").send_keys(:escape)
    assert_no_selector ".file-menu"

    visit projects_path
    find("aside.rail a.rail-tool-pin", text: "Box Generator").right_click
    find(".file-menu button", text: "Unpin from sidebar").click
    assert_current_path projects_path
    assert_selector ".flash", text: "Box Generator unpinned from the sidebar."
    assert_no_selector "aside.rail a.rail-tool-pin"
    assert_no_console_errors
  end

  test "the menu takes focus, Esc closes it and hands focus back, and only one menu is ever open" do
    visit tools_path
    find("#calculator").right_click
    assert page.evaluate_script(<<~JS), "the menu did not take focus"
      document.activeElement === document.querySelector(".file-menu button")
    JS

    # A second right click, on a tool in ANOTHER controller's scope (the rail's), replaces the menu.
    card.right_click
    find(".file-menu button", text: "Pin to sidebar").click
    find("aside.rail a.rail-tool-pin").right_click
    find("#calculator").right_click
    assert_selector ".file-menu", count: 1

    find(".file-menu button").send_keys(:escape)
    assert_no_selector ".file-menu"
    # The card is a <div> and cannot take focus; its Open button is where focus goes back to.
    assert page.evaluate_script(<<~JS), "focus did not go back to the tool"
      document.activeElement === document.querySelector("#calculator .calculator-card-open")
    JS
    assert_no_console_errors
  end

  test "an outside click closes the menu without pinning anything" do
    visit tools_path
    card.right_click
    assert_selector ".file-menu"
    find("h1", text: "Tools").click
    assert_no_selector ".file-menu"
    assert_no_selector "aside.rail a.rail-tool-pin"
  end
end
