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
# THE FEATURE DETECT IS THE POINT OF THE SECOND TEST. folder_field.js picks its shape from whether
# `ctx.chooseFolder` exists, because a bundle image can be published — or rolled back with
# bin/rollback — against a Rails that predates that key. Both arms therefore have to work, and the
# one that is NOT the current host's is the one no ordinary run will ever execute.
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
    find(".addon-card", text: "ABox").click
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

  # THE ROLLBACK ARM — the branch no ordinary run reaches, and the reason it exists.
  #
  # A context with no `chooseFolder` is EXACTLY what an older Rails looks like from inside the
  # bundle; there is no other difference the feature detect can see. So this mounts the real
  # folder_field.js — fetched through the real same-origin asset proxy, in the real page — against
  # that context, rather than asserting the fallback exists by reading the source. Without it, the
  # arm that protects a `bin/rollback` is the one arm nothing ever executes.
  test "against a host with no chooser, the bundle falls back to the flat select" do
    open_editor
    page.execute_script(<<~JS)
      window.__ffDone = false
      ;(async () => {
        const entry = document.querySelector("[data-controller=addon]").dataset.addonEntryValue
        const mod = await import(entry.replace(/boxes\\.js$/, "folder_field.js"))
        const slot = document.createElement("span")
        slot.id = "ff-fallback"
        document.body.appendChild(slot)
        mod.mountFolderField(slot, {
          folders: [ [ "/ (library root)", "" ], [ "/Projects", "p1" ] ], defaultFolder: "p1",
        })
        window.__ffDone = true
      })()
    JS

    assert_selector "#ff-fallback select"
    assert_no_selector "#ff-fallback .folder-field-btn"
    assert_equal "p1", find("#ff-fallback select").value, "defaultFolder must still preselect"
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
