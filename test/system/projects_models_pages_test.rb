require "application_system_test_case"

# PR 3's behaviour only a browser shows: the build-log composer (Lexxy inside a closed details)
# takes an entry; Detach is invisible until the tile is hovered and then works; a task moved to
# Done gets the filled mark through the Turbo Stream replace; the print composer logs a print.
#
# MUTATION-CHECKED, one per test (this directory's README requires it, and §15 asks that a guard be
# watched to fail before it is trusted):
#   - Rendering the build-log composer open (`<details class="composer" open>` in
#     projects/_build_log.html.erb) reddens test 1 at its closed-before-the-click assertion:
#     `expected not to find visible css ".build-log-panel details.composer[open]", found 1 match:
#     "Add entry"`.
#   - Deleting `.attachment-tile:hover .tile-meta, .attachment-tile:focus-within .tile-meta
#     { opacity: 1 }` from pages/projects.css reddens test 2 AFTER the hover: `expected to find
#     visible css ".attachment-tile .tile-detach" but there were no matches. Also found "", which
#     matched the selector but not all filters.` The hidden-before-hover assertion passes in that
#     run, so it is not vacuous either: Selenium really does report an `opacity: 0` control as not
#     displayed, and it is this rule that reveals it.
#   - Dropping the modifier from `_task.html.erb`'s mark (`class="task-state"` alone) reddens
#     test 3 after the Turbo Stream replace: `expected to find css "#project-tasks
#     .tasks-group.status-done .task-row .task-state--done" but there were no matches`.
#   - Rendering the print composer open reddens test 4, INDIRECTLY and worth knowing: the click on
#     the summary then TOGGLES IT SHUT, so the failure is `Capybara::ElementNotFound: Unable to
#     find visible field "print_run[printer]"` rather than a closed-state assertion. The test does
#     depend on the composer starting closed; it just reports it one line later than test 1 does.
#   - Deleting `.lexxy-content { color: inherit; }` from vendor-overrides.css reddens test 5:
#     `lexxy-content.css's own colour survived: oklch(0.2 0 0) inside a rgb(228, 231, 236) parent`
#     — the vendor near-black is back inside the page's light text (2026-09-04).
#   - Dropping the write from `Projects::PanelsController#update_view` (so the PATCH still
#     redirects to the panel's anchor but `panels["views"]` is never merged) reddens test 6 at its
#     first assertion after the click: `expected to find css "table.project-files" but there were
#     no matches`. That is the mutation the 2026-09-08 rewrite of this test replaced the old one
#     with — the old bullet named `ProjectsController#resolve_project_view`, a method the folder
#     panels deleted along with the page-wide `project_view` cookie it wrote.
class ProjectsModelsPagesTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("pmp@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "a build-log entry goes through the closed composer" do
    visit project_path(@project)
    assert_no_selector ".build-log-panel details.composer[open]"
    find(".build-log-panel details.composer > summary", text: "Add entry").click
    assert_selector ".build-log-panel details.composer[open] lexxy-editor", visible: true
    find(".build-log-panel lexxy-editor [contenteditable='true']").click
    find(".build-log-panel lexxy-editor [contenteditable='true']").send_keys("Shade printed in PETG.")
    click_on "Add entry"
    assert_selector ".log-timeline .log-entry .entry-body", text: "Shade printed in PETG."
    assert_no_console_errors
  end

  test "Detach is hidden until the tile is hovered, then detaches" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "base.stl", kind: "file")
    @project.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
    visit project_path(@project)
    tile = find(".attachments-panel .attachment-tile", text: "base.stl")
    # Hidden-until-hover only where hover exists. Under (hover: none) — a touch device, or a headless
    # Linux Chrome that reports no pointer, which is what CI runs — the stylesheet keeps the control
    # visible from the start ON PURPOSE, so asserting it hidden there asserts the wrong behaviour.
    # Found by CI, not locally: this Mac's Chrome reports hover: hover, CI's Linux Chrome does not.
    if page.evaluate_script("matchMedia('(hover: hover)').matches")
      assert_no_selector ".attachment-tile .tile-detach", visible: true
      tile.hover
    end
    assert_selector ".attachment-tile .tile-detach", visible: true
    accept_confirm { tile.find(".tile-detach").click }
    assert_no_selector ".attachments-panel .attachment-tile", text: "base.stl"
    assert_no_console_errors
  end

  test "moving a task to Done fills its mark" do
    @project.tasks.create!(user: @user, title: "Wire the LED", status: "todo", position: 0)
    visit project_path(@project)
    within("#project-tasks .tasks-group.status-todo") { click_on "Done" }
    assert_selector "#project-tasks .tasks-group.status-done .task-row .task-state--done"
    assert_no_selector "#project-tasks .tasks-group.status-todo .task-row"
    assert_no_console_errors
  end

  test "a print is logged through the closed composer" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "benchy.stl", kind: "file")
    model = @user.maker_models.create!(title: "Benchy", print_status: "want_to_print")
    model.file_attachments.create!(user: @user, node_id: node.node_id, role: "model")
    visit model_path(model)
    find(".print-log details.composer > summary", text: "Log a print").click
    fill_in "print_run[printer]", with: "Prusa MK4"
    click_on "Log a print"
    assert_selector ".print-log .print-run", text: "Prusa MK4"
    assert_no_console_errors
  end

  # The rendered rich text (`div.lexxy-content`, action_text's content layout) arrives painted by
  # lexxy-content.css in its own near-black, `oklch(0.2 0 0)` — on the dark theme that is black on
  # black, and a build-log entry read as almost empty. Found on the Home hero's "Latest entry"
  # (stage 2, S2-1, 2026-09-04), present on this page since stage 1; vendor-overrides.css now makes
  # `.lexxy-content` inherit. Only a browser can see a computed colour, hence a system test; it
  # asserts the rendered text takes its PARENT's colour, so it holds in either theme.
  test "a rendered entry takes the page's text colour, not lexxy's own" do
    @project.build_log_entries.create!(user: @user, body: "Shade printed in translucent PETG.",
                                       logged_at: Time.current)
    visit project_path(@project)
    assert_selector ".log-timeline .log-entry .entry-body .lexxy-content", text: "Shade printed"
    colours = page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector(".log-entry .entry-body .lexxy-content");
               return [getComputedStyle(c).color, getComputedStyle(c.parentElement).color]; })()
    JS
    assert_equal colours[1], colours[0],
                 "lexxy-content.css's own colour survived: #{colours[0]} inside a #{colours[1]} parent"
    assert_no_console_errors
  end

  # THE FILES PANEL'S OWN VIEW TOGGLE (stage 3, S3-1; rebuilt 2026-09-08 for the folder panels) — a
  # real click, so this is the one place that proves the control in the panel head works end to end.
  #
  # IT IS A `button_to` NOW, NOT A LINK, AND THE CHOICE LIVES ON THE PROJECT ROW. Until the folder
  # panels landed the toggle was an `?view=list` link and the answer was remembered in a page-wide
  # `project_view` COOKIE that ProjectsController#resolve_project_view read and rewrote; every panel
  # on the page shared it. A view is a WRITE now — three buttons per panel, each POSTing
  # `view[<key>]=<value>` to Projects::PanelsController#update_view, which merges the pair into
  # `panels["views"]` under that panel's own key and redirects to its anchor. So "remembers the
  # choice" is a database assertion here, not a cookie one, and it is made directly on the row as
  # well as through a second visit: a redirect that rendered the list for one request while writing
  # nothing would satisfy the render assertions alone.
  #
  # THE FILES PANEL'S KEY IS `attachments`, the folder ROOT — the loose file below sits there, not
  # in a subfolder, so this drives the panel that has no folder key at all. A depth-one subfolder's
  # own toggle (including its third value, the browser, which Files does not offer) is
  # repo_browser_test.rb's.
  test "the Files panel's List button switches it and the choice is stored on the project" do
    folder = project_folder_rows!(@user, @project)
    create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.stl", kind: "file",
                parent_node_id: folder.node_id)
    visit project_path(@project)
    assert_selector ".attachments-panel .attachments-grid .attachment-tile .grid-name", text: "bracket.stl"
    assert_no_selector "table.project-files"

    within(".attachments-panel .view-toggle") { click_on "List" }
    assert_selector "table.project-files td.col-name", text: "bracket.stl"
    assert_no_selector ".attachments-panel .attachments-grid .attachment-tile"
    assert_equal "list", @project.reload.panels.dig("views", "attachments")

    # A FRESH VISIT WITH NO PARAMS AT ALL. The row is the only thing left that could carry the
    # answer, so the table rendering here is what says the write is what the page reads.
    visit project_path(@project)
    assert_selector "table.project-files"
    assert_no_console_errors
  end
end
