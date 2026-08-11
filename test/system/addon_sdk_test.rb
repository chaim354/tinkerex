require "application_system_test_case"

# THE SDK, IN THE ONLY PLACE IT IS REAL. There is no JS unit-test runner in this repo (no
# package.json, importmap + Propshaft only), and the SDK is transport — a fetch, a CSRF header, a
# 409 round trip, a bare specifier resolving through a per-request merged importmap. None of that is
# observable from a request test; §14e records two CSP defects that shipped past every integration
# test and were caught only by a browser.
#
# HERMETIC, like its sibling addon_bundle_test.rb: this reads test/fixtures/addons, never the
# chaim354/tinkerex-addons working copy, so a fresh clone can run it.
class AddonSdkTest < ApplicationSystemTestCase
  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    sign_in_as "sdk@example.com"
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "a bundle that imports the SDK mounts, sees the host level, and reads the capability map" do
    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    # Asserted from the SERVER's own map rather than a literal, so flipping a capability in PR 4 or
    # PR 5 does not leave a stale literal here passing for the wrong reason.
    caps = Maker::Addons::Host.capabilities
    assert_selector "[data-role=sdk-caps]",
                    text: "write:#{caps["library:write"]} read:#{caps["library:read"]}"
    assert_no_console_errors
  end

  test "files.save writes through the real save door" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-one.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    assert_no_console_errors
  end

  # THE 409 DANCE, ABSORBED. Saving the same name twice is the bug CLAUDE.md §12 item 11 records:
  # the first copy is filed into a category subfolder by the intake sweep, leaving the picked folder
  # vacant, so the door accepts the second save and the sweep then cannot place it. The host answers
  # 409 would_replace BEFORE writing; what this proves is that the SDK reads that, calls onReplace,
  # and re-POSTs with overwrite=1 — the logic every bundle copies by hand today.
  test "files.save asks onReplace on a 409 and replaces when it answers true" do
    user = User.find_by!(email: "sdk@example.com")
    project = user.maker_projects.create!(name: "SDK Harbor")
    folder = project.ensure_library_folder!(user)

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."

    visit "/tools/sdk-fixture?parent=#{folder.node_id}&fname=sdk-dup.svg"
    click_button "Save"
    assert_selector "[data-role=sdk-status]", text: "Saved."
    # The onReplace callback ran and was told WHICH file and WHICH folder — a bundle that only knew
    # "something conflicted" could not write a truthful prompt. EXACT match, not a substring: this
    # save collides on exactly one file, so the attribute holds exactly one "name@folder" pair — a
    # substring match would pass just as happily on "sdk-dup.svg@undefined", asserting nothing about
    # the folder half of the pair, which is the half that comes from the server's `would_replace`
    # payload and is the actual reason a prompt can name a real destination.
    assert_selector "[data-role=sdk-status][data-replaced='sdk-dup.svg@design']"
    # THE 409 IS THE FLOW, NOT A DEFECT, and Chrome logs a SEVERE console entry for ANY non-2xx
    # fetch response — so an unfiltered assert_no_console_errors fails on the very thing this test
    # exists to exercise (addon_bundle_test.rb hits the identical shape for the identical reason).
    # Narrowly ignored (that exact status, on that exact page) rather than dropping the assertion,
    # so a real error still fails this test.
    assert_no_console_errors ignoring: [ /status of 409 \(Conflict\)/ ]
  end

  # THE CONNECT -> DISCONNECT -> CONNECT LIFECYCLE, THROUGH A REAL TURBO SOFT NAVIGATION. `visit` is
  # a hard browser load: it tears down the whole JS runtime and re-fetches every module fresh, so
  # addon_sdk.js's module-level `host` binding and `everInitialized` flag start over every time — a
  # `visit`-only test can never exercise addon_controller.js's disconnect() -> teardownHost() call,
  # or the following connect() -> initHost() finding a torn-down host already in place (the
  # `this.disposed` guard added in commit b3f4b78 exists precisely for that in-flight race). Only a
  # Turbo Drive pushState navigation — a `click_link` on a plain, non-turbo-disabled `link_to` — keeps
  # the SAME JS module graph alive across the round trip, the way a real user's session does, so the
  # SDK module instance actually carries state from one mount to the next and this test can catch a
  # regression in that handoff. Neither hop below opts out of Turbo (grep app/views/layouts and this
  # controller's own view: no `data: { turbo: false }` on either link), so both are soft navigations.
  test "a Turbo soft navigation away and back re-mounts the bundle cleanly" do
    visit "/tools/sdk-fixture"
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"

    # AWAY: the top-nav "Tools" link (app/views/layouts/application.html.erb) is a plain link_to —
    # Turbo Drive intercepts it, so this is a pushState visit, not a fresh page load.
    click_link "Tools"
    assert_selector ".tools-grid"
    assert_selector "h1", text: "Tools"

    # BACK: the addon gallery card itself is also a plain link_to (Tools::HomeController#index), so
    # this hop is a soft navigation too — the whole round trip after the initial `visit` above never
    # touches a real browser navigation, which is exactly what makes it able to catch a lifecycle bug
    # a `visit`-based test structurally cannot reach.
    click_link "SDK Fixture"

    # THE SECOND MOUNT. If disconnect() failed to tear the host down, or connect() failed to
    # reinitialize it, this either throws (addon_sdk.js's UNINITIALIZED_HOST proxy names exactly
    # this failure) or silently renders stale state — either way this line does not read "level 1"
    # (rendered fresh by the second mount() call) a second time.
    assert_selector "[data-role=sdk-level]", text: "level #{Maker::Addons::Host::LEVEL}"
    assert_no_console_errors
  end
end
