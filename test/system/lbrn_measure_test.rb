require "application_system_test_case"

# The .lbrn2 Measure view: click a contour, read its size in mm.
#
# BROWSER-TIER BY CONSTRUCTION (test/system/README.md's rule). Everything asserted here lives in
# lbrnmeasure_controller.js — an SVG built with createElementNS from a fetched JSON payload, hit
# tested by the browser's own paint-order dispatch, with the readout written into a target span.
# None of that is observable from a request test; test/integration/web/lbrn_geometry_test.rb already
# covers the endpoint's statuses, the payload's content type and the view's data-* attributes.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, for the same reason share_delivery_test.rb does it: the geometry
# job has to read REAL BYTES back out of the port, and dropping a fixture into a tmpdir + one scan is
# by far the cheapest way to get a node whose content the port can actually serve. `pin_file_layer_
# backend` rebuilds from ENV and would additionally need ENV["LIBRARY_PATH"], which its teardown does
# not restore. The trade is that a direct assignment does not set @file_layer_backend_pinned either,
# so test_helper's teardown will NOT clean up after it: the FileLayer.reset! below is load-bearing,
# not decoration — without it the Share adapter (pointing at a deleted tmpdir) leaks into the next
# test in this forked worker. This is not a backend-coverage test and must not become one; the
# README's "do not re-run the three-backend matrix through the browser" still applies.
class LbrnMeasureTest < ApplicationSystemTestCase
  FIXTURE = "bezier-circle.lbrn2".freeze

  # A PLATE WITH A HOLE THROUGH IT, and the only fixture that can test hit-test paint order.
  #   plate  Rect 60 x 40 at the origin        -> area 2400 mm^2
  #   hole   bezier circle r=5, SAME centre    -> area  100 mm^2, reported as a diameter
  # A click at the middle lands inside BOTH, so which one is reported is decided purely by the
  # order `draw` appended them in. bezier-circle.lbrn2 cannot do this: its two shapes are
  # equal-area AND disjoint, so neither ever covers the other and the ordering is unobservable.
  NESTED = "nested-plate.lbrn2".freeze
  HOLE_READOUT  = "⌀10 mm".freeze
  PLATE_READOUT = "60 × 40 mm".freeze

  # bezier-circle.lbrn2 holds exactly two shapes, DELIBERATELY THE SAME SIZE:
  #   circle  r=10 at (0,0)   -> bbox 20 x 20 mm, and the payload gives it d = 20
  #   square  20x20 at (50,0) -> bbox 20 x 20 mm, no d
  # So a readout that reported "20 × 20 mm" for both would look entirely plausible and be wrong.
  # That pair is the whole point of this file — see the mutation note above the second test.
  CIRCLE_READOUT = "⌀20 mm".freeze
  SQUARE_READOUT = "20 × 20 mm".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("lbrn-measure"))
    # The fixture lands BEFORE the first page render on purpose: FileLayer::Share reads an EMPTY
    # root as an unmounted mount point, and sign_in_as ends on /files, which renders through the
    # port. Indexing later is fine; an empty library at that moment is not.
    [ FIXTURE, NESTED ].each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("lbrn-measure@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @node_id   = @user.nodes.find_by!(storage_path: FIXTURE).node_id
    @nested_id = @user.nodes.find_by!(storage_path: NESTED).node_id
    render_geometry!(@node_id, FIXTURE)
    render_geometry!(@nested_id, NESTED)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "clicking a square contour reports its bounding box in mm" do
    open_measure_view

    contour_with_min_x(40).click

    assert_selector ".lbrn-measure-dims", text: SQUARE_READOUT
  end

  # THE ASSERTION THAT CARRIES THE WEIGHT, and the reason the fixture holds two same-sized shapes.
  # MUTATION-CHECKED: making sizeLabel always `return this.dims(shape.b)` — i.e. ignoring the
  # server's `d` — turns this test RED ("expected to find css '.lbrn-measure-dims' with text '⌀20
  # mm' ... found 1 match: '20 × 20 mm'") while the square test above stays GREEN. A single-shape
  # fixture could not tell those two apart.
  test "clicking a circular contour reports a diameter, not a bounding box" do
    open_measure_view

    contour_with_min_x(-10).click

    assert_selector ".lbrn-measure-dims", text: CIRCLE_READOUT
  end

  test "the Measure view draws the file's contours without logging a console error" do
    open_measure_view

    # COUNT, not mere presence: the whole payload has to reach the DOM, and "the SVG mounted" is
    # true of a draw that emitted one node and dropped the other.
    assert_selector "svg polygon.lbrn-contour", count: 2
    assert_no_console_errors
  end

  # THE ASSERTION THE WHOLE HIT-TEST DESIGN RESTS ON, and it was untestable until this fixture
  # existed. `draw` appends contours in DESCENDING bbox-area order so the browser's own
  # topmost-wins dispatch selects the SMALLEST shape containing the pointer — that is the entire
  # selection algorithm, there is no point-in-polygon code anywhere.
  #
  # Reverse that sort and a hole inside a plate becomes unclickable: every click reports the plate.
  # It is exactly the kind of break no output assertion catches, because both orders draw an
  # identical picture. bezier-circle.lbrn2 could not see it either — its two shapes are equal-area
  # AND disjoint, so neither ever covers the other and the mutation stayed green.
  #
  # Clicking the SVG ELEMENT'S CENTRE rather than a specific contour is the point: the fixture puts
  # plate and hole on a shared centre, and the padded viewBox is centred on it too, so the middle
  # of the element is user-space (0, 0) — inside both. Which one answers is decided by paint order
  # alone. Targeting a contour directly would prove nothing.
  # C02 IS RED, and picking a non-black layer is what makes this able to fail. On C00 the palette
  # colour and the client's fallback are both black, so a drawing that never consulted the palette
  # at all would look identical — that is precisely how an earlier version of this test stayed
  # green with the server sending no colours whatsoever.
  test "a layer's palette colour reaches the drawing" do
    open_measure_view(@nested_id)

    # The plate spans x -30..30 and the hole only -5..5, so minimum-x identifies each.
    #
    # COMPUTED STYLE, NOT THE ATTRIBUTE. Reading `[:stroke]` reports what we WROTE, which stays
    # right even when a stylesheet rule outranks it and the drawing is a different colour
    # entirely — adding `stroke: currentColor` back to .lbrn-contour left an attribute-based
    # version of this test perfectly green. Ask the browser what it actually painted.
    assert_equal "rgb(255, 0, 0)", contour_with_min_x(-5).style("stroke")["stroke"],
                 "the hole is on C02, which LightBurn paints red"
    assert_equal "rgb(0, 0, 0)", contour_with_min_x(-30).style("stroke")["stroke"],
                 "the plate is on C00, which is black"
  end

  test "clicking where a hole overlaps its plate selects the hole" do
    open_measure_view(@nested_id)

    stage_svg.click

    assert_selector ".lbrn-measure-dims", text: HOLE_READOUT
    assert_no_selector ".lbrn-measure-dims", text: PLATE_READOUT
  end

  # And the plate is still reachable where the hole is not, so the test above is not passing
  # because the plate became unclickable altogether.
  # LAYER COLOUR REACHES THE DRAWING, and the highlight still beats it. Both halves matter: the
  # colour arrives as a PRESENTATION ATTRIBUTE precisely so the --selected class can outrank it,
  # and an inline style (the obvious alternative) would silently invert that — clicking a contour
  # would change its width and nothing else. nested-plate.lbrn2 is all CutIndex 0, whose palette
  # entry is black, so this uses the circle/square fixture's C00 and asserts the mechanism rather
  # than a specific hue.
  test "contours are stroked in their LightBurn layer colour, and selection still overrides it" do
    open_measure_view

    contour = contour_with_min_x(40)
    assert_equal "#000000", contour[:stroke], "C00 is black in LightBurn's palette"

    contour.click
    assert_selector ".lbrn-measure-dims", text: SQUARE_READOUT
    # The class must win over the attribute — computed, not declared.
    assert_equal "rgb(221, 68, 0)", contour.style("stroke")["stroke"],
                 "the --selected rule must outrank the layer colour attribute"
  end

  test "the plate is still selectable away from the hole" do
    open_measure_view(@nested_id)

    # A QUARTER OF THE ELEMENT'S WIDTH RIGHT OF CENTRE, computed rather than guessed. The padded
    # viewBox is 62.4 user units wide in a square element, so with `meet` the horizontal axis fills
    # it: 1 mm is width/62.4 px. The plate reaches ±30 mm (±0.48 of the width) and the hole only
    # ±5 mm (±0.08), so 0.25 is comfortably inside one and clear of the other.
    svg = stage_svg
    svg.click(x: (svg.native.size.width * 0.25).to_i, y: 0)

    assert_selector ".lbrn-measure-dims", text: PLATE_READOUT
  end


  test "✕ Image dismisses the Measure view and returns to the poster" do
    open_measure_view

    click_on "✕ Image"

    assert_no_selector ".lbrn-measure--ready"
    assert_no_selector "svg polygon.lbrn-contour"
  end

  private

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner.
    #
    # A system test cannot wait for the job: ActiveJob's test adapter never runs what it queues, and
    # `perform_enqueued_jobs`' block form only inlines jobs enqueued DURING the block — the geometry
    # job is enqueued by the browser's own first poll, inside the server thread, which makes that
    # idiom a race even where it fires at all (see lbrn_geometry_test.rb's note on the same trap one
    # layer down). `perform_now` sidesteps the adapter entirely and is deterministic. It is still the
    # real pipeline: Enqueue mints the row the controller will look up, GeneratePreviewJob reads the
    # bytes back through the port and LbrnGeometry produces the payload — nothing here hand-writes
    # coordinates, so the numbers the browser measures are genuinely derived from the fixture.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end

    def open_measure_view(node_id = @node_id)
      visit file_path(node_id)
      click_on "Measure"
      # The --ready class is what reveals the stage and hides the poster; without waiting for it the
      # clicks below race the fetch and land on a display:none SVG.
      assert_selector ".lbrn-measure--ready"
    end

    # DOCUMENT ORDER CANNOT TELL THESE TWO APART — that is a coin flip, not a test. `draw` appends in
    # DESCENDING bbox-area order and both shapes are exactly 400 mm², so their relative order is
    # whatever the sort's tie-break happens to be. Their coordinates are disjoint, though: the circle
    # spans x -10..10 and the square x 40..60, so the minimum x of the rendered `points` attribute
    # identifies each one no matter how they were ordered or which is on top.
    def contour_with_min_x(expected)
      match = all("svg polygon.lbrn-contour").find { |poly| min_x(poly) == expected }
      assert match, "no contour whose points start at x=#{expected} — the fixture or the draw changed"
      match
    end

    # Scoped to the measure stage: the page carries a dozen other <svg> icons, and a bare
    # find("svg") is ambiguous.
    def stage_svg = find(".lbrn-measure-stage svg")

    def min_x(polygon)
      polygon[:points].split(/\s+/).reject(&:empty?).map { |p| p.split(",").first.to_f }.min
    end
end
