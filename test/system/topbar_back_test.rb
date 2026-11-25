require "application_system_test_case"

# THE TOP BAR'S BACK IN A REAL BROWSER (2026-11-24; spec
# docs/superpowers/specs/2026-11-24-back-button-and-kept-tools-design.md). The href is pinned in
# test/integration/web/topbar_back_test.rb; what only a browser can show is what a CLICK does, and
# that is the whole point of the button: it steps back in the tab's history, exactly as the
# browser's own Back does, instead of following a link to the page that linked here.
#
# THE DIFFERENCE IS A HISTORY ENTRY, AND THAT IS WHAT IS MEASURED. Both spellings land on the same
# page the first time, so asserting the page proves nothing. A link ADDS an entry and the page it
# reaches then names the one just left, so two pages bounce between themselves for ever; a step back
# REMOVES one. `history.length` after the click and the page a second click reaches tell the two
# apart.
#
# MUTATION-CHECKED (2026-11-24; each reverted, and the file re-run green after):
#   1. back_controller.js#go never calling `history.back()` (the link followed instead): the first
#      test red on `history.length`, 6 where 5 was expected, and the Recent test red, because the
#      page a link reaches is drawn with a page behind it and is never disabled again.
#   2. `behindIsOurs` answering true always: the Recent test red on the disabled state, and the
#      cold-tab test red, the click stepping out of the app instead of following the link.
#   3. ShellHelper#topbar_back_path dropping `breadcrumb_parent_path`: the cold-tab test red, the
#      click landing on Recent.
class TopbarBackTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("topbar-back@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def back = find("header.topbar a.topbar-back")
  def history_length = page.evaluate_script("history.length")

  test "a click steps back in history instead of adding to it, so two pages never bounce" do
    visit files_path
    within("aside.rail") { click_on "Tools" }
    assert_current_path tools_path
    entries = history_length

    back.click
    assert_current_path files_path
    assert_equal entries, history_length, "Back followed a link: the tab's history grew by a page"

    # A link would now name Tools, the page just left. A step back leaves the Library the way the
    # tab came into it, which is Recent, where the sign-in landed.
    back.click
    assert_current_path root_path
    assert_no_console_errors
  end

  # NOTHING OF OURS BEHIND THE PAGE: a new tab. `history.back()` there does nothing at all, so the
  # control has to be a link, and for a page with a breadcrumb that link is one level up.
  test "in a tab with no page behind it, Back goes one level up" do
    within_window(open_new_window) do
      visit trash_index_path
      assert_selector "nav.breadcrumb", text: "Trash"
      assert_nil back[:"aria-disabled"]
      back.click
      assert_current_path files_path
      assert_no_console_errors
    end
  end

  test "Recent in a new tab draws Back disabled until there is a page to go back to" do
    within_window(open_new_window) do
      visit root_path
      assert_selector "header.topbar a.topbar-back[aria-disabled='true']"

      within("aside.rail") { click_on "Tools" }
      assert_current_path tools_path
      assert_selector "header.topbar a.topbar-back:not([aria-disabled])"

      back.click
      assert_current_path root_path
      assert_selector "header.topbar a.topbar-back[aria-disabled='true']"
      assert_no_console_errors
    end
  end
end
