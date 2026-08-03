require "application_system_test_case"

# The bundle-loading pipeline, end to end, in a real browser: the shell mounts, the proxied ESM
# resolves (including makerjs's own bare-specifier imports through the merged importmap), and the
# generator renders. None of this is observable from a request test — a rendered importmap that
# parses is not one that resolves (§14e).
#
# ADDON_SOURCE_PATH, not ADDON_SOURCE_URL: this app's own dev/test default already prefers the
# local-filesystem source (config/environments/development.rb), for a reason worth restating here
# because it is exactly what this test would otherwise trip over. ADDON_SOURCE_URL pointed at THIS
# SAME Rails process makes every asset fetch a synchronous NESTED HTTP call from inside a request
# this same Puma pool is already handling. Capybara's system-test Puma runs a small, fixed thread
# pool (observed: max 4) — measured directly against it, that reentrancy stalled most of the
# `generators` bundle's own asset requests 14-24 seconds and 404'd several outright (Net::HTTP's own
# read timeout firing before a thread ever freed up). Reading public/addons straight off disk (still
# through the exact same Tools::AddonsController#asset proxy action, still exercising the browser's
# real ESM/importmap resolution) sidesteps that pool reentrancy entirely. See
# Maker::Addons::Source::Local's comment for the full account, and CLAUDE.md/STATUS.md for the record
# of this finding.
class AddonBundleTest < ApplicationSystemTestCase
  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.public_path.join("addons").to_s
    sign_in_as "bundle@example.com"
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "the generators bundle mounts and renders a preview" do
    visit "/tools/generators"
    assert_selector "[data-role=picker] option", text: "Material Test Grid"
    assert_selector "[data-role=preview]"
    assert_no_console_errors
  end
end
