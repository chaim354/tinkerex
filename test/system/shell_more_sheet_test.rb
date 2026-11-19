require "application_system_test_case"

# THE PHONE'S FIFTH TAB, MORE (UX audit A1). Below 720px the rail is display:none, and it held the only
# way to Settings, Account, Trash, Inventory, Help, the theme and Sign out: the four tabs carry
# Recent, Library, Projects and Tools, and no page body links to the rest. More is a `details.menu`
# in the tab bar whose list opens upward as a sheet (layouts/_tabbar, shell.css). Only a browser sees
# that the sheet is on screen at 375px, that each destination is one tap away, that the tab lights,
# and that the keyboard can open and close it.
#
# The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not make
# a WebDriver window narrower than 500px).
#
# MUTATION-CHECKED (2026-11-02; each reverted, and the file re-run green after):
#   1. `hidden` on the `<details class="menu tabbar-more">` in layouts/_tabbar (no More on screen): the
#      sheet, keyboard and theme tests red at the More summary.
#   2. Dropping `bottom: calc(100% + 8px)` from `.tabbar-more .tabbar-sheet` (shell.css), so the sheet
#      opens DOWNWARD from the bar as a menu list does: the first test red on the sheet's bottom edge.
#   3. Deleting the `:has()` selector from the lit-tab rule (shell.css): the lit test red on the
#      summary's weight on Settings.
#   4. Deleting `data-controller="menu"` from the details: the keyboard test red, Escape no longer
#      closes the sheet.
class ShellMoreSheetTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("more-sheet@example.com")
    # Inventory joins the rail once there are items (ShellHelper#sidebar_inventory?); the sheet
    # follows the same rule, so one item puts it there.
    @user.maker_inventory_items.create!(name: "M3 bolt")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a phone, More opens a sheet on screen that reaches every place the four tabs do not" do
    phone!
    visit root_path
    assert_equal %w[Recent Library Projects Tools More],
                 all("nav.tabbar .tabbar-link span").map(&:text)
    open_more
    # ON SCREEN, ABOVE THE BAR: inside the page's client width, below the top of the viewport, and
    # ending above the tab bar it hangs from.
    sheet, bar, client = page.evaluate_script(<<~JS)
      (() => { const r = (s) => { const b = document.querySelector(s).getBoundingClientRect(); return [b.left, b.top, b.right, b.bottom]; };
               return [r("nav.tabbar .tabbar-sheet"), r("nav.tabbar"), document.documentElement.clientWidth]; })()
    JS
    assert_operator sheet[0], :>=, 0, "the sheet starts off the left of the screen (#{sheet.inspect})"
    assert_operator sheet[2], :<=, client, "the sheet runs off the right of the screen (#{sheet.inspect}, client #{client})"
    assert_operator sheet[1], :>=, 0, "the sheet starts above the top of the screen (#{sheet.inspect})"
    assert_operator sheet[3], :<=, bar[1], "the sheet does not end above the tab bar (#{sheet.inspect}, bar #{bar.inspect})"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the open sheet scrolls the page sideways"
    within("nav.tabbar .tabbar-sheet") do
      assert_selector "[role=group][aria-label='Theme'] button", count: 3
      assert_selector "button", text: "Sign out"
    end

    { "Inventory" => inventory_items_path, "Trash" => trash_index_path, "Settings" => settings_path,
      "Account" => edit_user_registration_path, "Help" => help_path }.each do |label, path|
      visit root_path
      open_more
      within("nav.tabbar .tabbar-sheet") { click_link label }
      assert_current_path path
      assert_selector "nav.tabbar", visible: true
    end
    assert_no_console_errors
  end

  # THE TAB LIGHTS LIKE A PLACE when the page is one of its members: through CSS, from the member's
  # own aria-current, which ShellHelper#sidebar_current decided — never a second decision. The Account
  # page lights Settings, as the rail does (SECTIONS' users/registrations entry, UX audit F1).
  test "More lights on a page it carries, and its own item says which" do
    phone!
    weight = -> { page.evaluate_script("getComputedStyle(document.querySelector('nav.tabbar .tabbar-more > summary')).fontWeight") }
    visit root_path
    assert_equal "400", weight.call, "More is lit on Recent, which the first tab carries"
    { settings_path => "Settings", edit_user_registration_path => "Settings", trash_index_path => "Trash",
      help_path => "Help", inventory_items_path => "Inventory" }.each do |path, lit|
      visit path
      assert_equal "600", weight.call, "More is not lit on #{path}"
      assert_selector "nav.tabbar .tabbar-sheet a[aria-current='page']", count: 1, text: lit, visible: :all
      assert_selector "nav.tabbar a.tabbar-link[aria-current='page']", count: 0
    end
  end

  test "the keyboard opens the sheet, walks into it, and Escape closes it back onto More" do
    phone!
    visit root_path
    summary = find("nav.tabbar .tabbar-more > summary")
    summary.execute_script("this.focus()")
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector "nav.tabbar .tabbar-more[open]"
    page.driver.browser.action.send_keys(:tab).perform
    assert page.evaluate_script("document.querySelector('nav.tabbar .tabbar-sheet').contains(document.activeElement)"),
           "Tab from the open More did not move into its sheet"
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector "nav.tabbar .tabbar-more[open]"
    assert page.evaluate_script("document.activeElement === document.querySelector('nav.tabbar .tabbar-more > summary')"),
           "Escape did not return focus to More"
  end

  # THE SHEET'S THEME CHOICE IS THE SETTINGS ROW (settings/_theme), and like it, it renames the rail's
  # button at once (the rail is hidden on a phone, but it is the same page's control and must agree).
  test "the sheet's theme choice applies, and Sign out signs out" do
    phone!
    visit root_path
    open_more
    within("nav.tabbar .tabbar-sheet") { click_button "Dark" }
    assert_equal "dark", page.evaluate_script("document.documentElement.dataset.theme")
    assert_equal "dark", page.driver.browser.manage.cookie_named("theme")[:value]
    assert_equal "Use system theme", find("aside.rail [data-action='theme#cycle']", visible: :all)["aria-label"]
    within("nav.tabbar .tabbar-sheet") { click_button "Sign out" }
    assert_current_path root_path
    assert_selector ".auth-card"
    assert_no_selector "nav.tabbar"
  end

  test "at desktop width the tab bar and its More are not drawn" do
    visit root_path
    assert_no_selector "nav.tabbar"
    assert_selector "nav.tabbar .tabbar-more", visible: :hidden
  end

  private

    def phone!
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    end

    def open_more
      find("nav.tabbar .tabbar-more > summary", text: "More").click
      assert_selector "nav.tabbar .tabbar-more[open] .tabbar-sheet", visible: true
    end
end
