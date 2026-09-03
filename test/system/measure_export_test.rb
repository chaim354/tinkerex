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

  # THE TMPDIR GOES WITH THE BACKEND. `FileLayer.reset!` alone leaks one `measure-export*`
  # directory per test into the system temp dir on every run, and CLAUDE.md's CI section records
  # exactly that cost accumulating on a persistent self-hosted runner (334 stray `tmp.*`
  # directories on the mac runner). The guard is what makes this safe to run after a setup that
  # raised before `@root` was assigned.
  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

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

  # THE CLIENT RESOLVES THE ENDPOINTS ITSELF, because the wire form is centre + start angle +
  # signed sweep: SVG's endpoint parameterisation cannot survive the payload's 0.01 mm rounding
  # near a half-turn, and the server sends the conditioned form instead (Geometry.arc_curve).
  #
  # SO THE TIGHT DELTAS BELOW ARE THE ASSERTION, not decoration. A 37° endpoint is
  # 7.986355100472928, which rounds to 7.99 — 0.0036 mm away, six orders above the tolerance
  # here. Any rounding reintroduced in lib/shape_svg.js fails this, which is the point: it is the
  # ENDPOINTS whose rounding the centre reconstruction amplifies, wherever they are rounded.
  test "an arc exports as an A-command path whose endpoints the client resolved" do
    body = in_export_svg(<<~JS)
      m.exportSvg([{ b: [7.99, -6.02, 10, 0], p: [[10, 0], [7.99, -6.02]], k: 0, c: 0,
                     g: ["a", 0, 0, 10, 0, -37] }], {})
    JS

    parts = body[/ d="([^"]+)"/, 1].split

    assert_equal [ "M", "A", "10", "10", "0" ], parts.values_at(0, 3, 4, 5, 6),
                 "the command, both radii and the x-axis rotation"
    assert_in_delta 10.0, parts[1].to_f, 1e-9
    assert_in_delta 0.0, parts[2].to_f, 1e-9
    assert_in_delta 7.986355100472928, parts[9].to_f, 1e-9
    assert_in_delta(-6.018150231520483, parts[10].to_f, 1e-9)
  end

  # BOTH SVG FLAGS COME OFF `delta` ALONE — the client's entire share of an orientation the server
  # has already decided. A DXF arc always arrives negative, because the Y-flip reverses DXF's
  # counter-clockwise sweep; the positive cases are pinned anyway, since the flag rule is the
  # wire form's contract and not a DXF fact.
  test "an arc's large-arc and sweep flags are derived from delta's sign and magnitude" do
    paths = in_export_svg(<<~JS)
      [-90, -270, 90, 270].map((delta) =>
        m.exportSvg([{ b: [-10, -10, 10, 10], p: [[10, 0], [0, 10]], k: 0, c: 0,
                       g: ["a", 0, 0, 10, 0, delta] }], {}).match(/ d="([^"]+)"/)[1])
    JS

    assert_equal [ %w[0 0], %w[1 0], %w[0 1], %w[1 1] ], paths.map { |d| d.split.values_at(7, 8) }
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

  # ---- the button ------------------------------------------------------------------------

  # DRIVES THE REAL CLICK, because the builder being right about synthetic input proves nothing
  # about whether the SELECTION ever reaches it. The anchor's click is stubbed rather than allowed
  # to download: headless Chrome here has no configured download directory, and capturing the Blob
  # is both hermetic and a stronger assertion than a file appearing somewhere on disk.
  #
  # THE NUMBERS COME FROM sample.lbrn2 AND ARE ALL LITERALS. Its Ellipse is Rx = Ry = 10 at
  # XForm 1 0 0 1 50 30, so after the Y-flip it is a ⌀20 circle centred (50, -30) with a 20 x 20 mm
  # bbox — and its 40 x 20 Rect (bbox 30..70, -40..-20) ENCLOSES that bbox, which is what makes the
  # click a paint-order test: contours are appended in descending bbox area (Rect 800, circle 400),
  # so the circle is on top and a click at its own centre selects it rather than the Rect.
  test "the SVG button exports exactly the marked parts" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    page.execute_script(<<~JS)
      window.__blob = null
      window.__downloads = []
      const realCreate = URL.createObjectURL
      URL.createObjectURL = (blob) => { window.__blob = blob; return realCreate.call(URL, blob) }
      HTMLAnchorElement.prototype.click = function () { window.__downloads.push(this.download) }
    JS

    click_on "Select parts"
    find(".measure-stage circle.measure-contour").click
    assert_text "1 part"

    find("[data-measure-target='svgButton']").click

    svg = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      window.__blob ? window.__blob.text().then(done) : done("NO BLOB");
    JS

    # THE CIRCLE ALONE — not the 40 x 20 Rect around it and not the 100 mm Line. A width of 100mm
    # would mean the whole file was exported; 40mm would mean the Rect came too.
    assert_includes svg, 'width="20mm"'
    assert_includes svg, 'height="20mm"'
    assert_includes svg, "<circle "
    assert_includes svg, 'r="10"'
    # Normalized to the origin: the circle's own bbox starts at (40, -40).
    assert_includes svg, 'transform="translate(-40 40)"'
    # The SOURCE base name plus a suffix, never the source name itself.
    assert_equal [ "sample-parts.svg" ], page.evaluate_script("window.__downloads")
  end

  # THE BUTTON MUST NOT LIE ABOUT WHAT IT DOES. Its visible text is constant because the bar
  # already carries five other controls, so the accessible name is what tracks the target — written
  # by the same refreshPrintBar() that writes the Print label, from the same targetNoun(). The
  # at-rest literal is also in the ERB, so this catches the two drifting apart.
  test "the button's accessible name names the set it will export" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    assert_selector "[data-measure-target='svgButton'][aria-label='Download all as SVG']"

    click_on "Select parts"
    find(".measure-stage circle.measure-contour").click
    assert_selector "[data-measure-target='svgButton'][aria-label='Download 1 part as SVG']"
  end

  test "the exported blob is typed as an SVG image" do
    visit file_path(@sample_id)
    click_on "Measure"
    assert_selector ".measure-view--ready", wait: 10

    page.execute_script(<<~JS)
      window.__blob = null
      const realCreate = URL.createObjectURL
      URL.createObjectURL = (blob) => { window.__blob = blob; return realCreate.call(URL, blob) }
      HTMLAnchorElement.prototype.click = function () {}
    JS

    find("[data-measure-target='svgButton']").click

    assert_equal "image/svg+xml", page.evaluate_script("window.__blob.type")
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
      # THE READINESS ASSERTION IS THE POINT OF DOING THIS IN-PROCESS. Without it a render that
      # failed surfaces later as "no circle on the page" — a browser-tier failure naming a symptom
      # three layers from its cause. The tests below are the first here that read the RENDERED
      # payload rather than synthetic shapes, so this is the line that tells them apart.
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end
end
