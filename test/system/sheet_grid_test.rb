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

  # sheet_controller.js's question, in the words the other editors ask it.
  LEAVE = "Leave without saving your changes?".freeze

  setup do
    @user = User.create!(email: "grid@example.com", password: PASSWORD, confirmed_at: Time.current)
    @project = @user.maker_projects.create!(name: "Lamp")
    @sheet = @project.sheets.create!(user: @user, name: "Cut list", position: 0,
                                     data: Maker::Sheet.blank_data)

    visit new_user_session_path
    fill_in "user[email]", with: @user.email
    fill_in "user[password]", with: PASSWORD
    click_on "Sign in"
    # Wait for Turbo to actually FOLLOW the login redirect before navigating (see
    # tray_layout_test.rb — without this the next visit races the redirect and 401s into the login
    # page, which reads exactly like the page failing to render).
    assert_current_path "/"
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

  # THE DEBOUNCE WINDOW IS WHERE AN EDIT USED TO DIE. The autosave waits a second after the last
  # keystroke, and leaving the page inside that second dropped the edit: the waiting timer was
  # cleared (a Turbo render) or died with the document (every real way out of this page is a full
  # load, see show.html.erb on data-turbo-track), while the status still read "Saving…".
  #
  # THE DEBOUNCE IS STRETCHED TO A MINUTE HERE, AND THAT IS WHAT MAKES THIS A TEST OF LEAVING. With
  # the real second, a slow runner can take longer than that to fetch the next page, the timer fires
  # on its own, and the test goes green over a controller that never sends anything on the way out.
  test "an edit followed at once by leaving the page is saved" do
    open_sheet
    assert_equal "", stored_value(0, 0)
    debounce 60_000
    record_unload

    fill_cell(0, 0, "kept")
    within("nav.breadcrumb") { click_on @project.name }
    assert_current_path project_path(@project)

    assert_persisted_cell(0, 0, "kept")
    # THE SAVE WENT FIRST, SO NOTHING WAS LEFT TO ASK ABOUT. Leaving this page ends in a full load
    # (show.html.erb), which fires `beforeunload`; a guard that asked here would put the browser's
    # "Leave site?" in front of every ordinary link.
    assert_equal "false", unload_asked
  end

  # BACK, A CLOSED TAB, A TYPED ADDRESS: THE WAYS OUT THAT CANNOT BE MADE TO WAIT. Turbo raises no
  # `turbo:before-visit` for a history step, so the only hook is `beforeunload`, which cannot hold a
  # navigation for a request. The page does the two things it can: it asks (a cancelled
  # `beforeunload` is the browser's cue to draw "Leave site?"), and it sends the edit on the spot in
  # a form the browser finishes after the page is gone.
  #
  # THE EVENT IS ASSERTED, NOT THE DIALOG, for the reason page_editor_test.rb measured: this headless
  # Chrome draws no `beforeunload` dialog and goes straight through, which is also what makes the
  # second assertion a real one — nothing here waits for the request.
  test "Back with an edit still waiting asks, and sends the edit as it goes" do
    open_sheet
    debounce 60_000
    record_unload

    fill_cell(0, 0, "kept")
    page.go_back
    assert_current_path project_path(@project)

    assert_equal "true", unload_asked, "Back with an unsaved edit did not meet a cancelled beforeunload"
    assert_persisted_cell(0, 0, "kept")
  end

  # THE CONTROL FOR THE TEST ABOVE: a guard that always asked would pass it.
  test "Back from a sheet with nothing waiting asks nothing" do
    open_sheet
    record_unload

    fill_cell(0, 0, "kept")
    assert_persisted_cell(0, 0, "kept")
    assert_selector STATUS, exact_text: "Saved"
    page.go_back
    assert_current_path project_path(@project)

    assert_equal "false", unload_asked
  end

  # ONE SAVE AT A TIME. Every save posts the whole grid and the server keeps whichever arrives last
  # (Projects::SheetsController#update), so two requests open at once can land in the wrong order
  # and put an older grid over a newer one. The first save is held at the door here, the way a slow
  # network holds it; the second edit must wait behind it instead of going out beside it.
  test "a later edit is saved after a slow earlier save, never alongside it" do
    open_sheet
    debounce 50
    hold_saves

    fill_cell(0, 0, "first")
    wait_for_js "window.__saves.waiting.length === 1"
    fill_cell(1, 0, "second")
    refute_js_within 1.0, "window.__saves.open > 1", "a second save went out while the first was still open"

    release_save
    wait_for_js "window.__saves.waiting.length === 1"
    release_save

    assert_persisted_cell(0, 0, "first")
    assert_persisted_cell(1, 0, "second")
    assert_equal 1, page.evaluate_script("window.__saves.most")
  end

  # "SAVED" MEANS EVERYTHING, NOT THE LAST ANSWER TO ARRIVE. An older save coming back used to write
  # "Saved" over an edit that had not gone anywhere yet.
  test "the status reads Saved only when nothing edited is still waiting" do
    open_sheet
    debounce 50
    hold_saves

    fill_cell(0, 0, "first")
    wait_for_js "window.__saves.waiting.length === 1"
    fill_cell(1, 0, "second")
    # Give the second edit's debounce time to run out, so the old controller has sent it too and both
    # shapes of the code are past their timers when the first answer comes back.
    sleep 0.3

    release_save
    wait_for_js "window.__saves.done === 1"
    assert_equal "Saving…", find(STATUS).text

    release_saves_as_they_come
    assert_persisted_cell(1, 0, "second")
    assert_selector STATUS, exact_text: "Saved"
  end

  # A RENDER THE PAGE WAS NOT ASKED ABOUT. A history step onto a page Turbo can draw in place, or a
  # stream that replaces the element, disconnects the controller with no event before it; what is
  # waiting has to go out before the grid it is read from does.
  test "an edit waiting when the grid is taken off the page is still saved" do
    open_sheet
    debounce 60_000

    fill_cell(0, 0, "kept")
    page.execute_script("document.querySelector(\"#{SHEET}\").remove()")

    assert_persisted_cell(0, 0, "kept")
  end

  # THE SAME, WITH A SAVE ALREADY OPEN. The edit made behind it cannot go until that request
  # answers, and by then the grid has been destroyed. jspreadsheet still answers for a destroyed
  # grid (its data, headers and widths, probed 2026-11-16), which is what the controller leans on:
  # this test is the notice if an upgrade ever stops that, and the columns are checked because a
  # grid that answered with none would wipe the sheet's headers while the cells looked fine.
  test "an edit made behind an open save is still saved when the grid is taken off the page" do
    open_sheet
    debounce 50
    hold_saves

    fill_cell(0, 0, "first")
    wait_for_js "window.__saves.waiting.length === 1"
    fill_cell(1, 0, "second")
    page.execute_script("document.querySelector(\"#{SHEET}\").remove()")
    release_saves_as_they_come

    assert_persisted_cell(0, 0, "first")
    assert_persisted_cell(1, 0, "second")
    assert_equal Maker::Sheet.blank_data["columns"], @sheet.reload.data["columns"]
    assert_no_console_errors
  end

  # THE PAGE'S OWN RENAME RELOADS THE PAGE, and the reload draws the grid from the database. An edit
  # still waiting has to be there first, or the page comes back without it and the next save posts
  # a grid that never had it.
  test "renaming right after an edit keeps the edit and still says what was renamed" do
    open_sheet
    debounce 60_000

    fill_cell(0, 0, "kept")
    # CLICKED, THEN FILLED. The grid listens for keys on the whole document while one of its cells
    # is selected and lets go only on a mouse press outside it, which is what a person does on the
    # way to this field. `fill_in` alone focuses by script, and the typing lands in the grid.
    find_field("sheet[name]").click
    fill_in "sheet[name]", with: "Offcuts"
    click_on "Rename"

    assert_selector ".flash-stack .flash-notice", text: "Renamed the sheet to “Offcuts”."
    assert_selector "#{GRID} td", wait: 10
    assert_equal "kept", cell_text(0, 0)
    assert_equal "kept", stored_value(0, 0)
  end

  # A SAVE THE SERVER REFUSED CANNOT BE WAITED FOR. The visit is held while the save is tried once
  # more; when that is refused too, the status line already says why, and going is the person's
  # call, asked in the words the other editors use. The refusal is the real one: a grid over the
  # model's size limit (Maker::Sheet::MAX_DATA_BYTES).
  test "leaving after a refused save asks first, and leaving anyway asks only once" do
    open_sheet
    debounce 50
    record_unload

    set_cell(0, 0, "x" * (Maker::Sheet::MAX_DATA_BYTES + 1))
    assert_selector STATUS, text: "Not saved"

    dismiss_confirm(LEAVE) { within("nav.breadcrumb") { click_on @project.name } }
    assert_current_path sheet_path(@sheet)

    accept_confirm(LEAVE) { within("nav.breadcrumb") { click_on @project.name } }
    assert_current_path project_path(@project)
    # The full load this page's exits end in fires `beforeunload`, and the person has already
    # answered.
    assert_equal "false", unload_asked
  end

  # DELETE TAKES THE EDITS WITH IT. Its redirect is a visit like any other, and a guard that held it
  # to save a grid whose sheet is gone would end on a refusal and a question about leaving.
  test "deleting a sheet right after an edit just deletes it" do
    open_sheet
    debounce 60_000
    record_unload

    fill_cell(0, 0, "doomed")
    accept_confirm("Delete the sheet Cut list? Its rows go with it.") { click_on "Delete" }

    assert_current_path project_path(@project)
    assert_equal "false", unload_asked
    assert_not Maker::Sheet.exists?(@sheet.id)
  end

  # A SHEET THAT IS GONE HAS NOTHING LEFT TO SAVE, AND SAYS SO. Deleted in another tab, or by the
  # page's own Delete a moment ago: the save is answered 404, which is the server saying there is
  # no sheet, and no later try will go differently. The status line tells the person, and the way
  # out is clear, because asking "leave without saving?" about edits that cannot be saved has only
  # one answer.
  test "a sheet deleted elsewhere says so and lets the person leave unasked" do
    open_sheet
    debounce 50
    record_unload
    @sheet.destroy!

    fill_cell(0, 0, "nowhere to go")
    assert_selector STATUS, exact_text: "Not saved — this sheet no longer exists"
    # A LATER EDIT DOES NOT START "Saving…" AGAIN: nothing is being saved, and a status that said so
    # would sit there for good. Read at once, not waited for: the grid raises its change event
    # inside the keystroke, so whatever the edit does to the status has been done by now.
    fill_cell(1, 0, "still nowhere")
    assert_equal "Not saved — this sheet no longer exists", find(STATUS).text

    within("nav.breadcrumb") { click_on @project.name }
    assert_current_path project_path(@project)
    assert_equal "false", unload_asked
  end

  # THE CSV LINK IS A DOWNLOAD, NOT A VISIT: Turbo leaves a `.csv` address to the browser, so the
  # only event is `beforeunload`, and the browser's "Leave site?" has nothing to ask about a file
  # that leaves the page where it is. The link waits for the save and then goes, so the file holds
  # what the grid shows.
  #
  # NOT A DOWNLOAD IN THE TEST. The link keeps its place, its binding and its being outside Turbo,
  # and points at a page instead of a file, so a run leaves nothing in the Downloads folder.
  test "a link out of the page that Turbo does not follow waits for the save and asks nothing" do
    open_sheet
    debounce 60_000
    record_unload
    page.execute_script("const a = document.querySelector(\"#{SHEET} a[href$='.csv']\"); a.href = '/up'; a.dataset.turbo = 'false'")

    fill_cell(0, 0, "kept")
    click_on "Export CSV"
    assert_current_path "/up"

    assert_persisted_cell(0, 0, "kept")
    assert_equal "false", unload_asked
  end

  # THE SAVE SENT FROM A CLOSING PAGE IS ONE THE BROWSER FINISHES WITHOUT IT. An ordinary request is
  # cut off when its page goes; `keepalive` is the browser's promise to complete it. The promise is
  # what is asserted, because whether an ordinary request happens to get through depends on how fast
  # the server answers: on one machine it always does, which is why the Back test above cannot tell
  # the two apart.
  test "the save sent from a closing page is marked to outlive it" do
    open_sheet
    debounce 60_000
    intercept_saves hold: false

    fill_cell(0, 0, "kept")
    fire_beforeunload
    wait_for_js "window.__saves.done === 1"

    assert_equal [ true ], page.evaluate_script("window.__saves.keepalive")
    assert_persisted_cell(0, 0, "kept")
  end

  # ...AND ONLY WHEN THE BROWSER WILL TAKE IT. Chrome rejects a keepalive request whose body is over
  # 64 KiB before it sends anything, which would turn the one save that matters into no save at all.
  test "a grid too big for the browser to finish alone goes as an ordinary request" do
    open_sheet
    debounce 60_000
    intercept_saves hold: false

    set_cell(0, 0, "x" * 70_000)
    fire_beforeunload
    wait_for_js "window.__saves.done === 1"

    assert_equal [ false ], page.evaluate_script("window.__saves.keepalive")
    assert_persisted_cell(0, 0, "x" * 70_000)
  end

  # ...AND ONLY THE CLOSING SAVE. A browser lets one page hold 64 KiB of keepalive requests open in
  # total (the Fetch standard's in-flight allowance), so an ordinary save marked that way would use
  # up what the closing one needs when both are open at once, which is the next test's case. A
  # person who is asked and stays goes back to ordinary saves.
  test "an ordinary save is not marked to outlive the page, before a closing one or after" do
    open_sheet
    debounce 50
    intercept_saves hold: false

    fill_cell(0, 0, "one")
    wait_for_js "window.__saves.done === 1"
    debounce 60_000
    fill_cell(1, 0, "two")
    fire_beforeunload
    wait_for_js "window.__saves.done === 2"
    debounce 50
    fill_cell(2, 0, "three")
    wait_for_js "window.__saves.done === 3"

    assert_equal [ false, true, false ], page.evaluate_script("window.__saves.keepalive")
    assert_persisted_cell(2, 0, "three")
  end

  # A SAVE ALREADY OPEN WHEN THE PAGE CLOSES cannot be waited for, and the edit behind it has not
  # gone anywhere. The grid as it stands goes out beside it: the one place two requests are open at
  # once, because the alternative is losing the edit for certain.
  test "Back while an earlier save is still open sends the grid as it stands" do
    open_sheet
    debounce 50
    intercept_saves hold: true

    fill_cell(0, 0, "first")
    wait_for_js "window.__saves.waiting.length === 1"
    fill_cell(1, 0, "second")
    # The first save stays at the door for good; anything sent from here on goes straight through.
    page.execute_script("window.__saves.held = false")
    page.go_back
    assert_current_path project_path(@project)

    assert_persisted_cell(1, 0, "second")
    assert_equal "first", stored_value(0, 0)
  end

  private

    # Reached by a Turbo visit, for the reason the first test gives.
    def open_sheet
      visit project_path(@project)
      click_on @sheet.name
      assert_current_path sheet_path(@sheet)
      assert_selector "#{GRID} td", wait: 10
    end

    # The controller's own constant, set on the live class, so nothing here names a second copy of
    # the number. Stretched to a minute, a save can only come from the path under test; shrunk, a
    # test does not have to sit through the real second.
    def debounce(milliseconds)
      page.execute_script(<<~JS)
        const el = document.querySelector("#{SHEET}")
        window.Stimulus.getControllerForElementAndIdentifier(el, "sheet").constructor.DEBOUNCE_MS = #{milliseconds}
      JS
    end

    # A listener added AFTER the page's own records whether `beforeunload` was cancelled, in storage
    # that outlives the page (page_editor_test.rb's instrument).
    def record_unload
      page.execute_script("localStorage.removeItem('sheet-unload'); " \
                          "window.addEventListener('beforeunload', (e) => localStorage.setItem('sheet-unload', String(e.defaultPrevented)))")
    end

    def unload_asked = page.evaluate_script("localStorage.getItem('sheet-unload')")

    # A SLOW NETWORK, AND NOTHING ELSE: with `hold`, every autosave request waits at the door until
    # the test lets one through. Either way the door counts how many are open at once and records
    # what each was sent with. The grid, the controller and the server are all the real ones.
    def intercept_saves(hold:)
      page.execute_script(<<~JS)
        const real = window.fetch.bind(window)
        const saves = window.__saves = { open: 0, most: 0, done: 0, waiting: [], keepalive: [], held: #{hold} }
        window.fetch = async (url, options = {}) => {
          if ((options.method || "GET") !== "PATCH") return real(url, options)
          saves.open += 1
          saves.most = Math.max(saves.most, saves.open)
          saves.keepalive.push(options.keepalive === true)
          if (saves.held) await new Promise((resolve) => saves.waiting.push(resolve))
          try { return await real(url, options) } finally { saves.open -= 1; saves.done += 1 }
        }
      JS
    end

    def hold_saves = intercept_saves(hold: true)

    # A cell written through the grid's own API, for a value too long to type. It raises the same
    # change event typing does.
    def set_cell(x, y, value)
      page.execute_script(<<~JS, value)
        const el = document.querySelector("#{SHEET}")
        window.Stimulus.getControllerForElementAndIdentifier(el, "sheet").instance.setValueFromCoords(#{x}, #{y}, arguments[0])
      JS
    end

    # What the browser raises when a page is about to go, without the page going.
    def fire_beforeunload
      page.execute_script("window.dispatchEvent(new Event('beforeunload', { cancelable: true }))")
    end

    def release_save = page.execute_script("window.__saves.waiting.shift()()")

    def release_saves_as_they_come
      page.execute_script("window.__saves.held = false; window.__saves.waiting.splice(0).forEach((go) => go())")
    end

    def wait_for_js(expression, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.05 until page.evaluate_script(expression) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      assert page.evaluate_script(expression), "never became true in the page: #{expression}"
    end

    def refute_js_within(seconds, expression, message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        refute page.evaluate_script(expression), message
        break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
    end

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
