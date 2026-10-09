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
    # A fresh library root per test. The system gate shares ONE LIBRARY_PATH for the whole run
    # while the database rolls back per test, so files outlive the rows that named them and
    # Share's clobber refusal (§14a) rejects the second test to save a given name -- which
    # surfaces as 'Not saved. "shelf-box.svg" already exists' rather than as anything about
    # the feature under test.
    @root = use_fresh_share_library!
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    sign_in_as "bundle@example.com"
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  test "a fixture bundle mounts through the real pipeline, including a pinned bare-specifier import" do
    visit "/tools/fixture"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"
    assert_no_console_errors
  end

  # THE OVERWRITE CONFIRMATION ON THE RAW-CTX PATH, IN A REAL BROWSER. save.js's whole job is
  # client-side: read a 409 from the host, ask window.confirm, re-POST the same body with
  # overwrite=1. A request test can prove the host's half (it does, in addons_controller_test.rb)
  # and can prove nothing about the browser's.
  #
  # NOT THE CODE THAT SHIPS, AND THIS COMMENT USED TO CLAIM IT WAS. save.js was a verbatim copy of
  # the helper every real bundle imported; `@maker/addon-sdk` absorbed that dance and the bundles
  # moved to it, so what runs here is a raw-ctx implementation `fixture` keeps on purpose
  # (manifests.json's `sdk-fixture` entry) and which has already drifted on wire shape. THE SHIPPED
  # BRANCH — `host.files.save({onReplace})` — is asserted by test/system/addon_sdk_test.rb, which
  # owns both arms of its 409 dance plus the no-callback throw.
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

  # ctx.chooseFolder — THE HOST-PROVIDED FOLDER CHOOSER, CALLED FROM A BUNDLE.
  #
  # This is a cross-repo contract with no compile-time link between its two halves: the host hands a
  # function into a bundle it never sees, and the bundle calls a function it cannot type-check. The
  # two are also deployed independently — publishing a bundle image IS the addon deploy and Rails is
  # never rebuilt (§14c) — so nothing anywhere fails loudly when the shapes stop agreeing. A browser
  # driving the real modal through the real context is the only thing that does.
  #
  # WHY NOT COVERED BY file_chooser_test.rb. That drives the SAME modal, but through
  # shared/_folder_field on a server-rendered page — a path with no bundle, no proxied ESM and no
  # context object. It would stay green through a typo in addon_controller.js's values or the
  # show.html.erb data attributes that feed it, which is precisely the seam this test exists for.
  # Since openscad's retirement that file also drives the modal in FILE mode — the project form's
  # cover picker is the last `shared/_folder_field` caller in the app — so `ctx.chooseFolder` is now
  # the ONLY path on which folder mode ships, and these tests are the only ones that exercise it.
  test "a bundle can drive the host's folder chooser and save into what it picked" do
    user = User.find_by!(email: "bundle@example.com")
    Maker::LibraryFolder.ensure_path!(user, [ "Projects", "harbor" ])

    visit "/tools/fixture?fname=picked.svg"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"

    click_button "Choose folder"
    assert_selector ".filechooser-overlay"
    find(".filechooser-row", text: "Projects").click
    find(".filechooser-row", text: "harbor").click
    click_on "Choose"

    assert_selector "[data-role=fixture-folder]", text: "/Projects/harbor"

    # THE NODE_ID, NOT JUST THE PATH THE BUNDLE PRINTED. The modal reports {nodeId, path} and the
    # bundle shows one and submits the other, so asserting the visible half alone would pass over a
    # chooser that resolved the right label with the wrong id — a save into the wrong folder,
    # reported as a success.
    click_button "Save"
    assert_selector "[data-role=fixture-status]", text: "Saved."
    harbor = user.nodes.present.find_by!(name: "harbor", kind: "dir")
    assert_equal harbor.node_id, user.nodes.present.find_by!(name: "picked.svg").parent_node_id

    assert_no_console_errors
  end

  # CANCEL IS NOT "THE ROOT", and the promise has to say so. `{nodeId: ""}` is a real answer (save
  # to the library root) and `null` is the absence of one; a chooser that collapsed them would move
  # a user's destination to the root every time they pressed Esc — silently, and in the direction
  # that loses the file they were about to file.
  test "cancelling the chooser leaves the bundle's destination alone" do
    user = User.find_by!(email: "bundle@example.com")
    Maker::LibraryFolder.ensure_path!(user, [ "Projects" ])

    visit "/tools/fixture?fname=cancelled.svg"
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"

    click_button "Choose folder"
    find(".filechooser-row", text: "Projects").click # a selection exists — and is then thrown away
    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"

    assert_selector "[data-role=fixture-folder]", text: "(cancelled)"
    assert_no_console_errors
  end

  # THE SEEDED SELECTION — MOVED HERE FROM file_chooser_test.rb, WHICH CAN NO LONGER EXPRESS IT.
  #
  # `FileChooser#open` seeds a selection ONLY in folder mode:
  #   this.selection = this.mode === "folder" ? { nodeId: this.value, path: this.label || rootLabel } : null
  # and `addon_controller.js` feeds it the matched pair the server resolved (`value:
  # defaultFolderValue`, `label: defaultFolderLabelValue`). That file used to guard this through the
  # OpenSCAD editor's folder field; retiring it left the project form's cover picker as the only
  # `shared/_folder_field` caller, and that one is `mode: "file"` — where seeding is `null` BY
  # DESIGN, because there is no "current file" to resume from. So the behaviour did not become
  # untestable, it moved to the one caller that still uses folder mode.
  #
  # THE DEFECT IT GUARDS, restored from the original: seeding nodeId from the field while taking the
  # path from the ROOT LABEL made the two halves of one selection describe DIFFERENT folders from
  # the first frame. Open a chooser already pointing at a project folder, press Choose without
  # navigating, and the caller received the right id under a label reading "/ (library root)" —
  # wrong in the direction that looks like it worked.
  #
  # BOTH DIRECTIONS ARE COVERED, which is why the save assertion is here and not just the label:
  #   - seeding present but mismatched -> the LABEL assertion fails (it would read the root label);
  #   - seeding absent altogether      -> `selection` is null, "Choose" is DISABLED, nothing
  #     resolves, `chosen` stays null in the fixture and the save falls back to the `parent` query
  #     param — deliberately omitted below — so the file lands at the library ROOT and the
  #     parent_node_id assertion fails.
  # Asserting only the visible half would pass in the second case, because the fixture already
  # prints `ctx.defaultFolderLabel` before the modal is ever opened.
  test "the chooser resumes from the folder it was seeded with, in both halves" do
    user = User.find_by!(email: "bundle@example.com")
    project = user.maker_projects.create!(name: "Lamp")
    folder = project.ensure_library_folder!(user)

    # `?in=` IS WHAT MAKES THE DEFAULT FOLDER NON-ROOT
    # (Tools::AddonsController#tool_destination_node_id, step 1).
    visit "/tools/fixture?in=#{folder.node_id}&fname=seeded.svg" # NO `parent=` — see the header
    assert_selector "[data-role=fixture-output]", text: "pinned-ok"

    # The label the server resolved, before the modal is involved at all.
    expected_path = "/Projects/#{folder.name}"
    assert_selector "[data-role=fixture-folder]", text: expected_path

    click_button "Choose folder"
    assert_selector ".filechooser-overlay"
    # WITHOUT NAVIGATING. That is the whole point: the selection under test is the seeded one, and
    # any descent would replace it with a freshly built one that cannot be wrong in this way.
    assert_text "Selected: #{expected_path}"
    click_on "Choose"

    assert_selector "[data-role=fixture-folder]", text: expected_path

    click_button "Save"
    assert_selector "[data-role=fixture-status]", text: "Saved."

    # UNDER the seeded folder, not necessarily IN it — and that is §14f, not slack in the
    # assertion. The save door fires the eager project-folder intake nudge, which files anything
    # landing at `Projects/<slug>/`'s own root into a category subfolder (an .svg -> design/). So
    # the honest question is whether the bytes went where the SEEDED selection pointed, which is
    # answered by the project folder being the parent or the parent's parent. The library ROOT —
    # what a missing or unresolved seeding produces — is neither, so this still fails in exactly
    # the direction the test is for.
    saved = user.nodes.present.find_by!(name: "seeded.svg")
    filed_into = user.nodes.present.where(parent_node_id: folder.node_id, kind: "dir").pluck(:node_id)
    assert_includes [ folder.node_id, *filed_into ], saved.parent_node_id,
                    "the seeded selection's node_id must be the folder its label named"
    assert_no_console_errors
  end
end
