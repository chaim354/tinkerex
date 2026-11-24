require "capybara/selenium/driver"

# CHROME 158 REFUSES THE ORIGIN CAPYBARA 3.40 CLEARS STORAGE WITH, SO WITHOUT THIS EVERY SYSTEM
# TEST ERRORS IN TEARDOWN.
#
# `Capybara::Selenium::Driver::ChromeDriver#reset!` ends with
# `execute_cdp("Storage.clearDataForOrigin", origin: "*", storageTypes: "cookies,local_storage")`.
# Chrome 157 and earlier read "*" as every origin. Chrome 158 validates the origin and answers
# `InvalidArgumentError: invalid argument: * is not a valid URL`, raised from the `after_teardown`
# that resets the session, so a test whose own assertions all passed is reported as an ERROR, and
# that happens to every test in the run (first seen 2026-11-23, Chrome 158.0.8127.37 on a Mac).
# Capybara 3.40.0 is still the latest release; the upstream fix is unmerged
# (teamcapybara/capybara#2865, with the fix proposed in #2867 and #2868).
#
# ONLY THE REFUSED CALL IS REPLACED, AND ONLY ONCE IT HAS BEEN REFUSED. "*" is still sent first, so
# a Chrome that accepts it (the Linux runners' Chrome, today) takes capybara's own path unchanged.
# When Chrome refuses it, every cookie is cleared (`Network.clearBrowserCookies`, which is what "*"
# did for cookies), and local storage is cleared for each http(s) origin in the tab's navigation
# history. For this suite that is the app server's own origin, the only one it visits. The history
# is asked rather than `current_url` because reset! has already navigated to about:blank by then.
# Local storage is not optional here: the calculator, the Measure view and the material estimate
# all keep state in it, and a test that inherits another test's state fails for that test's reason.
#
# THIS OVERRIDES `execute_cdp` AND NOT `reset!`. Copying reset!'s body here would freeze capybara
# 3.40's version of it through every later upgrade. Delete this file once a capybara release stops
# sending "*".
#
# GUARDED: `browser_reset_test.rb` proves a reset still clears cookies and local storage, and
# deleting the `prepend` below brings the teardown error back on every system test. Both were
# mutation-checked on Chrome 158.
module ChromeStorageReset
  CLEAR_DATA = "Storage.clearDataForOrigin".freeze

  private

  def execute_cdp(cmd, params = {})
    super
  rescue Selenium::WebDriver::Error::InvalidArgumentError
    raise unless cmd == CLEAR_DATA && params[:origin] == "*"

    types = params[:storageTypes].to_s.split(",")
    execute_cdp("Network.clearBrowserCookies") if types.include?("cookies")
    return unless types.include?("local_storage")

    visited_origins.each { |origin| execute_cdp(CLEAR_DATA, origin: origin, storageTypes: "local_storage") }
  end

  def visited_origins
    execute_cdp("Page.getNavigationHistory").fetch("entries").filter_map do |entry|
      uri = URI.parse(entry["url"].to_s)
      uri.origin if uri.is_a?(URI::HTTP) && uri.host
    rescue URI::InvalidURIError
      nil
    end.uniq
  end
end

Capybara::Selenium::Driver::ChromeDriver.prepend(ChromeStorageReset)
