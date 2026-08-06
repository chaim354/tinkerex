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

  # THE OVERWRITE CONFIRMATION, IN A REAL BROWSER — the only place this flow is observable.
  # save.js's whole job is client-side: read a 409 from the host, ask window.confirm, re-POST the
  # same body with overwrite=1. A request test can prove the host's half (it does, in
  # addons_controller_test.rb) and can prove nothing about the browser's. The fixture imports a
  # VERBATIM COPY of the helper all three real bundles import, so what passes here is the same code
  # that ships.
  #
  # THE SETUP IS THE BUG. Save once (the nudge files it into design/), then save the same name
  # again — which before this arc left a SECOND copy stranded at the project root forever, because
  # the door checked the folder the user picked and the sweep checked the category folder.
  def project_folder_holding(name)
    user = User.find_by!(email: "bundle@example.com")
    project = user.maker_projects.create!(name: "Harbor Signs")
    folder = project.ensure_library_folder!(user)
    state = user.maker_addon_states.create!(addon_key: "fixture", name: "seed", data: {})
    Maker::Addons::LibraryOutput.write(
      user:, state:, parent_node_id: folder.node_id,
      files: [ { name:, bytes: "<svg>v1</svg>".b, content_type: "image/svg+xml", role: "output" } ]
    )
    Maker::ProjectIntake.for_user(user:)
    [ user, folder ]
  end

  test "re-saving a filed name asks in the browser, and replaces in place when accepted" do
    name = "harbor-number-v4.svg"
    user, folder = project_folder_holding(name)
    filed = user.nodes.present.find_by!(name:)

    visit "/tools/fixture?parent=#{folder.node_id}&fname=#{name}"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"

    accept_confirm(/Replace with this version\?/) { click_button "Save" }
    assert_selector "[data-role=fixture-status]", text: "Saved."

    assert_equal 1, user.nodes.present.where(name:).count,
                 "the whole bug: ONE copy, not one filed and one stranded at the project root"
    assert_equal filed.node_id, user.nodes.present.find_by!(name:).node_id,
                 "replaced in place — a new node_id would orphan every attachment (§14a)"
    # THE 409 IS THE FLOW, NOT A DEFECT, and Chrome logs a SEVERE console entry for ANY non-2xx
    # fetch response — so an unfiltered assert_no_console_errors fails on the very thing this test
    # exists to exercise. Narrowly ignored (that exact status, on that exact page) rather than
    # dropping the assertion, so a real error still fails this test.
    assert_no_console_errors ignoring: [ /status of 409 \(Conflict\)/ ]
  end

  # DECLINING IS NOT FAILING, and the fixture reports them differently because `res.ok` is false for
  # both — telling someone who just clicked Cancel that the save FAILED is the same class of
  # mis-reporting this arc exists to end.
  test "declining the overwrite writes nothing and says so" do
    name = "harbor-number-v4.svg"
    user, folder = project_folder_holding(name)
    filed = user.nodes.present.find_by!(name:)

    visit "/tools/fixture?parent=#{folder.node_id}&fname=#{name}"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"

    dismiss_confirm(/Replace with this version\?/) { click_button "Save" }
    assert_selector "[data-role=fixture-status]", text: "Not saved."

    assert_equal 1, user.nodes.present.where(name:).count
    assert_equal "<svg>v1</svg>", FileLayer.current.read(user, node_id: filed.node_id),
                 "declining must leave the original bytes untouched"
    # THE 409 IS THE FLOW, NOT A DEFECT, and Chrome logs a SEVERE console entry for ANY non-2xx
    # fetch response — so an unfiltered assert_no_console_errors fails on the very thing this test
    # exists to exercise. Narrowly ignored (that exact status, on that exact page) rather than
    # dropping the assertion, so a real error still fails this test.
    assert_no_console_errors ignoring: [ /status of 409 \(Conflict\)/ ]
  end
end
