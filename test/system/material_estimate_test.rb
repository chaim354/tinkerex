require "application_system_test_case"

# THE MATERIAL ESTIMATE IN A BROWSER (spec 2026-11-22). What only a browser can see: that picking
# files submits them to the measure action on its own, that a typed quantity or sheet size re-figures
# after its pause without a click, that the parts list survives a stock edit (it is not replaced),
# and that the stock is remembered across a reload; that Enter re-figures rather than uploading; that
# a submission asked for while another is in flight — by the page, by Enter or by a Remove click — is
# sent once that one's answer is on the page, carrying what was changed meanwhile, and that leaving
# the page drops it; and that the page fits a phone. The arithmetic is estimate_test.rb's and
# sheet_pack_test.rb's; the doors are material_estimate_test.rb's (integration).
#
# THE RACES ARE STAGED, NEVER TIMED. A request is held on the SERVER (it runs in this process, so a
# replaced singleton method is the one its requests call) until the test releases it, or its body is
# held in the PAGE after its headers (HOLD_MEASURE_BODY). The only sleeps outlast one of the page's
# own timers. 80 x 40 parts on a 200 x 100 sheet with gap 0 and no rotation fit 4 to a sheet, so the
# numbers below are chosen to make each wrong answer a different sheet count.
class MaterialEstimateTest < ApplicationSystemTestCase
  # Hands Turbo the NEXT measure answer's real headers at once and its body only when the test calls
  # `window.__releaseBody()`: the shape of a slow download, which no server here can send (Rails renders
  # the whole body before the headers go). Turbo calls `window.fetch` (fetchWithTurboHeaders), so this
  # is the fetch it uses. `data-held-body` on <html> says the hold has begun.
  HOLD_MEASURE_BODY = <<~JS.freeze
    (() => {
      const real = window.fetch
      let armed = true
      window.fetch = async (url, options) => {
        const response = await real(url, options)
        if (!armed || !String(url).includes("/tools/material/measure")) return response
        armed = false
        let release
        const released = new Promise((resolve) => { release = resolve })
        window.__releaseBody = release
        document.documentElement.dataset.heldBody = "1"
        const body = new ReadableStream({
          async start(controller) {
            await released
            controller.enqueue(new Uint8Array(await response.arrayBuffer()))
            controller.close()
          }
        })
        return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers })
      }
    })()
  JS

  setup do
    use_fresh_share_library!
    @user = sign_in_as("material-estimate@example.com")
  end

  def fixture(name) = Rails.root.join("test/fixtures/files", name).to_s

  # The house stub helper (help_page_test.rb carries the same body; Minitest 6 has no Object#stub).
  # Replaces a SINGLETON method for the block, removing an inherited one after.
  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end

  # Holds the FIRST call to `owner.name` on the server until the block pushes onto the gate it is
  # given (or 10 s pass); later calls run at once, so a held submission sent after it is never held
  # too. Released on the way out whatever happens, so a failing test leaves no server thread waiting.
  def holding_first_call(owner, name)
    gate = Queue.new
    original = owner.method(name)
    first = true
    held = lambda do |*args, **kwargs|
      if first
        first = false
        gate.pop(timeout: 10)
      end
      original.call(*args, **kwargs)
    end
    replacing(owner, name, held) { yield gate }
  ensure
    gate&.push(:release)
  end

  # The stock of the worked layout: 4 parts of 80 x 40 to a sheet.
  def small_sheet!
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"
  end

  # Uploads the fixtures and waits until the list has `rows` rows and the results count them, every
  # part at 1: the answer is on the page, not merely arrived.
  def upload!(*names, rows:)
    attach_file "material-uploads", names.map { |name| fixture(name) }
    assert_selector ".material-parts-table tbody tr", count: rows
    assert_copies rows
    assert_no_selector "form#material-form[aria-busy]"
  end

  def assert_copies(count)
    assert_selector :xpath, "//dl[contains(@class, 'material-summary')]/dt[.='Copies']/following-sibling::dd[1]",
                    text: /\A#{count}\z/
  end

  def assert_busy = assert_selector("form#material-form[aria-busy='true']")

  def part_names = all(".material-parts-table tbody .material-part-name").map { |cell| cell.text.strip }

  def row(index) = all(".material-parts-table tbody tr")[index]

  def quantity(index) = row(index).find("input.material-qty")

  test "uploading two drawings lists them, and a quantity or a sheet size re-figures the sheets" do
    visit tools_material_path
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"

    attach_file "material-uploads", [ fixture("plate.svg"), fixture("plate.dxf") ]
    assert_selector ".material-parts-table tbody tr", count: 2
    assert_selector ".material-parts-table", text: "80 × 40"
    assert_selector ".material-sheet-count", text: /\A1 × 200 × 100 mm\z/
    # The no-JavaScript button is hidden again in the parts list the upload's stream put back, which
    # only the target callback can do (connect() ran once, on the list this replaced).
    assert_no_selector "button", text: "Measure uploads"

    find("input[aria-label='Quantity of plate.svg']").set("5")
    assert_selector ".material-sheet-count", text: /\A2 × 200 × 100 mm\z/
    assert_selector "svg.material-sheet-svg", count: 2

    fill_in "sheet_width", with: "400"
    assert_selector ".material-sheet-count", text: /\A1 × 400 × 100 mm\z/
    assert_selector ".material-parts-table tbody tr", count: 2, wait: 0

    visit tools_material_path
    assert_field "sheet_width", with: "400"
    assert_no_console_errors
  end

  test "a unit switch converts the stock rather than reinterpreting it" do
    visit tools_material_path
    fill_in "sheet_width", with: "254"
    select "in", from: "unit"
    assert_field "sheet_width", with: "10"
    assert_no_console_errors
  end

  # ENTER IN A QUANTITY RE-FIGURES; IT NEVER PRESSES "MEASURE UPLOADS". Enter presses the form's
  # DEFAULT button, the first submit button in tree order, and left to that order it was Measure
  # uploads, which posts to the rate-limited measure action. The form opens with a `hidden` Update
  # button for that reason (tools/materials/show), and whether a hidden default button still takes
  # implicit submission is browser behaviour no request test can see. The new quantity is put in the
  # box WITHOUT an input event, so the page's own 300 ms re-figure never starts: a typed value would
  # re-figure through the right action whether Enter did anything or not, and then a browser that
  # ignored the Enter would read green. So the sheet count can only change because Enter submitted,
  # and the counter says it did not submit to measure.
  #
  # MUTATION-CHECKED: deleting the hidden Update button from show.html.erb makes Enter press Measure
  # uploads (hidden too, by the controller): the counter reads 1 — RED.
  test "enter in a quantity re-figures without pressing measure uploads" do
    visit tools_material_path
    small_sheet!
    upload! "plate.svg", rows: 1

    measured = 0
    measure = Maker::Material::Sources.method(:uploads)
    counting = lambda do |files|
      measured += 1
      measure.call(files)
    end
    replacing(Maker::Material::Sources, :uploads, counting) do
      qty = quantity(0)
      qty.execute_script("this.value = '5'")
      qty.send_keys(:enter)
      assert_selector ".material-sheet-count", text: /\A2 × 200 × 100 mm\z/
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal 0, measured, "Enter in a quantity posted to the measure action"
    end
    assert_no_console_errors
  end

  # A QUANTITY TYPED WHILE AN UPLOAD IS BEING MEASURED IS FIGURED WITH THE UPLOAD, NEVER WITHOUT IT.
  # The page holds a re-figure asked for during a submission and sends it once that one is done. Turbo
  # fires `turbo:submit-end` when the request finishes, BEFORE it renders the turbo-stream answer, so a
  # re-figure sent at submit-end reads a form that does not yet hold the uploaded parts and its answer
  # lands last: results for the old list on screen under the new one. The only timed step is
  # outlasting the page's own 300 ms pause.
  #
  # Both parts with the svg at 8 is 9 copies, 3 sheets. Figured from the stale list (the svg alone at
  # 8) it is 8 copies, 2 sheets; figured from the uploaded list with the typed 8 lost under the parts
  # list's replace (both at 1) it is 2 copies, 1 sheet.
  #
  # MUTATION-CHECKED: settling at `turbo:submit-end` (the controller before this fix) reads
  # "2 × 200 × 100 mm" — RED; not carrying the typed quantity across the parts replace reads
  # "1 × 200 × 100 mm" — RED.
  test "a quantity typed while an upload is measured is figured with the upload" do
    visit tools_material_path
    small_sheet!
    upload! "plate.svg", rows: 1

    holding_first_call(Maker::Material::Sources, :uploads) do |gate|
      attach_file "material-uploads", fixture("plate.dxf")
      assert_busy
      quantity(0).set("8")
      sleep 0.6 # twice the page's pause, so the re-figure has been asked for and held
      assert_selector "form#material-form[aria-busy='true']", wait: 0
      gate << :release

      assert_selector ".material-parts-table tbody tr", count: 2
      assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal "8", quantity(0).value
      assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/, wait: 0
    end
    assert_no_console_errors
  end

  # FILES PICKED WHILE AN UPLOAD IS BEING MEASURED ARE MEASURED AFTER IT, ONTO THE LIST IT RETURNS.
  # The same race with an upload held instead of a re-figure. Sent at submit-end it read the list
  # without the first upload's part, so its answer replaced the list and that part vanished. Sent
  # once the first answer is on the page it would find the file input that answer put back, which is
  # empty, so the picked files must be carried onto it.
  #
  # MUTATION-CHECKED: settling at `turbo:submit-end` leaves the dxf out (two rows, both plate.svg) —
  # RED; not carrying the picked files leaves the second plate.svg out (two rows) — RED.
  test "files picked while an upload is measured are added after it" do
    visit tools_material_path
    upload! "plate.svg", rows: 1

    holding_first_call(Maker::Material::Sources, :uploads) do |gate|
      attach_file "material-uploads", fixture("plate.dxf")
      assert_busy
      attach_file "material-uploads", fixture("plate.svg")
      assert_selector "form#material-form[aria-busy='true']", wait: 0
      gate << :release

      assert_selector ".material-parts-table tbody tr", count: 3
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal %w[plate.svg plate.dxf plate.svg], part_names
    end
    assert_no_console_errors
  end

  # AN ANSWER WHOSE BODY IS SLOW TO ARRIVE IS WAITED FOR. `turbo:submit-end` fires when the answer's
  # HEADERS arrive (fetch resolves then); the stream renders only once the whole body is read, and a
  # frame after. The page's 2 s timeout, there for an answer whose results never render, therefore
  # counts from the body: counted from the headers, a slow download let it send the held re-figure
  # from the form as it was before the upload, and the upload's answer, landing after, put its own
  # list back at the quantities it was sent with. The 2.5 s sleep outlasts that timeout.
  #
  # The svg at 7 with the other two at 1 is 9 copies, 3 sheets; the upload's answer landing last is
  # 3 copies, 1 sheet.
  #
  # MUTATION-CHECKED: starting the timeout at submit-end, as before, reads "1 × 200 × 100 mm" — RED.
  test "an answer whose body is slow to arrive is waited for" do
    visit tools_material_path
    small_sheet!
    upload! "plate.svg", "plate.dxf", rows: 2

    page.execute_script(HOLD_MEASURE_BODY)
    attach_file "material-uploads", fixture("plate.svg")
    assert_selector "html[data-held-body]", visible: :all
    assert_no_selector "form#material-form[aria-busy]" # the headers are in, so submit-end has fired
    quantity(0).set("7")
    sleep 2.5
    assert_selector ".material-parts-table tbody tr", count: 2, wait: 0
    page.execute_script("window.__releaseBody()")

    assert_selector ".material-parts-table tbody tr", count: 3
    assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/
    assert_no_selector "form#material-form[aria-busy]"
    assert_equal "7", quantity(0).value
    assert_no_console_errors
  end

  # ENTER WHILE AN UPLOAD IS BEING MEASURED WAITS FOR IT. A native submit (Enter presses the hidden
  # default button) never went through the page's hold: with the upload's request still out, Turbo
  # started the new submission by ABORTING it, so the picked file never got a row; with its headers
  # in, the two ran at once and the Enter's answer, figured without the upload, could land last.
  # The form's submit action now holds it like any re-figure. The quantity is set without an input
  # event, so only the Enter can re-figure it.
  #
  # Both parts with the svg at 8 is 9 copies, 3 sheets; the svg alone (the upload aborted) is 2.
  #
  # MUTATION-CHECKED: with the submit action letting every submit through, the dxf never gets a row
  # (one row, "2 × 200 × 100 mm") — RED.
  test "enter while an upload is measured waits for it" do
    visit tools_material_path
    small_sheet!
    upload! "plate.svg", rows: 1

    holding_first_call(Maker::Material::Sources, :uploads) do |gate|
      attach_file "material-uploads", fixture("plate.dxf")
      assert_busy
      qty = quantity(0)
      qty.execute_script("this.value = '8'")
      qty.send_keys(:enter)
      gate << :release

      assert_selector ".material-parts-table tbody tr", count: 2
      assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal %w[plate.svg plate.dxf], part_names
      assert_equal "8", quantity(0).value
    end
    assert_no_console_errors
  end

  # A REMOVE CLICKED WHILE AN UPLOAD IS BEING MEASURED WAITS FOR IT, AND KEEPS ITS ROW. A Remove click
  # is a native submit too, so it aborted the upload. Held, it keeps the button's row number and is
  # sent once the upload's answer is on the page: an upload only appends rows, so the number still
  # names the row that was clicked.
  #
  # MUTATION-CHECKED: with the submit action letting every submit through, the upload is aborted (one
  # row, plate.svg) — RED.
  test "a remove clicked while an upload is measured waits for it" do
    visit tools_material_path
    upload! "plate.svg", "plate.dxf", rows: 2

    holding_first_call(Maker::Material::Sources, :uploads) do |gate|
      attach_file "material-uploads", fixture("plate.svg")
      assert_busy
      row(1).find("button", text: "Remove").click
      gate << :release

      # The list starts at two rows too, so the wait is for the dxf to go, then for the second svg.
      assert_no_selector ".material-part-name", text: "plate.dxf"
      assert_selector ".material-parts-table tbody tr", count: 2
      assert_copies 2
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal %w[plate.svg plate.svg], part_names
    end
    assert_no_console_errors
  end

  # A REMOVE CLICKED WHILE ANOTHER IS BEING ANSWERED REMOVES THE ROW IT WAS CLICKED ON. A remove
  # renumbers the rows below it, so a row number held across one moves up with its row: held as
  # clicked, it would name the row after it. A quantity typed meanwhile moves with its row the same way.
  #
  # Rows plate.svg, plate.dxf, plate.svg: the first is removed, then the dxf, with the last at 3. Left
  # is the last plate.svg at 3. Holding the number as clicked removes that last row instead (the dxf
  # is left); not moving the quantity leaves it at 1.
  #
  # MUTATION-CHECKED: not moving held row numbers and quantities up after a remove leaves plate.dxf at
  # 1 (Copies reads 1) — RED; moving the row numbers but not the quantity leaves the right row at 1
  # (Copies reads 1) — RED.
  test "a remove clicked while another is answered removes the row it was clicked on" do
    visit tools_material_path
    upload! "plate.svg", "plate.dxf", rows: 2
    upload! "plate.svg", rows: 3

    holding_first_call(Maker::Material::Estimate, :from_params) do |gate|
      row(0).find("button", text: "Remove").click
      assert_busy
      quantity(2).execute_script("this.value = '3'")
      row(1).find("button", text: "Remove").click
      gate << :release

      assert_selector ".material-parts-table tbody tr", count: 1
      assert_copies 3
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal %w[plate.svg], part_names
      assert_equal "3", quantity(0).value
    end
    assert_no_console_errors
  end

  # LEAVING THE PAGE WHILE A RE-FIGURE IS OUT GOES WHERE IT WAS ASKED TO. A Turbo visit aborts the
  # form's submission in flight; the aborted submission's end used to send the held re-figure, and
  # Turbo cancels a visit to start a form submission, so the page stayed put. An aborted end drops
  # what is held. The re-figure is held on the server so it is still out when the link is clicked.
  #
  # MUTATION-CHECKED: keeping what is held on an aborted end stays on /tools/material — RED.
  test "leaving the page while a re-figure is out goes where it was asked to" do
    visit tools_material_path
    upload! "plate.svg", "plate.dxf", rows: 2

    holding_first_call(Maker::Material::Estimate, :from_params) do
      quantity(0).set("2")
      assert_busy
      quantity(0).set("3")
      sleep 0.6 # twice the page's pause, so the second re-figure has been asked for and held
      find("aside.rail a.rail-link[title='Library']").click
      assert_current_path files_path
    end
    assert_no_console_errors
  end

  # AT PHONE WIDTH THE CARD STILL OPENS THE TOOL, AND THE PAGE DOES NOT SCROLL SIDEWAYS. The
  # Material card's action row holds its "Open material estimate" link, the card's only way in, so
  # the row must show at every width. (A `max-width: 719px` rule hid the cards' Pin toggle until the
  # toggle itself was removed, 2026-11-23, and an earlier spelling of it hid this row too.) The
  # viewport is set through CDP, never `resize_to`: headless Chrome will not make a window narrower
  # than 500px (shell_test.rb's 375px sweep measured it). The overflow is read against
  # `clientWidth`, which leaves out a classic scrollbar, because the Linux runners draw a 15px one
  # and `innerWidth` includes it. Measured with two parts listed and their sheets drawn, so the
  # table and the drawings are laid out rather than the empty state.
  #
  # MUTATION-CHECKED: the parts table's scroll box made `overflow-x: visible; min-width: 420px`
  # reads scrollWidth 432 against clientWidth 360 — RED.
  test "at phone width the card opens the tool and the page does not scroll sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit tools_path
    within("#material") do
      assert has_link?("Open material estimate", href: tools_material_path, visible: true),
             "the Material card's Open link is hidden at 375px"
    end

    visit tools_material_path
    attach_file "material-uploads", [ fixture("plate.svg"), fixture("plate.dxf") ]
    assert_selector ".material-parts-table tbody tr", count: 2
    assert_selector "svg.material-sheet-svg"
    widths = page.evaluate_script(<<~JS)
      ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth })
    JS
    assert_operator widths["scroll"], :<=, widths["client"],
                    "the Material estimate scrolls sideways at 375px (#{widths.inspect})"
    assert_no_console_errors
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
