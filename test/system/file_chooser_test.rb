require "application_system_test_case"
require_relative "../support/fake_openscad"

# The reusable folder chooser, driven in a real browser.
#
# WHY THIS TIER AND NOT AN INTEGRATION TEST. Everything this modal is made of only exists in a
# browser: the Stimulus controller has to be REGISTERED (importmap `pin_all_from` +
# `eagerLoadControllersFrom`, neither of which any Ruby test exercises), the modal is built by
# `innerHTML` at click time so it is in no rendered template to assert against, and the columns
# arrive from `fetch`. An integration test can assert the trigger partial renders and prove nothing
# about whether clicking it does anything at all — which is the failure this file exists to catch.
#
# AND IT IS THE ONLY TIER THAT CAN SEE THE CSP. config/initializers/content_security_policy.rb is
# report-only today and `script_src :self`, so a chooser that reached for an inline handler or an
# eval would pass every Ruby test, log a violation only in a visitor's browser, and then break for
# real on the day that policy is flipped to enforcing. §14e: "a CSP header that parses is not a CSP
# that works — only a browser knows." assert_no_console_errors is what makes that check real here.
class FileChooserTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    # The chooser is addon-agnostic; /tools/openscad is simply the one page on `main` that renders
    # it. The sidecar stub is this page's own precondition, not the chooser's — the editor needs a
    # catalog to render at all, and OpenscadClient.current prefers @stub over the URL so nothing
    # here reaches the network.
    @prior_sidecar_url = ENV["OPENSCAD_SIDECAR_URL"]
    ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
    OpenscadClient.stub = FakeOpenscad.new
    @user = sign_in_as("chooser@example.com")
    Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "harbor" ])
  end

  teardown do
    ENV["OPENSCAD_SIDECAR_URL"] = @prior_sidecar_url
    OpenscadClient.reset!
  end

  # Straight to the editor rather than clicking through the index: the tile's visible text is the
  # generator KEY, so navigating by click couples this file to the gallery's markup for no coverage
  # — the gallery has its own tests, and nothing about the chooser is exercised on the way in.
  def open_editor
    visit new_tools_openscad_path(generator: "hex_plate")
    assert_selector ".folder-field-btn"
  end

  test "the trigger opens a modal, a folder can be descended and chosen, and the form carries it" do
    open_editor
    assert_text "/ (library root)", count: 1

    find(".folder-field-btn").click
    assert_selector ".filechooser-overlay"
    # Root column, dirs only — the seeded tree's top level.
    within(".filechooser-cols") { assert_text "Projects" }

    # Descending is what selects, in folder mode — there is no separate "select" click.
    find(".filechooser-row", text: "Projects").click
    within(".filechooser-cols") { assert_text "harbor" }
    find(".filechooser-row", text: "harbor").click
    assert_text "Selected: /Projects/harbor"

    click_on "Choose"
    assert_no_selector ".filechooser-overlay"

    # BOTH halves of the commit, because they are two different contracts and only one of them is
    # visible: the button LABEL is what the user reads, the hidden INPUT is what the form submits.
    # A chooser that updated only the label would look perfect and save to the wrong folder.
    assert_text "/Projects/harbor"
    chosen = @user.nodes.present.find_by(name: "harbor", kind: "dir")
    assert_equal chosen.node_id, find("input[name='parent_node_id']", visible: false).value

    assert_no_console_errors
  end

  test "New Folder creates a real dir through the port and steps into it" do
    open_editor
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click

    click_on "＋ New Folder"
    find(".filechooser-newform input").set("exports")
    click_on "Create"

    # A REAL NODE, not just a row in the modal. This is the one action in the chooser that writes,
    # and it goes through Maker::LibraryFolder — the cross-backend mkdir seam — so asserting the DOM
    # alone would pass over a modal that draws an optimistic entry for a folder that was never made.
    assert_text "Selected: /Projects/exports"
    parent = @user.nodes.present.find_by(name: "Projects", kind: "dir")
    assert @user.nodes.present.exists?(name: "exports", parent_node_id: parent.node_id, kind: "dir")

    assert_no_console_errors
  end

  test "a rejected folder name reports inline and creates nothing" do
    open_editor
    find(".folder-field-btn").click

    click_on "＋ New Folder"
    find(".filechooser-newform input").set("..")
    click_on "Create"

    # The door's refusal, surfaced where the user is looking. `..` is refused by
    # Maker::MoveNode.valid_leaf_name? in LibraryBrowseController — on CHUNK that door is the only
    # guard in the stack, so this is the browser-side half of that unit test.
    assert_text "That folder name isn't allowed."
    assert_equal 2, @user.nodes.present.where(kind: "dir").count, "nothing was created"

    # `ignoring:` the 422: Chrome logs any non-2xx fetch at SEVERE, and this refusal IS the flow —
    # same reason addon_bundle_test ignores its own 409.
    assert_no_console_errors(ignoring: [ /library\/folders.*422/ ])
  end

  # REOPENING MUST NOT FORGET WHAT IS ALREADY CHOSEN — a defect in the original controller, fixed
  # when the modal was split out into lib/file_chooser.js.
  #
  # It seeded the modal's selection as {nodeId: <the field's value>, path: <the ROOT label>}, two
  # halves describing different folders. Nothing looked wrong until you pressed Choose without
  # navigating: #choose writes nodeId (unchanged, still the subfolder) to the hidden input and the
  # path to the button, so the form submitted the subfolder under a label reading "/ (library
  # root)". Wrong in the direction that looks like it worked, and only ever on the SECOND open —
  # which is why the original suite, whose every case opened once, could not see it.
  test "reopening after a choice keeps the chosen folder, in both halves" do
    open_editor
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    click_on "Choose"
    assert_text "/Projects"

    find(".folder-field-btn").click
    assert_text "Selected: /Projects" # NOT "/ (library root)"
    click_on "Choose"

    chosen = @user.nodes.present.find_by(name: "Projects", kind: "dir")
    assert_text "/Projects"
    assert_equal chosen.node_id, find("input[name='parent_node_id']", visible: false).value,
                 "the label and the submitted node_id must name the same folder"
    assert_no_console_errors
  end

  test "Escape closes the modal without committing a selection" do
    open_editor
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    assert_text "Selected: /Projects"

    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    # Cancelling must leave the FIELD untouched — the selection lives in the modal until "Choose".
    assert_equal "", find("input[name='parent_node_id']", visible: false).value
    assert_no_console_errors
  end
end
