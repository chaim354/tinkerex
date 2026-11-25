require "application_system_test_case"

# A TOOL KEEPS ITS PLACE FOR 15 MINUTES AFTER ITS PAGE IS LEFT (2026-11-24; spec
# docs/superpowers/specs/2026-11-24-back-button-and-kept-tools-design.md). The owner's words: "tools
# should have some permanence so you can jump back and forth when working on it". Before this,
# leaving an add-on's page tore the tool down and the Material estimate came back an empty form.
#
# WHAT IS KEPT IS THE TOOL, NOT A COPY OF ITS VALUES, and the tests ask for exactly that: a marker
# set on an ELEMENT (a JavaScript property no copy carries) has to come back with it, the bundle's
# teardown handler must not have fired, and the host the bundle reads must answer. A typed value
# surviving would be true of a careful serialiser too.
#
# EVERY RETURN HERE IS A TURBO VISIT, NEVER `visit`. Capybara's `visit` loads a new document, which
# empties the page's memory, so a "comes back fresh" assertion made after one passes whether or not
# anything was ever kept. Leaving is a click on the rail; returning is the top bar's Back, a link, or
# `Turbo.visit`.
#
# THE CLOCK IS THE PAGE'S OWN `Date.now`, MOVED. Nothing waits 15 minutes: kept_tools.js asks the
# clock when a session is taken back, which is the check that matters on a laptop that slept.
#
# MUTATION-CHECKED (2026-11-24; each reverted, and the file re-run green after):
#   1. addon_controller.js#disconnect ending the host as it always did (no keep): all six add-on
#      tests red, the tool back from its defaults and the teardown handler fired on the way out.
#   2. kept_tools.js#take ignoring `expiresAt`: the 15-minute test red, the tool handed back late.
#   3. kept_tools.js#take ignoring `owner`: the other-account test red, the second account shown
#      the first one's text.
#   4. kept_tools.js's `submit` listener removed: the sign-out test red, the tool still running.
#   5. `take` handing a session to any URL of its tool (no `plain` test): the named-link test red.
#   6. keep_controller.js#disconnect keeping nothing: the Material estimate test red, an empty form.
#   7. tools/_resumed no longer asking for `no-preview`: both tests that read the meta tag red. The
#      flash it prevents was seen as a flake first: one run in three, the other-account test read
#      the first account's text out of Turbo's preview of the page before the fresh tool replaced it.
#   8. Either "Search everything" form given `turbo: false` back: the search test red, the page's
#      memory gone after the first search (the top bar's) or after the second (the results page's).
class KeptToolsTest < ApplicationSystemTestCase
  SIDECAR_URL = "http://kept-tools-sidecar.test".freeze
  TOOL = "/tools/sdk-fixture".freeze
  ART = "[data-role=sdk-art]".freeze
  # What the fixture's textarea holds when the bundle has just mounted (sdk-fixture/sdk.js's ART).
  FRESH_ART = "+-+-+-+\n| | | |\n+-+-+-+\n".freeze

  setup do
    @root = use_fresh_share_library!
    @prior_addon_source_path = ENV["ADDON_SOURCE_PATH"]
    ENV["ADDON_SOURCE_PATH"] = Rails.root.join("test/fixtures/addons").to_s
    # The fixture declares `fixture-svc`, so its page mounts only where that service has a URL
    # (addon_sdk_test.rb's setup says why). Nothing here calls it.
    ENV["FIXTURE_SVC_SIDECAR_URL"] = SIDECAR_URL
    @user = sign_in_as("kept-tools@example.com")
  end

  teardown do
    ENV["ADDON_SOURCE_PATH"] = @prior_addon_source_path
    ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # An expression over the SDK module `m`, evaluated in the page. The page's own import map resolves
  # the specifier, so `m.host` is the binding every bundle reads.
  def sdk(expression)
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      import("@maker/addon-sdk").then(
        (m) => { try { done(#{expression}) } catch (e) { done("threw " + (e.code || e.message)) } },
        (e) => done("import failed: " + e.message))
    JS
  end

  # Opens the fixture, types into it, marks the textarea ELEMENT, and counts its host's teardowns.
  def open_tool_and_work(text, path: TOOL)
    visit path
    assert_selector "[data-role=sdk-level]", text: /\Alevel \d+\z/
    find(ART).set(text)
    page.execute_script("document.querySelector(arguments[0]).keptMarker = 'the same element'", ART)
    page.execute_script("window.keptTeardowns = 0")
    sdk("(m.host.on('teardown', () => { window.keptTeardowns += 1 }), true)")
  end

  def leave_for_the_library
    within("aside.rail") { click_on "Library" }
    assert_current_path files_path
  end

  def turbo_visit(path)
    page.execute_script("Turbo.visit(arguments[0])", path)
  end

  def marker = page.evaluate_script("document.querySelector(arguments[0]).keptMarker", ART)
  def teardowns = page.evaluate_script("window.keptTeardowns")
  def move_clock_minutes(minutes)
    page.execute_script(<<~JS, minutes * 60_000)
      window.keptSkew = (window.keptSkew || 0) + arguments[0]
      if (!window.keptRealNow) { window.keptRealNow = Date.now.bind(Date); Date.now = () => window.keptRealNow() + window.keptSkew }
    JS
  end

  def assert_resumed(text)
    assert_selector ".tool-resumed", text: "Picked up where you left off."
    assert_equal text, find(ART).value
    assert_equal "the same element", marker, "the tool was rebuilt: this textarea is not the one that was left"
  end

  # A page that keeps a tool takes no Turbo preview (tools/_resumed says why).
  def assert_no_preview
    assert_selector "meta[name='turbo-cache-control'][content='no-preview']", visible: :all, count: 1
  end

  def assert_fresh
    assert_selector "[data-role=sdk-level]", text: /\Alevel \d+\z/
    assert_no_selector ".tool-resumed"
    assert_equal FRESH_ART, find(ART).value
    assert_nil marker
  end

  test "an add-on left for another page comes back as it was: the same elements, its host alive" do
    open_tool_and_work("a tray, half drawn")
    assert_no_preview
    leave_for_the_library

    assert_equal 0, teardowns, "leaving the page tore the tool down"
    assert_kind_of Integer, sdk("m.host.level"), "the kept tool's host is no longer bound"

    find("header.topbar a.topbar-back").click
    assert_current_path TOOL
    assert_resumed "a tray, half drawn"
    assert_equal 0, teardowns

    # The host answers, and its picker still opens: the chooser is a closure the kept host brought
    # back with it.
    find("[data-role=sdk-url-probe]").click
    assert_selector "[data-role=sdk-url-guards]", text: /\Aname=AddonError:\w+ path=AddonError:\w+\z/
    assert_no_selector "[data-role=sdk-url-guards]", text: "host_not_initialized"
    find("[data-role=sdk-pick]").click
    assert_selector ".filechooser[role=dialog]"
    find(".filechooser-cancel").click
    assert_selector "[data-role=sdk-picked]", exact_text: "cancelled"
    assert_no_console_errors
  end

  test "the tool's own link resumes it too, and Start over mounts it from nothing" do
    open_tool_and_work("resumed by a link")
    leave_for_the_library
    within("aside.rail") { click_on "Tools" }
    click_on "SDK Fixture"
    assert_current_path TOOL
    assert_resumed "resumed by a link"

    click_on "Start over"
    assert_fresh
    assert_equal 1, teardowns, "Start over left the old tool running"
    assert_no_console_errors
  end

  test "a tool comes back within 15 minutes and from nothing after them" do
    open_tool_and_work("left at the bench")
    leave_for_the_library
    move_clock_minutes(14)
    turbo_visit(TOOL)
    assert_resumed "left at the bench"

    # Each leaving starts the 15 minutes again.
    leave_for_the_library
    move_clock_minutes(16)
    turbo_visit(TOOL)
    assert_fresh
    assert_equal 1, teardowns, "the session ended without its host being torn down"
    assert_no_console_errors
  end

  # THE SEARCH BOX IS ON EVERY PAGE, A TOOL'S INCLUDED, and it used to load a new document
  # (`turbo: false`), which empties the memory a kept tool lives in. Returned to by a LINK on
  # purpose: after a page load the browser's Back may restore the old document whole, tool and all,
  # which would pass here without anything having been kept.
  test "a search from the top bar does not cost the tool" do
    open_tool_and_work("searched away from")
    find("header.topbar .topbar-search input[type=search]").set("bracket").send_keys(:enter)
    assert_current_path search_path, ignore_query: true
    assert_selector ".search-toolbar input[type=search]"
    assert_equal 0, teardowns, "the search loaded a new document: the page's memory is gone"

    # The results page's own box is the same form, and a second search from it is as likely.
    find(".search-toolbar input[type=search]").set("lid").send_keys(:enter)
    assert_selector ".search-toolbar input[type=search][value='lid']"
    assert_equal 0, teardowns, "the results page's own box loaded a new document"
    within("aside.rail") { click_on "Tools" }
    click_on "SDK Fixture"
    assert_resumed "searched away from"
    assert_no_console_errors
  end

  # ONE SESSION PER TOOL. A link that names something else (another saved item, another file) is a
  # request for that, so it mounts fresh, and the kept session ends rather than running beside it:
  # two live mounts of one bundle would share its module-level state.
  test "a link naming something else mounts fresh; the plain link resumes whatever was last open" do
    open_tool_and_work("the first design")
    leave_for_the_library
    turbo_visit("#{TOOL}?fname=other.svg")
    assert_fresh
    assert_equal 1, teardowns, "the first session went on running behind the second"

    find(ART).set("the second design")
    page.execute_script("document.querySelector(arguments[0]).keptMarker = 'the same element'", ART)
    leave_for_the_library
    turbo_visit(TOOL)
    assert_resumed "the second design"
    assert_no_console_errors
  end

  # THE TAB OUTLIVES A SIGN-OUT. The second account signs in from another window, so this window
  # never loads a page between the two: its memory still holds the first account's tool, and only
  # the owner check stands between that tool and the next page that asks for it.
  test "another account is never handed a kept tool" do
    open_tool_and_work("the first account's text")
    leave_for_the_library

    within_window(open_new_window) do
      visit root_path
      within("aside.rail") { click_button "Sign out" }
      assert_selector "form[action='#{user_session_path}']"
      sign_in_as("kept-tools-other@example.com")
    end

    turbo_visit(TOOL)
    assert_fresh
    assert_equal 1, teardowns
    assert_no_text "the first account's text"
  end

  test "signing out ends every kept tool" do
    open_tool_and_work("signed out over")
    leave_for_the_library
    assert_equal 0, teardowns

    within("aside.rail") { click_button "Sign out" }
    assert_selector "form[action='#{user_session_path}']"
    # The same document: `keptTeardowns` is this window's own, and a page load would have erased it.
    assert_equal 1, teardowns, "the tool was still running behind the sign-in page"
  end

  # THE BUILT-IN TOOL. Its state is its form, so the form is what is kept: the parts (hidden fields),
  # a typed quantity, the results the last answer drew. It still WORKS when it returns, which is the
  # half a snapshot of the page could not give: its controller reconnects and the next quantity
  # re-figures, the kept form's own CSRF token notwithstanding.
  test "the Material estimate comes back with its parts and its numbers, and goes on working" do
    visit tools_material_path
    assert_no_preview
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"
    attach_file "material-uploads", [ Rails.root.join("test/fixtures/files/plate.svg").to_s ]
    assert_selector ".material-parts-table tbody tr", count: 1
    find("input[aria-label='Quantity of plate.svg']").set("5")
    assert_selector ".material-sheet-count", text: /\A2 × 200 × 100 mm\z/

    leave_for_the_library
    find("header.topbar a.topbar-back").click
    assert_current_path tools_material_path
    assert_selector ".tool-resumed", text: "Picked up where you left off."
    assert_selector ".material-parts-table tbody tr", count: 1
    assert_equal "5", find("input[aria-label='Quantity of plate.svg']").value
    assert_selector ".material-sheet-count", text: /\A2 × 200 × 100 mm\z/

    find("input[aria-label='Quantity of plate.svg']").set("9")
    assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/

    click_on "Start over"
    assert_no_selector ".tool-resumed"
    assert_no_selector ".material-parts-table tbody tr"
    assert_no_console_errors
  end
end
