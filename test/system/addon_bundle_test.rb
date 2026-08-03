require "application_system_test_case"

# The bundle-loading pipeline, end to end, in a real browser: the shell mounts, the proxied ESM
# resolves (including a bare-specifier import through the merged importmap), and the module renders.
# None of this is observable from a request test — a rendered importmap that parses is not one that
# resolves (§14e).
#
# HERMETIC FIXTURE, NOT THE REAL BUNDLE (Phase B). Before Phase B the real `generators` bundle shipped
# inside this image at public/addons and this test read it straight off disk. Phase B moved the
# bundles to their own repo (chaim354/tinkerex-addons), served in production by the `addons` Kamal
# accessory — public/addons no longer exists here. Pointing this test at that repo's working copy
# (config/environments/development.rb's ADDON_SOURCE_PATH default) would make CI depend on a sibling
# repo being checked out beside this one, which a fresh clone does not have — "it passes on my
# machine" over a CI job that cannot pass on a fresh checkout. This test owns a minimal bundle of its
# own instead (test/fixtures/addons/), independent of both the sibling repo and the live accessory.
# The real bundle's correctness is the addons repo's business; this test's job is only to prove the
# HOST PIPELINE — shell, same-origin asset proxy, merged importmap, mount — still works.
#
# ADDON_SOURCE_PATH, not ADDON_SOURCE_URL: ADDON_SOURCE_URL pointed at THIS SAME Rails process makes
# every asset fetch a synchronous NESTED HTTP call from inside a request this same Puma pool is
# already handling. Capybara's system-test Puma runs a small, fixed thread pool (observed: max 4) —
# measured directly against it (against the real `generators` bundle, pre-Phase-B), that reentrancy
# stalled most asset requests 14-24 seconds and 404'd several outright (Net::HTTP's own read timeout
# firing before a thread ever freed up). Reading the fixture straight off disk (still through the
# exact same Tools::AddonsController#asset proxy action, still exercising the browser's real
# ESM/importmap resolution) sidesteps that pool reentrancy entirely. See
# Maker::Addons::Source::Local's comment for the full account, and CLAUDE.md/STATUS.md for the record
# of this finding.
class AddonBundleTest < ApplicationSystemTestCase
  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    sign_in_as "bundle@example.com"
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "a fixture bundle mounts through the real pipeline, including a pinned bare-specifier import" do
    visit "/tools/fixture"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"
    assert_no_console_errors
  end
end
