require "application_system_test_case"

# A PANEL'S VIEW SWITCHES IN PLACE (2026-11-16, the owner's report: "there shouldn't be a whole page
# reload to switch one panel's mode"). The Tiles / List / Browser buttons in a panel's head are a
# WRITE (Projects::PanelsController#update's `view` branch), and the door answered it the way every
# write on this page is answered: a redirect back to the page. So one press redrew every panel,
# sent every browser on the page back to its top folder and moved the window to the panel's anchor.
#
# The door now redirects a press made on the page to the page NAMING THE PANEL, and the page answers
# Turbo with a stream that replaces that one section (ProjectsController#show). Nothing else in the
# document is touched. With no JavaScript the same form still lands on the page.
#
# ONLY A BROWSER CAN SEE ANY OF THIS. project_panels_test.rb proves the redirect and the stream are
# what they should be; whether Turbo follows the one into the other, whether the rest of the page
# is the same elements afterwards, and where the focus and the window end up are facts about a
# running page.
#
# ROWS ONLY, as in repo_browser_test.rb: `project_folder_rows!` and bare `nodes` rows, so nothing
# here calls the port and the file reads the same on all three backends.
class PanelViewSwitchTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("panel-view@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
    @folder = project_folder_rows!(@user, @project)

    @firmware = dir!("firmware", @folder.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, @firmware.node_id) # a repository: its panel opens in the browser
    @src = dir!("src", @firmware.node_id)
    file!("main.c", @firmware.node_id)
    file!("led.c", @src.node_id)

    @models = dir!("models", @folder.node_id)
    @base = file!("base.stl", @models.node_id)
    file!("lid.stl", @models.node_id)

    file!("notes.txt", @folder.node_id) # loose, so the Files panel has a group to draw
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent)

  # An attribute selector, because the id carries a colon (repo_browser_test.rb's own note).
  def panel_for(dir) = "section.folder-panel[id='folder:#{dir.node_id}']"
  FILES = "section#attachments".freeze

  # WHAT A REDRAWN PAGE CANNOT KEEP. A full load throws the script context away, so the probe is
  # gone. A Turbo visit keeps the context, fires `turbo:visit` and swaps the body, so the count moves
  # and a panel that was on the page is no longer in the document. A stream does neither: `kept`
  # holds the elements that must still be the ones in the document afterwards.
  def watch_the_page(keep:)
    page.execute_script(<<~JS, *keep.map { |css| find(css) })
      window.panelProbe = { visits: 0, streams: 0, kept: Array.from(arguments) }
      document.addEventListener("turbo:visit", () => window.panelProbe.visits++)
      document.addEventListener("turbo:before-stream-render", () => window.panelProbe.streams++)
    JS
  end

  def probe(expression) = page.evaluate_script("window.panelProbe ? window.panelProbe.#{expression} : null")

  def assert_page_was_not_redrawn
    assert_equal 0, probe("visits"), "the page was visited again (nil: it was reloaded, the script context is gone)"
    assert probe("kept.every((element) => element.isConnected)"), "a panel that should be untouched is a new element"
  end

  def recent_names = all("#{FILES} .recent-files .attachment-tile .grid-name").map(&:text)

  # Turbo moves the focus a frame AFTER it renders a stream, so this waits for it; nothing a
  # selector can wait on tells a focused button from the same button unfocused.
  def assert_focused(element, message)
    focused = false
    40.times do
      break if (focused = page.evaluate_script("document.activeElement === arguments[0]", element))

      sleep 0.05
    end
    assert focused, message
  end

  test "switching one panel's view replaces that panel and leaves the rest of the page as it was" do
    visit project_path(@project)

    # STATE A REDRAW WOULD LOSE: the firmware browser, one folder down.
    within(panel_for(@firmware)) do
      find(".filechooser-row", text: "src").click
      assert_selector ".filechooser--inline .filechooser-col", count: 2
    end

    # THE BUTTON'S PLACE IN THE WINDOW, mid-screen, so the old answer (land on the panel's anchor,
    # its top at the top of the window) cannot coincide with it. ROOM BELOW FIRST: this panel is the
    # last tall thing on the page and its list is shorter than its tiles, so without the room the
    # page shrinks under a window already scrolled to its end and the browser pulls the window up
    # by the difference (measured: 3px). That is the page getting shorter, not the switch moving it.
    page.execute_script("document.querySelector('main').style.paddingBottom = '1200px'")
    list = within(panel_for(@models)) { find(".view-toggle button", text: "List") }
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", list)
    top_before = page.evaluate_script("arguments[0].getBoundingClientRect().top", list)
    assert_operator top_before, :>, 150, "the button must sit mid-window for the comparison below to mean anything"
    assert_operator page.evaluate_script("window.scrollY"), :>, 0, "the page must be scrolled, or it cannot be seen to move"
    watch_the_page(keep: [ panel_for(@firmware), FILES ])

    list.click

    within(panel_for(@models)) do
      assert_selector "table.project-files td.col-name", text: "base.stl"
      assert_no_selector ".attachments-grid .attachment-tile"
      assert_selector ".view-toggle button.active[aria-pressed='true']", text: "List"
      assert_selector ".view-toggle button[aria-pressed='false']", text: "Tiles"
    end

    assert_page_was_not_redrawn
    assert_equal 1, probe("streams"), "one stream, for the one panel: tiles to list changes nothing else"
    within(panel_for(@firmware)) do
      assert_selector ".filechooser--inline .filechooser-col", count: 2
      assert_selector ".filechooser-col:last-child .filechooser-row", text: "led.c"
    end

    # THE WINDOW DID NOT MOVE: the button that was pressed is where it was.
    pressed = within(panel_for(@models)) { find(".view-toggle button", text: "List") }
    top_after = page.evaluate_script("arguments[0].getBoundingClientRect().top", pressed)
    assert_in_delta top_before, top_after, 2, "the window moved under the button"
    # AND IT HAS THE FOCUS, so the keyboard carries on from the control it just pressed.
    assert_focused pressed, "focus left the pressed button"

    assert_current_path project_path(@project)
    assert_equal "list", @project.reload.panels.dig("views", "folder:#{@models.node_id}")
    assert_no_console_errors
  end

  # THE NEW SECTION IS AN ORDINARY ONE: its links leave the page, and its own buttons switch it
  # again in place, because the stream's copy of the form asks the same way the page's did.
  test "a panel that was switched switches again in place, and its files still open their pages" do
    visit project_path(@project)
    watch_the_page(keep: [ panel_for(@firmware), FILES ])

    within(panel_for(@models)) { click_on "List" }
    within(panel_for(@models)) do
      assert_selector "table.project-files td.col-name", text: "base.stl"
      click_on "Tiles"
    end
    within(panel_for(@models)) do
      assert_selector ".attachments-grid .attachment-tile", count: 2
      assert_no_selector "table.project-files"
    end
    assert_page_was_not_redrawn
    assert_equal 2, probe("streams")
    assert_equal "tiles", @project.reload.panels.dig("views", "folder:#{@models.node_id}")

    within(panel_for(@models)) { find(".attachment-tile a.file-cell", text: "base.stl").click }
    assert_current_path file_path(@base.node_id)
    assert_no_console_errors
  end

  # INTO THE BROWSER AND OUT OF IT. The columns are built by a controller that connects when the
  # new markup lands, so they are the proof the stream's section is live. AND THE FILES PANEL
  # FOLLOWS: its "Recently changed" row leaves out a browsed folder's files
  # (ProjectsController#dirs_without_tiles), so this is the one switch that changes a second panel,
  # and the door asks for both. Without that the row would name files the page now keeps closed.
  test "switching a folder into the browser mounts it and takes its files out of Recently changed" do
    visit project_path(@project)
    assert_equal %w[base.stl lid.stl notes.txt], recent_names.sort
    watch_the_page(keep: [ panel_for(@firmware) ])

    within(panel_for(@models)) { click_on "Browser" }
    within(panel_for(@models)) do
      assert_selector ".filechooser--inline .filechooser-col", count: 1
      assert_selector ".filechooser-row", text: "base.stl"
      assert_no_selector ".attachments-grid .attachment-tile"
    end
    assert_selector "#{FILES} .recent-files .attachment-tile", count: 1
    assert_equal %w[notes.txt], recent_names
    assert_equal 2, probe("streams"), "the panel and the Files panel"

    within(panel_for(@models)) { click_on "Tiles" }
    within(panel_for(@models)) { assert_selector ".attachments-grid .attachment-tile", count: 2 }
    assert_selector "#{FILES} .recent-files .attachment-tile", count: 3
    assert_equal %w[base.stl lid.stl notes.txt], recent_names.sort

    assert_page_was_not_redrawn
    assert_equal "tiles", @project.reload.panels.dig("views", "folder:#{@models.node_id}")
    assert_no_console_errors
  end

  # THE FILES PANEL'S OWN TWO VIEWS, the second place the buttons are drawn.
  test "the Files panel switches in place too" do
    visit project_path(@project)
    watch_the_page(keep: [ panel_for(@firmware), panel_for(@models) ])

    within(FILES) do
      assert_selector ".attachments-grid .attachment-tile", text: "notes.txt"
      click_on "List"
    end
    within(FILES) do
      assert_selector "table.project-files td.col-name", text: "notes.txt"
      assert_selector ".view-toggle button.active[aria-pressed='true']", text: "List"
    end

    assert_page_was_not_redrawn
    assert_equal 1, probe("streams")
    assert_equal "list", @project.reload.panels.dig("views", "attachments")
    assert_no_console_errors
  end
end
