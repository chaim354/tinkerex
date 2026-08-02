require "application_system_test_case"
require_relative "../support/fake_boxes"

# The Box Generator's collapsible sections, its table of contents, and the editor's self-starting
# preview. Every one of these is browser-only in the sense test/system/README.md asks for:
#
#   1. `<details>` open/closed is a DOM property the user toggles — a request test can assert the
#      SHIPPED state (and boxes_controller_test does), never what happens after a click.
#   2. The layout the user leaves behind lives in localStorage, so "still collapsed next visit"
#      needs a real second page load in a real browser.
#   3. The editor's first render fires from `connect()`, with nothing clicked. There is no request
#      to assert and no attribute that proves it — only an <img> that acquires a src on its own.
#   4. Filtering must REVEAL a match hidden inside a collapsed section, and must then put the
#      layout back. That interaction is two Stimulus controllers on one element agreeing about who
#      owns `open`, which is exactly the seam a server-side test cannot see.
#
# MUTATION-CHECKED (2026-08-02) — each reverted, watched go red, restored. Named per test below.
class BoxSectionsTest < ApplicationSystemTestCase
  # FakeBoxes gives ABox a sample photo and the other two none, so the gallery's <img> 404s on
  # purpose and the thumbfallback controller hides it. Chrome logs that at SEVERE. See
  # `assert_no_console_errors(ignoring:)`.
  SAMPLE_404 = %r{/tools/boxes/thumb/\w+ - Failed to load resource.+404}

  setup do
    Tools::BoxesClient.stub = FakeBoxes.new
    sign_in_as "sections@example.com"
  end

  teardown { Tools::BoxesClient.reset! }

  # Capybara's matchers wait on the DOM; an <img> swapping its src is a property read, so poll it.
  def wait_until(timeout: 5, message: "condition never became true")
    deadline = Time.now + timeout
    sleep 0.05 until yield || Time.now > deadline
    assert yield, message
  end

  # Capybara's `assert_no_selector` takes no failure message, and these negatives are the whole
  # point of most of these tests — "it was still open" needs to say WHICH claim broke.
  def assert_closed(selector, message)
    assert page.has_no_selector?("#{selector}[open]"), message
  end

  def assert_open(selector, message)
    assert page.has_selector?("#{selector}[open]"), message
  end

  # Typed, never `set`. Selenium's `set` is clear()-then-send_keys, and clear() does not reliably
  # fire `input` — which is the event boxfilter listens to. That makes `set("")` a no-op for the
  # filter, and "clearing the box puts the layout back" is precisely what this file has to prove.
  def search_for(text)
    field = find("input.box-search")
    field.click
    field.value.length.times { field.send_keys(:backspace) }
    field.send_keys(text) unless text.empty?
  end

  # MUTATION: made `jump` fall through to the browser's default #hash navigation (dropped the
  # preventDefault + `section.open = true`) — red, the section stayed shut.
  test "a table-of-contents entry opens the section it points at, even when that section is shut" do
    visit tools_boxes_path
    find("#box-section-tray > summary").click
    assert_closed "#box-section-tray", "clicking the summary should have folded it"

    find("nav.box-toc a[href='#box-section-tray']").click
    assert_selector "#box-section-tray[open]"
    assert_selector "#box-section-tray .addon-title", text: "TypeTray"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: dropped the localStorage write in `#persist` — red, the section came back open.
  test "what you fold away stays folded on the next visit" do
    visit tools_boxes_path
    assert_selector "#box-section-box[open]"
    find("#box-section-box > summary").click
    assert_closed "#box-section-box", "clicking the summary should have folded it"

    visit tools_boxes_path
    assert_closed "#box-section-box", "the collapsed section was not remembered"
    assert_open "#box-section-tray", "an untouched section must keep its shipped state"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # The whole reason persistence hangs off a summary CLICK rather than the `toggle` event: filtering
  # opens sections by assigning `.open`, which fires `toggle` too. Storing that would mean a search
  # silently rewrote the layout you had arranged.
  #
  # THE DEPARTURE MID-SEARCH IS THE LOAD-BEARING STEP, and the first draft of this test did not have
  # it. Persisting on `toggle` passed everything else, because boxfilter puts the prior state back
  # when the query is cleared — so storage lands on the right value anyway. The bug only exists for
  # someone who LEAVES while a filter is still applied, which is why the reload happens there.
  #
  # MUTATION: moved persistence onto the `toggle` event (`#onToggle` also calling `#persist`) — green
  # against the first draft, RED here at "a search must not persist as a choice".
  test "a search reveals matches inside collapsed sections without rewriting your layout" do
    visit tools_boxes_path
    find("#box-section-tray > summary").click
    assert_closed "#box-section-tray", "clicking the summary should have folded it"

    search_for "typetray"
    assert_open "#box-section-tray", "a match inside a collapsed section is a match nobody can see"
    assert_no_selector "#box-section-box", visible: true
    assert_no_selector "nav.box-toc a[href='#box-section-box']", visible: true

    # Walk away with the filter still on: nothing the search opened may have been banked.
    visit tools_boxes_path
    assert_closed "#box-section-tray", "a search must not persist as a choice"

    # And clearing the box in place puts the borrowed layout back.
    search_for "typetray"
    search_for ""
    assert_selector "#box-section-box", visible: true
    assert_closed "#box-section-tray", "clearing the box must put the layout back"
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: removed the `this.preview()` call from `connect()` — red, the <img> never got a src.
  test "the editor renders the generator's defaults with nothing clicked, then follows an edit" do
    visit new_tools_box_path(generator: "ABox")
    img = find("[data-boxpreview-target='image']", visible: :all)
    wait_until(message: "the default box was never previewed") { img[:src].to_s.start_with?("blob:") }

    first = img[:src]
    fill_in "params[x]", with: "222"
    # MUTATION: removed the debounced #onEdit listener — red here, the src never changed.
    wait_until(message: "editing a param did not refresh the preview") { img[:src] != first }
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end

  # MUTATION: reverted _form.html.erb's basic groups to plain <fieldset> — red, the summary click
  # found no element to fold.
  test "every param group folds, and collapse-all folds them together" do
    visit new_tools_box_path(generator: "ABox")
    assert_selector "#param-group-abox-settings[open]"
    assert_closed "#param-group-settings-for-finger-joints", "an advanced group starts folded"

    # A basic group folds too — that is the change; only the advanced ones could before.
    find("#param-group-abox-settings > summary").click
    assert_closed "#param-group-abox-settings", "a basic group must fold like any other"

    click_on "Expand all"
    assert_selector "#param-group-abox-settings[open]"
    assert_selector "#param-group-settings-for-finger-joints[open]"
    click_on "Collapse all"
    assert_closed "#param-group-abox-settings", "collapse-all left a basic group open"
    assert_closed "#param-group-settings-for-finger-joints", "collapse-all left an advanced group open"

    # Folded or not, the fields stay in the DOM, so they are still submitted.
    assert_selector "select[name='params[FingerJoint_style]']", visible: :all
    assert_no_console_errors ignoring: [ SAMPLE_404 ]
  end
end
