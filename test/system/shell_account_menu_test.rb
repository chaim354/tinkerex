require "application_system_test_case"

# THE ACCOUNT BUTTON AND THE PHONE TAB BAR (Shop manual spec §7, slice 3). The round account button in
# the strip holds what the rail's foot and the phone's More sheet held — Settings, Account, Help, the
# theme and Sign out — at every width, so the More tab retired; below 720px the tab bar is exactly the
# four places. Only a browser sees that the menu is on screen at 375px, that each destination is one
# tap away, that the keyboard can open and close it, and that the tab bar lights what the strip would.
#
# The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not make
# a WebDriver window narrower than 500px).
#
# MUTATION-CHECKED (2026-11-19; each reverted, and the file re-run green after):
#   1. Deleting `.strip-account .menu-list { left: 12px; right: 12px; min-width: 0; }` from the ≤719px
#      block (shell.css): the first test red, the menu hanging off its button's right edge and off the
#      left of a 375px screen.
#   2. Deleting `data-controller="menu"` from the account details (layouts/_strip): the keyboard test
#      red, Escape no longer closes the menu.
#   3. `.tabbar { display: flex }` dropped from the ≤719px block: the tab bar test red, no bar on a phone.
class ShellAccountMenuTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("account-menu@example.com")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a phone the account menu opens on screen and reaches Settings, Account and Help" do
    phone!
    visit root_path
    open_account
    menu, client = page.evaluate_script(<<~JS)
      (() => { const b = document.querySelector("header.strip .strip-account .menu-list").getBoundingClientRect();
               return [[b.left, b.top, b.right, b.bottom], document.documentElement.clientWidth]; })()
    JS
    assert_operator menu[0], :>=, 0, "the menu starts off the left of the screen (#{menu.inspect})"
    assert_operator menu[2], :<=, client, "the menu runs off the right of the screen (#{menu.inspect}, client #{client})"
    assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth"),
           "the open menu scrolls the page sideways"
    within("header.strip .strip-account .menu-list") do
      assert_selector "[role=group][aria-label='Theme'] button", count: 3
      assert_selector "button", text: "Sign out"
    end

    { "Settings" => settings_path, "Account" => edit_user_registration_path, "Help" => help_path }.each do |label, path|
      visit root_path
      open_account
      within("header.strip .strip-account .menu-list") { click_link label }
      assert_current_path path
      assert_selector "nav.tabbar", visible: true
    end
    assert_no_console_errors
  end

  test "the keyboard opens the account menu, walks into it, and Escape closes it back onto the button" do
    visit root_path
    summary = find("header.strip .strip-account > summary")
    summary.execute_script("this.focus()")
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector "header.strip .strip-account[open]"
    page.driver.browser.action.send_keys(:tab).perform
    assert page.evaluate_script("document.querySelector('header.strip .strip-account .menu-list').contains(document.activeElement)"),
           "Tab from the open account button did not move into its menu"
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector "header.strip .strip-account[open]"
    assert page.evaluate_script("document.activeElement === document.querySelector('header.strip .strip-account > summary')"),
           "Escape did not return focus to the account button"
  end

  # THE MENU'S THEME CHOICE IS THE SETTINGS ROW (settings/_theme): it applies at once and writes the
  # cookie the next page renders from.
  test "the account menu's theme choice applies and persists, and Sign out signs out" do
    phone!
    visit root_path
    open_account
    within("header.strip .strip-account .menu-list") { click_button "Dark" }
    assert_equal "dark", page.evaluate_script("document.documentElement.dataset.theme")
    assert_equal "dark", page.driver.browser.manage.cookie_named("theme")[:value]
    visit files_path
    assert_equal "dark", page.evaluate_script("document.documentElement.dataset.theme")
    assert_selector "header.strip .strip-account button[data-theme-theme-param='dark'][aria-pressed='true']", visible: :all
    open_account
    within("header.strip .strip-account .menu-list") { click_button "Sign out" }
    assert_current_path root_path
    assert_selector ".auth-card"
    assert_no_selector "nav.tabbar"
    assert_no_selector "header.strip", visible: :all
  end

  # THE TAB BAR IS THE FOUR PLACES, AND LIGHTS WHAT THE STRIP WOULD (ShellHelper#place_aria); the
  # strip's own places are not drawn on a phone.
  test "on a phone the tab bar carries the four places and lights the one the page is in" do
    phone!
    visit files_path
    assert_equal %w[Library Projects Tools Inventory], all("nav.tabbar .tabbar-link span").map(&:text)
    assert_selector "nav.tabbar .tabbar-link[aria-current='page']", count: 1, text: "Library"
    assert_selector "header.strip nav.strip-places", visible: :hidden
    find("nav.tabbar .tabbar-link", text: "Projects").click
    assert_current_path projects_path
    assert_selector "nav.tabbar .tabbar-link[aria-current='page']", count: 1, text: "Projects"
    visit settings_path
    assert_no_selector "nav.tabbar .tabbar-link[aria-current]"
    assert_no_console_errors
  end

  test "at desktop width the tab bar is not drawn and the places are in the strip" do
    visit root_path
    assert_no_selector "nav.tabbar"
    assert_selector "nav.tabbar", visible: :hidden
    assert_selector "header.strip nav.strip-places a.strip-place", count: 4
  end

  private

    def phone!
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    end

    def open_account
      find("header.strip .strip-account > summary").click
      assert_selector "header.strip .strip-account[open] .menu-list", visible: true
    end
end
