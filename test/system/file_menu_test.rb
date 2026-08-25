require "application_system_test_case"

# The Files page's per-row right-click menu, plus the two heaviest-weight things a file can do
# from its own page: join a project (which RELOCATES it, not just references it) and survive a
# name collision without clobbering the file that was already there.
#
# STEP 1 (read the controller and the view first) FOUND THE PLAN'S PREMISE WAS WRONG, WHICH IS
# WHY STEP 1 EXISTS. The task doc says "filemenu_controller.js drives attach/move/rename... and
# the collision-rename prompt." Reading the controller (97 lines, matching the doc's line count)
# shows it is a right-click "Add note" / "Open" popover -- wired via
# `data-action="contextmenu->filemenu#open"` on each file-cell link in files/_list.html.erb --
# with nothing about attaching, moving or renaming anywhere in it. There is also no
# `window.prompt` anywhere under app/javascript (grepped), so the task doc's "critical mechanical
# warning" about `page.driver.browser.switch_to.alert` does not apply to this app.
#
# THE REAL ATTACH-AND-RELOCATE FLOW IS A PLAIN, TURBO-DISABLED RAILS FORM, not a Stimulus
# controller at all: files/show.html.erb renders `form_with url: attachments_path, method: :post,
# data: { turbo: false }` (a <select> of projects + a submit button), which POSTs to
# Projects::AttachmentsController#create -> Maker::AttachToProject#call -> Maker::MoveNode. A
# collision renders projects/_move_conflict.html.erb -- a plain `<dialog open>` (no JS opens it;
# `open` sits in the static markup) holding a `button_to "Move it in as “#{suggested_name}”",
# relocate_project_attachments_path(...)` -- a second ordinary form, not a text prompt of any
# kind. So behaviours 2 and 3 below exercise real links/forms/redirects rather than JS mechanics,
# adjusted from the plan's assumption per the standing instruction to fix MECHANICS and keep
# INTENT. Behaviour 1 is the one place the plan's premise and the code actually agree: the note
# menu really is DOM/event-wired open-on-trigger, close-on-outside-click, so it still stands in
# for "the cheapest thing on this page to break" even though it is not an attach menu.
#
# test/integration/web/attach_auto_move_test.rb already has exhaustive request-level coverage of
# every attach/relocate/collision RULE (45 tests) -- this file does not re-test the policy, only
# that the real rendered page's controls actually drive it end to end through a browser.
#
# MUTATION-CHECKED, all three, against a cleared tmp/dev-chunks* (README's warning: a stale
# content-addressed blob can make a broken mutation read green):
#   - Commenting out the outside-click listener in filemenu_controller.js#connect goes RED on
#     test 1's close assertion: "expected not to find visible css '.file-menu', found 1 match".
#   - Changing Maker::AttachToProject#call's `relocation: (move(node) if refusal.nil?)` to
#     `relocation: nil` (skip the relocate call) goes RED on test 2, and confirms the predicted
#     asymmetry: the failure is at the parent_node_id assert_eventually (line ~77), which only
#     happens once the FIRST assert_eventually (the attachment row) has already returned
#     successfully — the row exists, the node just never moved.
#   - Disabling MoveNode#collision!'s guard (`return` unconditionally instead of `return unless
#     collision?`) goes RED on test 3 -- but at the FIRST assertion (the dialog never renders),
#     not the bytes assertion, and ROOT-CAUSED rather than accepted at face value: on this
#     backend, `chunk_move` (Sync::Mutation.apply) reassigns columns ONLY on the node object it is
#     handed, so it can never reach or alter a sibling's row by name lookup. Disabling the
#     pre-write guard converts what would be a byte-level clobber on share/s3 into "two live
#     nodes share one name" on chunk -- AttachToProject#move then returns :moved instead of
#     :conflict, no ?move_conflict= param is minted, and the dialog simply stops appearing. A
#     SECOND, more surgical mutation was tried specifically to isolate the bytes assertion --
#     rewriting the `rescue Maker::MoveNode::Collision` branch to destroy the colliding sibling
#     and retry the move, simulating an actual clobber-on-collision implementation -- and it ALSO
#     reddened at the dialog assertion, for the same reason: that rescue only fires on a call this
#     app's own code already routed through `collision!`, so bypassing it here likewise turns the
#     outcome into :moved before the controller ever mints the prompt. No mutation reachable
#     through the real attach/relocate/collision path was found that reddens the bytes assertion
#     specifically without first reddening the dialog assertion -- which is a real property of
#     this backend (chunk_move cannot touch another row), not a gap in the test. The assertion
#     stays: it is the correct regression guard for the invariant CLAUDE.md states generally
#     ("every backend here is current-state-only, so a silent clobber is the user's file
#     permanently gone"), it is what would catch a FUTURE refactor of the rescue branch that
#     resolved a collision by deleting the incumbent, and per the standing instruction an
#     assertion that currently holds is not to be weakened or deleted for a mutation-order
#     technicality.
class FileMenuTest < ApplicationSystemTestCase
  setup do
    # A hermetic share library, where this pinned embedded chunk. What the suite is about is the
    # right-click MENU -- that it opens, closes on an outside click, offers Download and Edit, and
    # that attaching moves the file -- none of which is a claim about which backend holds bytes.
    @root = use_fresh_share_library!
    @user = sign_in_as("filemenu@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # Pure DOM/event wiring -- the cheapest thing in this controller to break and the least visible
  # server-side. A bare Node (no version) is enough: FileLayer::Chunk#stat_all includes every
  # present node whether or not it has content (Size renders "—"), so the row shows up.
  test "the right-click file menu opens on its trigger and closes on an outside click" do
    create_node!(@user, node_id: SecureRandom.uuid, name: "widget.stl", kind: "file")
    visit files_path

    assert_no_selector ".file-menu"

    find(".file-cell", text: "widget.stl").right_click
    assert_selector ".file-menu", text: "Add note"

    # Anywhere outside the menu — the page heading is far from wherever the right-click landed.
    find("h1", text: "Files").click
    assert_no_selector ".file-menu"

    assert_no_console_errors
  end

  # DOWNLOAD, IN THE GRID, WHICH IS THE SURFACE THAT NEEDS IT. A grid card has no row-actions cell,
  # so before this the only way to the bytes was to open the file first — the list at least had a
  # Download link per row. The href is asserted rather than clicked: following it would hand the
  # headless browser a real file transfer, and what is being tested is the menu's wiring, not
  # FilesController#blob (which files_flow_test.rb already drives end to end).
  #
  # test/integration/web/file_menu_wiring_test.rb asserts every SURFACE feeds the attribute; this
  # asserts the controller turns the attribute into a usable entry. Different failures — the
  # attribute can be present on a menu that never reads it, and vice versa.
  test "the right-click menu offers Download, in the grid as well as the list" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "widget.stl", kind: "file")
    visit files_path(view: "grid")

    find(".file-cell", text: "widget.stl").right_click

    assert_selector ".file-menu a", text: "Download"
    assert_equal blob_file_path(node.node_id, download: 1),
                 find(".file-menu a", text: "Download")[:href].sub(%r{\Ahttps?://[^/]+}, "")

    assert_no_console_errors
  end

  # "EDIT IN <ADDON>", WHICH ONLY A BROWSER CAN SEE. Three views write `data-addon-open-url` and
  # `data-addon-open-label` (test/integration/web/addon_origin_surfaces_test.rb asserts every one of
  # them); this asserts filemenu_controller.js turns the pair into a usable entry. Different
  # failures, exactly as the Download pair above: an attribute on a menu that never reads it renders
  # nothing, and a menu reading an attribute no view emits renders nothing either — and a Stimulus
  # controller that stopped building the entry would be SILENT, which is §14d's whole complaint
  # about this layer.
  #
  # THE REAL SOURCE, NOT A STUB, via test/fixtures/addons — the same hermetic fixture directory
  # addon_bundle_test.rb uses, whose `boxes` entry is titled "Box Generator". The label asserted
  # below is therefore the manifest's own title travelling through Registry, AddonOrigins and the
  # view, rather than a string this test also wrote.
  test "the right-click menu offers Edit in the addon that made the file" do
    prior_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "box.svg", kind: "file")
    state = @user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box", data: {})
    state.files.create!(node_id: node.node_id, role: "output", position: 0)

    visit files_path
    find(".file-cell", text: "box.svg").right_click

    entry = find(".file-menu a", text: "Edit in Box Generator")
    assert_equal tools_addon_path("boxes", state: state.id),
                 entry[:href].sub(%r{\Ahttps?://[^/]+}, "")

    assert_no_console_errors
  ensure
    ENV["ADDON_SOURCE_PATH"] = prior_source_path
  end

  # project_with_folder gives a SOURCE folder ("parts") that is deliberately NOT the project's own
  # folder — this is a file sitting in the library, not yet part of any project, which is the
  # ordinary case the attach control exists for.
  test "attaching a file to a project moves it into the project's folder" do
    project, folder = project_with_folder(@user)
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "widget.stl", kind: "file",
                               parent_node_id: folder.node_id)

    visit file_path(node.node_id)
    select project.name, from: "attach_project_id"
    click_on "Attach"

    assert_eventually("the attachment row was never created") do
      project.file_attachments.exists?(node_id: node.node_id)
    end

    # THE ASSERTION WITH TEETH. Maker::AttachToProject owns an attach-AND-RELOCATE policy: an
    # attach that records the link but leaves the file sitting in "parts" would satisfy the
    # assertion above — the real bug this exists to catch — and still read green without this.
    assert_eventually("the file's node never moved into the project folder") do
      node.reload.parent_node_id == project.reload.folder_node_id
    end

    assert_no_console_errors
  end

  test "a name collision on attach prompts a rename instead of clobbering" do
    project = @user.maker_projects.create!(name: "Lamp")
    project_folder = project.ensure_library_folder!(@user)

    # Real, byte-readable content on the SIBLING (not a bare Node) — needed so "the original is
    # untouched" below is a check on actual bytes, not on two nil content_tokens agreeing.
    sibling  = create_file!(name: "bracket.stl", bytes: "original bracket bytes",
                            parent_node_id: project_folder.node_id)
    incoming = create_file!(name: "bracket.stl", bytes: "a different file, same name")

    visit file_path(incoming.node_id)
    select project.name, from: "attach_project_id"
    click_on "Attach"

    # The attach succeeds (it is bookkeeping) even though the move does not — the dialog is what
    # tells the user their file did NOT land where every other attach lands.
    assert_selector "dialog.move-conflict", text: "bracket (2).stl"

    click_on "Move it in as"

    moved = nil
    assert_eventually("the renamed file never landed in the project folder") do
      moved = @user.nodes.present.find_by(parent_node_id: project_folder.node_id, name: "bracket (2).stl")
      moved.present?
    end
    assert_equal incoming.node_id, moved.node_id, "the SAME node was renamed, not a new one created"

    # THE ORIGINAL'S BYTES, not just its row. Every backend here is current-state-only, so a
    # silent clobber would be that file permanently gone — reading it back through the port is
    # what a name/parent_node_id check alone cannot prove.
    assert_equal "original bracket bytes", FileLayer.current.read(@user, node_id: sibling.node_id)

    assert_no_console_errors
  end

  private

    # A REAL FILE WITH ITS BYTES ON DISK, where this used to drive Sync::Commit and put a chunk in
    # the in-process store. The collision test asserts "the original is untouched", which a bare
    # Node.create! cannot back -- there has to be real content to still be there afterwards -- and
    # a file in the share root backs it exactly as a committed chunk did.
    def create_file!(name:, bytes:, parent_node_id: nil)
      parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
      rel = parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
      path = @root.join(rel)
      path.dirname.mkpath
      path.binwrite(bytes)
      # `nodes.create!`, NOT test_helper's create_node!. That helper materialises a placeholder of
      # its own, so calling it here would write the real bytes above and then immediately overwrite
      # them with "x" -- which is exactly what happened, and surfaced as this file's collision test
      # reading back "x" where it expected "original bracket bytes".
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id:,
                          size: bytes.bytesize, storage_path: rel,
                          content_hash: Digest::SHA256.hexdigest(bytes))
    end

    def assert_eventually(message, timeout: 15)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return if yield
        flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end
end
