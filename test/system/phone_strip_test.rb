require "application_system_test_case"

# THE STRIP ON A PHONE (Shop manual spec §7, slice 3; below 720px). The four places move to the tab bar,
# Search becomes an icon linking to the Search page, Add shows only its "+", and the wordmark keeps
# its disc and name; the Contents button opens the column as a sheet. ADD'S UPLOAD is "Upload…" in its
# menu at every width, forwarding a click to the hidden Upload BUTTON beside it
# (upload_forward_controller.js; the phone's "+" carried it first, structural redesign §4.3). A request
# test sees the markup; only a browser sees what is on screen at 375px, and that the forwarded click
# takes the same road a tap on the button does — the chooser on a page with no folder, the file
# picker on a folder.
#
# The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not make a
# WebDriver window narrower than 500px). The picks counter is topbar_upload_test.rb's: headless Chrome
# shows no file picker, so it counts the click the input receives — it proves the call, not the dialog.
#
# MUTATION-CHECKED (2026-11-19; each reverted, and the file re-run green after):
#   1. upload_forward_controller.js clicking `#topbar_upload_file` instead of the button: the Home test
#      red at the chooser — an input-targeted click never reaches upload_pick_controller.js.
#   2. shell.css hiding all of `.topbar-upload` instead of its button: the chunk-flow test red, the
#      progress text an upload started from the menu writes has nowhere to show.
#   (1 reddens at "expected to find css .filechooser-overlay".)
#   3. Dropping `.strip-search` from the ≤719px block's display:none: the first test red, the box
#      still drawn at 375px ("expected to find non-visible css header.strip form.strip-search").
class PhoneStripSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("phone-strip@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a phone the strip keeps the wordmark, Contents, a Search icon, the '+' and the account button, all on screen" do
    phone!
    visit files_path(folder: @cad.node_id)
    assert_selector "header.strip .brand .brand-name", text: "Tinkerex"
    assert_selector "header.strip nav.strip-places", visible: :hidden
    assert_selector "header.strip form.strip-search", visible: :hidden
    assert_selector "header.strip a.strip-search-link[href='#{search_path}']", visible: true
    assert_selector "header.strip .strip-add-label", visible: :hidden
    assert_equal "Add", find("header.strip .strip-add-menu > summary")["aria-label"]
    edges, client = page.evaluate_script(<<~JS)
      (() => {
        const shown = Array.from(document.querySelectorAll("header.strip .strip-contents, header.strip .brand, header.strip .strip-search-link, header.strip .strip-add-menu > summary, header.strip .strip-account > summary"))
          .map((el) => { const r = el.getBoundingClientRect(); return [el.className, r.left, r.right, r.width]; });
        return [shown, document.documentElement.clientWidth];
      })()
    JS
    assert_equal 5, edges.size, "the strip is missing a control at 375px: #{edges.inspect}"
    edges.each do |name, left, right, width|
      assert_operator width, :>, 0, "#{name} is not drawn at 375px"
      assert_operator left, :>=, 0, "#{name} starts off the left of the screen (#{left})"
      assert_operator right, :<=, client, "#{name} runs off the right of the screen (#{right} of #{client})"
    end
    # PRESENT AND HIDDEN, not merely absent: absence would mean the partial stopped rendering the
    # button the menu forwards to, which is a broken Upload rather than a phone layout.
    assert_selector "header.strip .topbar-upload button.upload-btn", visible: :hidden
    assert_no_console_errors
  end

  test "on Home, Add's Upload asks for a folder first and then opens the picker" do
    phone!
    visit root_path
    count_picks!
    open_upload.click
    assert_selector ".filechooser-overlay"
    assert_equal 0, picks, "the file picker opened before a folder was chosen"
    find(".filechooser-row", text: "cad").click
    # CHOOSE IS ON SCREEN AT 375px. The chooser's foot was one row inside an `overflow: hidden` panel and
    # put Cancel and Choose past its right edge, so a phone could not finish this upload; it wraps now
    # (components.css). Measured against the client width: CI's Linux Chrome draws a scrollbar.
    choose_right, cancel_right, edge = page.evaluate_script(<<~JS)
      (() => { const b = [...document.querySelectorAll('.filechooser-foot button')];
               const r = (t) => b.find((e) => e.textContent.trim() === t).getBoundingClientRect().right;
               return [r('Choose'), r('Cancel'), document.documentElement.clientWidth]; })()
    JS
    assert_operator choose_right, :<=, edge, "the chooser's Choose button sits off-screen (right #{choose_right} of #{edge})"
    assert_operator cancel_right, :<=, edge, "the chooser's Cancel button sits off-screen (right #{cancel_right} of #{edge})"
    click_on "Choose"
    # THE CAPTION IS READ AS TEXT (`visible: :all`): it heads Add's menu, closed now, but the chooser's
    # callback still writes it, just before it clicks the input — so no race.
    assert_selector "header.strip .topbar-upload-caption", text: "Saves to cad", visible: :all
    assert_equal 1, picks, "choosing a folder did not open the file picker"
    assert_equal @cad.node_id, find("header.strip .topbar-upload input[name='parent_node_id']", visible: :all).value
    assert_no_console_errors
  end

  test "on a folder, Add's Upload closes the menu and opens the picker with no chooser" do
    phone!
    visit files_path(folder: @cad.node_id)
    count_picks!
    open_upload.click
    # upload_forward_controller.js#open closes its menu and then clicks the button, inside one
    # synchronous `click()`, so waiting for the menu to close is waiting for the input's click too.
    assert_no_selector "header.strip .strip-add-menu[open]"
    assert_equal 1, picks, "Add's Upload did not open the file picker"
    assert_no_selector ".filechooser-overlay"
    assert_no_console_errors
  end

  # ONLY THE BUTTON HIDES, NEVER `.topbar-upload`. On the chunk flow the uploader's `.upload-status`
  # sits beside the button inside it, outside Add's menu, and an upload started from the menu writes
  # its progress there while the menu is closed; it hangs under the strip's rule at the right, so a
  # long line neither moves the strip nor pushes the account button off a phone. The flow is forced by
  # answering `port_writable?` false (the page's other questions go to the real port), and the status
  # is filled the way uploader_controller.js#setStatus fills it. At a phone's width and a desktop's.
  test "the chunk flow's upload progress shows under the strip, inside the screen" do
    FileLayer.current = Class.new(SimpleDelegator) do
      def capabilities = __getobj__.capabilities.with(port_writable: false)
    end.new(FileLayer.current)
    [ true, false ].each do |on_phone|
      on_phone ? phone! : page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      visit root_path
      # Which flow rendered, asked of the markup (`visible: :all`); what shows is the last assertion's.
      assert_selector "header.strip .topbar-upload section.uploader[data-controller='uploader']", visible: :all
      assert_selector "header.strip .topbar-upload button.upload-btn", visible: :hidden
      page.execute_script("document.querySelector('header.strip .upload-status').textContent = " \
                          "'Uploading a rather long file name for a phone, plate-for-the-bench-v12.dxf…'")
      assert_selector "header.strip .topbar-upload .upload-status", text: "Uploading a rather long"
      status, account, strip, client = page.evaluate_script(<<~JS)
        [ "header.strip .upload-status", "header.strip .strip-account", "header.strip" ]
          .map((s) => { const r = document.querySelector(s).getBoundingClientRect(); return [ r.left, r.right, r.bottom ]; })
          .concat([ document.documentElement.clientWidth ])
      JS
      where = on_phone ? "on a phone" : "at desktop width"
      assert_operator account[1], :<=, client, "the progress pushed the account button off the screen #{where}"
      assert_operator status[0], :>=, 0, "the progress runs off the left of the screen #{where} (#{status.inspect})"
      assert_operator status[1], :<=, client, "the progress runs off the right of the screen #{where} (#{status.inspect})"
      assert_operator strip[2], :<=, 53, "the progress made the strip taller #{where} (#{strip.inspect})"
    end
  end

  private

    def phone!
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    end

    def open_upload
      find("header.strip .strip-add-menu > summary").click
      find("header.strip .strip-add-menu button.strip-add-upload", text: "Upload…")
    end

    def count_picks!
      page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    end

    def picks = page.evaluate_script("window.__picks")
end
