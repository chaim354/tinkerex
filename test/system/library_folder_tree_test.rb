require "application_system_test_case"

# THE LIBRARY COLUMN'S FOLDER TREE IN A BROWSER (Shop manual spec §9; column_tree_controller.js,
# LibraryBrowseController#tree). What only a browser sees: a closed folder opening in place (its level
# loaded into the frame its row carries), the choice written to the `library_tree` cookie and drawn
# open by the server on the NEXT page, closing persisting the same way, the disclosure reached by the
# keyboard before its row, and a deep chain of long names never pushing the column sideways at 375px
# (rule 11). What the server draws is library_folder_tree_test.rb's.
#
# MUTATION-CHECKED (2026-11-19): see the report of the branch that built the tree.
class LibraryFolderTreeTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("tree@example.com")
    @projects = mkdir("Projects")
    @catan = mkdir("catan", @projects)
    mkdir("design", @catan)
    @laser = mkdir("laser")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "opening a folder loads its level in place, and the next page draws it open; closing persists too" do
    visit files_path
    assert_selector "aside.column .column-row", text: "Projects"
    assert_no_selector "aside.column .column-row", text: "catan"

    toggle = find("aside.column button.column-tree-toggle[aria-label='Folders in Projects'][aria-expanded='false']")
    toggle.click
    assert_selector "aside.column button.column-tree-toggle[aria-label='Folders in Projects'][aria-expanded='true']"
    # catan's own level arrived with its disclosure, closed: the frame holds the server's rows.
    assert_selector "aside.column turbo-frame#column-tree-#{@projects} button.column-tree-toggle[aria-label='Folders in catan'][aria-expanded='false']"
    assert_equal @projects, tree_cookie

    # A row inside the loaded level opens the PAGE (target _top), and that page draws the tree open
    # from the cookie with no click.
    within("aside.column") { click_link "catan" }
    assert_current_path files_path(folder: @catan)
    within("aside.column") { click_link "Trash" }
    assert_current_path trash_index_path
    assert_selector "aside.column turbo-frame#column-tree-#{@projects}:not([hidden]) .column-row", text: "catan"
    assert_selector "aside.column button.column-tree-toggle[aria-label='Folders in Projects'][aria-expanded='true']"

    # Closing hides the level now and is remembered: the next page draws Projects closed.
    find("aside.column button.column-tree-toggle[aria-label='Folders in Projects']").click
    assert_no_selector "aside.column .column-row", text: "catan"
    assert_nil tree_cookie
    visit files_models_path
    assert_selector "aside.column button.column-tree-toggle[aria-label='Folders in Projects'][aria-expanded='false']"
    assert_no_selector "aside.column .column-row", text: "catan", visible: :all
    assert_no_console_errors
  end

  # THE DISCLOSURE IS A REAL BUTTON, BEFORE ITS ROW IN FOCUS ORDER (as it sits before it on screen),
  # and Enter and Space both work it. A leaf (laser) has none, so Tab goes row to row there.
  test "the keyboard reaches each disclosure before its row and works it" do
    visit files_path
    find("aside.column a.column-row", text: "Library").send_keys(:tab)
    assert_equal "laser", focused_text
    page.send_keys(:tab)
    assert_equal "Folders in Projects", page.evaluate_script("document.activeElement.getAttribute('aria-label')")
    page.send_keys(:enter)
    assert_selector "aside.column .column-row", text: "catan"
    page.send_keys(:space)
    assert_no_selector "aside.column .column-row", text: "catan"
    page.send_keys(:tab)
    assert_equal "Projects", focused_text

    # The disclosure sits in the indent before its row's square, inside the column.
    box = page.evaluate_script(<<~JS)
      (() => { const b = document.querySelector("aside.column button.column-tree-toggle").getBoundingClientRect();
               const btn = document.querySelector("aside.column button.column-tree-toggle");
               const n = btn.parentElement.querySelector(":scope > a.column-row .column-row-name").getBoundingClientRect();
               const c = document.querySelector("aside.column").getBoundingClientRect();
               return { right: b.right, name: n.left, left: b.left, column: c.left }; })()
    JS
    assert_operator box["right"], :<=, box["name"], "the disclosure overlaps its row's name (#{box.inspect})"
    assert_operator box["left"], :>=, box["column"], "the disclosure sits outside the column (#{box.inspect})"
    assert_no_console_errors
  end

  # RULE 11. Eighteen levels of 80-character unbroken names open down to the deepest: the open sheet
  # at 375px never scrolls sideways, inside or out, and every row ends inside it. The indent stops
  # growing at seven levels, and each name ellipsizes. Catalog rows, because the chain's path is longer
  # than a Mac's PATH_MAX and the tree reads only `nodes`.
  test "at 375px a deep chain of long names never pushes the column sideways" do
    parent = nil
    18.times do |i|
      parent = @user.nodes.create!(node_id: "deep-#{i}", name: "level_#{i}_#{"x" * 72}", kind: "dir",
                                   parent_node_id: parent, mtime: 1, size: 0).node_id
    end
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit files_path(folder: parent)
    find("header.strip button.strip-contents").click
    assert_selector "aside.column", visible: true
    assert_selector "aside.column .column-row[aria-current]", text: "level_17"
    drawn = page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector("aside.column"), r = c.getBoundingClientRect();
               const rights = Array.from(c.querySelectorAll(".column-row, .column-tree-toggle")).map((e) => e.getBoundingClientRect().right);
               return { scroll: c.scrollWidth, client: c.clientWidth, right: r.right, rows: Math.max(...rights),
                        page: document.documentElement.scrollWidth, viewport: document.documentElement.clientWidth }; })()
    JS
    assert_operator drawn["scroll"], :<=, drawn["client"], "the column scrolls sideways (#{drawn.inspect})"
    assert_operator drawn["rows"], :<=, drawn["right"], "a row runs past the column (#{drawn.inspect})"
    assert_operator drawn["page"], :<=, drawn["viewport"], "the page scrolls sideways (#{drawn.inspect})"
    assert_no_console_errors
  end

  private

    def mkdir(name, parent = nil) = FileLayer.current.mkdir(@user, parent_node_id: parent, name:).node_id

    def tree_cookie
      page.driver.browser.manage.cookie_named(Maker::FolderTree::COOKIE)[:value].presence
    rescue Selenium::WebDriver::Error::NoSuchCookieError
      nil
    end

    def focused_text = page.evaluate_script("document.activeElement.textContent.trim()")
end
