require "application_system_test_case"

# THE STRIP'S UPLOAD IN A BROWSER (structural redesign spec §4.2, §8; slice 4. In the strip's Add since
# Shop manual slice 3: its menu's "Upload…" forwards a click to the hidden Upload button beside it.) A
# request test sees the destination in the markup; only a browser sees the file actually land there,
# and only a browser can drive the chooser step on a page with no folder. Share only
# (use_fresh_share_library!): the chunk flow's browser test is uploader_test.rb.
#
# WHAT NO TEST HERE CAN SEE: that the file picker OPENS after Choose. upload_pick_controller.js calls
# `inputTarget.click()` for that, and headless Chrome shows no picker, so the tests below count the
# click the input receives (`window.__picks`): that proves the call, not the dialog. Capybara's
# `attach_file` sets the input's files directly. A human choosing Add › Upload… on Home, then Choose,
# is the only check that a real browser shows its dialog.
#
# UPLOAD IS A <button> (UX audit I): it was a <label> over the hidden input and took no focus, so a
# keyboard could not upload. The keyboard reaches it now through Add's "Upload…", itself a button;
# the keyboard tests below press Enter and Space on it.
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
    open_add
    assert_selector "header.strip .strip-add-menu .topbar-upload-caption", text: "Saves to cad"
    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "on Home, Add's Upload asks for a folder first and then saves there" do
    visit root_path
    # THE FILE PICKER MUST OPEN FROM THE CHOOSER STEP. Headless Chrome shows no picker, so this counts
    # the click upload_pick_controller.js dispatches on the input: none while the chooser is open (the
    # button's click asks first), exactly one after Choose. It proves the call, not that a real
    # browser opens its dialog — that last link is the PR checklist manual check.
    count_picks!
    upload_item.click
    assert_selector ".filechooser-overlay"
    assert_equal 0, picks, "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    # The caption heads Add's menu, closed by the click; the chooser wrote it before it clicked.
    assert_selector "header.strip .topbar-upload-caption", text: "Saves to cad", visible: :all
    assert_equal 1, picks, "choosing a folder did not open the file picker"
    assert_equal @cad.node_id, find("header.strip .topbar-upload input[name='parent_node_id']", visible: :all).value

    attach_file("topbar_upload_file", @sample.to_s, make_visible: true)
    assert_text File.basename(@sample)
    assert_equal @cad.node_id, @user.nodes.present.find_by!(name: File.basename(@sample)).parent_node_id
    assert_no_console_errors
  end

  test "cancelling the chooser uploads nothing and leaves the caption empty" do
    visit root_path
    upload_item.click
    assert_selector ".filechooser-overlay"
    find(".filechooser").send_keys(:escape)
    assert_no_selector ".filechooser-overlay"
    assert_selector "header.strip .topbar-upload-caption", visible: :hidden
    assert_equal "", find("header.strip .topbar-upload-caption", visible: :all).text(:all)
    assert_equal "", find("header.strip .topbar-upload input[name='parent_node_id']", visible: :all).value
  end

  # THE KEYBOARD CAN UPLOAD (UX audit I). Upload was a <label> over the hidden input: no tab stop, no
  # key handler, so the Library's one upload was mouse-only. Now Add's "Upload…" is a <button>: in the
  # Tab order of the open menu, focusable, and Enter and Space each open the picker (counted as the
  # click the input receives, for the reason this file's header gives).
  # Mutation-checked (2026-11-19): `upload-forward#open` taken off the menu item (layouts/_strip_add)
  # reddens this on the first count ("Enter on Upload did not open the file picker").
  test "on a folder, Add's Upload is a tab stop that Enter and Space open" do
    visit files_path(folder: @cad.node_id)
    count_picks!
    open_add
    upload = find("header.strip .strip-add-menu button.strip-add-upload")
    assert_equal [ "BUTTON", 0 ], [ upload.tag_name.upcase, upload.evaluate_script("this.tabIndex") ]
    upload.execute_script("this.focus()")
    assert page.evaluate_script("document.activeElement === document.querySelector('header.strip .strip-add-upload')"),
           "Add's Upload does not take focus"
    page.driver.browser.action.send_keys(:enter).perform
    assert_equal 1, picks, "Enter on Upload did not open the file picker"
    # The click closed the menu; opened again, Space does the same.
    open_add
    find("header.strip .strip-add-menu button.strip-add-upload").execute_script("this.focus()")
    page.driver.browser.action.send_keys(:space).perform
    assert_equal 2, picks, "Space on Upload did not open the file picker"
    assert_no_selector ".filechooser-overlay"
    assert_no_console_errors
  end

  test "on Home, Enter on Add's Upload asks for the folder and then opens the picker" do
    visit root_path
    count_picks!
    open_add
    find("header.strip .strip-add-menu button.strip-add-upload").execute_script("this.focus()")
    page.driver.browser.action.send_keys(:enter).perform
    assert_selector ".filechooser-overlay"
    assert_equal 0, picks, "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_selector "header.strip .topbar-upload-caption", text: "Saves to cad", visible: :all
    assert_equal 1, picks
    assert_no_console_errors
  end

  # EVERY CLICK ASKS AGAIN (UX audit A7). The first choice used to stick for the rest of the page with
  # nothing on screen saying so, so a second upload went to the first one's folder unasked. The
  # chooser now opens each time, on the folder chosen last.
  # Mutation-checked (2026-11-02): making upload_pick_controller.js#pick open the input straight away
  # once a folder has been chosen (`if (this.lastChoice) { this.inputTarget.click(); return }`, the
  # old sticky behaviour) reddens the second `.filechooser-overlay` assertion.
  test "on Home, a second Upload asks for the folder again, starting from the last one" do
    jigs = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "jigs")
    visit root_path
    count_picks!
    upload_item.click
    find(".filechooser-row", text: "cad").click
    click_on "Choose"
    assert_equal 1, picks

    upload_item.click
    assert_selector ".filechooser-overlay"
    assert_equal 1, picks, "the second click opened the picker without asking"
    # It opens on the last choice: Choose straight away keeps cad.
    click_on "Choose"
    assert_equal 2, picks
    assert_equal @cad.node_id, find("header.strip .topbar-upload input[name='parent_node_id']", visible: :all).value

    upload_item.click
    find(".filechooser-row", text: "jigs").click
    click_on "Choose"
    assert_equal 3, picks
    assert_selector "header.strip .topbar-upload-caption", text: "Saves to jigs", visible: :all
    assert_equal jigs.node_id, find("header.strip .topbar-upload input[name='parent_node_id']", visible: :all).value
    assert_no_console_errors
  end

  private

    def open_add
      find("header.strip .strip-add-menu > summary").click
      assert_selector "header.strip .strip-add-menu[open] .menu-list", visible: true
    end

    def upload_item
      open_add
      find("header.strip .strip-add-menu button.strip-add-upload", text: "Upload…")
    end

    def count_picks!
      page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    end

    def picks = page.evaluate_script("window.__picks")
end
