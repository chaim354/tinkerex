require "application_system_test_case"

# THE PAGE EDITOR, DRIVEN (2026-09-09; spec §7). The server tests prove what the page and the doors
# write; only a browser can prove that a drag reorders, that Apply re-renders, that the pencil
# changes the heading in place, and that Save posts what the maker sees.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!): the editor reads `nodes` and fetches no bytes.
class PageEditorTest < ApplicationSystemTestCase
  include WebHelpers

  # The one question every way off a dirty editor asks (layout_editor_controller.js).
  LEAVE = "Leave the page layout without saving?".freeze

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
    # FOCUS SURVIVES THE MOVE: `before()`/`after()` re-inserts the slot, which blurs the button, and
    # the controller refocuses it so a second press goes where the first did (found in review).
    assert_equal "Move Tasks down", page.evaluate_script("document.activeElement.getAttribute('aria-label')")
    moved = order_on_page
    assert_equal moved.index("tasks"), moved.index("bom") + 1, "Tasks moved below BOM"

    click_on "Save layout"
    assert_current_path project_path(@project)
    assert_selector ".flash-notice", text: "Saved the page layout."
    assert_equal moved, @project.reload.panels["order"]
    assert_no_console_errors
  end

  test "dragging a panel by its handle reorders it, as far as the very end" do
    open_editor
    drag(find("#{slot(key(@models))} .panel-strip-handle"), find(slot("tasks")))

    assert_operator order_on_page.index(key(@models)), :>, order_on_page.index("photos"),
                    "models dropped after Photos: #{order_on_page.inspect}"

    # NOTHING IS PINNED ANY MORE (2026-10-26). Publish was always last (spec decision 11) and the
    # editor refused a drop onto it, so nothing could reach the end of the page; it became the edit
    # area's Publishing tab, and the last slot is an ordinary panel a drag can land past.
    assert_no_selector ".panel-slot--pinned, #{slot('publish')}"
    last = order_on_page.last
    drag(find("#{slot(key(@models))} .panel-strip-handle"), find(slot(last)))
    assert_equal key(@models), order_on_page.last, "the drop did not land at the end: #{order_on_page.inspect}"

    click_on "Save layout"
    assert_selector ".flash-notice", text: "Saved the page layout."
    assert_equal key(@models), @project.reload.panels["order"].last
  end

  # SORTABLE RUNS `forceFallback: true` (layout_editor_controller.js says why), so it listens for
  # REAL mouse events rather than the HTML5 drag events `handle.drag_to` synthesises — and a
  # `drag_to` therefore moves nothing at all here, silently. This is the pointer sequence the plan
  # names as the fallback: press on the handle, move far enough to pass `fallbackTolerance`, then
  # onto the target and release. The intermediate `move_by` is load-bearing — Sortable starts a
  # fallback drag on the first move past the tolerance, and a single jump to the target arrives
  # before the drag has begun.
  #
  # THE HANDLE IS SCROLLED TO JUST BELOW THE TOP BAR FIRST. A W3C pointer move does not scroll, so a
  # target past the bottom of the 1400px window is MoveTargetOutOfBounds, and how far down a slot
  # sits is the page's business, not this test's — slice 6's "Recently changed" row in Files was
  # enough to push Tasks out of it. With the handle near the top, the whole window below is room.
  def drag(handle, target)
    page.execute_script("window.scrollBy(0, arguments[0].getBoundingClientRect().top - 120)", handle.native)
    page.driver.browser.action
        .click_and_hold(handle.native)
        .move_by(0, 40)
        .move_to(target.native)
        # TEN PIXELS PAST THE TARGET'S CENTRE, where `move_to` lands and Sortable's before/after
        # decision is borderline; the nudge makes it "after" every time, and without it the
        # Publish assertion below can go vacuous (found in review).
        .move_by(0, 10)
        .release
        .perform
  end

  test "Half width, Hide, and a view change apply in place and persist" do
    open_editor
    within(slot("attachments")) { click_on "Half" }
    assert_selector "#{slot('attachments')}.panel--half"
    # THE PRESSED STATE IS SPOKEN TOO (C10): `aria-pressed` follows the click, not only the class.
    # Mutation-checked: dropping the setAttribute from `activate` turns this red.
    assert_selector "#{slot('attachments')} .panel-strip button[data-width=half][aria-pressed=true]"
    assert_selector "#{slot('attachments')} .panel-strip button[data-width=full][aria-pressed=false]"
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
    assert_selector "#{slot(key(@models))} .panel-strip button[data-view=list][aria-pressed=true]"
    assert_selector "#{slot(key(@models))} .panel-strip button[data-view][aria-pressed=true]", count: 1

    click_on "Save layout"
    assert_selector ".flash-notice", text: "Saved the page layout."
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

    click_on "Save layout"
    assert_selector "section.folder-panel h2", text: "Prints"
    assert_selector "section.folder-panel .panel-intro", text: "Sliced for 0.2 mm."
    assert_equal "models", @models.reload.name, "a title never renames the folder"
  end

  test "the drawer shows the draft as YAML, follows a change, and Apply re-renders the page" do
    # SHEETS IS HIDDEN IN THE SAVED ROW, and the applied text below never names it — which is what
    # makes "a panel the text does not mention keeps its state" a claim about the MERGE rather than
    # about a default. Sheets is a SAVED hide and Tasks, below, an UNSAVED one, so both halves of the
    # merge — the row's state and the browser's — are asserted at the end of this test.
    @project.update!(panels: { "hidden" => %w[sheets] })
    open_editor
    # CLOSED MEANS OFF SCREEN (F-S34-2, 2026-10-19). `.layout-drawer { display: flex }` beat the user
    # agent's `[hidden]`, so from the moment edit mode opened the drawer (Copy, Apply and an empty
    # textarea) sat under the panel grid, and "closing" it changed only the attribute — which is all
    # this test used to read. Capybara counts VISIBLE elements, so these lines read what is on screen.
    # Mutation-checked: deleting application.css's base `[hidden]` rule reddens the first.
    assert_no_selector "aside.layout-drawer"
    click_on "Edit as text"
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
    # COPY FOLLOWS THE TYPED TEXT, not the server's last render (found in review).
    assert_equal yaml.value, find("[data-layout-editor-target=copy]")["data-copy-text-value"]
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
    # AND THE EYE'S UNSAVED HIDE OF TASKS SURVIVES TOO: Apply merges into the BROWSER's draft, which
    # rides beside the text (Projects::LayoutsController#parse), not into the saved row. The first
    # version of this suite found the opposite — `parse` took only the YAML — and pinned it; this
    # line is that finding, fixed (2026-09-09).
    assert_selector "#{slot('tasks')}.panel-slot--hidden"

    yaml.set("layout: 1\npanels:\n  - panel: tsaks\n")
    click_on "Apply"
    assert_selector ".layout-note--error", text: "unknown panel “tsaks”"
    click_on "Edit as text"
    assert_no_selector "aside.layout-drawer"
    assert_no_console_errors
  end

  test "Cancel changes nothing and Reset clears the override" do
    @project.update!(panels: { "hidden" => %w[tasks], "widths" => { "bom" => "full" } })
    open_editor
    within(slot("bom")) { click_on "Half" }
    # A DRAFT IS ON THE PAGE, so Cancel asks before it throws it away (the leave guard below).
    accept_confirm(LEAVE) { click_on "Cancel" }
    assert_current_path project_path(@project)
    assert_equal "full", @project.reload.panels["widths"]["bom"]

    visit edit_layout_project_path(@project)
    within(slot("bom")) { click_on "Half" }
    # RESET ASKS ITS OWN QUESTION AND NO OTHER: once answered, the redirect it ends in is not asked
    # about a second time, although the draft it discards is dirty. A second dialog here would be
    # an unexpected alert and fail the next command.
    accept_confirm(/Reset the page to its type's defaults\?/) { click_on "Reset to Other defaults" }
    assert_selector ".flash-notice", text: "Reset the page layout to the Other defaults."
    assert_current_path project_path(@project)
    assert_nil @project.reload[:panels]
  end

  # --- the draft is not dropped without a question (the UX audit's B1, 2026-11-02) --------------

  # THE GUARD IS ONE turbo:before-visit LISTENER, so the rail (a link this page did not render),
  # the edit area's own tabs and Done all meet it. Dismissed, the page and the draft stay; accepted,
  # the visit goes and nothing was written. Mutation-checked: deleting the listener in connect()
  # turns the first dismiss_confirm red (Capybara::ModalNotFound).
  test "leaving a page layout with unsaved changes asks first, by any link" do
    open_editor
    within(slot("tasks")) { click_on "Hide" }

    dismiss_confirm(LEAVE) { find(".rail a.rail-link[href='#{files_path}']").click }
    assert_current_path edit_layout_project_path(@project)
    assert_selector "#{slot('tasks')}.panel-slot--hidden"

    dismiss_confirm(LEAVE) { within("nav.edit-tabs") { click_on "Details" } }
    assert_current_path edit_layout_project_path(@project)

    accept_confirm(LEAVE) { within(".edit-head") { click_on "Done" } }
    assert_current_path project_path(@project)
    assert_nil @project.reload[:panels], "leaving writes nothing"
  end

  # A DRAFT THAT ENDS WHERE IT STARTED IS NOT A CHANGE: "dirty" is the draft against the one the page
  # loaded with, not "something was clicked". Leaving then asks nothing — an unexpected confirm
  # would fail `assert_current_path` with UnexpectedAlertOpenError. Mutation-checked: marking the
  # draft dirty on every `changed()` (the naive flag) turns it red exactly that way.
  test "a draft put back the way it was, or never touched, leaves without a question" do
    open_editor
    within(slot("tasks")) { click_on "Hide" }
    within(slot("tasks")) { click_on "Show" }
    within(".edit-head") { click_on "Done" }
    assert_current_path project_path(@project)
  end

  # BACK AFTER LEAVING A DRAFT SHOWS THE SAVED LAYOUT, not Turbo's snapshot of the abandoned draft:
  # restored from the cache, the page would show the unsaved Hide as if it had been saved, and the
  # guard would read that state as clean. Mutation-checked: deleting `exemptPageFromCache` from
  # connect() turns the last assertion red.
  test "Back after leaving with unsaved changes shows the saved layout, not the abandoned draft" do
    open_editor
    within(slot("tasks")) { click_on "Hide" }
    accept_confirm(LEAVE) { within(".edit-head") { click_on "Done" } }
    assert_current_path project_path(@project)

    page.go_back
    assert_current_path edit_layout_project_path(@project)
    assert_selector slot("tasks")
    assert_no_selector "#{slot('tasks')}.panel-slot--hidden"
  end

  # BACK FROM AN EDITOR REACHED BY A TURBO LINK. A Turbo history step is a restoration visit, which
  # fires neither `turbo:before-visit` nor `beforeunload`, so a draft on an editor Turbo had rendered
  # into the page it came from went on Back with no question. The editor's
  # `turbo-visit-control: reload` (projects/_layout_bar) makes arriving there a whole document load,
  # so Back crosses documents and meets the `beforeunload` guard.
  #
  # THE EVENT IS ASSERTED, NOT THE DIALOG, AND THAT IS MEASURED (2026-11-02): this headless Chrome
  # under WebDriver draws no `beforeunload` dialog for ANY navigation — a script `location.assign`
  # included — while the event fires and is cancelled. A listener added after the guard records
  # `defaultPrevented`, which is the browser's cue to ask. Mutation-checked: without the meta the
  # record stays nil (Back fires no `beforeunload`), the gap this closes.
  test "Back from an editor reached by a link meets the beforeunload guard" do
    visit project_path(@project)
    within(".project-head") { click_on "Edit" }
    assert_current_path edit_project_path(@project)
    within("nav.edit-tabs") { click_on "Page layout" }
    assert_selector ".layout-bar", text: "Editing page layout"
    page.execute_script("localStorage.removeItem('page-editor-unload'); " \
                        "window.addEventListener('beforeunload', (e) => localStorage.setItem('page-editor-unload', String(e.defaultPrevented)))")
    within(slot("tasks")) { click_on "Hide" }

    page.go_back
    assert_current_path edit_project_path(@project)
    assert_equal "true", page.evaluate_script("localStorage.getItem('page-editor-unload')"),
                 "Back from the dirty editor did not meet a cancelled beforeunload"
  end

  # A TOAST THAT NAMES NO KIND IS AN ALERT (`toast()` has no default): a problem drawn as a notice
  # reads "Done", so forgetting the kind must fail safe. Every caller names one today, which is why
  # this asks the controller directly. Mutation-checked: `kind === "alert"` turns it red.
  test "a toast with no kind is drawn as an alert" do
    open_editor
    page.execute_script(<<~JS)
      const el = document.querySelector("[data-controller~='layout-editor']")
      window.Stimulus.getControllerForElementAndIdentifier(el, "layout-editor").toast("A message with no kind.")
    JS
    assert_selector ".flash-stack .flash-alert[role=alert]", text: "A message with no kind."
    assert_no_selector ".flash-notice", text: "A message with no kind."
  end

  # `beforeunload` IS THE OTHER HALF — a reload, a closed tab, a typed address — and Selenium cannot
  # answer its dialog the way it answers a confirm, so the handler is asked directly: a cancelable
  # event that the guard cancels while the draft is dirty, and leaves alone once it is saved.
  test "beforeunload is cancelled while the draft is dirty" do
    open_editor
    probe = "(() => { const e = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(e); return e.defaultPrevented })()"
    assert_equal false, page.evaluate_script(probe), "a clean page lets the browser leave"
    within(slot("tasks")) { click_on "Hide" }
    assert_equal true, page.evaluate_script(probe), "a dirty draft asks the browser to confirm"
  end

  # A REFUSAL THE BROWSER COULD NOT FORESEE KEEPS THE DRAFT (B1) AND SAYS SO AS AN ALERT (B2). The
  # browser's own gate (slotProblem) catches every refusal a maker can cause, so this one is made by
  # hand: a width the document does not know, written onto a slot the way a stale page or a future
  # rule would leave one. Mutation-checked (2026-11-02): letting the form submit itself (dropping
  # `event.preventDefault()` and `this.submit()` from save()) goes red at the alert assertion —
  # Turbo follows the refusal's redirect, so the leave guard's confirm opens unexpectedly; with the
  # guard also removed, the redirect reloads the editor and its flash lacks "Your changes are still
  # on this page".
  test "a Save the server refuses keeps every unsaved change on the page and says why as an alert" do
    open_editor
    within(slot("tasks")) { click_on "Hide" }
    page.execute_script("document.querySelector(#{slot('bom').to_json}).dataset.width = 'huge'")
    click_on "Save layout"

    assert_selector ".flash-alert", text: /The layout was not saved: .*Your changes are still on this page\./
    assert_no_selector ".flash-notice"
    assert_current_path edit_layout_project_path(@project)
    assert_selector "#{slot('tasks')}.panel-slot--hidden"
    assert_nil @project.reload[:panels], "nothing was written"
    # THE SAVE BUTTON IS BACK, and the guard still stands: the draft is as unsaved as it was.
    assert_selector ".layout-bar input[type=submit][value='Save layout']:not([disabled])"
    dismiss_confirm(LEAVE) { within(".edit-head") { click_on "Done" } }
    assert_current_path edit_layout_project_path(@project)
  end
end
