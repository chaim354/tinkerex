require "application_system_test_case"

# THE TOP BAR'S UPLOAD IN A BROWSER (structural redesign spec §4.2, §8; slice 4). A request test sees
# the destination in the markup; only a browser sees the file actually land there, and only a browser
# can drive the chooser step on a page with no folder. Share only (use_fresh_share_library!): the
# chunk flow's browser test is uploader_test.rb.
#
# WHAT NO TEST HERE CAN SEE: that the file picker OPENS after Choose. upload_pick_controller.js calls
# `inputTarget.click()` for that, and Capybara's `attach_file` sets the input's files directly, so
# deleting the call leaves this file green (mutation-checked). A human clicking Upload on Home, then
# Choose, is the only check.
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

  test "on Home, Upload asks for a folder first and then saves there" do
    visit root_path
    # THE FILE PICKER MUST OPEN FROM THE CHOOSER STEP. Headless Chrome shows no picker, so this counts
    # the click upload_pick_controller.js dispatches on the input: none while the chooser is open (the
    # label click is intercepted), exactly one after Choose. It proves the call, not that a real
    # browser opens its dialog — that last link is the PR checklist manual check.
    page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    find("header.topbar .topbar-upload label.upload-btn").click
    assert_selector ".filechooser-overlay"
    assert_equal 0, page.evaluate_script("window.__picks"), "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to /cad"
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
    find("header.topbar .topbar-upload label.upload-btn").click
    assert_selector ".filechooser-overlay"
    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    assert_selector "header.topbar .topbar-upload-caption", visible: :hidden
    assert_equal "", find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value
  end
end
