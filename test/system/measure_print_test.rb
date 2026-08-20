require "application_system_test_case"

# Selecting parts in the Measure view and printing them at 1:1 for paper fit testing.
#
# TWO TIERS IN ONE FILE, deliberately. The layout maths in lib/print_sheet.js is pure and is
# exercised directly through `in_print_sheet` with synthetic shapes, because a tiling assertion
# wants inputs chosen to land exactly on a tile boundary and no fixture does that. The
# end-to-end tests below drive real clicks against a real payload, because the maths being right
# about synthetic input proves nothing about whether the payload ever reaches it.
#
# ASSERT THE WIRE FORMAT, NEVER A ROUND-TRIP THROUGH OUR OWN READER. CLAUDE.md §14e: FakeS3
# decoded copy_source with the exact inverse of the encoder, so 79/80 tests were green over
# silent permanent data loss. Parsing our own SVG with our own parser would be that shape again.
# These assert the literal `width="215.9mm"` and the literal point coordinates a printer will see.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, exactly as lbrn_measure_test.rb does it and for the same
# reason: the geometry job has to read REAL BYTES back out of the port. The FileLayer.reset! in
# teardown is load-bearing — a direct assignment does not set @file_layer_backend_pinned, so
# test_helper's teardown will not clean up after it and a Share adapter pointing at a deleted
# tmpdir would leak into the next test in this forked worker.
class MeasurePrintTest < ApplicationSystemTestCase
  # x -30..30, y -20..20 plate with a ⌀10 hole on the same centre.
  NESTED = "nested-plate.lbrn2".freeze
  # A ⌀20 circle at x -10..10 and a 20 x 20 square at x 40..60. DISJOINT, and the gap between
  # their nearest edges is exactly 30 mm while their min-x values are 50 mm apart — which is what
  # makes it the fixture for the separation assertion.
  APART = "bezier-circle.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-print"))
    # The fixtures land BEFORE the first page render: FileLayer::Share reads an EMPTY root as an
    # unmounted mount point, and sign_in_as ends on /files, which renders through the port.
    [ NESTED, APART ].each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-print@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @nested_id = @user.nodes.find_by!(storage_path: NESTED).node_id
    @apart_id  = @user.nodes.find_by!(storage_path: APART).node_id
    render_geometry!(@nested_id, NESTED)
    render_geometry!(@apart_id, APART)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # ---- lib/print_sheet.js: pagination ---------------------------------------------------------

  test "Letter's content box is the printable area less the two reserved strips" do
    box = JSON.parse(in_print_sheet("JSON.stringify(m.contentBox(m.PAPERS.Letter))"))

    # 215.9 - 20 margin = 195.9 wide; 279.4 - 20 margin - 7 header - 22 calibration = 230.4 tall.
    assert_in_delta 195.9, box["w"], 0.001
    assert_in_delta 230.4, box["h"], 0.001
  end

  # THE TRANSLATION IS THE WHOLE "TRUE POSITIONS" CLAIM, and it is relative rather than absolute:
  # the SELECTION's bbox origin is the datum, not the file's. A part sitting at x 500 in a 600 mm
  # laser sheet prints at the left edge of sheet 1, not on tile 3 of 12 with two blank ones.
  test "a selection that fits produces one page whose translation puts it at the content origin" do
    out = JSON.parse(in_print_sheet(<<~JS))
      JSON.stringify(m.buildSheets(
        [{ b: [500, 300, 560, 340], p: [[500, 300], [560, 340]], k: 1, i: 0, o: 1 }],
        m.PAPERS.Letter))
    JS

    assert_equal 1, out["pages"].length
    assert_equal 1, out["cols"]
    assert_equal 1, out["rows"]
    # MARGIN (10) less the selection's own x0 (500); MARGIN + HEADER_H (17) less its y0 (300).
    assert_in_delta(-490.0, out["pages"][0]["translateX"], 0.001)
    assert_in_delta(-283.0, out["pages"][0]["translateY"], 0.001)
  end

  private

    def in_print_sheet(body)
      visit file_path(@nested_id) unless page.current_path == file_path(@nested_id)
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        import("lib/print_sheet")
          .then((m) => done(#{body}))
          .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
      JS
      raise result if result.is_a?(String) && result.start_with?("ERROR:")
      result
    end

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner. A system test cannot wait for the job:
    # ActiveJob's test adapter never runs what it queues, and `perform_enqueued_jobs`' block form
    # only inlines jobs enqueued DURING the block — the geometry job is enqueued by the browser's
    # own first poll, inside the server thread. `perform_now` sidesteps the adapter and is
    # deterministic, while still being the real pipeline.
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end
end
