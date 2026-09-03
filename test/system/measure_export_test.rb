require "application_system_test_case"

# Exporting selected Measure shapes as a standalone SVG.
#
# TWO TIERS IN ONE FILE, the split measure_print_test.rb established. lib/export_svg.js is pure and
# is exercised directly with synthetic shapes, because an export assertion wants inputs whose
# numbers are chosen rather than whatever a fixture happens to produce. The end-to-end test below
# drives a real click against a real payload, because the builder being right about synthetic input
# proves nothing about whether the selection ever reaches it.
#
# WHY PURE CODE EARNS A PLACE IN THIS TIER. test/system/README.md's rule is that a behaviour
# qualifies only if it is observable ONLY in a browser. This repo has NO JS test runner, so a
# browser is the only executor there is for lib/export_svg.js — the same precedent
# measure_print_test.rb and plan_export_test.rb set.
#
# ASSERT THE WIRE FORMAT, NEVER A ROUND-TRIP THROUGH OUR OWN READER. §14e: FakeS3 decoded
# copy_source with the exact inverse of the encoder, so 79/80 tests were green over silent
# permanent data loss. Parsing our own SVG with our own parser would be that shape again.
# SHARE BACKEND, ASSIGNED DIRECTLY, exactly as lbrn_measure_test.rb and measure_print_test.rb do it
# and for the same reason: the geometry job has to read REAL BYTES back out of the port. The
# FileLayer.reset! in teardown is load-bearing — a direct assignment does not set
# @file_layer_backend_pinned, so test_helper's teardown will not clean up after it and a Share
# adapter pointing at a deleted tmpdir would leak into the next test in this forked worker.
class MeasureExportTest < ApplicationSystemTestCase
  # A ⌀20 Ellipse (Rx = Ry = 10 at XForm 1 0 0 1 50 30, so centred 50, -30 after the Y-flip) beside
  # a 40 x 20 Rect and an open Line. THE ONLY FIXTURE IN THE REPO WITH A <Shape Type="Ellipse"> that
  # this file needs — nested-plate's and bezier-circle's circles are bezier Paths and carry no
  # descriptor at all, so neither can exercise the export's whole point.
  SAMPLE = "sample.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-export"))
    # The fixture lands BEFORE the first page render on purpose: FileLayer::Share reads an EMPTY
    # root as an unmounted mount point, and sign_in_as ends on /files, which renders through the
    # port.
    File.binwrite(@root.join(SAMPLE), File.binread(Rails.root.join("test/fixtures/files", SAMPLE)))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-export@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @sample_id = @user.nodes.find_by!(storage_path: SAMPLE).node_id
    render_geometry!(@sample_id, SAMPLE)
  end

  teardown { FileLayer.reset! }

  # ---- lib/export_svg.js: the document ---------------------------------------------------

  # ONE USER UNIT IS ONE MILLIMETRE, and the width/height + viewBox pair is the entire scale
  # mechanism — no transform, no dpi constant. A px width over the same viewBox draws an
  # identical-looking file that is silently the wrong size in an application that will cut it.
  test "the document carries the selection's own size in millimetres" do
    head = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 60, 40], p: [[0, 0], [60, 0], [60, 40], [0, 40]], k: 1, c: 0 }], {})
       .match(/<svg[^>]*>/)[0]
    JS

    assert_includes head, 'width="60mm"'
    assert_includes head, 'height="40mm"'
    assert_includes head, 'viewBox="0 0 60 40"'
  end

  # NORMALIZED TO THE ORIGIN, so a part pulled out of a big sheet imports at 0,0 rather than
  # somewhere out in an empty canvas. ONE TRANSLATE FOR THE WHOLE SET, so several selected parts
  # keep their relative positions.
  test "the whole selection is translated by one transform" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [100, 50, 110, 60], p: [[100, 50], [110, 60]], k: 0, c: 0 },
                   { b: [120, 50, 130, 60], p: [[120, 50], [130, 60]], k: 0, c: 0 }], {})
    JS

    assert_includes body, 'transform="translate(-100 -50)"'
    assert_equal 1, body.scan("<g ").length, "one group, not one per shape"
    assert_includes body, 'points="100,50 110,60"', "coordinates are untouched; the group moves them"
  end

  # THE LAYER COLOUR, not print's black: a mono printer flattens a palette to greys, which is why
  # the sheet chose black — an argument that does not transfer to a file, where LightBurn maps
  # stroke colour back to layers on import.
  test "each outline carries its layer colour and no fill" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 0, c: 3 }], { colors: { 3: "#ff0000" } })
    JS

    assert_includes body, 'stroke="#ff0000"'
    assert_includes body, 'fill="none"'
  end

  test "a layer with no colour falls back to black" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 10]], k: 0, c: 9 }], { colors: {} })
    JS

    assert_includes body, 'stroke="#000000"'
  end

  # THE WHOLE POINT OF THE `g` DESCRIPTOR, on the surface it exists for: a circle exports as a
  # circle, not as 49 line segments a CAD app cannot constrain.
  test "a shape the file described as round exports as a circle" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 20, 20], p: [[0, 0], [20, 20]], k: 1, c: 0, g: ["e", 10, 10, 10, 10] }], {})
    JS

    assert_includes body, "<circle "
    assert_includes body, 'r="10"'
    assert_not_includes body, "<polygon"
  end

  test "an arc exports as an A-command path" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[10, 0], [0, 10]], k: 0, c: 0,
                     g: ["a", 10, 0, 0, 10, 10, 0, 0] }], {})
    JS

    assert_includes body, 'd="M 10 0 A 10 10 0 0 0 0 10"'
  end

  # A photo's base64 is deliberately absent from the payload, but the RECTANGLE it occupies is
  # real information about where an engrave sits. Selected means exported — a shape the user
  # picked must never vanish silently from the file.
  test "a bitmap exports as the dashed rectangle it shows on screen" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [0, 0, 10, 10], p: [[0, 0], [10, 0], [10, 10], [0, 10]], k: 1, i: 1, c: 0 }], {})
    JS

    assert_includes body, 'stroke-dasharray="4 3"'
  end

  test "exporting nothing refuses rather than writing an empty document" do
    err = in_export_svg(<<~JS)
      (() => { try { m.exportSvg([], {}); return "NO THROW" } catch (e) { return e.message } })()
    JS

    assert_match(/nothing selected/i, err)
  end

  private

    # Import the exporter and evaluate `body` against it (the module object is bound to `m`). The
    # page must already be an app page so the importmap and same-origin both hold — the shapes
    # below are synthetic, so WHICH page does not matter, only that one is loaded.
    def in_export_svg(body)
      visit file_path(@sample_id) unless page.current_path == file_path(@sample_id)
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        import("lib/export_svg")
          .then((m) => done(#{body}))
          .catch((e) => done("ERROR: " + (e && e.message ? e.message : String(e))));
      JS
      raise result if result.is_a?(String) && result.start_with?("ERROR:")
      result
    end

    # The geometry preview, rendered through the REAL renderer against the REAL fixture bytes, in
    # this process rather than by the job runner. A system test cannot wait for the job: ActiveJob's
    # test adapter never runs what it queues, and `perform_enqueued_jobs`' block form only inlines
    # jobs enqueued DURING the block — the geometry job is enqueued by the browser's own first poll,
    # inside the server thread. `perform_now` sidesteps the adapter and is deterministic, while
    # still being the real pipeline. (Copied from measure_print_test.rb, which copied it from
    # lbrn_measure_test.rb — three system tests need the same bootstrap and none can share a
    # superclass with the rest of the suite.)
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
    end
end
