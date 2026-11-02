require "application_system_test_case"

# THE BUILD LOG'S "UPLOAD & ATTACH" (projects/_upload_control), the shell's other Upload button. Like
# the top bar's, it is a <button> beside a hidden file input (UX audit I: a <label> over the input took
# no focus), and on share/s3 its form is submitted by zip_upload_controller.js, mounted with no unpack
# door, which writes "Uploading NAME…" while the browser POSTs (UX audit B8) where an inline
# `onchange="this.form.requestSubmit()"` said nothing. Share only (use_fresh_share_library!): the chunk
# branch is uploader_controller.js's, unchanged.
#
# MUTATION-CHECKED (2026-11-02; each reverted, and the file re-run green after):
#   1. The share branch's control back to a `<label>`: the keyboard test red, a label is no tab stop.
#   2. The file field's `change->zip-upload#change` action dropped: the status test red, the form
#      never submitted and nothing said "Uploading".
class ShellUploadAttachTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("upload-attach@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
    @entry = @project.build_log_entries.create!(user: @user, body: "glued the base")
    @dir = Dir.mktmpdir("upload_attach")
    @photo = File.join(@dir, "base.png")
    File.binwrite(@photo, Rails.root.join("test/fixtures/files/sample.png").binread)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the entry's Upload & attach is a tab stop that Enter opens" do
    visit project_path(@project)
    open_entry_menu
    upload = find(".log-entry .menu-list .upload-btn", text: "Upload & attach")
    assert_equal [ "BUTTON", 0 ], [ upload.tag_name.upcase, upload.evaluate_script("this.tabIndex") ]
    page.execute_script(<<~JS)
      window.__picks = 0
      document.querySelector(".log-entry .menu-list .uploader input[type=file]").addEventListener("click", () => window.__picks++)
    JS
    upload.execute_script("this.focus()")
    page.driver.browser.action.send_keys(:enter).perform
    assert_equal 1, page.evaluate_script("window.__picks"), "Enter on Upload & attach did not open the file picker"
    assert_no_console_errors
  end

  test "choosing a file says Uploading NAME in a live region, then attaches it to the entry" do
    visit project_path(@project)
    open_entry_menu
    # HELD FIRST, so the line can be read before the POST replaces the page (files_js_feedback_test.rb's
    # technique); then released for the real upload.
    page.execute_script("HTMLFormElement.prototype.__realSubmit = HTMLFormElement.prototype.requestSubmit; " \
                        "HTMLFormElement.prototype.requestSubmit = function () { window.__heldSubmit = this.action }")
    within(".log-entry .menu-list") { attach_file(@photo, make_visible: true) }
    status = find(".log-entry .menu-list .upload-status", text: "Uploading base.png…")
    assert_equal "polite", status[:"aria-live"]
    assert_match %r{/build_log_entries/#{@entry.id}/uploads\z}, page.evaluate_script("window.__heldSubmit")

    page.execute_script("HTMLFormElement.prototype.__realSubmit.call(document.querySelector('.log-entry .menu-list form.uploader'))")
    assert_selector ".flash-stack .flash-notice", text: "base.png"
    assert_current_path project_path(@project)
    assert_equal [ "base.png" ], @entry.file_attachments.reload.map { |a| @user.nodes.find_by!(node_id: a.node_id).name }
    assert_no_console_errors
  end

  private

    def open_entry_menu
      find(".log-entry .entry-head summary[aria-label='Entry actions']").click
      assert_selector ".log-entry .entry-head details.menu[open]"
    end
end
