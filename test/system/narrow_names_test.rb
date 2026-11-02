require "application_system_test_case"

# A LONG NAME CANNOT PUSH A PAGE SIDEWAYS AT 375px (UX audit J, 2026-11-02). The audit listed these
# as static risks it had not measured: `.page-head h1` with no `overflow-wrap`, a `.btn` (nowrap)
# carrying a name, release file paths and the pickers' rows. This measures them, in shell_test.rb's
# no-sideways-scroll style, where a maker's own long name lands: the file page (its h1, its crumbs,
# and the Attach to project select, whose options ARE project names), the project page (its head
# and a release row), the project's Attach picker (its h1, a row, and the button that reads "Attach
# and move into NAME"), and a recipe table, which keeps its width and scrolls inside its panel.
#
# MUTATION-CHECKED, ONE RULE AT A TIME, and each reddens this file: `.page-head h1`'s and
# `.breadcrumb`'s `overflow-wrap`, `.btn-name` (the rule and the class on the picker's button),
# `.picker-result form`'s max-width, `.release-files .col-path`, `.attach-form`'s wrap,
# `.workspace-side`'s `minmax(0, 1fr)` track and `.lbrn-table-scroll`.
#
# THE NAME IS UNDERSCORE-JOINED ON PURPOSE. An underscore is not a line-break opportunity (UAX #14
# class AL), so eighty characters of `a_b_c` are ONE word whose min-content width is the whole name
# — the shape a slicer's or a CAD tool's export actually has. A hyphenated name (shell_test.rb's
# `a-very-long-file-name-…`) breaks at every hyphen with no CSS rule at all and so measures nothing.
#
# MEASURED AGAINST clientWidth, NOT innerWidth: CI's Linux Chrome draws a 15px classic scrollbar,
# so a page 10px too wide is still under innerWidth there and scrolls all the same.
class NarrowNamesTest < ApplicationSystemTestCase
  LONG = %w[workshop lampshade bracket revision three exported for big laser cutter final v2].join("_")

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("narrow-names@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "an eighty-character name wraps on the file page, the project page, a release row and the Attach picker" do
    assert_equal 80, LONG.length, "the fixture's name is the length the test says it is"
    project = @user.maker_projects.create!(name: LONG)
    # Rows plus the directory they claim to be, never through the port (ensure_library_folder! is a
    # real mkdir) — public_fixture.rb's make_project_folder!, inline.
    folder = project_folder_rows!(@user, project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    # AT THE LIBRARY ROOT, so the picker predicts a move and its button carries the project's name.
    file = create_node!(@user, node_id: SecureRandom.uuid, kind: "file", name: "#{LONG}.stl")
    release = project.releases.create!(user: @user, version: "v1.0", published_at: Time.current)
    release.files.create!(user: @user, node_id: file.node_id, name: file.name, size: 4096,
                          path: "#{LONG}/#{LONG}/#{file.name}",
                          content_token: FileLayer.current.stat(@user, node_id: file.node_id).content_token)

    # CDP, not resize_to: headless Chrome will not make a WINDOW narrower than 500px (shell_test.rb).
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)

    visit file_path(file.node_id)
    assert_selector ".page-head h1", text: LONG
    assert_fits ".page-head h1", "the file page's h1"
    assert_no_sideways_scroll "the file page"

    visit project_path(project)
    assert_selector ".project-head h1", text: LONG
    assert_fits ".project-head h1", "the project page's h1"
    assert_selector ".releases-panel details.release[open] .release-files td.col-path", text: release.files.first.path
    assert_fits ".release-files td.col-path", "a release row's path", within: ".releases-panel"
    assert_no_sideways_scroll "the project page"

    visit new_project_attachment_path(project)
    assert_selector ".page-head h1", text: "Attach a file to #{LONG}"
    assert_fits ".page-head h1", "the Attach picker's h1"
    assert_selector ".picker-result .picker-name", text: file.name
    assert_fits ".picker-result .picker-name", "the picker row's name"
    assert_selector ".picker-result .btn", text: "Attach and move into #{LONG}"
    assert_fits ".picker-result .btn", "the picker's Attach and move into NAME button", within: ".picker-result"
    assert_no_sideways_scroll "the Attach picker"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  # THE RECIPE TABLE KEEPS ITS WIDTH AND SCROLLS INSIDE ITS PANEL (design-system.md rule 11): its
  # headers are nowrap, and a layer name the maker chose can be one unbroken run. The metadata is
  # written by hand, as settings_panel_test.rb does, and the preview row has no asset, so the page
  # draws the panel and no picture (nothing for the browser to fetch and log a 404 about).
  test "a recipe table with a long layer name scrolls inside its panel, not the page" do
    name = "cut.lbrn2"
    node = create_node!(@user, node_id: SecureRandom.uuid, name:, kind: "file", storage_path: name,
                               content_hash: SecureRandom.hex(8))
    token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
    @user.maker_previews.create!(node_id: node.node_id, version_id: token, kind: "thumbnail", status: "ready",
                                 metadata: { "app_version" => "1.7.03",
                                             "layers" => [ { "index" => 1, "name" => LONG, "color" => "#0000ff",
                                                             "mode" => "Line", "speed" => 100, "power_max" => 60,
                                                             "power_min" => 20, "passes" => 2 } ] })

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit file_path(node.node_id)
    assert_selector ".lbrn-settings .lbrn-table-scroll .lbrn-layers td", text: LONG
    # `overflowX === 'auto'` is what makes this ask about SCROLLING: an `overflow: visible` box whose
    # content spills also has scrollWidth > clientWidth, and the message would lie.
    scrolls = page.evaluate_script(
      "(function () { var w = document.querySelector('.lbrn-table-scroll'); return getComputedStyle(w).overflowX === 'auto' && w.scrollWidth > w.clientWidth })()")
    # Both ways this goes false are failures: the column grew to the table instead of letting it
    # scroll (the implicit auto track `.workspace-side` had), or the fixture stopped outgrowing it.
    assert scrolls, "the recipe table does not scroll inside its panel at 375px: the panel grew to fit it, or the fixture's layer name no longer outgrows it"
    assert_fits ".lbrn-settings", "the recipe panel"
    assert_no_sideways_scroll "the recipe file's page"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  private

  def assert_no_sideways_scroll(label)
    scroll, client = page.evaluate_script("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
    assert_operator scroll, :<=, client, "#{label} scrolls sideways at 375px (scrollWidth #{scroll}, clientWidth #{client})"
  end

  # NOT WIDER THAN ITS CONTAINER, measured two ways, because either alone can pass over the bug: the
  # element's own text must not overflow its box (scrollWidth over clientWidth), and the box must
  # not run past its parent's, or `within:`'s (a flex item or a table cell whose min-content is the
  # whole name grows past its line, and a cell's own row grows with it).
  def assert_fits(selector, label, within: nil)
    own, box, right, parent_right = page.evaluate_script(<<~JS)
      (function () {
        var el = document.querySelector(#{selector.to_json});
        return [el.scrollWidth, el.clientWidth, el.getBoundingClientRect().right,
                (#{within.to_json} ? el.closest(#{within.to_json}) : el.parentElement).getBoundingClientRect().right];
      })()
    JS
    assert_operator own, :<=, box, "#{label}'s text overflows its own box at 375px (scrollWidth #{own}, clientWidth #{box})"
    assert_operator right, :<=, parent_right + 0.5,
                    "#{label} is wider than its container at 375px (right edge #{right}, container's #{parent_right})"
  end
end
