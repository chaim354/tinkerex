require "test_helper"

module Maker
  module Previews
    class LbrnGeometryTest < ActiveSupport::TestCase
      test "build returns a versioned payload with one entry per contour" do
        payload = build("real-export.lbrn2")

        assert_equal 1, payload["v"]
        assert_equal 4, payload["shapes"].length
        payload["shapes"].each do |s|
          assert s["b"].is_a?(Array) && s["b"].length == 4, "every contour carries a bbox"
          assert s["p"].is_a?(Array) && s["p"].length >= 2, "every contour carries drawing points"
          assert_includes [ 0, 1 ], s["k"]
          assert_kind_of Integer, s["o"]
        end
      end

      # THE GUARD THAT MATTERS. It ties the payload to the size the Laser Settings panel
      # already reports, so nobody can optimise the walk for one caller without this going red.
      # job_size rounds to 1dp and the payload carries 2, so round ONCE then demand equality —
      # a tolerance band would let a real divergence hide inside it.
      test "the payload's bboxes union to exactly job_size" do
        %w[real-export.lbrn2 sample.lbrn2 laser-settings.lbrn2 bezier-circle.lbrn2
           text-backup-path.lbrn2].each do |name|
          doc = Lbrn2.parse_document(fixture(name))
          expected = Lbrn2.job_size(doc)
          # NOT `next if expected.nil?` — all five fixtures report a size today, but a silent
          # skip means a fixture that ever stopped yielding geometry would quietly drop out of
          # this loop instead of failing it.
          assert expected, "#{name} must report a job size (it has geometry), or this comparison is vacuous"

          boxes = build(name)["shapes"].map { |s| s["b"] }
          w = boxes.map { |b| b[2] }.max - boxes.map { |b| b[0] }.min
          h = boxes.map { |b| b[3] }.max - boxes.map { |b| b[1] }.min

          assert_equal expected["width"],  w.round(1), "#{name}: payload width disagrees with job_size"
          assert_equal expected["height"], h.round(1), "#{name}: payload height disagrees with job_size"
        end
      end

      test "job carries the document bbox and its origin" do
        payload = build("real-export.lbrn2")
        job = payload["job"]

        assert_in_delta 110.0, job["w"], 0.01
        assert_in_delta 110.0, job["h"], 0.01
        # BY VALUE, not `key?` — a wrong origin puts every shape in the wrong place in the
        # client's viewBox even though w/h are still right, and `key?` cannot tell a correct 0.0
        # apart from a bug that always writes 0.0. real-export.lbrn2's own leftmost/topmost point
        # (verified against a fresh build, not assumed) sits at x=0.0, y=-110.0.
        assert_in_delta 0.0, job["x"], 0.01, "the client needs the real origin, not just a present key"
        assert_in_delta(-110.0, job["y"], 0.01)
      end

      test "s[c] reports each shape's own CutIndex, not a shared default" do
        shapes = build("real-export.lbrn2")["shapes"].index_by { |s| s["o"] }

        # real-export.lbrn2 (see RealExportTest in lbrn2_test.rb): the Rect and the grouped Path
        # sit on CutIndex 0, the two Paths (one an instance of the other) on CutIndex 1 — verified
        # against a fresh build, not assumed. CutIndex is a STRING attribute value, not an
        # Integer. A shared value, or nil, would pass any test that never reads two that differ.
        assert_equal "0", shapes[1]["c"]
        assert_equal "1", shapes[2]["c"]
        assert_equal "1", shapes[3]["c"]
        assert_equal "0", shapes[4]["c"]
      end

      test "s[i] flags a real image, and the image's own bytes never reach the payload" do
        marker = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        xml = %(<LightBurnProject AppVersion="1.6.00">) +
              %(<Shape Type="Bitmap" CutIndex="0" W="10" H="10" Data="#{marker}"><XForm>1 0 0 1 0 0</XForm></Shape>) +
              %(</LightBurnProject>)
        result = LbrnGeometry.render(xml)

        shape = JSON.parse(result[:bytes])["shapes"].first
        assert_equal 1, shape["i"], "the parser must have genuinely recognised a real PNG, not defaulted to 0"

        # `bytes` is the actual WIRE FORMAT — re-checking the parsed hash would only prove the
        # JSON key exists, not that the base64 is absent from what actually ships (0.1 KB vs
        # 1.45 MB on a real file is the whole point of "i" existing at all).
        assert_not_includes result[:bytes], marker, "the bitmap's own base64 must never reach the payload"
        assert_not_includes result[:bytes], "data:image", "nor a data: URL — that is the same bytes, re-wrapped"
        assert_not_includes result[:bytes], "href"
      end

      test "coordinates are rounded to PRECISION, not shipped at full float precision" do
        xml = %(<LightBurnProject AppVersion="1.6.00">) +
              %(<Shape Type="Rect" CutIndex="0" W="10" H="10"><XForm>1 0 0 1 5.12345 0</XForm></Shape>) +
              %(</LightBurnProject>)
        payload = JSON.parse(LbrnGeometry.render(xml)[:bytes])

        # Raw x-min is 0.12345000000000006. Every real fixture's bbox extreme happens to be a
        # clean number, so .round(2) and .round(3) are IDENTICAL floats on all of them — nothing
        # above can tell PRECISION apart from an off-by-one. This shape's x-min rounds to 0.12 at
        # the shipped PRECISION (2); a PRECISION of 3 would report 0.123 instead.
        assert_equal 0.12, payload["shapes"].first["b"][0]
        assert_equal 0.12, payload["job"]["x"]
      end

      test "render returns JSON bytes the job can attach" do
        result = LbrnGeometry.render(fixture("real-export.lbrn2"))

        assert_equal "application/json", result[:content_type]
        assert result[:bytes].bytesize.positive?
        assert_equal 4, JSON.parse(result[:bytes])["shapes"].length
      end

      # Paired POSITIONALLY with a fresh each_geometry walk, not by object_id. each_geometry's own
      # doc comment (lbrn2.rb) is explicit that ids are NOT guaranteed unique — a Text and its
      # BackupPath share one, and a Path can yield several polylines under one — so a hash keyed
      # by oid silently keeps only the LAST contour seen for a repeated id. Not live on this
      # fixture's two shapes (bezier-circle.lbrn2 has no Text), but positional pairing is correct
      # BY CONSTRUCTION rather than by which fixtures happen not to trigger it. The `next if
      # points.length < 2` mirrors LbrnGeometry.build's own filter exactly, so the two walks stay
      # aligned index-for-index.
      test "decimation thins big contours but never moves a reported bbox" do
        doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
        full = []
        Lbrn2.each_geometry(doc) do |_c, points, *|
          next if points.length < 2

          xs = points.map(&:first); ys = points.map(&:last)
          full << [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) }
        end

        build("bezier-circle.lbrn2")["shapes"].zip(full).each do |s, expected|
          assert_equal expected, s["b"], "the reported bbox must equal the FULL-resolution bbox"
        end
      end

      # THE GAP THE TEST ABOVE CANNOT CLOSE, however identical it looks. A UNION over a whole
      # document hides any per-shape error some other shape already bounds — on
      # bezier-circle.lbrn2 the union stayed green with `b` measured from thinned points on three
      # separate fixtures. This isolates ONE shape whose extremes are its own: laser-settings'
      # Ellipse is not shadowed by the co-located Rect in either axis, so thinning it moves the
      # reported box measurably (x 40.0..60.0 becomes x 40.19..60.0) and this assertion fails for
      # the reason it exists.
      #
      # Paired positionally, same reasoning as the test above — laser-settings.lbrn2 has no Text
      # either, so this isn't live here, but the pairing shouldn't depend on that.
      test "a thinned ellipse still reports its FULL-resolution bbox" do
        doc = Lbrn2.parse_document(fixture("laser-settings.lbrn2"))
        full = []
        Lbrn2.each_geometry(doc) do |_c, points, *|
          next if points.length < 2

          xs = points.map(&:first); ys = points.map(&:last)
          full << { n: points.length, bbox: [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) } }
        end

        ellipse = build("laser-settings.lbrn2")["shapes"].zip(full).max_by { |_s, f| f[:n] }
        assert ellipse, "the fixture should have an ellipse"
        s, f = ellipse
        assert_equal f[:bbox], s["b"]
      end

      # THE INVARIANT THE DRAWING PAYLOAD ACTUALLY OWES ITS READER, stated as a BOUND rather than
      # as a property of one algorithm: whatever thinning is applied, no point of the true contour
      # may end up further than SIMPLIFY_TOLERANCE from the line the browser draws.
      #
      # This replaces a coupling assertion that could not fail for the reason it existed.
      # `BEZIER_SAMPLES % DECIMATE_STRIDE == 0` was said to mean "every original vertex survives",
      # and it does — but ONLY for a contour built entirely of `B` ops, because `polylines` appends
      # 12 points per bezier segment and exactly ONE per `L` segment. A single straight edge shifts
      # every later index by one and destroys the alignment. bezier-circle.lbrn2 is all-bezier
      # (PrimList `B0 1B1 2B2 3B3 0`), so it satisfied the old assertion while real mixed-geometry
      # files were being mangled: measured over the 58-file corpus, 1148 of 5259 thinned contours
      # were displaced by more than 5% of their own size, worst case 58.7 mm.
      #
      # A dropped CURVE SAMPLE flattens a curve slightly. A dropped VERTEX cuts a corner off
      # entirely — and for an `L` segment every point IS a vertex.
      # THE TEST BELOW MEASURES AGAINST SIMPLIFY_TOLERANCE, SO IT CANNOT POLICE THE CONSTANT
      # ITSELF — set it to 100 and every deviation assertion passes trivially while the drawing
      # turns to spaghetti. This pins the magnitude against a literal instead. 0.05 mm is a hobby
      # laser's positional accuracy; anything at or above that is visible in the terms this
      # file's readers measure in, and is a decision to argue for here rather than to slip past.
      test "the tolerance stays below what a laser can actually resolve" do
        assert_operator Geometry::SIMPLIFY_TOLERANCE, :>, 0,
                        "a zero tolerance disables thinning entirely"
        assert_operator Geometry::SIMPLIFY_TOLERANCE, :<=, 0.05
      end

      test "simplification never moves the drawn line further than the tolerance" do
        %w[real-export.lbrn2 sample.lbrn2 laser-settings.lbrn2 bezier-circle.lbrn2
           text-backup-path.lbrn2].each do |name|
          doc = Lbrn2.parse_document(fixture(name))
          drawn = build(name)["shapes"].map { |s| s["p"] }
          full = []
          Lbrn2.each_geometry(doc) { |_c, pts, *| full << pts if pts.length >= 2 }

          full.zip(drawn).each_with_index do |(original, kept), i|
            dev = max_deviation(original, kept)
            assert_operator dev, :<=, Geometry::SIMPLIFY_TOLERANCE + 0.011,
                            "#{name} contour #{i}: drawn line is #{dev.round(3)} mm off the real one"
          end
        end
      end

      # THE CASE THE OLD ALGORITHM GOT WRONG, isolated. Six edges alternating straight and curved,
      # so `polylines` emits 1 point for each `L` and 12 for each `B` and no vertex lands on a
      # predictable index. Under stride-3 decimation EVERY corner here is dropped (they sit at
      # indices 1, 13, 25, 26, 38 — none a multiple of 3) and the outline cuts straight across the
      # shape. The rightmost corner is the one to name: lose it and the contour visibly collapses.
      test "a contour mixing straight and curved edges keeps its corners" do
        xml = <<~XML
          <LightBurnProject AppVersion="1.6.00">
            <Shape Type="Path" CutIndex="0" VertID="1" PrimID="1">
              <XForm>1 0 0 1 0 0</XForm>
              <VertList>V0 0c0x1c1x1V30 0c0x40c0y-6c1x22c1y0V40 10c0x40c0y16c1x40c1y4V30 20c0x1c1x1V0 20c0x-10c0y26c1x8c1y20V-10 10c0x-10c0y4c1x-10c1y16</VertList>
              <PrimList>L0 1B1 2B2 3L3 4B4 5B5 0</PrimList>
            </Shape>
          </LightBurnProject>
        XML
        doc = Lbrn2.parse_document(xml)
        original = nil
        Lbrn2.each_geometry(doc) { |_c, pts, *| original = pts }
        assert_operator original.length, :>, 32, "the fixture must exceed any thinning threshold"

        drawn = JSON.parse(LbrnGeometry.render(xml)[:bytes])["shapes"].first["p"]

        # apply() flips Y, so the shape's rightmost corner (40, 10) arrives as (40.0, -10.0).
        assert_includes drawn, [ 40.0, -10.0 ],
                        "the rightmost corner must survive — dropping it cuts the shape open"
        assert_operator max_deviation(original, drawn), :<=, Geometry::SIMPLIFY_TOLERANCE + 0.011
      end

      # Thinning must still HAPPEN — an implementation that returns every point trivially satisfies
      # the bound above while re-inflating the payload the exclusion rules exist to keep small.
      #
      # Asserted on `simplify` DIRECTLY rather than through a fixture, and that is the honest
      # framing rather than a shortcut. None of the repo's fixtures thin at all, because thinning
      # removes REDUNDANCY and LightBurn does not oversample a 20 mm circle: its 49 flattened
      # points sit ~0.021 mm off their neighbours' chord, above the 0.01 mm tolerance, so every one
      # of them is load-bearing. The redundancy lives in the real corpus — small text contours
      # flattened at a fixed 12 samples per cubic — where this cuts the worst file from 728 KB to
      # 200 KB gzipped. `rake lbrn:geometry_report` is what observes that; a 2 KB fixture cannot.
      test "simplify collapses points that carry no shape" do
        straight = (0..49).map { |i| [ i * 0.1, 0.0 ] }
        assert_equal [ [ 0.0, 0.0 ], [ 4.9, 0.0 ] ], Geometry.simplify(straight),
                     "50 collinear points describe one segment"

        # A curve sampled far finer than the tolerance needs: 200 points around a 0.5 mm circle.
        fine = (0..200).map { |i| t = i * 2 * Math::PI / 200; [ 0.5 * Math.cos(t), 0.5 * Math.sin(t) ] }
        kept = Geometry.simplify(fine)
        assert_operator kept.length, :<, fine.length / 4, "an oversampled arc must collapse"
        assert_operator max_deviation(fine, kept), :<=, Geometry::SIMPLIFY_TOLERANCE + 1e-9
      end

      # `d` COMES FROM FULL-RESOLUTION POINTS, and this is the case that can prove it. A 0.2 mm
      # circle — a pilot hole or a registration dot — arrives as 49 flattened points and thins to
      # 9, because at that size LightBurn's fixed 12-samples-per-cubic is wildly redundant. Nine is
      # BELOW MIN_CIRCLE_POINTS, so a `diameter` computed from the thinned outline would refuse to
      # call it round and report no `d` at all, silently turning a correct "⌀0.2 mm" into a bare
      # bounding box. Measuring before thinning is what keeps the readout honest for exactly the
      # small features a measuring tool exists to inspect.
      test "a small circle still reports a diameter after its outline is thinned" do
        xml = <<~XML
          <LightBurnProject AppVersion="1.6.00">
            <Shape Type="Path" CutIndex="0" VertID="1" PrimID="1">
              <XForm>1 0 0 1 0 0</XForm>
              <VertList>V0.1 0c0x0.1c0y0.05523c1x0.1c1y-0.05523V0 0.1c0x-0.05523c0y0.1c1x0.05523c1y0.1V-0.1 0c0x-0.1c0y-0.05523c1x-0.1c1y0.05523V0 -0.1c0x0.05523c0y-0.1c1x-0.05523c1y-0.1</VertList>
              <PrimList>B0 1B1 2B2 3B3 0</PrimList>
            </Shape>
          </LightBurnProject>
        XML
        full = nil
        Lbrn2.each_geometry(Lbrn2.parse_document(xml)) { |_c, pts, *| full = pts }
        shape = JSON.parse(LbrnGeometry.render(xml)[:bytes])["shapes"].first

        assert_operator full.length, :>=, Geometry::MIN_CIRCLE_POINTS
        assert_operator shape["p"].length, :<, Geometry::MIN_CIRCLE_POINTS,
                        "the thinned outline must fall below the circularity floor, or this proves nothing"
        # Asserted before the delta so a regression reads as "no diameter at all" rather than as a
        # TypeError from assert_in_delta trying to coerce nil.
        assert shape["d"], "no diameter reported — d was measured from the thinned outline"
        assert_in_delta 0.2, shape["d"], 0.01, "d must be measured before thinning"
      end

      # BOTH DIRECTIONS. Asserting only that the circle is round still passes with the tolerance
      # loosened to 50% — the square is the assertion that carries the weight.
      test "a bezier circle reports a diameter and a same-sized square does not" do
        shapes = build("bezier-circle.lbrn2")["shapes"].sort_by { |s| s["b"][0] }
        circle, square = shapes

        assert_in_delta 20.0, circle["d"], 0.05, "the circle must report d"
        assert_nil square["d"], "a 20x20 square is NOT round, however equidistant its corners are"

        # They are deliberately the same size, so w==h cannot be what separated them.
        assert_in_delta circle["b"][2] - circle["b"][0], square["b"][2] - square["b"][0], 0.05
      end

      test "an open contour never reports a diameter" do
        shapes = build("real-export.lbrn2")["shapes"]
        assert shapes.any? { |s| s["k"].zero? }, "fixture must have an open contour"
        shapes.each { |s| assert_nil s["d"], "an open contour has no diameter" if s["k"].zero? }
      end

      # CIRCLE_TOLERANCE, PINNED. Every other test above leaves the tolerance unguarded: the
      # square "a bezier circle reports a diameter..." relies on is 5 points, so
      # MIN_CIRCLE_POINTS (12) rejects it before CIRCLE_TOLERANCE is ever consulted — set the
      # tolerance to 1_000_000 and the whole file above stays green (checked by hand while
      # writing this test). This is the missing case: a 10x9 ellipse (LightBurn's own Ellipse
      # samples 32 points + a closing point = 33, clearing the point floor) whose radius varies
      # ~5.5% around its bbox-centre mean — round enough to be a plausible "is this circular"
      # candidate, not round enough to pass the shipped 2% tolerance. At CIRCLE_TOLERANCE = 0.5
      # this shape's "d" flips from nil to 19.0 — verified by hand — which is what makes this
      # assertion, unlike the others, actually exercise the tolerance comparison rather than
      # never reaching it.
      test "an ellipse just outside the tolerance reports no diameter" do
        xml = %(<LightBurnProject AppVersion="1.6.00">) +
              %(<Shape Type="Ellipse" CutIndex="0" Rx="10" Ry="9"><XForm>1 0 0 1 0 0</XForm></Shape>) +
              %(</LightBurnProject>)
        shapes = JSON.parse(LbrnGeometry.render(xml)[:bytes])["shapes"]

        assert_equal 1, shapes.length
        assert_nil shapes.first["d"], "a 10x9 ellipse is ~5.5% off-round — outside the shipped 2% tolerance"
      end

      # A document parse_document cannot make sense of at all — SAME condition Lbrn2.to_svg
      # raises ParseError for. This input (verified by hand) leaves doc.root nil without Nokogiri
      # raising directly; a DIFFERENT corrupt-input shape (Lbrn2Test's own null-byte fixture)
      # makes parse_document itself raise Nokogiri::XML::SyntaxError before doc.root is ever
      # checked — that path already propagated (uncaught) before this test existed and is
      # untouched by it. This one is the case the behaviour change targets: without the
      # doc.root.nil? guard in LbrnGeometry.build, each_geometry's own `return if doc.root.nil?`
      # yields nothing, silently, and build happily returns the ordinary empty-payload shape —
      # turning a corrupt upload into a READY Measure view lying about the file.
      test "render raises ParseError for a document with no root, matching Lbrn2.to_svg" do
        assert_raises(Lbrn2::ParseError) { LbrnGeometry.render("not xml at all, no tags whatsoever") }
      end

      # THE CASE THE GUARD ABOVE MUST NOT CATCH. A document that parses cleanly and genuinely has
      # no shapes (an empty project, or every shape filtered by a hidden layer) is honest, not
      # corrupt — the client has a "No measurable geometry in this file" message for exactly this,
      # and raising here would make an empty-but-real project look like a failed preview.
      test "a document that parses but has no shapes returns the honest empty payload, not an error" do
        xml = %(<?xml version="1.0"?><LightBurnProject></LightBurnProject>)
        payload = JSON.parse(LbrnGeometry.render(xml)[:bytes])

        assert_equal [], payload["shapes"]
        assert_equal({ "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 }, payload["job"])
      end

      # ---- curve descriptors ----------------------------------------------------------------

      # `sample.lbrn2` carries an <Ellipse>, and the traversal has always yielded an exact
      # descriptor for it — `Lbrn2.to_svg` draws a real <ellipse> from it. The payload discarded it
      # by name (`_ellipse`) until now, so the Measure view drew a 32-gon beside a thumbnail
      # drawing an ellipse.
      test "an Ellipse shape carries an exact curve descriptor" do
        payload = build("sample.lbrn2")
        curves = payload["shapes"].filter_map { |s| s["g"] }

        assert_equal 1, curves.length, "sample.lbrn2 has exactly one Ellipse"
        assert_equal "e", curves.first[0]
      end

      # NOT "close to". ELLIPSE_SAMPLES is 32 — a multiple of 4 — so an axis-aligned ellipse's axis
      # extents are sampled EXACTLY and `ellipse_from` recovers the file's own radii rather than an
      # approximation of them. A tolerance here would pass just as well for a descriptor derived
      # from a coarse sample, which is the thing worth knowing.
      test "the descriptor recovers the file's own radii exactly" do
        payload = build("rotated-ellipse.lbrn2")
        upright = payload["shapes"].find { |s| s["g"] }

        assert_equal [ "e", 0.0, 0.0, 20.0, 10.0 ], upright["g"]
      end

      # THE SAFETY ARGUMENT, PINNED. `bezier-circle.lbrn2`'s circle is a <Shape Type="Path"> of four
      # cubic segments — it MEASURES round, so `d` is present and the readout says ⌀20 mm — but the
      # file never declared it a primitive, so it must carry NO descriptor. Nothing may infer one
      # from the points: `Geometry.diameter`'s accepted consequence is that a genuine 16-gon reports
      # as round, which is harmless in a LABEL and is wrong geometry in a file somebody cuts.
      #
      # This is the assertion that would catch a "helpfully" widened implementation, and it is the
      # one no Ellipse fixture can make.
      test "a Path that measures round carries no descriptor" do
        payload = build("bezier-circle.lbrn2")
        round = payload["shapes"].find { |s| s["d"] }

        assert_not_nil round, "the bezier circle still measures round"
        assert_not round.key?("g"), "but it was never DECLARED round, so nothing may say it is"
      end

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def build(name) = JSON.parse(LbrnGeometry.render(fixture(name))[:bytes])

      # The largest distance from any point of `original` to the polyline `kept` — i.e. how far
      # the drawn line strays from the real contour. Measured point-to-SEGMENT, not
      # point-to-point: a thinned polyline is allowed to omit points, and only matters when it
      # omits them in a way that moves the LINE.
      def max_deviation(original, kept)
        original.map { |p| kept.each_cons(2).map { |a, b| point_segment_distance(p, a, b) }.min || 0.0 }.max
      end

      def point_segment_distance(point, a, b)
        px, py = point
        ax, ay = a
        bx, by = b
        dx = bx - ax
        dy = by - ay
        return Math.hypot(px - ax, py - ay) if dx.abs < 1e-12 && dy.abs < 1e-12

        t = (((px - ax) * dx) + ((py - ay) * dy)) / ((dx * dx) + (dy * dy))
        t = t.clamp(0.0, 1.0)
        Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))
      end
    end
  end
end
