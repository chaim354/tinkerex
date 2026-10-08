require "application_system_test_case"

# The reusable folder/file chooser, driven in a real browser.
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
#
# ── THE HOST PAGE MOVED, AND SO DID THE MODE ──────────────────────────────────────────────────
# This file used to open `/tools/openscad/new`, whose own comment said the chooser is addon-agnostic
# and that page "is simply the one page on `main` that renders it". Retiring Tools::OpenscadController
# took that page away, and `app/views/projects/_form.html.erb` is now the ONLY view in the app that
# renders `shared/_folder_field` — so the project form is the host page.
#
# IT RENDERS THE FIELD IN `mode: "file"` (the cover-image picker), AND THAT IS NOT A DETAIL TO SKIM
# PAST. The retired editor used the folder-mode default, so this move changes which arm of
# lib/file_chooser.js each test drives. Four of the five subjects are mode-independent and are
# unchanged in substance — the trigger opens the modal, the columns fetch and descend, "＋ New
# Folder" writes through the real port, a refused name reports inline, Esc commits nothing, and a
# commit has to move the BUTTON LABEL and the HIDDEN INPUT together. What genuinely does not survive
# is the *seeding* half of the reopen case: `FileChooser#open` seeds a selection only when
# `mode === "folder"` (`{nodeId: this.value, path: this.label || this.rootLabel}`), because in file
# mode there is no "current file" to resume from. That behaviour is not lost, it MOVED — see
# addon_bundle_test.rb's "the chooser resumes from the folder it was seeded with", which drives the
# same seeding through `ctx.chooseFolder`, the one path on which folder mode still ships. The
# file-mode reopen contract that DOES live here (reopening and backing out must not clear a choice
# the field is already carrying) is `filechooser_controller.js`'s own, and is tested below.
#
# WHAT THIS FILE IS STILL FOR, given addon_bundle_test.rb drives the same modal: this is the
# FORM-FIELD face — `shared/_folder_field` + filechooser_controller.js, a hidden input inside a real
# `form_with`, on a server-rendered page with no bundle, no proxied ESM and no context object. That
# controller is the only thing that writes a chosen node_id into a form, and nothing else covers it.
class FileChooserTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("chooser@example.com")
    harbor = Maker::LibraryFolder.ensure_path!(@user, [ "Projects", "harbor" ])
    # A CATALOG ROW IS ALL THE CHOOSER READS. `/library/children` lists `nodes`; nothing here
    # fetches bytes, so `nodes.create!` is honest rather than a shortcut past the port — and it is
    # what keeps this test identical on all three LIBRARY_BACKEND legs. (Contrast the save-door
    # tests, which must go through the real write door because a `nodes.create!` node has a NULL
    # storage_path — §14a.) The folders above still go through Maker::LibraryFolder, because the
    # "＋ New Folder" test asserts against that same door.
    @file = @user.nodes.create!(node_id: SecureRandom.uuid, name: "beacon.stl", kind: "file",
                                parent_node_id: harbor.node_id)
  end

  # The project form's cover-image field. Straight to `new` rather than clicking through the
  # projects index: nothing about the chooser is exercised on the way in, and navigating by click
  # would couple this file to that page's markup for no coverage.
  #
  # "Choose automatically" is this caller's `root_label`, not the partial's "/ (library root)"
  # default — a reminder that the label is caller-supplied and the modal must show what it is given.
  def open_form
    visit new_project_path
    assert_selector ".folder-field-btn"
  end

  def cover_input = find("input[name='project[cover_node_id]']", visible: false)

  test "the trigger opens a modal, a file can be found by descending, and the form carries it" do
    open_form
    assert_text "Choose automatically", count: 1

    find(".folder-field-btn").click
    assert_selector ".filechooser-overlay"
    # Root column, the seeded tree's top level.
    within(".filechooser-cols") { assert_text "Projects" }
    # THE ROWS DRAW THE RAIL'S LINE ICONS, NOT EMOJI (2026-10-08 redesign): a folder row carries
    # svg.folder-glyph and the column text has no 📁/📄 left in it.
    assert_selector ".filechooser-row svg.folder-glyph"
    within(".filechooser-cols") { assert_no_text "📁"; assert_no_text "📄" }

    # IN FILE MODE, DESCENDING SELECTS NOTHING — folders navigate and only a file click commits.
    # Asserting the placeholder is what makes that an assertion rather than an assumption: were
    # descending to select (the folder-mode behaviour), "Open" would already be live here and the
    # user could commit a directory into a field that means "an image".
    find(".filechooser-row", text: "Projects").click
    within(".filechooser-cols") { assert_text "harbor" }
    find(".filechooser-row", text: "harbor").click
    assert_text "Select a file"

    find(".filechooser-row", text: "beacon.stl").click
    assert_text "Selected: /Projects/harbor/beacon.stl"

    click_on "Open" # the file-mode label for Choose
    assert_no_selector ".filechooser-overlay"

    # BOTH HALVES OF THE COMMIT, because they are two different contracts and only one of them is
    # visible: the button LABEL is what the user reads, the hidden INPUT is what the form submits.
    # A chooser that updated only the label would look perfect and save the wrong node_id.
    assert_text "/Projects/harbor/beacon.stl"
    assert_equal @file.node_id, cover_input.value
  end

  # THE ROOT COLUMN IS THE ONE DEPTH AT WHICH THE COMPOSED PATH CAN BE WRONG, and nothing reached
  # it until now: the assertion above descends twice and addon_sdk_test.rb's `pickFile` case
  # descends once, so BOTH compose correctly and neither can fail for this reason. `pickFile` builds
  # `pathPrefix(depth) + "/" + name`, and at depth 0 `pathPrefix` used to answer the caller's
  # `rootLabel` — a display label — so this pick came back as "Choose automatically/hero.png".
  #
  # THE NON-DEFAULT root_label IS THE WHOLE TRAP, not incidental to the host page: with the
  # partial's "/ (library root)" default the broken string starts with a "/" too, so a fix that
  # merely hardcoded "/" would look right here while leaving the label in the path for every other
  # caller. The project form passes "Choose automatically", which shares no prefix with the answer.
  test "a file picked in the root column gets a path, not the chooser's root label" do
    # CREATED IN THE TEST, NOT IN setup: this is the only case that needs a file at the root, and
    # every other test in this file reads the root column, so seeding one there would silently
    # change what five passing tests are looking at.
    root_file = @user.nodes.create!(node_id: SecureRandom.uuid, name: "hero.png", kind: "file",
                                    parent_node_id: nil)

    open_form
    find(".folder-field-btn").click
    # PIN THE TRAP LOCALLY. The paragraph above turns on the host page passing a non-default
    # root_label; nothing in this test named it, so if projects/_form.html.erb ever reverted to the
    # partial's "/ (library root)" default the trap would weaken with NOTHING going red. The crumbs
    # render rootLabel verbatim, so asserting it here fails loudly instead.
    assert_selector ".filechooser-crumbs", text: "Choose automatically"
    find(".filechooser-row", text: "hero.png").click # NO descent — depth 0 is the subject
    assert_text "Selected: /hero.png"

    click_on "Open"
    assert_no_selector ".filechooser-overlay"

    # BOTH HALVES, for the reason the first test states: the committed label is what was wrong, and
    # a fix that got the string right while dropping the node_id would pass on the label alone.
    assert_selector ".ff-path", exact_text: "/hero.png"
    assert_equal root_file.node_id, cover_input.value
    assert_no_console_errors
  end

  # BACK CLEARS A FILE-MODE PICK. `pickFile` collapses the trail to the file's own depth, so popping
  # a level removes the column that file was IN — leaving the footer naming a file that is no longer
  # on screen, with Open live. `descend` has always cleared here; `back` wrapped its whole selection
  # update in `if (mode === "folder")` and did not. Nothing in this suite clicked Back in either
  # mode before this test.
  test "Back clears a file-mode selection, because the column holding it is gone" do
    open_form
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    find(".filechooser-row", text: "harbor").click
    find(".filechooser-row", text: "beacon.stl").click
    assert_text "Selected: /Projects/harbor/beacon.stl"

    find(".filechooser-back").click
    assert_no_text "Selected: /Projects/harbor/beacon.stl"
    assert_text "Select a file"           # the placeholder `render` shows for an empty file-mode pick
    assert_button "Open", disabled: true  # and the commit is refused, not merely unlabelled
    assert_no_console_errors
  end

  test "New Folder creates a real dir through the port and steps into it" do
    open_form
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click

    click_on "＋ New Folder"
    find(".filechooser-newform input").set("exports")
    click_on "Create"

    # THE DOM ASSERTION COMES FIRST, AND THE ORDER IS LOAD-BEARING RATHER THAN STYLISTIC. Creating
    # a folder is a `fetch` the test does not await; only Capybara's own retrying matchers wait for
    # it. A bare ActiveRecord `exists?` does not retry, so asserting the row first races the POST
    # and fails intermittently — for a reason ("Expected false to be truthy") that says nothing
    # about what actually happened. Asserted on the CRUMBS rather than on "Selected:", because in
    # file mode `descend` deliberately leaves nothing selected, so the folder-mode spelling of this
    # assertion would fail here for a reason unrelated to whether the new folder was opened.
    assert_selector ".filechooser-crumbs", text: /exports/

    # A REAL NODE, not just a row in the modal. This is the one action in the chooser that writes,
    # and it goes through Maker::LibraryFolder — the cross-backend mkdir seam — so asserting the DOM
    # alone would pass over a modal that draws an optimistic entry for a folder never made.
    parent = @user.nodes.present.find_by(name: "Projects", kind: "dir")
    assert @user.nodes.present.exists?(name: "exports", parent_node_id: parent.node_id, kind: "dir")
  end

  test "a rejected folder name reports inline and creates nothing" do
    open_form
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
    assert_no_console_errors(ignoring: [ %r{library/folders.*422} ])
  end

  # REOPENING MUST NOT DISCARD WHAT IS ALREADY CHOSEN. In file mode the modal cannot resume a
  # selection (see the header), so what is under test here is narrower and belongs entirely to
  # filechooser_controller.js: `#open` awaits the modal and returns early on a null answer
  # (`if (!selection) return`), leaving the input and the button exactly as they were. Delete that
  # early return and backing out of a reopened chooser silently blanks a cover the user had already
  # picked — reverting a field by cancelling out of it, which is the opposite of what Cancel means.
  #
  # The ONLY-ON-THE-SECOND-OPEN shape is why this is worth its own test: every assertion in the
  # first test above is made after one open, and would stay green.
  test "reopening and backing out leaves an existing choice untouched, in both halves" do
    open_form
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    find(".filechooser-row", text: "harbor").click
    find(".filechooser-row", text: "beacon.stl").click
    click_on "Open"
    assert_text "/Projects/harbor/beacon.stl"

    find(".folder-field-btn").click
    assert_selector ".filechooser-overlay"
    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"

    assert_text "/Projects/harbor/beacon.stl"
    assert_equal @file.node_id, cover_input.value,
                 "the label and the submitted node_id must still name the same file"
    assert_no_console_errors
  end

  test "Escape closes the modal without committing a selection" do
    open_form
    find(".folder-field-btn").click
    find(".filechooser-row", text: "Projects").click
    find(".filechooser-row", text: "harbor").click
    find(".filechooser-row", text: "beacon.stl").click
    assert_text "Selected: /Projects/harbor/beacon.stl"

    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    # Cancelling must leave the FIELD untouched — the selection lives in the modal until "Open".
    assert_equal "", cover_input.value
    assert_no_console_errors
  end
end
