require "application_system_test_case"
require_relative "../support/fake_boxes_sidecar"

# The Box Generator's "Save to folder" control — the REAL shipped bundle's use of the chooser.
#
# WHY THIS IS NOT ALREADY COVERED BY addon_bundle_test.rb. That drives `ctx.chooseFolder` from the
# minimal `fixture` bundle, which proves the HOST's half of the contract: the function is handed
# across, the modal opens, the promise resolves with a node_id a bundle can submit. It says nothing
# about whether the bundle people actually use calls it — and the bundle is a different repo
# (chaim354/tinkerex-addons), published independently of Rails, where the failure mode is not an
# exception but a save UI that quietly still shows the old flat <select>.
#
# So this file exercises the SNAPSHOT in test/fixtures/addons/boxes/ (mirrored by that repo's
# bin/check-fixture-drift, which refuses to publish a bundle whose fixture has not been updated).
# Same hermetic-snapshot trade-off box_sections_test.rb's header sets out at length.
#
# THERE IS NO LONGER A FEATURE DETECT, AND THE TEST THAT DROVE ITS OTHER ARM WENT WITH IT.
# folder_field.js used to pick its shape from whether `ctx.chooseFolder` existed, and a second test
# here mounted the `ctx.folders` <select> arm directly, on the grounds that a bundle image can be
# published — or rolled back with bin/rollback — against a Rails that predates that key. That
# argument does not survive the bundle's move onto @maker/addon-sdk: a host old enough to lack
# `chooseFolder` is a host that does not pin the SDK either, so boxes.js fails to resolve its
# import, mount() never runs, and folder_field.js is never reached. The deleted test could only
# reach that arm by dynamic-importing folder_field.js directly, and that module now imports the SDK
# itself — so it fails to resolve for the same reason. What was left was a branch nothing can take
# and nothing can honestly exercise, which tinkerex CLAUDE.md §15 warns about in as many words. The
# recovery for a genuinely old host is `bin/rollback <sha>` in the bundles repo, restoring the
# pre-SDK image whole — not a dead branch carried inside the new one.
class BoxSaveFolderTest < ApplicationSystemTestCase
  SAMPLE_404 = %r{/tools/boxes/service/boxes/sample/\w+ - Failed to load resource.+404}

  setup do
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    FakeBoxesSidecar.install!
    @user = sign_in_as "boxsave@example.com"
    Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "harbor" ])
  end

  teardown do
    FakeBoxesSidecar.uninstall!
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
  end

  def open_editor
    visit tools_addon_path("boxes")
    open_addon_card("ABox")
    assert_selector "[data-role=folder-field]"
  end

  test "the editor offers the chooser, and a save lands in the folder it picked" do
    open_editor
    # The chooser shape, not the flat select — this assertion is what a bundle that silently kept
    # the old control would fail.
    assert_selector "[data-role=folder-field] .folder-field-btn"
    assert_no_selector "[data-role=folder-field] select"

    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    find(".filechooser-row", text: "harbor").click
    click_on "Choose"
    assert_selector ".folder-field-btn", text: "/Projects/harbor"

    fill_in_name "harbor sign"
    click_on "Save to library"

    # THE SAVED FILE'S PARENT, not the button's label. The bundle shows `path` and submits `nodeId`,
    # so a chooser that resolved the right label with the wrong id would pass every visible check
    # and file the box in the wrong folder.
    harbor = @user.nodes.present.find_by!(name: "harbor", kind: "dir")
    node = wait_for_node("harbor-sign.svg")
    assert_equal harbor.node_id, node.parent_node_id
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  private

  def fill_in_name(name)
    field = find("[data-role=name]")
    field.click
    field.send_keys(name)
  end

  # The save POSTs and Turbo follows the redirect; the node appears when the request lands.
  def wait_for_node(name)
    deadline = Time.now + 5
    node = nil
    while Time.now < deadline
      node = @user.nodes.present.find_by(name:)
      break if node

      sleep 0.05
    end
    assert node, "#{name.inspect} was never written"
    node
  end
end
