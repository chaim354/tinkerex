require "application_system_test_case"

# What only a browser can show about PR 2's Files pages: the overflow menu opens and closes the
# way a menu should, and the notes composer — Lexxy inside a <details> that starts closed —
# actually takes a note. The second is the risk the spec (§13) named; this is the verification.
#
# MUTATION-CHECKED, each assertion separately (this directory's README requires it, and §15 asks
# that each assertion be shown to carry weight rather than the test merely going red somewhere):
#   - Commenting out BOTH `document.addEventListener` lines in menu_controller.js#connect reddens
#     test 1 at the assertion AFTER THE OUTSIDE CLICK: `expected not to find visible css
#     ".page-actions details.menu[open]", found 1 match: "⋯\nRescan library"`. The Escape
#     assertion below it is never reached, so that mutation alone does not speak for it.
#   - Commenting out only the `keydown` listener reddens the same test at the assertion AFTER
#     ESCAPE, with the identical message — the outside-click half having passed first. So both
#     halves of the controller are pinned, not just whichever fails first.
#   - Rendering the composer open (`<details class="composer" open>` in files/show.html.erb)
#     reddens test 2 at its closed-before-the-click assertion: `expected not to find visible css
#     ".notes-panel details.composer[open]", found 1 match: "Add a note"`.
#
# LEXXY'S EDITABLE SURFACE IS `[contenteditable='true']` INSIDE `lexxy-editor`, and it lays itself
# out fine inside a details that started closed — the spec's named risk did not materialise. The
# note reaches `article.note .note-body`, so this is a claim about the note landing, not about the
# element being present.
class FilesPagesTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("files-pages@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the overflow menu opens on its button and closes on an outside click or Escape" do
    visit files_path
    assert_selector ".page-actions details.menu"
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open] .menu-item", text: /rescan/i
    find("h1", text: "Files").click
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open]"
    find("body").send_keys(:escape)
    assert_no_selector ".page-actions details.menu[open]"
    assert_no_console_errors
  end

  test "a note written through the closed composer lands on the page" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.dxf", kind: "file")
    visit file_path(node.node_id)
    assert_selector ".notes-panel details.composer"
    assert_no_selector ".notes-panel details.composer[open]"
    find(".notes-panel details.composer > summary", text: "Add a note").click
    assert_selector ".notes-panel details.composer[open] lexxy-editor", visible: true
    find(".notes-panel lexxy-editor [contenteditable='true']").click
    find(".notes-panel lexxy-editor [contenteditable='true']").send_keys("Print upside down, 4 walls.")
    click_on "Add note"
    assert_selector ".notes-panel article.note .note-body", text: "Print upside down, 4 walls."
    assert_no_console_errors
  end
end
