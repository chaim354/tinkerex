require "application_system_test_case"

# Stage 2, S2-6: the settings page's three-way theme choice, which the strip's account menu carries
# too (Shop manual slice 3; the rail's cycle button retired with the rail) -- the
# thing a request test cannot see is whether the button's `data-theme-theme-param` actually reaches
# the controller and actually writes the cookie, which is what makes the NEXT page render already
# themed (design-system.md rule 7: theme state is a cookie the client writes and the server
# renders, never an inline script).
#
# NO SHARE LIBRARY FIXTURE: the settings page reads no `nodes` and calls the port not at all (the
# same reasoning settings_reference_test.rb and settings_shelves_test.rb give for their own request
# tests), so there is nothing here for use_fresh_share_library! to seed.
class SettingsThemeTest < ApplicationSystemTestCase
  setup do
    @user = sign_in_as("settings-theme@example.com")
  end

  # THE PRESSED THEME IS INK, AND ONLY IT (design-system.md rule 13: selection is ink). The fill
  # comes from the one `.btn[aria-pressed="true"]` rule in components.css; it used to be this
  # page's own copy of those three declarations.
  # `main`, because the strip's account menu carries the same choice first in the document, hidden
  # while closed, and `background_of` reads the first match.
  test "the chosen theme's button is drawn pressed, and the others are not" do
    visit settings_path
    ink = ink_colour

    assert_equal ink, background_of("main .theme-choice .theme-option[aria-pressed='true']")
    assert_not_equal ink, background_of("main .theme-choice .theme-option[aria-pressed='false']")
    # UNDER THE POINTER TOO. `.btn:hover` has the pressed rule's specificity and a pale fill, and
    # the pressed text is pale: the later rule wins, so the pressed one has to be the later.
    find("main .theme-choice .theme-option[aria-pressed='true']").hover
    assert_equal ink, background_of("main .theme-choice .theme-option[aria-pressed='true']")

    find("main .theme-choice button[data-theme-theme-param='dark']").click
    assert_selector "main .theme-choice button[data-theme-theme-param='dark'][aria-pressed='true']"
    assert_equal ink_colour, background_of("main .theme-choice .theme-option[aria-pressed='true']")
  end

  test "choosing a theme writes html[data-theme] and the cookie immediately, and the account menu agrees" do
    visit settings_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "light", theme.call
    assert_selector ".theme-choice button[data-theme-theme-param='light'][aria-pressed='true']"

    # ONE CONTROL ON THE ROW (UX audit A6): the lowercase "Theme: light" readout that sat beside the
    # three buttons is gone; the pressed button is the state.
    assert_no_selector ".theme-choice", text: /Theme:/i
    # The account menu's copy of the choice, read hidden while its menu is closed.
    menu = ->(t) { "header.strip .strip-account .theme-choice button[data-theme-theme-param='#{t}'][aria-pressed='true']" }
    assert_selector menu.("light"), visible: :all
    page_choice = "main .theme-choice"

    find("#{page_choice} button[data-theme-theme-param='dark']").click
    assert_equal "dark", theme.call
    assert_equal "dark", page.driver.browser.manage.cookie_named("theme")[:value]
    assert_selector "#{page_choice} button[data-theme-theme-param='dark'][aria-pressed='true']"
    # THE ACCOUNT MENU'S CHOICE FOLLOWS AT ONCE, with no reload (UX audit A6). It is a SEPARATE
    # `theme` controller instance from this row's; theme_controller.js#apply broadcasts every change
    # and each instance re-renders. Mutation-checked (2026-11-19): #apply rendering only its own
    # instance (`this.render(next)` for the `document.dispatchEvent(...)` broadcast) leaves the menu's
    # Light pressed here, and this assertion red.
    find("header.strip .strip-account > summary").click
    assert_selector menu.("dark")
    find("header.strip .strip-account > summary").click

    # AND A PAGE RENDERED AFTERWARDS AGREES: the server reads the cookie the click wrote, not the
    # in-page DOM tweak, and renders both controls already in that state.
    visit settings_path
    assert_selector menu.("dark"), visible: :all
    assert_selector "#{page_choice} button[data-theme-theme-param='dark'][aria-pressed='true']"

    # MUTATION-CHECKED (test/system/README.md): inside theme_controller.js#choose, replacing
    # `this.apply(next)` with the write path minus its `document.cookie = ...` line (i.e. set
    # `document.documentElement.dataset.theme`, the two metas and call `this.render(next)`
    # directly, skipping the cookie) leaves the first DOM assertion after the click green -- the
    # in-page DOM still flips to "dark" -- but turns the cookie read below it red, before this test
    # ever reaches the reload:
    #   Selenium::WebDriver::Error::NoSuchCookieError: no such cookie
    #     test/system/settings_theme_test.rb:26:in 'block in <class:SettingsThemeTest>'
    # (chromedriver raises rather than answering nil for a cookie that was never set -- this is
    # the FIRST theme change in the test, so there is no earlier write for the mutated `choose` to
    # have left behind.) The reload assertions two lines up would have caught the identical defect
    # one step later, had this one not already caught it first. Reverted immediately after.
    find("#{page_choice} button[data-theme-theme-param='system']").click
    assert_equal "system", theme.call
    assert_selector "#{page_choice} button[data-theme-theme-param='system'][aria-pressed='true']"
    assert_selector menu.("system"), visible: :all
    assert_no_console_errors
  end
end
