require "application_system_test_case"

# THE FIND BOX AND THE INDEX OF FILES (the Shop manual spec §9; figure_find_controller.js and
# files_index_controller.js). The request tests (figure_numbers_test.rb) pin what the server draws;
# this drives what only a browser does: typing filters the index in place, Enter goes to a figure —
# a name to the first match's, a number to that figure — and marks it selected, Escape puts it all
# back, an index entry's number goes to its figure and hands it the focus, a figure in the closed
# Backups group is opened to, and at 375px the column is a sheet that gets out of the way.
#
# CATALOG ROWS ONLY, so nothing calls the port and the file reads the same on all three backends.
# The files carry an extension no renderer claims, so the page has no thumbnail to wait for.
class FigureFindTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("figures@example.com")
    @project = @user.maker_projects.create!(name: "Manual", status: "active", autofile: false)
    folder = project_folder_rows!(@user, @project)
    @laser = dir!("laser", folder)
    @design = dir!("design", folder)
    @files = {}
    # laser: a stack of two versions (one figure), three parts, and a backup that stacks with nothing,
    # so it sits in the Files panel's closed Backups group.
    %w[hex\ tiles\ v1.zzz hex\ tiles\ v2.zzz robber\ holder.zzz game\ top.zzz number\ tokens.zzz
       old\ jig_backup.lbrn2].each { |name| file!(name, @laser) }
    # "desktop" sorts before "top plate" and holds "top" mid-word: Enter on "top" must still take the
    # name that STARTS with it.
    %w[box\ plan.zzz harbor\ tokens.zzz tile\ nesting.zzz desktop.zzz top\ plate.zzz].each { |name| file!(name, @design) }
    file!("notes.zzz", folder)
    # ONE WORD EIGHTY CHARACTERS LONG (narrow_names_test.rb's reason): an underscore is no break
    # opportunity, so the index entry must end it in an ellipsis or push a phone's page sideways.
    file!("#{%w[workshop lampshade bracket revision three exported for big laser cutter final cut].join("_")}.zzz", folder)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: "d-#{name}", name:, kind: "dir", parent_node_id: parent.node_id, mtime: 1, size: 0)

  def file!(name, parent)
    @files[name] = @user.nodes.create!(node_id: "f-#{@files.size}", name:, kind: "file", parent_node_id: parent.node_id,
                                       size: 100, mtime: 1_700_000_000_000_000_000 + @files.size)
  end

  def box = find("#column .figure-find input[type=search]")
  def shown_entries = all("#project-index .files-index-entry", visible: true).map { |li| li.find("a.files-index-name").text }
  def selected = all("[data-fig][aria-current='true']")

  # IN THE WINDOW, ONCE THE SCROLL HAS LANDED: the jump scrolls smoothly, so this asks for a moment.
  def assert_in_view(element, message)
    landed = false
    40.times do
      landed = page.evaluate_script(<<~JS, element)
        (function (el) { var r = el.getBoundingClientRect(); return r.top >= 0 && r.bottom <= window.innerHeight; })(arguments[0])
      JS
      break if landed

      sleep 0.05
    end
    assert landed, message
  end

  test "typing filters the index, Enter goes to the figure, and Escape puts it all back" do
    visit project_path(@project)
    total = all("#project-index .files-index-entry").size
    assert_equal 13, total

    # A NAME: the index narrows in place as it is typed, and says how many match.
    box.fill_in(with: "hex")
    assert_equal [ "hex tiles v1.zzz", "hex tiles v2.zzz" ], shown_entries
    assert_selector "#column .figure-find-status", text: "2 of 13 files"
    # Enter goes to the first match's figure: the stack the two versions are, one figure.
    box.send_keys(:enter)
    assert_selector ".stack-item[data-fig][aria-current='true']", count: 1
    stack = selected.sole
    assert_in_view stack, "the figure gone to is in the window"
    assert_selector "#column .figure-find-status", text: /hex tiles.*Fig\. #{stack['data-fig']}/
    assert_equal "hex", box.value, "the box keeps what was typed, and the focus"
    assert page.evaluate_script("document.activeElement.matches('#column .figure-find input')"), "Enter leaves the focus in the box"

    # THE BEST NAME: one that starts with what was typed, before one that only holds it.
    box.fill_in(with: "top")
    assert_equal [ "desktop.zzz", "game top.zzz", "top plate.zzz" ], shown_entries
    box.send_keys(:enter)
    assert_selector "#column .figure-find-status", text: /\Atop plate\.zzz, Fig\. \d+\z/

    # A NUMBER: straight to that figure.
    box.fill_in(with: "")
    box.send_keys("3", :enter)
    assert_selector "[data-fig='3'][aria-current='true']", count: 1
    assert_equal 1, selected.size, "one selected figure on the page"
    assert_in_view selected.sole, "Fig. 3 is in the window"

    # ESCAPE: the box empties, the whole index is back and nothing is selected.
    box.send_keys(:escape)
    assert_equal "", box.value
    assert_equal total, shown_entries.size
    assert_empty selected
    assert_no_selector "#column .figure-find-status", visible: true
    assert_no_console_errors
  end

  test "an entry's number goes to its figure, opening the Backups group it sits in" do
    visit project_path(@project)
    assert_selector "#attachments details:not([open]) > summary", text: /backups/i
    entry = find("#project-index .files-index-entry", text: "old jig_backup.lbrn2")
    number = entry["data-entry-fig"]
    entry.find("a.files-index-fig").click
    assert_selector "#attachments details[open] [data-fig='#{number}'][aria-current='true']"
    figure = selected.sole
    assert_in_view figure, "the backup's figure is in the window"
    focused = page.evaluate_script("document.activeElement.closest('[data-fig]')?.getAttribute('data-fig')")
    assert_equal number, focused, "the figure's own link takes the focus, as following an anchor does"
    assert_no_console_errors
  end

  # A FIGURE'S DISC LIVES INSIDE ITS `.thumb` (files/_thumb's `fig`), and the thumbnail poll empties
  # that box when a picture or a badge lands. thumbs_controller.js#clear keeps the disc; this lands
  # both on a figure the way the poll does, through the controller itself.
  test "a picture or a badge landing in a figure's frame keeps its number" do
    visit project_path(@project)
    cell = find("#attachments .attachment-tile[data-fig] a.file-cell", match: :first)
    number = cell.find(:xpath, "..")["data-fig"]
    page.execute_script(<<~JS, cell.native)
      const cell = arguments[0]
      const thumbs = window.Stimulus.getControllerForElementAndIdentifier(cell.closest("[data-controller~='thumbs']"), "thumbs")
      thumbs.setIcon(cell, { failed: true })
    JS
    assert_selector "[data-fig='#{number}'] .thumb > .thumb-icon"
    assert_selector "[data-fig='#{number}'] .thumb > .fig-num", text: number
    page.execute_script(<<~JS, cell.native)
      const cell = arguments[0]
      cell.querySelector(".thumb-icon").remove()
      const thumbs = window.Stimulus.getControllerForElementAndIdentifier(cell.closest("[data-controller~='thumbs']"), "thumbs")
      thumbs.setImage(cell, "data:image/gif;base64,R0lGODlhAQABAAAAACw=")
    JS
    assert_selector "[data-fig='#{number}'] .thumb > img"
    assert_selector "[data-fig='#{number}'] .thumb > .fig-num", text: number
  end

  test "at 375px the column is a sheet the find box closes on its way to a figure, and nothing scrolls sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit project_path(@project)
    scroll, client = page.evaluate_script("[document.documentElement.scrollWidth, document.documentElement.clientWidth]")
    assert_operator scroll, :<=, client, "the project page with its index scrolls sideways at 375px (#{scroll} > #{client})"

    find(".strip-contents").click
    assert_selector "body.column-open"
    box.fill_in(with: "tile nesting")
    box.send_keys(:enter)
    assert_no_selector "body.column-open"
    assert_in_view selected.sole, "the figure is in the window, not under the sheet"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
