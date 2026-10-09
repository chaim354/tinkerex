require "application_system_test_case"

# ONE "+" ON A PHONE (structural redesign spec §4.3, slice 7). At 719px and below the New summary reads
# "+", the top bar's upload LABEL hides, and the New menu's first item is "Upload…", which forwards a
# click to that label (upload_forward_controller.js). A request test sees the button and its action;
# only a browser sees which of the two is shown at which width, and that the forwarded click takes the
# same road a tap on the label does — the chooser on a page with no folder, the file picker on a folder.
#
# The viewport is set through CDP for the reason shell_test.rb records (headless Chrome will not make a
# WebDriver window narrower than 500px). The picks counter is topbar_upload_test.rb's: headless Chrome
# shows no file picker, so it counts the click the input receives — it proves the call, not the dialog.
#
# MUTATION-CHECKED (slice 7, Task 2):
#   1. upload_forward_controller.js clicking `#topbar_upload_file` instead of the label — the Recent test
#      goes red at the chooser: the input-targeted click is the one upload_pick_controller.js lets
#      through, so no chooser opens and the picker would open on the library root unasked.
#   2. shell.css hiding all of `.topbar-upload` instead of its label — the chunk-flow test goes red: the
#      progress text an upload started from the menu writes has nowhere to show.
#   3. Dropping `.topbar-new-upload` from the desktop-hide rule — the desktop test goes red: "Upload…"
#      shows, because nothing else outranks `.menu-item`'s own `display: flex`.
#   4. `display: block` for `revert-layer` in the phone block — the first test goes red on the display.
class PhoneTopbarSystemTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("phone-topbar@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "on a phone the top bar has one '+', and Upload is the first thing in it" do
    phone!
    visit root_path
    summary = find("header.topbar .topbar-new > summary")
    assert_equal "+", summary.text
    assert_equal "New and upload", summary["aria-label"]
    # ONE ROW FOR THE BREADCRUMB AND THE "+", AND SEARCH BELOW BOTH (spec §4.3): the "+"'s middle sits
    # inside the crumbs' line, and the search box starts below the lower of the two.
    crumbs, plus, search = page.evaluate_script(<<~JS)
      [ ".topbar-crumbs", ".topbar-new > summary", ".topbar-search" ].map((s) => {
        const r = document.querySelector("header.topbar " + s).getBoundingClientRect(); return [ r.top, r.bottom ]; })
    JS
    plus_middle = (plus[0] + plus[1]) / 2
    assert plus_middle.between?(crumbs[0], crumbs[1]) || (crumbs[0] + crumbs[1]) / 2 <= plus[1] && (crumbs[0] + crumbs[1]) / 2 >= plus[0],
           "the + is not on the breadcrumb's row (crumbs #{crumbs.inspect}, + #{plus.inspect})"
    assert_operator search[0], :>=, [ crumbs[1], plus[1] ].max - 1, "the search box is not on its own row below them"
    # PRESENT AND HIDDEN, not merely absent: absence would mean the partial stopped rendering the label
    # the "+" forwards to, which is a broken Upload rather than a phone layout.
    assert_selector "header.topbar .topbar-upload label.upload-btn", visible: :hidden

    summary.click
    assert_selector "header.topbar .topbar-new .menu-list > button.menu-item.topbar-new-upload:first-child", text: "Upload…"
    assert_selector "header.topbar .topbar-new .menu-sep.topbar-new-upload"
    # The item lays out as its siblings do. shell.css hands it back its component's own display
    # (`revert-layer`) rather than restating one, so a `block` there would sit its text at the top.
    upload, sibling = page.evaluate_script(<<~JS)
      [ getComputedStyle(document.querySelector("header.topbar .topbar-new-upload.menu-item")).display,
        getComputedStyle(document.querySelector("header.topbar .topbar-new a.menu-item")).display ]
    JS
    assert_equal sibling, upload
    assert_no_console_errors
  end

  test "on Recent, the phone's Upload asks for a folder first and then opens the picker" do
    phone!
    visit root_path
    count_picks!
    open_plus.click
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
    # THE CAPTION IS READ AS TEXT (`visible: :all`): it hides below 1100px, so a phone never shows it,
    # but the chooser's callback still writes it, just before it clicks the input — so no race.
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to cad", visible: :all
    assert_equal 1, picks, "choosing a folder did not open the file picker"
    assert_equal @cad.node_id, find("header.topbar .topbar-upload input[name='parent_node_id']", visible: :all).value
    assert_no_console_errors
  end

  test "on a folder, the phone's Upload opens the picker with no chooser" do
    phone!
    visit files_path(folder: @cad.node_id)
    count_picks!
    open_plus.click
    # THE FORWARDED LABEL CLICK CLOSES THE MENU (menu_controller.js sees it land outside), and it does
    # so inside the same synchronous `click()` that then clicks the input. Waiting for the menu to
    # close is therefore waiting for the input's click too.
    assert_no_selector "header.topbar .topbar-new[open]"
    assert_equal 1, picks, "the phone's Upload did not open the file picker"
    assert_no_selector ".filechooser-overlay"
    assert_no_console_errors
  end

  test "at desktop width Upload stays in the top bar and the New menu has no Upload item" do
    visit root_path
    summary = find("header.topbar .topbar-new > summary")
    assert_equal "New ▾", summary.text
    assert_selector "header.topbar .topbar-upload label.upload-btn", text: "Upload"

    summary.click
    assert_selector "header.topbar .topbar-new a.menu-item", text: "Text file"
    assert_no_selector "header.topbar .topbar-new-upload"
    assert_selector "header.topbar .topbar-new-upload", visible: :hidden, count: 2
  end

  # ONLY THE LABEL HIDES, NEVER `.topbar-upload`. On the chunk flow the uploader's `.upload-status` sits
  # beside the label inside it, and an upload started from the menu writes its progress there. The flow
  # is forced by answering `port_writable?` false (the page's other questions go to the real port), and
  # the status is filled the way uploader_controller.js#setStatus fills it.
  test "on a phone the chunk flow's upload progress still shows" do
    FileLayer.current = Class.new(SimpleDelegator) do
      def capabilities = __getobj__.capabilities.with(port_writable: false)
    end.new(FileLayer.current)
    phone!
    visit root_path
    # Which flow rendered, asked of the markup (`visible: :all`); what shows is the last assertion's.
    assert_selector "header.topbar .topbar-upload section.uploader[data-controller='uploader']", visible: :all
    assert_selector "header.topbar .topbar-upload label.upload-btn", visible: :hidden
    page.execute_script("document.querySelector('header.topbar .upload-status').textContent = 'Uploading plate.dxf…'")
    assert_selector "header.topbar .topbar-upload .upload-status", text: "Uploading plate.dxf…"
  end

  private

    def phone!
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    end

    def open_plus
      find("header.topbar .topbar-new > summary").click
      find("header.topbar .topbar-new button.topbar-new-upload", text: "Upload…")
    end

    def count_picks!
      page.execute_script("window.__picks = 0; document.getElementById('topbar_upload_file').addEventListener('click', () => window.__picks++)")
    end

    def picks = page.evaluate_script("window.__picks")
end
