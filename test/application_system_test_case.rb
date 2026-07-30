require "test_helper"
require_relative "system/support/web_helpers"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]

  include WebHelpers
end
