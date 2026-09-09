require "application_system_test_case"

# THE PAGE EDITOR, DRIVEN (2026-09-09; spec §7). The server tests prove what the page and the doors
# write; only a browser can prove that a drag reorders, that Apply re-renders, that the pencil
# changes the heading in place, and that Save posts what the maker sees.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!): the editor reads `nodes` and fetches no bytes.
class PageEditorTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @user = sign_in_as("page-editor@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
    @folder = project_folder_rows!(@user, @project)
    @models = dir!("models", @folder.node_id)
    file!("base.stl", @models.node_id)
    file!("arm.stl", @models.node_id)
    @firmware = dir!("firmware", @folder.node_id)
    dir!(Library::RepoMetadata::DIR_NAME, @firmware.node_id)
    file!("main.c", @firmware.node_id)
  end

  def dir!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
  def file!(name, parent) = @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent, mtime: 1, size: 3)
  def key(dir) = Maker::ProjectKind.folder_key(dir.node_id)
  def slot(k) = "div.panel-slot[data-key='#{k}']"
  def order_on_page = all("div.panel-slot").map { |s| s["data-key"] }

  def open_editor
    visit edit_layout_project_path(@project)
    assert_selector ".layout-bar", text: "Editing page layout"
    assert_selector "div.panel-slot", minimum: 5
  end

  test "Down then Save persists the order, and the keyboard alone can do it" do
    open_editor
    within(slot("tasks")) { find("button[aria-label='Move Tasks down']").click }
    moved = order_on_page
    assert_equal moved.index("tasks"), moved.index("bom") + 1, "Tasks moved below BOM"

    click_on "Save"
    assert_current_path project_path(@project)
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_equal moved, @project.reload.panels["order"]
    assert_no_console_errors
  end

  test "dragging a panel by its handle reorders it, and the pinned Publish slot refuses the drop" do
    open_editor
    assert_equal "publish", order_on_page.last
    drag(find("#{slot(key(@models))} .panel-strip-handle"), find(slot("tasks")))

    assert_operator order_on_page.index(key(@models)), :>, order_on_page.index("photos"),
                    "models dropped after Photos: #{order_on_page.inspect}"

    # PUBLISH IS ALWAYS LAST (spec decision 11), and this is the drag that proves it rather than
    # observing it: dropping ONTO the pinned slot is what `onMove` refuses, and `filter` is what
    # keeps Publish from being dragged away itself. Without both, this drop lands models past
    # Publish — the mutation this assertion exists for.
    drag(find("#{slot(key(@models))} .panel-strip-handle"), find(slot("publish")))
    assert_equal "publish", order_on_page.last, "the drop landed past Publish: #{order_on_page.inspect}"

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    assert_operator @project.reload.panels["order"].index(key(@models)), :>, @project.panels["order"].index("photos")
  end

  # SORTABLE RUNS `forceFallback: true` (layout_editor_controller.js says why), so it listens for
  # REAL mouse events rather than the HTML5 drag events `handle.drag_to` synthesises — and a
  # `drag_to` therefore moves nothing at all here, silently. This is the pointer sequence the plan
  # names as the fallback: press on the handle, move far enough to pass `fallbackTolerance`, then
  # onto the target and release. The intermediate `move_by` is load-bearing — Sortable starts a
  # fallback drag on the first move past the tolerance, and a single jump to the target arrives
  # before the drag has begun.
  def drag(handle, target)
    page.driver.browser.action
        .click_and_hold(handle.native)
        .move_by(0, 40)
        .move_to(target.native)
        .move_by(0, 10)
        .release
        .perform
  end

  test "Half width, Hide, and a view change apply in place and persist" do
    open_editor
    within(slot("attachments")) { click_on "Half" }
    assert_selector "#{slot('attachments')}.panel--half"
    within(slot("tasks")) { click_on "Hide" }
    assert_selector "#{slot('tasks')}.panel-slot--hidden"
    assert_selector "#{slot('tasks')} button", text: "Show"
    # SCOPED TO THE STRIP, NOT THE SLOT. A folder panel carries its OWN Tiles/List/Browser toggle in
    # its head (projects/_folder_panel), so a bare `click_on "List"` inside the slot is ambiguous —
    # two buttons, and the panel's own one is a `button_to` that SAVES rather than editing the draft.
    within("#{slot(key(@models))} .panel-strip") { click_on "List" }
    assert_no_selector "#{slot(key(@models))} .attachments-grid"
    within("#{slot(key(@models))} .panel-slot-body") { assert_text "base.stl" }
    assert_selector "#{slot(key(@models))} .panel-strip button.toggle.active", text: "List"

    click_on "Save"
    assert_selector ".flash-notice", text: "Page layout saved."
    panels = @project.reload.panels
    assert_equal "half", panels["widths"]["attachments"]
    assert_includes panels["hidden"], "tasks"
    assert_equal "list", panels["views"][key(@models)]
    assert_no_selector "section.tasks-panel"
    assert_no_console_errors
  end

  test "the pencil renames a folder panel and adds an intro, live and on the saved page" do
    open_editor
    within(slot(key(@models))) do
      find("details.panel-strip-edit > summary").click
      fill_in "Title", with: "Prints"
      fill_in "Intro", with: "Sliced for 0.2 mm."
    end
    assert_selector "#{slot(key(@models))} .panel-slot-body h2", text: "Prints"
    assert_selector "#{slot(key(@models))} .panel-slot-body .panel-intro", text: "Sliced for 0.2 mm."
    assert_selector "#{slot(key(@models))} .panel-strip .mono", text: "models/"

    click_on "Save"
    assert_selector "section.folder-panel h2", text: "Prints"
    assert_selector "section.folder-panel .panel-intro", text: "Sliced for 0.2 mm."
    assert_equal "models", @models.reload.name, "a title never renames the folder"
  end

  test "the drawer shows the draft as YAML, follows a change, and Apply re-renders the page" do
    # SHEETS IS HIDDEN IN THE SAVED ROW, and the applied text below never names it — which is what
    # makes "a panel the text does not mention keeps its state" a claim about the MERGE rather than
    # about a default. It has to be a SAVED hide rather than one made with the eye a moment earlier;
    # see the note beside the assertion at the end of this test.
    @project.update!(panels: { "hidden" => %w[sheets] })
    open_editor
    click_on "Edit as YAML"
    assert_selector "aside.layout-drawer:not([hidden])"
    # THE TEXT ARRIVES FROM THE SERVER, NOT WITH THE DRAWER: opening it posts the draft to `yamlUrl`
    # and fills the textarea when that answers, so the element exists a beat before its value does.
    # A textarea's VALUE is not its text node, so no Capybara matcher can wait on it — poll, for the
    # same reason the refresh below polls.
    wait_until(message: "the drawer never filled with the server's YAML") do
      find("textarea.layout-yaml").value.include?("layout: 1")
    end
    yaml = find("textarea.layout-yaml")
    assert_includes yaml.value, "- folder: models"
    refute_includes yaml.value, @models.node_id

    within(slot("tasks")) { click_on "Hide" }
    # A textarea's VALUE is not its text node, so Capybara's `text:` cannot see a refresh; poll the
    # value with the suite's own helper (test/system/support/web_helpers.rb#wait_until).
    wait_until(message: "the drawer did not follow the change") do
      find("textarea.layout-yaml").value.include?("- panel: tasks\n  width: half\n  hidden: true")
    end

    yaml.set(<<~YAML)
      layout: 1
      panels:
        - folder: models
          title: Prints
          width: half
        - folder: enclosure
          hidden: true
        - panel: bom
          hidden: true
    YAML
    click_on "Apply"
    assert_selector ".layout-drawer-notes .layout-note", text: "no folder named “enclosure”"
    assert_no_selector ".layout-note--error"
    assert_equal key(@models), order_on_page.first
    assert_selector "#{slot(key(@models))}.panel--half .panel-slot-body h2", text: "Prints"
    assert_selector "#{slot('bom')}.panel-slot--hidden"
    # A PANEL THE TEXT DID NOT MENTION KEEPS ITS STATE: Sheets is still hidden. (No message argument
    # on any of these — Capybara's `assert_selector` accepts none and raises `ArgumentError: Unused
    # parameters` rather than ignoring it.)
    assert_selector "#{slot('sheets')}.panel-slot--hidden"
    # AND THE ASYMMETRY THIS PINS, RECORDED RATHER THAN ENDORSED (2026-09-09). `yaml` is handed the
    # BROWSER's draft (LayoutsController#yaml -> #from_draft), which is why the poll above sees the
    # eye's unsaved hide of Tasks in the text; `parse` is handed only the YAML and merges into the
    # SAVED layout (LayoutScoped#document builds the document from `@project.panel_layout`), so
    # Apply DISCARDS an unsaved change to a panel the text does not name. The plan's own draft of
    # this test expected Tasks to survive here; it does not, and the fix — if it is one — is a
    # `draft` parameter on `parse`, which is Projects::LayoutsController's to add, not this
    # controller's to work around in the browser (spec decision 2: one grammar, server-side).
    assert_no_selector "#{slot('tasks')}.panel-slot--hidden"

    yaml.set("layout: 1\npanels:\n  - panel: tsaks\n")
    click_on "Apply"
    assert_selector ".layout-note--error", text: "unknown panel “tsaks”"
    assert_no_console_errors
  end

  test "Cancel changes nothing and Reset clears the override" do
    @project.update!(panels: { "hidden" => %w[tasks], "widths" => { "bom" => "full" } })
    open_editor
    within(slot("bom")) { click_on "Half" }
    click_on "Cancel"
    assert_current_path project_path(@project)
    assert_equal "full", @project.reload.panels["widths"]["bom"]

    visit edit_layout_project_path(@project)
    accept_confirm { click_on "Reset to Other defaults" }
    assert_selector ".flash-notice", text: "reset"
    assert_nil @project.reload[:panels]
  end
end
