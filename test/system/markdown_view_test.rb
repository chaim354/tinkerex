require "application_system_test_case"

# A MARKDOWN FILE'S RENDERED / SOURCE TOGGLE, DRIVEN (2026-11-02, the UX audit's D8). The request
# suite (test/integration/web/markdown_file_page_test.rb) proves what the server renders into each
# pane; only a browser proves that the buttons swap them, that the editor mounted inside a HIDDEN
# pane is a working editor once shown, and that a Save in Source does not leave Rendered showing
# the file as it was.
#
# A LOOSE .md ON A SHARE ROOT OF ITS OWN, so the editor is the writable one (a .md outside a
# repository, FilesController::EDITABLE_WITHOUT_HISTORY) and a Save writes real bytes.
class MarkdownViewTest < ApplicationSystemTestCase
  include WebHelpers

  BODY = "# Desk Lamp\n\nA lamp that sits on a desk.\n".freeze

  setup do
    @root = use_fresh_share_library!
    @root.join("README.md").write(BODY)
    @user = sign_in_as("markdown-view@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @node = @user.nodes.find_by!(storage_path: "README.md")
  end

  def pressed = find(".markdown-view .view-toggle button[aria-pressed=true]").text

  test "the page opens on the rendered view and the toggle swaps it for a working editor" do
    visit file_path(@node.node_id)
    assert_selector ".markdown-rendered h1", text: "Desk Lamp"
    assert_equal "Rendered", pressed
    assert_no_selector ".cm-editor"

    click_on "Source"
    assert_selector ".cm-editor .cm-content", text: "A lamp that sits on a desk.", wait: 10
    assert_no_selector ".markdown-rendered"
    assert_equal "Source", pressed
    assert_selector ".markdown-view .view-toggle button.toggle.active", count: 1, text: "Source"

    click_on "Rendered"
    assert_selector ".markdown-rendered h1", text: "Desk Lamp"
    assert_no_selector ".cm-editor"
    assert_equal "Rendered", pressed
    assert_no_console_errors
  end

  # THE EDITOR SAVES WITHOUT A RELOAD, so the rendered pane is of the bytes the page was built from.
  # Mutation-checked (2026-11-02): with `this.dispatch("saved")` deleted from editor_controller.js,
  # Rendered shows the old heading and the last h1 assertion goes red.
  test "a Save in Source shows the saved text when Rendered is pressed again" do
    visit file_path(@node.node_id)
    click_on "Source"
    find(".cm-content .cm-line", text: "# Desk Lamp", wait: 10).click
    page.send_keys(:end, " v2")
    click_on "Save", exact: true
    assert_selector ".editor-status", text: "Saved"
    assert_equal "# Desk Lamp v2", @root.join("README.md").read.lines.first.chomp

    click_on "Rendered"
    assert_selector ".markdown-rendered h1", text: "Desk Lamp v2"
    assert_equal "Rendered", pressed
    assert_no_console_errors
  end

  # TURBO RESTORES THE PAGE AS IT WAS LEFT, so the panes must follow the pressed button rather than
  # the default. Mutation-checked (2026-11-02): connect() applying "rendered" unconditionally shows
  # the rendered pane under a pressed Source, and the first assertion after Back goes red.
  test "Back onto a page left on Source restores Source" do
    visit file_path(@node.node_id)
    click_on "Source"
    assert_selector ".cm-editor", wait: 10
    back_through_turbo_cache

    assert_equal "Source", pressed
    assert_no_selector ".markdown-rendered"
    assert_selector ".cm-editor .cm-content", text: "A lamp that sits on a desk.", wait: 10
  end
end
