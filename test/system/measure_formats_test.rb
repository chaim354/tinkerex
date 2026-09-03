require "application_system_test_case"

# The Measure view on the formats that are NOT LightBurn: .mage, .dxf and .svg.
#
# WHY A SECOND SYSTEM FILE RATHER THAN MORE CASES IN lbrn_measure_test.rb. That file's whole
# design is one fixture pair chosen to make paint order and diameter-vs-bbox observable, and its
# setup indexes exactly those two files. This one asks a different question — does a format OTHER
# than the one the view was built for reach the browser and measure correctly — and answering it
# needs its own fixtures. The hit-testing, panning and selection behaviour is NOT re-tested here;
# it lives in measure_controller.js, is format-agnostic by construction, and is already covered.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, for the reason lbrn_measure_test.rb documents at length: the
# geometry job must read REAL BYTES back through the port, and a tmpdir plus one scan is the
# cheapest way to get there. `FileLayer.reset!` in teardown is load-bearing, not decoration — a
# direct assignment does not set @file_layer_backend_pinned, so test_helper's teardown will not
# clean up after it and a Share adapter pointing at a deleted tmpdir would leak into the next test
# in this forked worker. This is not a backend-coverage test and must not become one.
class MeasureFormatsTest < ApplicationSystemTestCase
  # Each fixture is a plate with a round feature, sized so the two readouts are DIFFERENT numbers —
  # a view that reported the job box for everything, or the same shape twice, could not pass.
  #
  #   plate.dxf   80 x 40 mm plate (LWPOLYLINE, layer Cut) + a 10 mm hole (CIRCLE, layer Engrave)
  #   plate.svg   the same sizes in a 1:1 mm document, as a <rect> and a <circle>
  #   real-export.mage  100 x 60 job: an open toolpath and a 20 mm circle
  FIXTURES = %w[plate.dxf plate.svg real-export.mage].freeze

  HOLE_READOUT  = "⌀10 mm".freeze
  PLATE_READOUT = "80 × 40 mm".freeze
  MAGE_READOUT  = "⌀20 mm".freeze

  # WHAT THE PARSER CANNOT DRAW, WHICH THE STATUS LINE NOW HAS TO SAY. SYNTHESIZED RATHER THAN
  # CHECKED IN: the whole content of interest is a `0`-code naming an entity type this parser does
  # not handle, which is two lines of group codes — a fixture file would put that behind something
  # a reader has to open a DXF viewer to see.
  #
  # THE TYPE IS `ELLIPSE` BECAUSE IT WAS `SPLINE` UNTIL SPLINE BECAME DRAWABLE (tinkerex#216), and
  # a status-line test must not be pinned to a gap somebody is about to close — that is what made
  # this file go red on the change that fixed it. ELLIPSE has zero occurrences in the 129-file
  # corpus and is deliberately out of scope, which is exactly what makes it the stable choice; the
  # SPLINE half of this claim moved to `dxf_geometry_test.rb`, where the malformed-spline tally is
  # asserted on the payload directly.
  #
  # DELIBERATELY NOT IN `FIXTURES`. That list drives the console-error sweep, which asserts at
  # least one contour — `only-ellipses.dxf` draws none, and must not.
  UNREADABLE_DXF = {
    "some-ellipses.dxf" =>
      "0\nSECTION\n2\nENTITIES\n" \
      "0\nLINE\n8\nCut\n10\n0\n20\n0\n11\n60\n21\n0\n" \
      "0\nELLIPSE\n8\nCut\n" \
      "0\nLINE\n8\nCut\n10\n0\n20\n0\n11\n0\n21\n30\n" \
      "0\nELLIPSE\n8\nCut\n0\nELLIPSE\n8\nCut\n0\nENDSEC\n0\nEOF\n",
    "only-ellipses.dxf" =>
      "0\nSECTION\n2\nENTITIES\n0\nELLIPSE\n8\nCut\n0\nELLIPSE\n8\nCut\n0\nENDSEC\n0\nEOF\n"
  }.freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-formats"))
    # The fixtures land BEFORE the first page render on purpose: FileLayer::Share reads an EMPTY
    # root as an unmounted mount point, and sign_in_as ends on /files, which renders through the port.
    FIXTURES.each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    UNREADABLE_DXF.each { |name, body| File.binwrite(@root.join(name), body) }
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-formats@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    names = FIXTURES + UNREADABLE_DXF.keys
    @nodes = names.to_h { |f| [ f, @user.nodes.find_by!(storage_path: f).node_id ] }
    names.each { |f| render_geometry!(@nodes[f], f) }
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # THE HEADLINE: a DXF's numbers reach the browser as MILLIMETRES. The plate is 80 x 40 in the
  # file's own units with $INSUNITS=4, so a scale bug reports a plausible-looking wrong number
  # rather than failing — which is why the assertion is on the literal size, not on "some text".
  test "a dxf measures its plate and its hole in mm" do
    open_measure_view("plate.dxf")

    click_plate_away_from_the_hole
    assert_selector ".measure-dims", text: PLATE_READOUT

    # The hole sits at the plate's centre, so the stage's own centre is where the two overlap —
    # and paint order must hand it to the smaller shape.
    stage_svg.click
    assert_selector ".measure-dims", text: HOLE_READOUT
  end

  test "an svg measures the same shapes at the same sizes" do
    open_measure_view("plate.svg")

    click_plate_away_from_the_hole
    assert_selector ".measure-dims", text: PLATE_READOUT

    stage_svg.click
    assert_selector ".measure-dims", text: HOLE_READOUT
  end

  test "a mage file measures through the shared LightBurn walker" do
    open_measure_view("real-export.mage")

    contour_with_min_x(40.0).click
    assert_selector ".measure-dims", text: MAGE_READOUT
  end

  # A DXF LAYER'S COLOUR REACHES THE DRAWING, from the file's own LAYER table rather than a
  # client-side copy. Asserted on the COMPUTED style: reading the attribute reports what we wrote
  # even when a CSS rule outranks it, which is the failure mode `.measure-contour` declaring a
  # stroke would produce.
  test "a dxf layer's own colour reaches the drawing" do
    open_measure_view("plate.dxf")

    plate = contour_with_min_x(0.0)
    hole = contour_with_min_x(35.0)
    assert_equal "rgb(255, 0, 0)", plate.style("stroke")["stroke"], "layer Cut is ACI 1 (red)"
    assert_equal "rgb(0, 0, 255)", hole.style("stroke")["stroke"], "layer Engrave is ACI 5 (blue)"
  end

  # AN SVG'S POSTER IS THE FILE ITSELF, and the Measure view still supersedes it on click. This is
  # the one measurable format the browser can display raw, so it is the one place the poster is
  # not a server-rendered thumbnail.
  test "an svg posters itself and still opens the measure view" do
    visit file_path(@nodes["plate.svg"])

    assert_selector ".measure-fallback img"
    click_on "Measure"
    assert_selector ".measure-view--ready"
    assert_no_selector ".measure-fallback img", visible: true
  end

  # THE HONESTY BACKSTOP, DRIVEN THROUGH A BROWSER BECAUSE NOTHING ELSE CAN SEE IT. The payload
  # carrying `"u"` is asserted server-side; that the VIEW says so is a different claim, and a
  # controller change that silently does nothing is this repo's recorded failure shape (§14d:
  # Stimulus neither throws nor warns, and two deleted controllers left a feature inert for nine
  # days behind a green request test).
  test "a dxf reports the entity types the parser could not draw" do
    open_measure_view("some-ellipses.dxf")

    assert_selector ".measure-dims",
                    exact_text: "2 shapes · 3 ELLIPSE not readable · click one to measure"
  end

  # THE OTHER HALF, AND WITHOUT IT AN IMPLEMENTATION THAT ALWAYS APPENDS A CLAUSE PASSES. `exact_text`
  # is what carries that: plate.dxf is read completely, so the line must be the bare one it always was.
  test "a dxf the parser reads completely claims nothing" do
    open_measure_view("plate.dxf")

    assert_selector ".measure-dims", exact_text: "2 shapes · click one to measure"
  end

  # THE OBSERVED HARM, AS A TEST. A real .dxf of four SPLINEs and nothing else measured zero shapes
  # and read "No measurable geometry in this file" — a lie about a file that is entirely geometry
  # (tinkerex#216). Splines measure now; the branch does not go away with them, because any file
  # whose every entity is a type this parser cannot draw lands here, and it never reaches
  # `restingStatus()` — the one case a test of that method alone would leave uncovered, and the
  # case the mechanism was built for. The view stays on the poster here, which is why this does
  # not wait for --ready.
  test "a dxf of nothing but unreadable entities says so instead of blaming the file" do
    visit file_path(@nodes.fetch("only-ellipses.dxf"))
    click_on "Measure"

    assert_selector ".measure-dims",
                    exact_text: "No measurable geometry in this file · 2 ELLIPSE not readable"
  end

  # THE BROWSER IS THE ONLY THING THAT KNOWS. A payload the client cannot read, a CSP that drops a
  # directive, an exception mid-draw — none is visible from a request test, and all of them leave
  # a SEVERE line in the console.
  test "every format draws without logging a console error" do
    FIXTURES.each do |f|
      open_measure_view(f)
      assert_selector "svg .measure-contour", minimum: 1, wait: 5

      severe = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
      assert_empty severe.map(&:message), "#{f} logged a console error while drawing"
    end
  end

  private

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner — see lbrn_measure_test.rb for why `perform_now`
    # rather than `perform_enqueued_jobs`.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "#{filename}: the geometry payload must be ready"
    end

    # Scoped to the measure stage: the page carries a dozen other <svg> icons, and a bare
    # find("svg") is ambiguous.
    def stage_svg = find(".measure-stage svg")

    # 30% OF THE ELEMENT'S WIDTH RIGHT OF CENTRE — computed from the fixtures, not guessed, the
    # same way lbrn_measure_test's "still selectable away from the hole" does it.
    #
    # Both plate fixtures are an 80 x 40 job, so `draw` pads by max(w,h)*0.02 = 1.6 and the viewBox
    # is 83.2 x 43.2 in a SQUARE stage. With `meet` the horizontal axis is the binding one
    # (83.2 > 43.2), so 1 mm is width/83.2 px and the element's centre is the job's centre — which
    # is exactly where the hole is. The plate reaches +-40 mm from there (+-0.48 of the width) and
    # the hole only +-5 mm (+-0.06), so 0.30 is comfortably inside the plate and clear of the hole.
    def click_plate_away_from_the_hole
      svg = stage_svg
      svg.click(x: (svg.native.size.width * 0.30).to_i, y: 0)
    end

    def open_measure_view(fixture)
      visit file_path(@nodes.fetch(fixture))
      click_on "Measure"
      # The --ready class is what reveals the stage and hides the poster; without waiting for it
      # the clicks below race the fetch and land on a display:none SVG.
      assert_selector ".measure-view--ready"
    end

    # DOCUMENT ORDER CANNOT IDENTIFY A CONTOUR — `draw` appends in DESCENDING bbox-area order, so
    # the order is a property of the drawing rather than of the file. Each shape's minimum x names
    # it regardless of ordering, the same way lbrn_measure_test does it. A shape `min_x` cannot
    # read is skipped rather than compared, so it can never raise on the way to the assert below.
    def contour_with_min_x(expected)
      match = all("svg .measure-contour").find { |c| (x = min_x(c)) && (x - expected).abs < 0.5 }
      assert match, "no contour whose points start at x=#{expected} — the fixture or the draw changed"
      match
    end

    # A CONTOUR IS NOT NECESSARILY A <polygon>, SO `points` IS NOT A GENERAL WAY TO ASK ONE WHERE IT
    # IS. The Measure view draws the primitive the FILE declared: a LightBurn <Ellipse>, a DXF
    # CIRCLE/ARC and an SVG <circle>/<ellipse> reach the client as a `g` curve descriptor and render
    # as a real <circle>/<ellipse>/<path> (app/javascript/lib/shape_svg.js), never as a sampled
    # polygon. plate.dxf's hole and real-export.mage's circle are both <circle> today, and a
    # <circle> HAS NO `points` ATTRIBUTE AT ALL — so the old one-line body read nil and this
    # helper's caller subtracted from it, which is the NoMethodError this shape exists to stop
    # recurring. Ask each element kind for its own geometry instead.
    #
    # nil FOR ANYTHING ELSE, DELIBERATELY. An arc draws as a <path> whose geometry lives in `d`,
    # with no attribute a minimum x can be read from; no fixture here produces one, and answering
    # nil means the day one does the caller reports a missing contour rather than raising again.
    def min_x(contour)
      case contour.tag_name
      when "circle"  then contour[:cx].to_f - contour[:r].to_f
      when "ellipse" then contour[:cx].to_f - contour[:rx].to_f
      else contour[:points].to_s.split(/\s+/).reject(&:empty?).map { |p| p.split(",").first.to_f }.min
      end
    end
end
