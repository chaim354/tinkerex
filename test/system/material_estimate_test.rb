require "application_system_test_case"

# THE MATERIAL ESTIMATE IN A BROWSER (spec 2026-11-22). What only a browser can see: that picking
# files submits them to the measure action on its own, that a typed quantity or sheet size re-figures
# after its pause without a click, that the parts list survives a stock edit (it is not replaced),
# and that the stock is remembered across a reload; that Enter re-figures rather than uploading; that
# a submission asked for while another is in flight is sent once that one's answer is on the page,
# carrying what was changed meanwhile; and that the page fits a phone. The arithmetic is
# estimate_test.rb's and sheet_pack_test.rb's; the doors are material_estimate_test.rb's (integration).
class MaterialEstimateTest < ApplicationSystemTestCase
  setup do
    use_fresh_share_library!
    @user = sign_in_as("material-estimate@example.com")
  end

  def fixture(name) = Rails.root.join("test/fixtures/files", name).to_s

  # The house stub helper (help_page_test.rb carries the same body; Minitest 6 has no Object#stub).
  # Replaces a SINGLETON method for the block, removing an inherited one after. The page's server
  # runs in this process, on a thread, so a replacement here is the one its requests call.
  def replacing(owner, name, replacement)
    mod = owner.singleton_class
    own = mod.instance_methods(false).include?(name)
    original = mod.instance_method(name)
    mod.define_method(name, &replacement)
    yield
  ensure
    own ? mod.define_method(name, original) : mod.remove_method(name)
  end

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
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"
    attach_file "material-uploads", fixture("plate.svg")
    assert_selector ".material-sheet-count", text: /\A1 × 200 × 100 mm\z/
    assert_no_selector "form#material-form[aria-busy]"

    measured = 0
    measure = Maker::Material::Sources.method(:uploads)
    counting = lambda do |files|
      measured += 1
      measure.call(files)
    end
    replacing(Maker::Material::Sources, :uploads, counting) do
      qty = find("input[aria-label='Quantity of plate.svg']")
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
  # lands last: results for the old list on screen under the new one. The upload is HELD on the server
  # by a gate (the server runs in this process) rather than slowed by a sleep, so the race is staged
  # however slow the machine is; the only timed step is outlasting the page's own 300 ms pause.
  #
  # The numbers make each wrong answer a different sheet count. 80 x 40 parts on 200 x 100, gap 0, no
  # rotation, fit 4 to a sheet: both parts with the svg at 8 is 9 copies, 3 sheets. Figured from the
  # stale list (the svg alone at 8) it is 8 copies, 2 sheets; figured from the uploaded list with the
  # typed 8 lost under the parts list's replace (both at 1) it is 2 copies, 1 sheet.
  #
  # MUTATION-CHECKED: settling at `turbo:submit-end` (the controller before this fix) reads
  # "2 × 200 × 100 mm" — RED; not carrying the typed quantity across the parts replace reads
  # "1 × 200 × 100 mm" — RED.
  test "a quantity typed while an upload is measured is figured with the upload" do
    visit tools_material_path
    fill_in "sheet_width", with: "200"
    fill_in "sheet_height", with: "100"
    fill_in "gap", with: "0"
    uncheck "rotate"
    attach_file "material-uploads", fixture("plate.svg")
    assert_selector ".material-parts-table tbody tr", count: 1
    assert_selector ".material-sheet-count", text: /\A1 × 200 × 100 mm\z/

    gate = Queue.new
    measure = Maker::Material::Sources.method(:uploads)
    held = lambda do |files|
      gate.pop(timeout: 10)
      measure.call(files)
    end
    replacing(Maker::Material::Sources, :uploads, held) do
      attach_file "material-uploads", fixture("plate.dxf")
      assert_selector "form#material-form[aria-busy='true']"
      find("input[aria-label='Quantity of plate.svg']").set("8")
      sleep 0.6 # twice the page's pause, so the re-figure has been asked for and held
      assert_selector "form#material-form[aria-busy='true']", wait: 0
      gate << :measure

      assert_selector ".material-parts-table tbody tr", count: 2
      assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/
      assert_no_selector "form#material-form[aria-busy]"
      assert_equal "8", find("input[aria-label='Quantity of plate.svg']").value
      assert_selector ".material-sheet-count", text: /\A3 × 200 × 100 mm\z/, wait: 0
    ensure
      gate << :measure
    end
    assert_no_console_errors
  end

  # FILES PICKED WHILE AN UPLOAD IS BEING MEASURED ARE MEASURED AFTER IT, ONTO THE LIST IT RETURNS.
  # The same race with an upload held instead of a re-figure. Sent at submit-end it read the list
  # without the first upload's part, so its answer replaced the list and that part vanished. Sent
  # once the first answer is on the page it would find the file input that answer put back, which is
  # empty, so the picked files must be carried onto it. Only the FIRST measure is held here: the
  # second is the one under test, and holding it too would only wait out the gate's timeout.
  #
  # MUTATION-CHECKED: settling at `turbo:submit-end` leaves the dxf out (two rows, both plate.svg) —
  # RED; not carrying the picked files leaves the second plate.svg out (two rows) — RED.
  test "files picked while an upload is measured are added after it" do
    visit tools_material_path
    attach_file "material-uploads", fixture("plate.svg")
    assert_selector ".material-parts-table tbody tr", count: 1
    assert_no_selector "form#material-form[aria-busy]"

    gate = Queue.new
    measure = Maker::Material::Sources.method(:uploads)
    first = true
    held = lambda do |files|
      if first
        first = false
        gate.pop(timeout: 10)
      end
      measure.call(files)
    end
    replacing(Maker::Material::Sources, :uploads, held) do
      attach_file "material-uploads", fixture("plate.dxf")
      assert_selector "form#material-form[aria-busy='true']"
      attach_file "material-uploads", fixture("plate.svg")
      assert_selector "form#material-form[aria-busy='true']", wait: 0
      gate << :measure

      assert_selector ".material-parts-table tbody tr", count: 3
      assert_no_selector "form#material-form[aria-busy]"
      names = all(".material-parts-table tbody .material-part-name").map { |cell| cell.text.strip }
      assert_equal %w[plate.svg plate.dxf plate.svg], names
    ensure
      gate << :measure
    end
    assert_no_console_errors
  end

  # AT PHONE WIDTH THE CARD STILL OPENS THE TOOL, AND THE PAGE DOES NOT SCROLL SIDEWAYS. Below 720px
  # there is no sidebar to pin to, so the pin toggle goes — but the Material card's action row also
  # holds its "Open material estimate" link, the card's only way in, so the row itself must stay
  # (pages/tools.css hides an ADDON card's row, whose title is the link). The viewport is set through
  # CDP, never `resize_to`: headless Chrome will not make a window narrower than 500px
  # (shell_test.rb's 375px sweep measured it). The overflow is read against `clientWidth`, which
  # leaves out a classic scrollbar, because the Linux runners draw a 15px one and `innerWidth`
  # includes it. Measured with two parts listed and their sheets drawn, so the table and the
  # drawings are laid out rather than the empty state.
  #
  # MUTATION-CHECKED: the old `.tools-home .tool-card-actions` in place of
  # `.tools-home .addon-card .tool-card-actions` in the `max-width: 719px` rule hides the link — RED;
  # the parts table's scroll box made `overflow-x: visible; min-width: 420px` reads scrollWidth 432
  # against clientWidth 360 — RED.
  test "at phone width the card opens the tool and the page does not scroll sideways" do
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 375, height: 812, deviceScaleFactor: 1, mobile: false)
    visit tools_path
    within("#material") do
      assert has_link?("Open material estimate", href: tools_material_path, visible: true),
             "the Material card's Open link is hidden at 375px"
      assert_selector "button.tool-pin", visible: :hidden
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
