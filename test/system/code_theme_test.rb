require "application_system_test_case"

# The source viewer follows the theme (spec §3, §13): under the dark theme the editor is painted by
# oneDark (its ground is #282c34, rgb(40, 44, 52)); under the light theme it keeps this app's own
# surface. Asserting a computed colour rather than a class, because CodeMirror's theme classes are
# generated names (ͼ-prefixed) that change between builds.
class CodeThemeTest < ApplicationSystemTestCase
  # SCANNED INTO PLACE rather than built with `create_node!`, and the difference is not cosmetic:
  # Share's `stat` answers out of the node ROW, so a hand-built row has a nil `content_token` and
  # files/show renders "No content yet." instead of the viewer — no editor to ask about a colour.
  # code_viewer_test.rb reaches this page the same way, for the same reason.
  setup do
    @root = use_fresh_share_library!
    @root.join("main.c").write("int main(void) { return 0; }\n")
    @user = sign_in_as("code-theme@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @node = @user.nodes.find_by!(storage_path: "main.c")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def editor_background
    page.evaluate_script("getComputedStyle(document.querySelector('.cm-editor')).backgroundColor")
  end

  test "the editor is dark under the dark theme and light under the light theme" do
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(40, 44, 52)", editor_background

    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(255, 255, 255)", editor_background
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=dark; path=/; max-age=31536000; samesite=lax'")
  end
end
