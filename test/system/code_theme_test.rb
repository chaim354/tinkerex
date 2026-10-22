require "application_system_test_case"

# THE CODE VIEWERS ARE PAINTED BY THE DESIGN SYSTEM'S TOKENS IN BOTH THEMES, AND A THEME SWITCH
# REPAINTS AN OPEN EDITOR (2026-10-21). The chrome is unscoped token CSS in vendor-overrides.css and
# the syntax colours a HighlightStyle of `--code-*` custom properties (lib/codemirror_theme.js), so
# nothing is chosen when an editor mounts. Before this, Graphite was oneDark (#282c34, a cool
# blue-grey from another product) chosen AT MOUNT, and an editor on screen kept the theme it was
# built with until the next page.
#
# Asserting computed colours rather than classes, because CodeMirror's theme and highlight classes
# are generated names (ͼ-prefixed) that change between builds. Three readings, each for a reason:
# the editor GROUND (vendor-overrides' rule against CodeMirror's transparent default), the GUTTER
# (the light base-theme variant's #f5f5f5 literal, which is what an unscoped rule exists to beat in
# Graphite), and the `return` KEYWORD (the highlight style — the ground alone cannot see it).
class CodeThemeTest < ApplicationSystemTestCase
  PAPER = { ground: "rgb(252, 251, 248)",   # --surface  #fcfbf8
            gutter: "rgb(235, 232, 225)",   # --raised   #ebe8e1
            keyword: "rgb(154, 52, 18)" }.freeze  # --code-keyword #9a3412
  GRAPHITE = { ground: "rgb(27, 28, 25)",   # --surface  #1b1c19
               gutter: "rgb(37, 38, 34)",   # --raised   #252622
               keyword: "rgb(255, 154, 102)" }.freeze # --code-keyword #ff9a66

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

  # nil for the keyword when no such span exists, which fails the assert_equal rather than passing
  # anything vacuously.
  def colours
    page.evaluate_script(<<~JS).transform_keys(&:to_sym)
      (() => {
        const editor = document.querySelector(".cm-editor")
        const span = [...editor.querySelectorAll(".cm-line span")].find((s) => s.textContent === "return")
        return {
          ground: getComputedStyle(editor).backgroundColor,
          gutter: getComputedStyle(editor.querySelector(".cm-gutters")).backgroundColor,
          keyword: span ? getComputedStyle(span).color : null
        }
      })()
    JS
  end

  def open_editor
    visit file_path(@node.node_id)
    # The keyword is a highlighted span only once the parser has run, which is after mount.
    assert_selector ".cm-editor .cm-line span", exact_text: "return"
    # A MARK ON THE MOUNTED EDITOR, so a live-switch assertion below proves it repainted THIS
    # editor: a reload or a remount would build a new .cm-editor without it.
    page.execute_script("document.querySelector('.cm-editor').dataset.themeProbe = 'mounted'")
  end

  # Exactly what theme_controller.js#apply writes to the page; no visit, no cookie.
  def switch_live(theme)
    page.execute_script("document.documentElement.dataset.theme = #{theme.to_json}")
    assert_equal "mounted", page.evaluate_script("document.querySelector('.cm-editor').dataset.themeProbe"),
                 "the editor was rebuilt, so this did not test a live switch"
  end

  test "the editor follows the theme, and a live switch repaints it in both directions" do
    open_editor
    assert_equal PAPER, colours, "the default (light) theme"

    switch_live("dark")
    assert_equal GRAPHITE, colours, "a light-mounted editor after a live switch to dark"
    switch_live("light")
    assert_equal PAPER, colours, "and back"

    # MOUNTED UNDER GRAPHITE TOO, because a mount-time choice is invisible from one side only: an
    # extension or a literal picked for the theme the editor was BUILT under matches on that side
    # whatever it does after a switch.
    page.execute_script("document.cookie = 'theme=dark; path=/; max-age=31536000; samesite=lax'")
    open_editor
    assert_equal GRAPHITE, colours, "the dark theme from the cookie"
    switch_live("light")
    assert_equal PAPER, colours, "a dark-mounted editor after a live switch to light"
    assert_no_console_errors
  ensure
    page.execute_script("document.cookie = 'theme=light; path=/; max-age=31536000; samesite=lax'")
  end

  # `system` follows the OS through application.css's `(prefers-color-scheme: dark)` token block —
  # the only CodeMirror input that is a media query now. Emulated through CDP; on a driver without
  # it this SKIPS rather than asserting about a media query it cannot set.
  test "under system the editor follows the OS colour scheme, live" do
    browser = page.driver.browser if page.driver.respond_to?(:browser)
    skip "needs Chrome's CDP to emulate prefers-color-scheme" unless browser.respond_to?(:execute_cdp)

    open_editor
    switch_live("system")
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "dark" } ])
    assert_equal GRAPHITE, colours, "system under a dark OS"
    browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
    assert_equal PAPER, colours, "system under a light OS"
    assert_no_console_errors
  ensure
    # ONE CHROME SERVES EVERY TEST IN A WORKER, so an emulation left behind would make every later
    # `system` page dark.
    browser&.execute_cdp("Emulation.setEmulatedMedia", features: []) if browser.respond_to?(:execute_cdp)
  end
end
