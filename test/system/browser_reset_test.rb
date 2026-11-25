require "application_system_test_case"

# A SESSION RESET STILL EMPTIES THE BROWSER, which is what `support/chrome_storage_reset.rb` exists
# to keep true on Chrome 158 and later, where capybara 3.40's own clear is refused. Every test in
# this tier relies on it without saying so: one Chrome serves a whole worker, so a cookie or a
# localStorage key that outlives a reset hands one test's state to the next. That is how a test
# fails for another test's reason (the calculator, the Measure view and the material estimate all
# keep state in localStorage).
#
# Only a browser can show this, because the thing under test is the browser's own storage.
#
# MUTATION-CHECKED on Chrome 158: dropping the local-storage clear from the fallback fails the
# localStorage assertion, and dropping the cookie clear fails the cookie assertion. On a Chrome
# that still accepts "*" this checks capybara's own clear, which is the same promise.
class BrowserResetTest < ApplicationSystemTestCase
  PROBE = "browser_reset_probe".freeze

  test "a session reset clears the app origin's cookies and local storage" do
    visit rails_health_check_path
    execute_script("document.cookie = '#{PROBE}=1; path=/'; localStorage.setItem('#{PROBE}', '1')")
    # The writes took, so the assertions after the reset are about the reset and not about a page
    # that refused to store anything.
    assert_includes evaluate_script("document.cookie"), "#{PROBE}=1"
    assert_equal "1", evaluate_script("localStorage.getItem('#{PROBE}')")

    page.reset!
    visit rails_health_check_path

    assert_not_includes evaluate_script("document.cookie"), PROBE
    assert_nil evaluate_script("localStorage.getItem('#{PROBE}')")
  end
end
