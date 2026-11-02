require "application_system_test_case"

# THE SHELVES PAGE'S "EDIT EXTENSIONS", IN A REAL BROWSER (UX audit F7). Every chip's remove form is
# in the page from the start, and pages/settings.css shows it only while that card's `details` is open
# (a `:has()` rule), so a request test sees every remove button whether or not a maker ever could.
# Only the browser can say the chips are plain until asked and the removes appear when they are.
class SettingsShelvesEditTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("shelves@example.com")
  end

  def models_card = find(".filing-card", text: "models/")

  test "chips are plain until Edit extensions, which reveals each named remove and the add form" do
    visit settings_shelves_path

    within(models_card) do
      assert_selector ".filing-chip", text: ".stl"
      assert_no_selector "button[aria-label='Remove .stl']"
      assert_no_selector "input[name='filing_rule[ext]']"

      find("summary", text: "Edit extensions").click

      assert_selector "button[aria-label='Remove .stl']"
      assert_selector "input[name='filing_rule[ext]']"
    end
    # Opening one card's editor leaves the others' chips plain.
    within(find(".filing-card", text: "laser/")) { assert_no_selector "button[aria-label^='Remove .']" }

    within(models_card) do
      accept_confirm(/Remove \.stl from the models\/ shelf\?/) { find("button[aria-label='Remove .stl']").click }
    end
    assert_selector ".flash-stack .flash-notice", text: "Removed .stl from the models/ shelf."
    assert_not @user.maker_filing_rules.exists?(ext: "stl", folder: "models")
    assert_no_console_errors
  end
end
