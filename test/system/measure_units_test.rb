require "application_system_test_case"

# The Measure view's mm/in toggle (docs/invariants/measure-view.md, the mm/in bullet).
#
# THE TOGGLE CHANGES WORDS, NEVER GEOMETRY. The payload is millimetres; measure_controller.js's
# `length()` converts at the last step. So every test here asserts both halves where both can be
# seen: the readout and the printed labels move, the export's `width="…mm"` and the sheet's
# calibration ruler do not.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, and the same sample.lbrn2 as measure_export_test.rb, for that
# file's reasons: the geometry job reads real bytes back out of the port, and the fixture's ⌀20
# circle sits on top of the 40 x 20 Rect around it in paint order, so a click at its centre picks
# the circle. Its numbers in inches: 20 / 25.4 = 0.787, 40 / 25.4 = 1.575.
class MeasureUnitsTest < ApplicationSystemTestCase
  SAMPLE = "sample.lbrn2".freeze
  CIRCLE_MM = "⌀20 mm · 1 part · 20 × 20 mm".freeze
  CIRCLE_IN = "⌀0.787 in · 1 part · 0.787 × 0.787 in".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-units"))
    File.binwrite(@root.join(SAMPLE), File.binread(Rails.root.join("test/fixtures/files", SAMPLE)))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-units@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @sample_id = @user.nodes.find_by!(storage_path: SAMPLE).node_id
    render_geometry!(@sample_id, SAMPLE)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the readout rewrites itself when the unit flips, and flips back" do
    open_measure_view
    assert_unit_pressed "mm"

    click_circle
    assert_selector ".measure-dims", exact_text: CIRCLE_MM

    choose_unit "in"
    # THE LINE ALREADY ON SCREEN, not the next one: nothing was clicked between the flip and this
    # read, so only the kept readout can have rewritten it.
    assert_selector ".measure-dims", exact_text: CIRCLE_IN
    assert_unit_pressed "in"

    choose_unit "mm"
    assert_selector ".measure-dims", exact_text: CIRCLE_MM
    assert_unit_pressed "mm"
  end

  # A FLIP MUST NOT RESURRECT A MEASUREMENT the user has moved past. Reset writes the resting line
  # through a plain setStatus, which drops the kept readout — without that, flipping here puts the
  # circle's size back over an empty selection.
  test "a flip after Reset leaves the resting line alone" do
    open_measure_view
    click_circle
    assert_selector ".measure-dims", exact_text: CIRCLE_MM

    click_on "Reset"
    assert_selector ".measure-dims", exact_text: "3 shapes · click one to measure"

    choose_unit "in"
    assert_unit_pressed "in"
    assert_selector ".measure-dims", exact_text: "3 shapes · click one to measure"
  end

  test "the chosen unit is remembered on the next visit" do
    open_measure_view
    choose_unit "in"

    visit file_path(@sample_id)
    assert_selector ".measure-view--ready"

    assert_unit_pressed "in"
    click_circle
    assert_selector ".measure-dims", exact_text: CIRCLE_IN
  end

  # `constructor` RATHER THAN AN ARBITRARY WORD, because it is the stored value that tells
  # `Object.hasOwn(UNITS, saved)` from `UNITS[saved]`: an unknown word fails both, while this one
  # answers truthy off Object.prototype and would print "⌀NaN undefined" in every label.
  test "a remembered unit this build does not offer falls back to millimetres" do
    visit file_path(@sample_id)
    page.execute_script("localStorage.setItem('measure.unit', 'constructor')")
    # AGAIN, because the unit is read on connect — the visit above connected before the write.
    visit file_path(@sample_id)
    assert_selector ".measure-view--ready"

    assert_unit_pressed "mm"
    click_circle
    assert_selector ".measure-dims", exact_text: CIRCLE_MM
  end

  # THE SHEET'S LABELS ARE THE READOUT'S WORDS (one injected sizeLabel, §14h) AND ITS SCALE IS NOT.
  # The page width and the ruler's "100 mm" are asserted beside the labels because they are the
  # half a careless "make everything inches" change would move — on paper, where it shows only
  # against a ruler.
  test "printed labels follow the unit while the sheet's scale stays in millimetres" do
    open_measure_view
    choose_unit "in"
    stub_print!
    click_on "Print all"
    assert_selector ".measure-print-frame", visible: :all

    sheet = page.evaluate_script(<<~JS)
      (() => {
        const svg = document.querySelector(".measure-print-frame").contentDocument.querySelector("svg")
        return {
          width: svg.getAttribute("width"),
          labels: Array.from(svg.querySelectorAll("text[data-role='size']")).map((n) => n.textContent),
          texts: Array.from(svg.querySelectorAll("text")).map((n) => n.textContent),
        }
      })()
    JS

    assert_includes sheet["labels"], "⌀0.787 in"
    assert_includes sheet["labels"], "1.575 × 0.787 in"
    assert sheet["labels"].all? { |l| l.end_with?(" in") }, "every size label in inches: #{sheet["labels"]}"
    assert_equal "215.9mm", sheet["width"]
    assert_includes sheet["texts"], "100 mm — check with a ruler"
  end

  # THE EXPORT IS A FILE SOMEBODY CUTS. Its `width="…mm"` over a viewBox is the whole scale
  # mechanism, so it must read millimetres whatever the readout says.
  test "an SVG exported under inches is still drawn in millimetres" do
    open_measure_view
    choose_unit "in"
    page.execute_script(<<~JS)
      window.__blob = null
      const realCreate = URL.createObjectURL
      URL.createObjectURL = (blob) => { window.__blob = blob; return realCreate.call(URL, blob) }
      HTMLAnchorElement.prototype.click = function () {}
    JS

    click_circle
    find("[data-measure-target='svgButton']").click
    svg = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      window.__blob ? window.__blob.text().then(done) : done("NO BLOB");
    JS

    assert_includes svg, 'width="20mm"'
    assert_includes svg, 'height="20mm"'
    assert_includes svg, 'r="10"'
  end

  private

    # THE PREMISE IS ASSERTED, NOT ASSUMED: every test below starts from millimetres, and a unit
    # left in localStorage by an earlier test would make the first assertion of each one about
    # inherited state rather than about the code. Capybara's reset clears storage between tests;
    # this says so where it matters instead of relying on it silently.
    def open_measure_view
      visit file_path(@sample_id)
      assert_selector ".measure-view--ready"
      assert_unit_pressed "mm"
    end

    def click_circle
      find(".measure-stage circle.measure-contour").click
      assert_text "1 part"
    end

    # By the data attribute, NOT `click_on "in"`: Capybara matches button text by substring, and
    # "in" is inside "Print all".
    def choose_unit(unit)
      find("[data-measure-unit-param='#{unit}']").click
    end

    def assert_unit_pressed(unit)
      assert_selector "[data-measure-unit-param='#{unit}'].active[aria-pressed='true']"
      other = unit == "mm" ? "in" : "mm"
      assert_selector "[data-measure-unit-param='#{other}'][aria-pressed='false']:not(.active)"
    end

    # The print dialog, stubbed — copied from measure_print_test.rb, which explains it.
    def stub_print!
      page.execute_script(<<~JS)
        window.__printed = 0
        const desc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, "contentWindow")
        Object.defineProperty(HTMLIFrameElement.prototype, "contentWindow", {
          configurable: true,
          get() {
            const w = desc.get.call(this)
            try { w.print = () => { window.__printed += 1 } } catch (_) {}
            return w
          },
        })
      JS
    end

    # The geometry preview rendered in-process — copied from measure_export_test.rb, which explains
    # why a system test cannot wait for the job.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end
end
