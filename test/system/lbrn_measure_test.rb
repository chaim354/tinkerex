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
    File.binwrite(@root.join(FIXTURE), File.binread(Rails.root.join("test/fixtures/files", FIXTURE)))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("lbrn-measure@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @node_id = @user.nodes.find_by!(storage_path: FIXTURE).node_id
    render_geometry!
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

  # A GAP, RECORDED RATHER THAN PAPERED OVER: nothing here covers `draw`'s paint order.
  #
  # The controller appends contours in DESCENDING bbox-area order so the browser's own
  # topmost-wins hit dispatch selects the smallest shape containing the click — that is the
  # entire selection algorithm, and reversing it silently makes a hole inside a plate
  # unclickable. Mutation-checked and it stayed GREEN: this fixture's two shapes are the same
  # area AND disjoint, so neither ever covers the other and order cannot matter.
  #
  # Catching it needs a fixture with one contour strictly inside another (a plate with a hole),
  # asserting the click lands on the hole. Not added here because bezier-circle.lbrn2 is shared
  # with lbrn_geometry_test.rb, where the equal-size circle/square pair is load-bearing for the
  # circularity assertions — a nested fixture is a separate file and a separate decision.
  # Until that exists, treat the paint-order rule in draw() as UNTESTED.

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
    def render_geometry!
      token = FileLayer.current.stat(@user, node_id: @node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: @node_id, name: FIXTURE,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: FIXTURE)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end

    def open_measure_view
      visit file_path(@node_id)
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

    def min_x(polygon)
      polygon[:points].split(/\s+/).reject(&:empty?).map { |p| p.split(",").first.to_f }.min
    end
end
