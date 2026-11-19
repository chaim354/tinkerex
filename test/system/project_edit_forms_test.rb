require "application_system_test_case"

# THE DETAILS AND PUBLISHING TABS ASK BEFORE TYPED INPUT IS LEFT BEHIND (2026-11-02, the UX audit's
# B1), DRIVEN. The Page layout tab's guard is page_editor_test.rb; these two forms share one
# controller, dirty_form_controller.js, and test/integration/web/project_edit_area_test.rb pins the
# wiring the server renders. Only a browser can say that Done asks, that Save does not, and that the
# question is about the form as it stands rather than about whether a key was pressed.
#
# ROWS ONLY, NEVER THE PORT (project_folder_rows!): neither tab reads bytes, and the cover chooser
# is driven by its hidden input, never opened.
class ProjectEditFormsTest < ApplicationSystemTestCase
  include WebHelpers

  # The one question every way off a dirty form asks (dirty_form_controller.js).
  LEAVE = "Leave without saving your changes?".freeze

  # What the guard answers a cancelable `beforeunload`: the browser asks when it is prevented. The
  # real dialog is not drivable in this headless Chrome (page_editor_test.rb measured that), so the
  # handler is asked directly.
  GUARD_HOLDS = "(() => { const e = new Event('beforeunload', { cancelable: true }); " \
                "window.dispatchEvent(e); return e.defaultPrevented })()".freeze

  setup do
    @user = sign_in_as("edit-forms@example.com")
    @user.update!(handle: "edit-forms")
    @project = @user.maker_projects.create!(name: "Lamp")
    project_folder_rows!(@user, @project)
  end

  def name_field = find("input[name='project[name]']")

  def open_details
    visit edit_project_path(@project)
    assert_selector "form.project-form[data-controller=dirty-form]"
  end

  # Mutation-checked (2026-11-02): with dirty() answering false whatever the form holds, the first
  # dismiss_confirm finds no dialog (Capybara::ModalNotFound) and the beforeunload probe reads false.
  test "Done from a Details form with a typed change asks; dismissed it stays, accepted it leaves" do
    open_details
    refute page.evaluate_script(GUARD_HOLDS), "an untouched form asks before leaving"
    name_field.fill_in(with: "Lamp, mark two")
    assert page.evaluate_script(GUARD_HOLDS), "a full navigation would leave the typed name unasked"

    dismiss_confirm(LEAVE) { within(".edit-head") { click_on "Done" } }
    assert_current_path edit_project_path(@project)
    assert_equal "Lamp, mark two", name_field.value

    dismiss_confirm(LEAVE) { within("nav.edit-tabs") { click_on "Publishing" } }
    assert_current_path edit_project_path(@project)

    accept_confirm(LEAVE) { within(".edit-head") { click_on "Done" } }
    assert_current_path project_path(@project)
    assert_equal "Lamp", @project.reload.name, "leaving writes nothing"
  end

  # ONE QUESTION, NOT TWO. The Page layout tab carries `turbo-visit-control: reload`, so a visit to it
  # that the maker has already agreed to ends in a full load, and `beforeunload` fires on this page
  # with the guard still connected. A listener added after the guard records whether the event was
  # cancelled — the browser's cue to ask again — because this headless Chrome draws no beforeunload
  # dialog to wait for (page_editor_test.rb measured that).
  # Mutation-checked (2026-11-02): without `this.leaving = true` on an accepted confirm, the recorded
  # answer is "true".
  test "an accepted question on the way to Page layout is not asked again by beforeunload" do
    open_details
    page.execute_script("localStorage.removeItem('dirty-form-unload'); " \
                        "window.addEventListener('beforeunload', (e) => localStorage.setItem('dirty-form-unload', String(e.defaultPrevented)))")
    name_field.fill_in(with: "Lamp, mark two")

    accept_confirm(LEAVE) { within("nav.edit-tabs") { click_on "Page layout" } }
    assert_selector ".layout-bar", text: "Editing page layout"
    assert_equal "false", page.evaluate_script("localStorage.getItem('dirty-form-unload')"),
                 "the full load that ended the agreed visit asked a second time"
  end

  # DIRTY IS THE FORM AGAINST THE ONE THE PAGE LOADED, not "a key was pressed": a name typed and put
  # back leaves without a question. An unexpected confirm would fail assert_current_path with
  # UnexpectedAlertOpenError.
  test "an untouched form, or one put back the way it was, leaves without a question" do
    open_details
    within(".edit-head") { click_on "Done" }
    assert_current_path project_path(@project)

    open_details
    name_field.fill_in(with: "Something else")
    name_field.fill_in(with: "Lamp")
    within("form.project-form") { click_on "Cancel" }
    assert_current_path project_path(@project)
  end

  # THE FORM'S OWN SUBMIT STANDS THE GUARD DOWN. Save's redirect is a Turbo visit, so without that
  # it would meet the question it exists to avoid — and an unexpected confirm fails the path check.
  # Mutation-checked (2026-11-02): with the `submit`/`turbo:submit-start` actions removed from
  # projects/_form, this goes red with UnexpectedAlertOpenError.
  test "Save changes asks nothing and saves" do
    open_details
    name_field.fill_in(with: "Lamp, mark two")
    click_on "Save changes"
    assert_current_path project_path(@project)
    assert_equal "Lamp, mark two", @project.reload.name
  end

  # COMPARED WHEN ASKED, NOT TRACKED ON input/change: the cover chooser writes its hidden input from
  # script and fires neither event, so a guard that listened for them would let this change go.
  test "a cover chosen through the chooser's hidden input counts as a change" do
    open_details
    page.execute_script("document.querySelector(\"input[name='project[cover_node_id]']\").value = 'n-cover'")
    assert page.evaluate_script(GUARD_HOLDS), "a chosen cover would be left without a question"
  end

  test "the Publishing tab asks the same question, and Save publishing does not" do
    visit publishing_project_path(@project)
    assert_selector "form.publish-form[data-controller=dirty-form]"
    choose "project_visibility_unlisted"

    dismiss_confirm(LEAVE) { within("form.publish-form") { click_on "Cancel" } }
    assert_current_path publishing_project_path(@project)

    click_on "Save publishing"
    assert_current_path publishing_project_path(@project)
    assert_selector ".publish-unlisted"
    assert_equal "unlisted", @project.reload.visibility
    within(".edit-head") { click_on "Done" }
    assert_current_path project_path(@project)
    assert_no_console_errors
  end
end
