require "application_system_test_case"

# CLICK-THROUGH FOLDER PANELS (2026-11-24; docs/superpowers/specs/2026-11-24-project-panel-click-through-design.md
# §1). A folder panel shows one folder at a time: a folder tile opens inside the panel, the path bar
# goes back up, and the URL records where each panel is (`?at[<panel id>]=<node id>`), so Back steps
# out of a folder and a reload opens the page where it was.
#
# ONLY A BROWSER CAN SEE ANY OF THIS. project_attachments_test.rb proves the links carry the frame
# and the action, and that a frame request answers one panel; whether Turbo then swaps that panel
# alone, advances the URL and walks it back on Back are facts about a running page. The frame
# answer renders in this app's layouts/turbo_rails/frame, whose real <head> is what lets Turbo record
# the promoted visit — without it Back shows the wrong folder (model_page_test.rb's lesson).
#
# ROWS ONLY, as in repo_browser_test.rb: `project_folder_rows!` and bare `nodes` rows, so nothing
# here calls the port and the file reads the same on all three backends.
class ProjectPanelNavigationTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("panel-navigation@example.com")
    @project = @user.maker_projects.create!(name: "Case")
    @folder = project_folder_rows!(@user, @project)
    out = dir!("d-out", "out", @folder.node_id)
    itx = dir!("d-itx", "itx", out.node_id)
    jig = dir!("d-jig", "jig", out.node_id)
    docs = dir!("d-docs", "docs", @folder.node_id)
    sub = dir!("d-sub", "sub", docs.node_id)
    file!("foot.stl", itx.node_id)
    file!("clamp.stl", jig.node_id)
    file!("top.stl", out.node_id)
    file!("manual.pdf", docs.node_id)
    file!("spec.pdf", sub.node_id)
  end

  def dir!(id, name, parent) = @user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent)

  # An attribute selector, because the id carries a colon (repo_browser_test.rb's own note).
  def panel_for(id) = "section.folder-panel[id='folder:#{id}']"

  # WHAT A REDRAWN PAGE CANNOT KEEP: a mark on the OTHER panel's element, which a Turbo frame swap of
  # this panel leaves alone and a page render replaces, and a value on the window, which a full
  # reload throws away.
  def mark_the_page
    page.execute_script(<<~JS)
      document.querySelector("#{panel_for('d-docs')}").dataset.marker = "kept"
      window.panelMark = "kept"
    JS
  end

  # WAIT ON THE PAGE, THEN LOOK INSIDE THE PANEL. A frame swap replaces the section and Back restores
  # a snapshot of the whole body, so a `within` resolved before either lands holds a DETACHED section
  # and waits on it forever. A page-level selector is resolved afresh on every retry.
  #
  # AND WAIT FOR THE FRAME TO FINISH, not merely for its new markup: Turbo puts the new contents in
  # the frame and THEN awaits repaints before it lets go of the request, setting `complete` when it
  # has. A click inside that window cancels the request Turbo is still finishing, and Chrome logs an
  # uncaught "signal is aborted without reason" (measured: the next click came about 30 ms early).
  # A person cannot click that fast twice; a test can. Only before a click: a frame restored from
  # Back's snapshot need not carry the attribute, and nothing clicks after it.
  def assert_open(folder, panel: "d-out", before_a_click: true)
    if folder
      assert_selector "#{panel_for(panel)} .folder-path-here", text: folder
    else
      assert_no_selector "#{panel_for(panel)} .folder-path"
    end
    assert_selector "turbo-frame[id='frame-folder-#{panel}'][complete]", visible: :all if before_a_click
  end

  def assert_page_was_not_redrawn
    assert_equal "kept", page.evaluate_script("window.panelMark || null"), "the page was reloaded"
    assert_equal "kept", page.evaluate_script("document.querySelector(\"#{panel_for('d-docs')}\").dataset.marker || null"),
                 "the other panel was redrawn"
  end

  test "a folder tile opens inside its panel, the path goes back up, and Back steps out" do
    visit project_path(@project)
    within(panel_for("d-out")) do
      assert_selector ".attachment-tile .grid-name", text: "top.stl"
      assert_no_selector ".folder-path"
    end
    mark_the_page

    within(panel_for("d-out")) { find(".folder-tile a", text: "itx").click }
    assert_open "itx"
    within(panel_for("d-out")) do
      assert_selector ".attachment-tile .grid-name", text: "foot.stl"
      assert_no_selector ".attachment-tile .grid-name", text: "top.stl"
      # THE HEAD STILL DESCRIBES THE PANEL'S OWN FOLDER, and its view buttons carry where it is.
      assert_selector ".panel-head h2", text: "out"
      assert_selector ".view-toggle input[name='at[d-out]'][value='d-itx']", visible: :all, count: 3
    end
    assert_current_path project_path(@project, at: { "d-out" => "d-itx" })
    assert_page_was_not_redrawn

    within(panel_for("d-out")) { find("nav.folder-path a", text: "out").click }
    assert_open nil
    within(panel_for("d-out")) { assert_selector ".attachment-tile .grid-name", text: "top.stl" }
    assert_current_path project_path(@project)
    assert_page_was_not_redrawn

    page.go_back
    assert_open "itx", before_a_click: false
    within(panel_for("d-out")) { assert_selector ".attachment-tile .grid-name", text: "foot.stl" }
    assert_current_path project_path(@project, at: { "d-out" => "d-itx" })
    assert_no_console_errors
  end

  # EVERY OTHER PANEL'S FOLDER COMES FROM THE PAGE'S URL AT THE CLICK (panel_at_controller.js), never
  # from the render that drew the link. A frame swap redraws its own panel alone, so docs's tile still
  # carries the `at` the page loaded with: before the controller, opening `sub` after `itx` wrote
  # `?at[d-docs]=d-sub` alone, and a reload put out back at its own folder. A view button is the same
  # case with a form: docs's buttons below were drawn by the reload, before out moved to `jig`, and
  # the panel the switch's redirect redraws shows which `at` that redirect carried.
  test "two panels keep each other's open folder through a click, a reload and a view switch" do
    visit project_path(@project)
    within(panel_for("d-out")) { find(".folder-tile a", text: "itx").click }
    assert_open "itx"
    within(panel_for("d-docs")) { find(".folder-tile a", text: "sub").click }
    assert_open "sub", panel: "d-docs"
    assert_current_path project_path(@project, at: { "d-out" => "d-itx", "d-docs" => "d-sub" })
    assert_open "itx", before_a_click: false
    within(panel_for("d-out")) { assert_selector ".attachment-tile .grid-name", text: "foot.stl" }
    within(panel_for("d-docs")) { assert_selector ".attachment-tile .grid-name", text: "spec.pdf" }

    visit current_url
    assert_open "itx", before_a_click: false
    assert_open "sub", panel: "d-docs", before_a_click: false
    assert_current_path project_path(@project, at: { "d-out" => "d-itx", "d-docs" => "d-sub" })

    # A PATH-BAR LINK TO THE PANEL'S OWN FOLDER DROPS ITS OWN ENTRY AND KEEPS THE OTHER'S.
    within(panel_for("d-out")) { find("nav.folder-path a", text: "out").click }
    assert_open nil
    assert_current_path project_path(@project, at: { "d-docs" => "d-sub" })
    within(panel_for("d-out")) { find(".folder-tile a", text: "jig").click }
    assert_open "jig"
    assert_current_path project_path(@project, at: { "d-out" => "d-jig", "d-docs" => "d-sub" })

    within(panel_for("d-docs")) { click_button "List" }
    assert_selector "#{panel_for('d-docs')} table.project-files", text: "spec.pdf"
    within(panel_for("d-docs")) do
      assert_selector ".folder-path-here", text: "sub"
      # out's folder AS THE URL HAS IT, not the `itx` these buttons were drawn with.
      assert_selector ".view-toggle input[name='at[d-out]'][value='d-jig']", visible: :all, count: 3
      assert_selector ".view-toggle input[name='at[d-docs]'][value='d-sub']", visible: :all, count: 3
    end
    within(panel_for("d-out")) do
      assert_selector ".folder-path-here", text: "jig"
      assert_selector ".attachment-tile .grid-name", text: "clamp.stl"
    end
    assert_current_path project_path(@project, at: { "d-out" => "d-jig", "d-docs" => "d-sub" })
    assert_no_console_errors
  end

  # EVERY OTHER LINK IN THE PANEL STILL LEAVES THE PAGE: the frame is `_top`, and only folder links
  # opt into it. A file tile that navigated the frame instead would swap the panel for nothing — the
  # file page holds no `frame-folder-` frame — and Turbo would log a missing-frame error.
  test "a file tile in an opened folder opens the file's page" do
    visit project_path(@project, at: { "d-out" => "d-itx" })
    foot = @user.nodes.find_by!(name: "foot.stl")
    within(panel_for("d-out")) { find(".attachment-tile a.file-cell", text: "foot.stl").click }
    assert_current_path file_path(foot.node_id)
    assert_no_console_errors
  end
end
