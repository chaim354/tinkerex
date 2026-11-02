require "application_system_test_case"
require "support/git_repo_fixture"

# WHAT ONLY A BROWSER'S LAYOUT CAN ANSWER ABOUT THE LIBRARY'S ACTIONS (UX audit D2 and D6,
# 2026-11-02), each a property no request test sees because it asserts elements, never pixels:
#
#   - AT 375PX A LIST ROW'S ACTIONS ARE ICONS ON ONE LINE, and one row's targets never sit on the
#     next row's. They were three words stacked in a cell, so a row's Delete touched the next row's
#     Download.
#   - THE FADE IS ONLY FOR A POINTER THAT CAN HOVER. Visible by default; a fine, hovering pointer gets
#     the hover reveal, anything else sees them from the start. The probe BRANCHES ON matchMedia, the
#     way the browser decides: CI's Linux Chrome reports `hover: none`, a Mac's reports a fine
#     pointer, and both must be right.
#   - TRASH'S RESTORE IS NEVER FADED, on any pointer: it is that page's only action.
#   - THE COMMIT PAGE'S COMMIT CARRIES THE ACCENT, which `.editor-bar`'s later-layer reset cancelled.
class FilesRowActionsSystemTest < ApplicationSystemTestCase
  include GitRepoFixture

  setup do
    @root = use_fresh_share_library!
    @library = @root
    @user = sign_in_as("files-actions@example.com")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def boxes(selector)
    page.evaluate_script(<<~JS)
      [...document.querySelectorAll(#{selector.to_json})].map((el) => {
        const r = el.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, height: r.height };
      })
    JS
  end

  test "at 375px a row's actions are icons on one line, and no row's targets touch the next row's" do
    3.times { |i| create_node!(@user, node_id: SecureRandom.uuid, name: "part-#{i}.lbrn2", kind: "file", size: 5, mtime: 1_000_000_000) }
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit files_path(view: "list")
    assert_selector "table.files tbody tr", count: 3

    rows = page.evaluate_script(<<~JS)
      [...document.querySelectorAll("table.files tbody tr")].map((tr) => {
        const acts = [...tr.querySelectorAll(".row-action")].map((el) => el.getBoundingClientRect());
        return { tops: acts.map((r) => Math.round(r.top)), heights: acts.map((r) => r.height),
                 top: Math.min(...acts.map((r) => r.top)), bottom: Math.max(...acts.map((r) => r.bottom)),
                 icons: tr.querySelectorAll(".row-action .action-icon").length,
                 shownIcons: [...tr.querySelectorAll(".row-action .action-icon")].filter((s) => getComputedStyle(s).display !== "none").length,
                 shownLabels: [...tr.querySelectorAll(".row-action-label")].filter((s) => getComputedStyle(s).display !== "none").length };
      })
    JS
    rows.each_with_index do |row, i|
      assert_equal 3, row["icons"], "row #{i} does not carry Details, Download and Delete"
      assert_equal 3, row["shownIcons"], "row #{i}'s icons are not drawn at 375px"
      assert_equal 0, row["shownLabels"], "row #{i} still draws its words at 375px"
      assert_equal 1, row["tops"].uniq.size, "row #{i}'s actions wrap onto more than one line: #{row["tops"]}"
      assert row["heights"].all? { |h| h >= 24 }, "row #{i}'s targets are under 24px tall: #{row["heights"]}"
    end
    rows.each_cons(2) do |above, below|
      assert_operator below["top"] - above["bottom"], :>=, 8, "a row's actions sit on the next row's"
    end
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "the list scrolls sideways at 375px"
    assert_no_console_errors
  end

  test "row actions fade only for a pointer that can hover, and Trash's Restore never does" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.dxf", kind: "file", size: 5, mtime: 1_000_000_000)
    other = create_node!(@user, node_id: SecureRandom.uuid, name: "lid.dxf", kind: "file", size: 5, mtime: 1_000_000_000)
    hovering = page.evaluate_script("matchMedia('(hover: hover) and (pointer: fine)').matches")

    visit files_path(view: "list")
    find("h1").hover # park the pointer off every row
    opacity = page.evaluate_script("getComputedStyle(document.querySelector('table.files td.row-actions')).opacity")
    assert_equal(hovering ? "0" : "1", opacity, "a resting row's actions under hover=#{hovering}")

    FileLayer.current.delete(@user, node_id: node.node_id)
    FileLayer.current.delete(@user, node_id: other.node_id)
    visit trash_index_path
    find("h1").hover
    restore = page.evaluate_script("getComputedStyle(document.querySelector('table.files td.row-actions')).opacity")
    assert_equal "1", restore, "Trash's Restore is faded on a resting row (hover=#{hovering})"
    assert_no_console_errors
  end

  test "the commit page's Commit wears the accent" do
    root = make_repo!(name: "demo", files: { "notes.md" => "hello\n" })
    File.write(File.join(library_root, "demo", "notes.md"), "hello world\n")
    visit repo_commit_path(root.node_id)
    colours = page.evaluate_script(<<~JS)
      (() => {
        const probe = document.createElement("span");
        probe.style.background = "var(--accent)";
        document.body.appendChild(probe);
        const accent = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return { accent, commit: getComputedStyle(document.querySelector(".editor-bar input[type=submit]")).backgroundColor };
      })()
    JS
    assert_equal colours["accent"], colours["commit"], "Commit is not the page's accent"
    assert_no_console_errors
  end
end
