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
    pin_file_layer_backend("chunk")   # chunk-shaped by construction — see uploader_test.rb
    Storage::ChunkStore.reset!
    @user = sign_in_as("filemenu@example.com")
  end

  # Pure DOM/event wiring -- the cheapest thing in this controller to break and the least visible
  # server-side. A bare Node (no version) is enough: FileLayer::Chunk#stat_all includes every
  # present node whether or not it has content (Size renders "—"), so the row shows up.
  test "the right-click file menu opens on its trigger and closes on an outside click" do
    @user.nodes.create!(node_id: SecureRandom.uuid, name: "widget.stl", kind: "file")
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
    node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "widget.stl", kind: "file")
    visit files_path(view: "grid")

    find(".file-cell", text: "widget.stl").right_click

    assert_selector ".file-menu a", text: "Download"
    assert_equal blob_file_path(node.node_id, download: 1),
                 find(".file-menu a", text: "Download")[:href].sub(%r{\Ahttps?://[^/]+}, "")

    assert_no_console_errors
  end

  # project_with_folder gives a SOURCE folder ("parts") that is deliberately NOT the project's own
  # folder — this is a file sitting in the library, not yet part of any project, which is the
  # ordinary case the attach control exists for.
  test "attaching a file to a project moves it into the project's folder" do
    project, folder = project_with_folder(@user)
    node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "widget.stl", kind: "file",
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

    # A real, committed file — node + version + a chunk actually sitting in the store — needed for
    # the collision test's "the original is untouched" assertion, which a bare `Node.create!` (no
    # version) cannot back. Mirrors test/services/file_layer/chunk_test.rb#create_file!.
    def create_file!(name:, bytes:, parent_node_id: nil)
      node_id = SecureRandom.uuid
      hash = Digest::SHA256.hexdigest(bytes)
      Storage::ChunkStore.current.put!(@user.id, hash, bytes)
      commit_id = SecureRandom.uuid
      Sync::Commit.begin(
        user: @user, device: device, commit_id:, node_id:, parent_node_id:,
        name:, base_version_id: nil, size: bytes.bytesize,
        mtime: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond),
        manifest: [ { "hash" => hash, "offset" => 0, "length" => bytes.bytesize } ]
      )
      Sync::Commit.finalize(user: @user, commit_id:)
      @user.nodes.find_by!(node_id:)
    end

    def device
      @device ||= Device.register!(user: @user, name: "filemenu-system-test")
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
