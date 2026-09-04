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
end
