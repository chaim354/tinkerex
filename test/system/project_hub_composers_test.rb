require "application_system_test_case"
require "support/git_repo_fixture"

# THE HUB'S COMPOSERS IN A REAL BROWSER (2026-11-02, the UX audit's B3 and C10) — the half a request
# test cannot see: that a refusal answered as a 422 turbo-stream really replaces the composer IN
# PLACE with the typed values still there (Turbo applies a stream whatever the status), that a
# refused README keeps the draft in the CodeMirror buffer rather than fetching the file over it,
# and that the wiring table's unsaved-row warning (wiring_controller.js) stops a Save that would
# drop another row's edit.
#
# EVERY REFUSAL HERE IS A 422, and Chrome logs a failed fetch as a SEVERE console message — so the
# console check ignores exactly that line and nothing else.
#
# MUTATION-CHECKED:
#   - THE DRAFT IS GUARDED TWICE, and each half alone keeps this green: the editor re-rendered for a
#     refusal carries an EMPTY `data-readme-url-value` (projects/_readme_editor) AND
#     `data-readme-draft-value="true"`, which readme_controller.js#reveal reads before fetching.
#     With BOTH undone (the url rendered for a draft, and `if (this.urlValue && !this.draftValue)`
#     -> `if (this.urlValue)`) the README test goes RED: `expected to find visible css ".cm-content"
#     with text "DRAFT-41" … but there were no matches. Also found "# Lamp, from the desktop"` —
#     the fetch put the file back over the draft. The server half alone is pinned by
#     readme_edit_test.rb (`data-readme-url-value=''`).
#   - wiring_controller.js `save` returning before its confirm: the wiring test goes RED with
#     `Capybara::ModalNotFound: Unable to find modal dialog with (?-mix:Another row has unsaved
#     changes)`.
#   - Dropping `data: { action: "submit->wiring#save" }` from projects/_wiring_composer's form
#     (its submit then only switched the leave-guard off, and an Add dropped the edit silently): the
#     same test goes RED at the composer's `dismiss_confirm`, with the identical ModalNotFound.
class ProjectHubComposersTest < ApplicationSystemTestCase
  include GitRepoFixture

  REFUSED = [ /status of 422/ ].freeze

  setup do
    @library = use_fresh_share_library!
    @user = sign_in_as("hub-composers@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
  end

  teardown { FileLayer.reset! }

  test "a refused BOM line comes back in place, open, with what was typed" do
    visit project_path(@project, add: "bom")
    find(".bom-panel details.composer > summary", text: "Add…").click
    within("#bom-composer") do
      fill_in "bom_line[reference]", with: "R7"
      choose "bom_line_target_kind_text"
      fill_in "bom_line[notes]", with: "the long one"
      click_on "Add line"
    end

    # THE SAME PAGE, NOT A NAVIGATION: the stream replaced the composer and nothing else.
    assert_current_path project_path(@project, add: "bom")
    within("#bom-composer[open]") do
      assert_selector ".form-errors", text: "Enter a part name."
      assert_field "bom_line[reference]", with: "R7"
      assert_field "bom_line[notes]", with: "the long one"
      assert_checked_field "bom_line_target_kind_text"
    end
    assert_no_console_errors(ignoring: REFUSED)
  end

  test "a README refused as stale keeps the draft in the editor" do
    @project.ensure_library_folder!(@user)
    path = File.join(library_root, "Projects", @project.slug, "README.md")
    File.write(path, "# Lamp\n")
    Library::ScanJob.new.perform(user_id: @user.id)

    visit project_path(@project)
    find(".readme-editor summary", text: /edit readme/i).click
    content = find(".readme-editor .cm-content", wait: 10)
    content.click
    content.send_keys(:end, " DRAFT-41")
    # The file moves on disk with no scan behind it: the port's store-side check refuses the save.
    File.write(path, "# Lamp, from the desktop\n")
    click_on "Save README"

    within("#readme-editor[open]") do
      assert_selector ".form-errors", text: /changed since you opened it/
      assert_selector ".cm-content", text: "DRAFT-41", wait: 10
    end
    assert_equal "# Lamp, from the desktop\n", File.read(path)
    assert_no_console_errors(ignoring: REFUSED)
  end

  test "Save on one wiring row asks first when another row has unsaved edits" do
    first = @project.connections.create!(user: @user, from_label: "PSU", to_label: "Driver", position: 0)
    second = @project.connections.create!(user: @user, from_label: "Driver", to_label: "Motor", position: 1)
    visit project_path(@project)

    fill_in "connection-#{first.id}-wire", with: "18 AWG"
    assert_selector "tr.wiring-row[data-dirty=true] .wiring-unsaved", text: "Unsaved", visible: true

    # Declined: nothing is posted, and the edit in the other row is still there to save.
    dismiss_confirm(/Another row has unsaved changes/) do
      within(:xpath, "//input[@id='connection-#{second.id}-wire']/ancestor::tr") { click_on "Save" }
    end
    assert_field "connection-#{first.id}-wire", with: "18 AWG"

    # ADDING A CONNECTION RELOADS THE TABLE TOO, so the composer asks the same question; declined,
    # nothing is added and the edit is still there.
    find(".wiring-panel details.composer > summary", text: "Add…").click
    within("#wiring-composer") do
      fill_in "connection[from_label]", with: "Fan"
      fill_in "connection[to_label]", with: "Header"
      dismiss_confirm(/Another row has unsaved changes/) { click_on "Add connection" }
    end
    assert_field "connection-#{first.id}-wire", with: "18 AWG"
    assert_equal 2, @project.connections.count

    # The row's own Save asks nothing.
    within(:xpath, "//input[@id='connection-#{first.id}-wire']/ancestor::tr") { click_on "Save" }
    assert_selector ".flash-notice", text: "Saved PSU → Driver."
    assert_equal "18 AWG", first.reload.wire
    assert_no_console_errors
  end
end
