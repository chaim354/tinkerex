require "application_system_test_case"

# THE TOP BAR'S UPLOAD IN A BROWSER (structural redesign spec §4.2, §8; slice 4). A request test sees
# the destination in the markup; only a browser sees the file actually land there, and only a browser
# can drive the chooser step on a page with no folder. Share only (use_fresh_share_library!): the
# chunk flow's browser test is uploader_test.rb.
#
# WHAT NO TEST HERE CAN SEE: that the file picker OPENS after Choose. upload_pick_controller.js calls
# `inputTarget.click()` for that, and headless Chrome shows no picker, so the tests below count the
# click the input receives (`window.__picks`): that proves the call, not the dialog. Capybara's
# `attach_file` sets the input's files directly. A human clicking Upload on Recent, then Choose, is
# the only check that a real browser shows its dialog.
#
# UPLOAD IS A <button> (UX audit I): it was a <label> over the hidden input and took no focus, so a
# keyboard could not upload. The keyboard tests below press Enter and Space on it.
class TopbarUploadSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("topbar-upload@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
    @sample = Rails.root.join("tmp", "topbar-upload-#{SecureRandom.hex(4)}.txt")
    File.write(@sample, "hello")
  end

  teardown do
    FileUtils.rm_f(@sample)
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a folder, Upload puts the file in that folder" do
    visit files_path(folder: @cad.node_id)
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to cad"
    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "on Recent, Upload asks for a folder first and then saves there" do
    visit root_path
    # THE FILE PICKER MUST OPEN FROM THE CHOOSER STEP. Headless Chrome shows no picker, so this counts
    # the click upload_pick_controller.js dispatches on the input: none while the chooser is open (the
    # button's click asks first), exactly one after Choose. It proves the call, not that a real
    # browser opens its dialog — that last link is the PR checklist manual check.
    page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    find("header.topbar .topbar-upload button.upload-btn").click
    assert_selector ".filechooser-overlay"
    assert_equal 0, page.evaluate_script("window.__picks"), "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to cad"
    # After the caption, which the same callback writes just before it clicks — so no race.
    assert_equal 1, page.evaluate_script("window.__picks"), "choosing a folder did not open the file picker"
    assert_equal @cad.node_id, find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value

    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "cancelling the chooser uploads nothing and leaves the caption empty" do
    visit root_path
    find("header.topbar .topbar-upload button.upload-btn").click
    assert_selector ".filechooser-overlay"
    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    assert_selector "header.topbar .topbar-upload-caption", visible: :hidden
    assert_equal "", find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value
  end

  # THE KEYBOARD CAN UPLOAD (UX audit I). Upload was a <label> over the hidden input: no tab stop, no
  # key handler, so the one accent action on the Library, Recent and the hub was mouse-only. Now it is
  # a <button>: in the Tab order, focusable, and Enter and Space each open the picker (counted as the
  # click the input receives, for the reason this file's header gives).
  # Mutation-checked (2026-11-02): putting the share/s3 branch's control back as a `tag.label` in
  # layouts/_topbar_upload reddens this on `["LABEL", -1]` (a label is no tab stop), and the Recent
  # keyboard test below on the chooser that Enter never opened.
  test "on a folder, Upload is a tab stop that Enter and Space open" do
    visit files_path(folder: @cad.node_id)
    count_picks!
    upload = find("header.topbar .topbar-upload .upload-btn")
    assert_equal [ "BUTTON", 0 ], [ upload.tag_name.upcase, upload.evaluate_script("this.tabIndex") ]
    upload.execute_script("this.focus()")
    assert page.evaluate_script("document.activeElement === document.querySelector('header.topbar .topbar-upload .upload-btn')"),
           "the Upload control does not take focus"
    page.driver.browser.action.send_keys(:enter).perform
    assert_equal 1, picks, "Enter on Upload did not open the file picker"
    page.driver.browser.action.send_keys(:space).perform
    assert_equal 2, picks, "Space on Upload did not open the file picker"
    assert_no_selector ".filechooser-overlay"
    assert_no_console_errors
  end

  test "on Recent, Enter on Upload asks for the folder and then opens the picker" do
    visit root_path
    count_picks!
    find("header.topbar .topbar-upload .upload-btn").execute_script("this.focus()")
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector ".filechooser-overlay"
    assert_equal 0, picks, "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to cad"
    assert_equal 1, picks
    assert_no_console_errors
  end

  # EVERY CLICK ASKS AGAIN (UX audit A7). The first choice used to stick for the rest of the page with
  # nothing on screen saying so below 1100px, where the caption hides: a second upload went to the
  # first one's folder unasked. The chooser now opens each time, on the folder chosen last.
  # Mutation-checked (2026-11-02): making upload_pick_controller.js#pick open the input straight away
  # once a folder has been chosen (`if (this.lastChoice) { this.inputTarget.click(); return }`, the
  # old sticky behaviour) reddens the second `.filechooser-overlay` assertion.
  test "on Recent, a second click on Upload asks for the folder again, starting from the last one" do
    jigs = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "jigs")
    visit root_path
    count_picks!
    upload = find("header.topbar .topbar-upload .upload-btn")
    upload.click
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_equal 1, picks

    upload.click
    assert_selector ".filechooser-overlay"
    assert_equal 1, picks, "the second click opened the picker without asking"
    # It opens on the last choice: Choose straight away keeps cad.
    click_on "Choose"
    assert_equal 2, picks
    assert_equal @cad.node_id, find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value

    upload.click
    find(".filechooser-row", text: "jigs").click
    click_on "Choose"
    assert_equal 3, picks
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to jigs", visible: :all
    assert_equal jigs.node_id, find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value
    assert_no_console_errors
  end

  private

    def count_picks!
      page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    end

    def picks = page.evaluate_script("window.__picks")
end
