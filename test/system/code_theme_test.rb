require "application_system_test_case"

# The source viewer follows the theme (spec §3, §13): under the default light theme it keeps this
# app's own surface (--surface, Paper: #fcfbf8, rgb(252, 251, 248)); under the dark theme it is
# painted by oneDark (its ground is #282c34, rgb(40, 44, 52)). Asserting a computed colour rather
# than a class, because CodeMirror's theme classes are generated names (ͼ-prefixed) that change
# between builds.
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

  # The `return` keyword's colour: CodeMirror's default highlight style paints it #708
  # (rgb(119, 0, 136)), oneDark paints it #c678dd (rgb(198, 120, 221)). nil when no such span
  # exists, which fails either assert_equal rather than passing a refute vacuously.
  def keyword_color
    page.evaluate_script(<<~JS)
      (() => {
        const span = [...document.querySelectorAll(".cm-editor .cm-line span")].find((s) => s.textContent === "return")
        return span ? getComputedStyle(span).color : null
      })()
    JS
  end

  test "the editor is light by default and dark under the dark theme" do
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(252, 251, 248)", editor_background
    # THE BACKGROUND ALONE CANNOT SEE oneDark LOADED UNDER LIGHT. vendor-overrides.css paints
    # `:root[data-theme="light"] .cm-editor` with --surface, and that rule outranks oneDark (it is
    # meant to), so a darkThemeActive() that wrongly answered true for "light" -- the default since
    # 2026-10-08 -- left the background assertion above green while every token on the page wore
    # oneDark's colours on paper. MUTATION-CHECKED: its final `return false` -> `return true` passed
    # the background assertion and failed this one with rgb(198, 120, 221).
    assert_equal "rgb(119, 0, 136)", keyword_color

    page.execute_script("document.cookie = 'theme=dark; path=/; max-age=31536000; samesite=lax'")
    visit file_path(@node.node_id)
    assert_selector ".cm-editor"
    assert_equal "rgb(40, 44, 52)", editor_background
    assert_equal "rgb(198, 120, 221)", keyword_color
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end
end
