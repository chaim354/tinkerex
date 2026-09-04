require "application_system_test_case"

# Stage 2, S2-6: the settings page's three-way theme choice writes through the SAME path the
# rail's cycle button does (theme_controller.js's `choose`, sharing `apply` with `cycle`) -- the
# thing a request test cannot see is whether the button's `data-theme-theme-param` actually reaches
# the controller and actually writes the cookie, which is what makes the NEXT page render already
# themed (design-system.md rule 7: theme state is a cookie the client writes and the server
# renders, never an inline script).
#
# NO SHARE LIBRARY FIXTURE: the settings page reads no `nodes` and calls the port not at all (the
# same reasoning settings_reference_test.rb and shelves_test.rb give for their own request tests),
# so there is nothing here for use_fresh_share_library! to seed.
class SettingsThemeTest < ApplicationSystemTestCase
  setup do
    @user = sign_in_as("settings-theme@example.com")
  end

  test "choosing a theme writes html[data-theme] and the cookie immediately, and the rail agrees after a reload" do
    visit settings_path
    theme = -> { page.evaluate_script("document.documentElement.dataset.theme") }
    assert_equal "dark", theme.call
    assert_selector ".theme-choice button[data-theme-theme-param='dark'][aria-pressed='true']"

    find(".theme-choice button[data-theme-theme-param='light']").click
    assert_equal "light", theme.call
    assert_equal "light", page.driver.browser.manage.cookie_named("theme")[:value]
    assert_selector ".theme-choice button[data-theme-theme-param='light'][aria-pressed='true']"

    # RELOAD, NOT JUST THE IMMEDIATE DOM CHANGE. The rail's theme button is a SEPARATE Stimulus
    # `theme` controller instance from the settings row's (theme_controller.js's own comment: two
    # instances, two independent renders), so the rail's label only ever picks up a click made on
    # the settings row on the NEXT server render -- which reads the cookie the click wrote, not the
    # in-page DOM tweak. That is the property actually worth pinning here: not "the button looks
    # pressed", but "a page rendered afterwards agrees".
    visit settings_path
    assert_selector "aside.rail [data-action='theme#cycle']", text: "Theme: light"
    assert_selector ".theme-choice button[data-theme-theme-param='light'][aria-pressed='true']"

    # MUTATION-CHECKED (test/system/README.md): inside theme_controller.js#choose, replacing
    # `this.apply(next)` with the write path minus its `document.cookie = ...` line (i.e. set
    # `document.documentElement.dataset.theme`, the two metas and call `this.render(next)`
    # directly, skipping the cookie) leaves line 25's own DOM assertion green -- the in-page
    # DOM still flips to "light" -- but turns line 26's cookie read red, before this test ever
    # reaches the reload:
    #   Selenium::WebDriver::Error::NoSuchCookieError: no such cookie
    #     test/system/settings_theme_test.rb:26:in 'block in <class:SettingsThemeTest>'
    # (chromedriver raises rather than answering nil for a cookie that was never set -- this is
    # the FIRST theme change in the test, so there is no earlier write for the mutated `choose` to
    # have left behind.) The reload assertions two lines up would have caught the identical defect
    # one step later, had this one not already caught it first. Reverted immediately after.
    find(".theme-choice button[data-theme-theme-param='system']").click
    assert_equal "system", theme.call
    assert_selector ".theme-choice button[data-theme-theme-param='system'][aria-pressed='true']"
    assert_no_console_errors
  end
end
