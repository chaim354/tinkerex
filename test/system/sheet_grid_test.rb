require "application_system_test_case"

# THE SECOND SYSTEM TEST IN THIS REPO, and the first to cover the grid.
#
# It exists because 1587 green tests across three backends caught NEITHER shipped grid bug — both
# were client-side only and therefore structurally invisible to a server-side suite:
#
#   1. jspreadsheet-ce v5's factory is an ASYNC WORKBOOK api. Called with a flat {data, columns} it
#      throws INSIDE an uncatchable promise, so the grid renders permanently empty with no error
#      anywhere — it looks like a blank sheet, not a broken one.
#   2. The classic <script> tags needed data-turbo-track="reload": every real path to this page is a
#      Turbo VISIT, which merges <head> rather than reparsing, so untracked tags load async and
#      Stimulus connected before window.jspreadsheet existed.
#
# Both fail this test at the typing step, because both leave nothing to type into — verified by
# reintroducing each one and watching this go red on the missing <td>, with the failure screenshot
# showing the production symptom verbatim: "Grid failed to load".
#
# HOW TO MUTATION-CHECK (2), because the obvious version of it is a FALSE NEGATIVE and would
# libel this test as worthless: stripping data-turbo-track from that page's javascript_include_tag
# ALONE leaves this test GREEN. Turbo hashes ALL tracked elements on a page into one signature, and
# the sheet page's stylesheet_link_tag is tracked too — a single surviving tag the project page
# lacks still makes the signatures differ, so Turbo still does a real reload() and the race never
# happens. Strip BOTH tags to reproduce. That is a fact about the mechanism, not a gap here: this
# test asserts the behaviour (a Turbo-visited grid works), which is the thing worth pinning, and
# pinning the attribute instead would go green even if Turbo changed what it means.
class SheetGridTest < ApplicationSystemTestCase
  PASSWORD = "correct horse battery staple".freeze

  SHEET  = "[data-controller='sheet']".freeze
  GRID   = "#{SHEET} [data-sheet-target='grid']".freeze
  STATUS = "#{SHEET} [data-sheet-target='status']".freeze

  setup do
    @user = User.create!(email: "grid@example.com", password: PASSWORD, confirmed_at: Time.current)
    @project = @user.maker_projects.create!(name: "Lamp")
    @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                     data: Maker::Sheet.blank_data)

    visit new_user_session_path
    fill_in "user[email]", with: @user.email
    fill_in "user[password]", with: PASSWORD
    click_on "Log in"
    # Wait for Turbo to actually FOLLOW the login redirect before navigating (see
    # tray_layout_test.rb — without this the next visit races the redirect and 401s into the login
    # page, which reads exactly like the page failing to render).
    assert_current_path "/files"
  end

  test "a formula computes in the grid and persists as its raw text" do
    # REACHED BY A TURBO VISIT, NOT `visit sheet_path`. This is the single most important line in
    # the file and the easiest to lose in a later edit: a direct `visit` is a HARD LOAD, which is
    # the one path where the data-turbo-track bug does NOT reproduce. Clicking through from the
    # project page is what a real user does and what exercises the <head> merge.
    visit project_path(@project)
    click_on @sheet.name
    assert_current_path sheet_path(@sheet)

    # The grid is built asynchronously; wait for a real cell rather than for a fixed time.
    assert_selector "#{GRID} td", wait: 10

    # C1 STARTS EMPTY. Without this, both assertions about C1 below — the computed 42 and the stored
    # "=A1*B1" — could in principle be satisfied by the seeded blob rather than by anything the
    # browser did. A test has to own the value it checks. Read once rather than polled: this is a
    # precondition on state that already exists, so there is nothing to wait for.
    assert_equal "", stored_value(2, 0)

    fill_cell(0, 0, "6")
    fill_cell(1, 0, "7")
    fill_cell(2, 0, "=A1*B1")

    # THE COMPUTED VALUE. An empty grid never gets here — this is what catches both bugs. It is also
    # what proves the edit registered in the grid at all, which is why nothing below has to watch for
    # the transient "Saving…" to establish that.
    assert_equal "42", cell_text(2, 0)

    # THE RAW FORMULA, NOT THE RESULT. getData(false, false) reads the underlying data model, so
    # "=A1*B1" must come back as itself — persisting "42" instead would silently destroy every
    # formula in the sheet on the next load.
    #
    # POLLED, not read once, and NOT gated on the status indicator. The autosave is debounced 1000ms,
    # so a single read races it. The indicator cannot substitute: the span ships from the server
    # already reading "Saved" (show.html.erb:68), so it is vacuous before the first save, and
    # asserting the intermediate "Saving…" instead only moves the race — that string lives for one
    # debounce window, so a slow round-trip on a loaded runner misses it and the test flakes.
    # Polling the row is the only form that is neither vacuous nor timed.
    assert_persisted_cell(2, 0, "=A1*B1")
    # …and its operands went with it, so the formula still has something to multiply next time. They
    # rode the same save, so they are already on the row — polled anyway rather than switching to a
    # bare read, because one form for "what reached the database" is one fewer thing to get wrong
    # when someone later inserts an edit between these lines.
    assert_persisted_cell(0, 0, "6")
    assert_persisted_cell(1, 0, "7")

    # Now safe to assert, and only now: the polls above prove the save landed, so this can fail only
    # if the indicator itself lies. exact_text, not text — the failure wording is "Not saved — …",
    # which a substring match on "Saved" would happily accept as success.
    assert_selector STATUS, exact_text: "Saved"
  end

  private

    # Jspreadsheet renders a <td> per cell carrying data-x/data-y — VERIFIED in the vendored bundle
    # (createCell does `setAttribute("data-x", …)`/`setAttribute("data-y", …)`), not assumed from
    # docs. Column headers carry data-x ALONE, so requiring both is also what keeps this off them.
    def cell_selector(x, y) = "#{GRID} td[data-x='#{x}'][data-y='#{y}']"

    def cell(x, y) = find(cell_selector(x, y))

    # Types into a cell WITHOUT naming the editor element. Double-click opens the editor and focuses
    # it, so `:focus` is whatever the library actually created — deliberately class-name-independent,
    # because the bundle builds the editor with a bare createElement("input") whose class names are
    # internal, and pinning one would make this test fail on a library upgrade for a reason that has
    # nothing to do with the behaviour under test. Scoped INSIDE the cell rather than a bare
    # find(":focus"): when no editor opens at all, `:focus` resolves to <body> and the failure would
    # read as a weird `set` error somewhere else instead of "this cell never became editable".
    def fill_cell(x, y, value)
      cell(x, y).double_click
      editor = find("#{cell_selector(x, y)} :focus")
      editor.set(value)
      editor.send_keys(:enter)
    end

    def cell_text(x, y) = cell(x, y).text.strip

    # Waits on the DATABASE rather than the DOM. Capybara's waiting matchers don't help here — the
    # value never appears on the page. Hand-rolled rather than reached for out of habit: the thing
    # being waited on is a debounced write landing on a row, and every DOM-shaped alternative either
    # asserts something vacuous or races the debounce (see the call site).
    def assert_persisted_cell(x, y, expected, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      actual = nil
      loop do
        actual = stored_value(x, y)
        break if actual == expected
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
      assert_equal expected, actual, "cell (#{x},#{y}) never persisted as #{expected.inspect}"
    end

    # The single raw read of the stored blob — what the poll above spins on, and what the test's
    # empty-C1 precondition reads once. `fetch`, not `[]`: a malformed or half-written blob then
    # names the missing key instead of failing later as a nil somewhere unrelated.
    def stored_value(x, y) = @sheet.reload.data.fetch("cells").fetch(y).fetch(x)
end
