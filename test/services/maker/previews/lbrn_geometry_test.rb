require "test_helper"

module Maker
  module Previews
    class LbrnGeometryTest < ActiveSupport::TestCase
      # The four cubic quadrants of an r = 10 circle, in the `V<x> <y>c0x..c0y..c1x..c1y..` form
      # real LightBurn writes — the same vertices `bezier-circle.lbrn2` carries, reused by the two
      # inline documents below so their expected answers are the same arithmetic as that fixture's.
      CIRCLE_VERTS = "V10 0c0x10c0y5.523c1x10c1y-5.523V0 10c0x-5.523c0y10c1x5.523c1y10" \
                     "V-10 0c0x-10c0y-5.523c1x-10c1y5.523V0 -10c0x5.523c0y-10c1x-5.523c1y-10".freeze

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

      # THE GATE, IN THE DIRECTION THAT MATTERS. Under a rotation an SVG <ellipse> is not an SVG
      # <ellipse>, so emitting a descriptor would export geometry the file does not contain — and
      # unlike a wrong LABEL, that is a shape somebody cuts. The upright ellipse in the same
      # fixture is asserted two tests up: an implementation that always emits and one that never
      # emits each pass exactly one of the pair.
      test "a rotated Ellipse carries no descriptor and stays a polygon" do
        payload = build("rotated-ellipse.lbrn2")

        assert_equal 2, payload["shapes"].length
        with, without = payload["shapes"].partition { |s| s.key?("g") }
        assert_equal 1, with.length, "the upright ellipse keeps its descriptor"
        assert_equal 1, without.length, "the rotated one does not acquire one"
        assert_operator without.first["p"].length, :>, 12, "it is still drawn as a polygon"
      end

      # THE SAFETY ARGUMENT, PINNED — AND IT IS ABOUT WHICH KIND OF DESCRIPTOR, NOT ABOUT WHETHER
      # THERE IS ONE. `bezier-circle.lbrn2`'s circle is a <Shape Type="Path"> of four cubic
      # segments. It MEASURES round, so `d` is present and the readout says ⌀20 mm; since
      # tinkerex#217 it also carries a `"p"` descriptor, which is the file's OWN cubics transformed
      # into client space — a faithful rendering of what the file said, not an inference from the
      # points. What must never appear is an `"e"`: nothing may promote a contour to an ELLIPSE
      # because it happened to measure round. `Geometry.diameter`'s accepted consequence is that a
      # genuine 16-gon reports as round — harmless in a LABEL, and wrong geometry in a file
      # somebody cuts.
      #
      # UNTIL 2026-09-03 THIS ASSERTED `g` ABSENT, and that was the same rule stated in a world
      # where `"p"` did not exist: the only descriptor a Path could have acquired was an inferred
      # ellipse. The rule did not move; the set of exact forms did.
      test "a Path that measures round is described by its own cubics, never promoted to an ellipse" do
        payload = build("bezier-circle.lbrn2")
        round = payload["shapes"].find { |s| s["d"] }

        assert_not_nil round, "the bezier circle still measures round"
        assert_equal "p", round["g"]&.first,
                     "a Path is described by the cubics the file wrote, never by an inferred primitive"
      end

      # THE GUARD THAT DISCHARGES THE WHOLE FEATURE, AND IT RESOLVES THE DESCRIPTOR RATHER THAN
      # READING IT. A string-equality assertion cannot do this job: tinkerex#213's arc descriptor
      # passed its own five-number equality test while drawing 1.37 mm from the shape's own points,
      # because the numbers were never what was wrong. The live trap here has the same shape — a
      # control point that misses the affine yields a perfectly well-formed `d` describing a
      # plausible curve that is not the file's — so this asks the two questions the rest of the
      # payload already answers: does the resolved curve pass through the shape's own `p` points,
      # and does it reach the shape's own `b` bbox.
      test "a bezier Path's descriptor draws the curve its own points and bbox describe" do
        circle = build("bezier-circle.lbrn2")["shapes"].find { |s| s["g"] }

        assert_curve_tracks_shape circle, "bezier-circle's Path circle"
      end

      # THE MUTATION THIS FIXTURE EXISTS FOR: TRANSFORM THE VERTICES AND NOT THE CONTROL POINTS.
      # Every `B` PrimList in the fixture corpus (bezier-circle, nested-plate) sits under the
      # IDENTITY XForm, where the only affine a control point can miss is `apply`'s Y-flip. That
      # flip alone does catch it — but a scale and a translate are what a real file's Paths carry
      # (real-export.lbrn2 places a group at `2 0 0 2 0 100`), and a guard that can only see the
      # flip would go green the moment someone applied the flip and not the matrix. Built inline
      # for the reason dxf_geometry_test.rb builds `arc_dxf` inline: what is needed is one
      # document property, not a new file.
      #
      # r = 10 scaled by 2 and placed at (30, 40) is a ⌀40 circle centred (30, -40) after the flip.
      test "the descriptor's control points ride the same affine as its vertices" do
        shape = build_xml(bezier_path_doc(xform: "2 0 0 2 30 40"))["shapes"].first

        assert_in_delta 40.0, shape["d"], 0.05, "the scaled circle is ⌀40"
        assert_curve_tracks_shape shape, "a bezier Path under a scale and a translate"
      end

      # A DESCRIPTOR BELONGS TO A CONTOUR, NOT TO A SHAPE. `polylines` starts a new contour
      # whenever an op does not continue from the previous one (`prev != ai`), so one
      # <Shape Type="Path"> legitimately yields several — and each reaches `Collector#add`
      # separately, with its own points, its own bbox and therefore its own descriptor. One
      # descriptor emitted per SHAPE would be attached to both contours, and the resolved curve
      # would then span the whole shape while `b` covers one contour: the bbox assertion below is
      # what fails.
      #
      # `B0 1B2 3` is two disjoint cubics over four vertices — the first quadrant of the circle and
      # the third — so the two contours are far apart and neither bbox is a subset of the other.
      test "a Path that splits into several contours gets one descriptor each" do
        shapes = build_xml(bezier_path_doc(prims: "B0 1B2 3"))["shapes"]

        assert_equal 2, shapes.length, "the fixture must actually split, or this test is vacuous"
        # THE GEOMETRY ASSERTION SPEAKS FIRST, DELIBERATELY. The inequality below is a cheap sanity
        # check and it is NOT what discharges this: a shared descriptor is wrong because it
        # describes geometry the entry it rides on does not contain, and that is a claim about the
        # resolved curve against `b`. Ordered the other way, the mutation reports two equal strings
        # and the assertion that carries the weight never runs.
        shapes.each_with_index { |s, i| assert_curve_tracks_shape s, "contour #{i}" }
        assert_not_equal shapes[0]["g"][1], shapes[1]["g"][1],
                         "two contours cannot share one path"
      end

      # `prim_ops` HAS A SECOND ARM THAT BUILDS OPS FROM NO `PrimList` AT ALL — a bare
      # "BezierClosed" means "a cubic between every consecutive vertex, and back to the first" —
      # and it produces `B` ops that never appear as `B<a> <b>` text anywhere in the file. An
      # implementation that read the descriptor's segments off the PrimList STRING rather than off
      # the resolved ops would emit nothing here, silently, on the arm that has no test of its own.
      test "the synthetic BezierClosed arm carries a descriptor too, and closes it" do
        shape = build_xml(bezier_path_doc(prims: "BezierClosed"))["shapes"].first

        assert_equal 1, shape["k"], "BezierClosed is a closed contour"
        assert_match(/ Z\z/, shape["g"][1], "a closed contour's path must close")
        assert_curve_tracks_shape shape, "a BezierClosed Path"
      end

      # A STRAIGHT-ONLY CONTOUR GETS NO DESCRIPTOR, AND THAT IS A DECISION RATHER THAN AN OMISSION.
      # `p` already IS the geometry of a run of `L` ops — thinning only drops points that sit
      # within SIMPLIFY_TOLERANCE of the line the browser draws — so a path descriptor there would
      # be an exact restatement of the points beside them, paid for on the wire per contour. The
      # form exists for what has no exact form already (`Geometry.path_curve`). A contour that
      # MIXES straight and curved ops still gets the whole path, because a path is continuous.
      test "a Path with no curve in it carries no descriptor at all" do
        %w[real-export.lbrn2 text-backup-path.lbrn2 real-export.mage].each do |name|
          build(name)["shapes"].each do |s|
            assert_not_equal "p", s["g"]&.first, "#{name}: a straight-only contour needs no path"
          end
        end
      end

      # THE `d`-STRING SAFETY ARGUMENT, DISCHARGED MECHANICALLY RATHER THAN BY THE COMMENT ALONE.
      # The wire form is a string, and a reviewer should ask what stops a filename or a
      # `<VertList>`'s own text riding into it. The answer is that it is built from PARSED NUMBERS
      # — `Lbrn2` has already turned every coordinate into a Float, and `Geometry.path_curve`
      # rounds each one — so there is no path by which a byte of file text reaches the output. This
      # asserts that on the real fixtures: nothing outside the M/L/C/Z grammar and the number
      # grammar appears in any emitted `d`.
      test "an emitted d string holds nothing but the command letters and numbers" do
        %w[bezier-circle.lbrn2 nested-plate.lbrn2].each do |name|
          paths = build(name)["shapes"].filter_map { |s| s["g"] }.select { |g| g[0] == "p" }
          assert paths.any?, "#{name} must produce a path descriptor, or this is vacuous"

          paths.each do |(_, d)|
            assert_match(/\A[MLCZ0-9 .eE+-]+\z/, d, "#{name}: a d string may hold only numbers and M/L/C/Z")
          end
        end
      end

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def build(name) = JSON.parse(LbrnGeometry.render(fixture(name))[:bytes])

      def build_xml(xml) = JSON.parse(LbrnGeometry.render(xml)[:bytes])

      # A bezier Path in the dialect real LightBurn writes, with the one document property the
      # caller is testing — an XForm, or a connectivity that splits. The vertices are the same
      # r = 10 circle `bezier-circle.lbrn2` holds (four cubic quadrants, handle length 0.5523r),
      # so a caller can reason about the answer in mm.
      def bezier_path_doc(xform: "1 0 0 1 0 0", prims: "B0 1B1 2B2 3B3 0")
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <LightBurnProject AppVersion="1.6.00" FormatVersion="1" MaterialHeight="0">
            <Shape Type="Path" CutIndex="0" VertID="1" PrimID="1">
              <XForm>#{xform}</XForm>
              <VertList>#{CIRCLE_VERTS}</VertList>
              <PrimList>#{prims}</PrimList>
            </Shape>
          </LightBurnProject>
        XML
      end

      # THE DESCRIPTOR RESOLVED THE WAY A RENDERER RESOLVES IT, which is the only form of this
      # assertion that carries weight — see the test above for why the string form does not.
      #
      # STRICT ON PURPOSE: an unknown command RAISES. The wire form is absolute M/L/C/Z and
      # nothing else (`Geometry.path_curve`), and a lenient parser that skipped an `S`, a `Q` or an
      # `A` would let a producer start emitting one while every assertion below stayed green —
      # which is exactly how a client that does not understand the command would fail, silently.
      def resolve_path(d, per_curve: 48)
        tokens = d.split
        pts = []
        cur = start = nil
        i = 0
        while i < tokens.length
          case tokens[i]
          when "M", "L"
            pts << (cur = [ Float(tokens[i + 1]), Float(tokens[i + 2]) ])
            start ||= cur
            i += 3
          when "C"
            c1 = [ Float(tokens[i + 1]), Float(tokens[i + 2]) ]
            c2 = [ Float(tokens[i + 3]), Float(tokens[i + 4]) ]
            p3 = [ Float(tokens[i + 5]), Float(tokens[i + 6]) ]
            (1..per_curve).each { |k| pts << cubic_at(cur, c1, c2, p3, k.to_f / per_curve) }
            cur = p3
            i += 7
          when "Z"
            pts << (cur = start)
            i += 1
          else
            raise "unexpected path command #{tokens[i].inspect} — the wire form is absolute M/L/C/Z only"
          end
        end
        pts
      end

      def cubic_at(p0, c1, c2, p3, t)
        u = 1.0 - t
        [ 0, 1 ].map do |axis|
          (u * u * u * p0[axis]) + (3 * u * u * t * c1[axis]) +
            (3 * u * t * t * c2[axis]) + (t * t * t * p3[axis])
        end
      end

      # THE TWO QUESTIONS THE REST OF THE PAYLOAD ALREADY ANSWERS, asked of the resolved curve.
      #
      # 0.05 mm is where the three roundings land, stated rather than tuned: `p` is thinned to
      # within SIMPLIFY_TOLERANCE (0.01) of the true contour and rounded at PRECISION (≤0.007 mm
      # diagonally), and the descriptor's control points are rounded at PRECISION too — which
      # displaces the curve by at most that much, because a cubic is a convex combination of its
      # own control points. Roughly 0.03 mm of headroom, against a mutation that misses by
      # millimetres.
      #
      # THE BBOX IS TWO-SIDED HERE, where dxf_geometry_test.rb's arc guard is one-sided, and the
      # difference is a property of these fixtures rather than a stronger rule: a cubic quadrant's
      # ENDPOINTS are the circle's axis extremes, so the flattened `b` is exact and the resolved
      # curve owes it equality. Where a curve's extreme falls BETWEEN flattened samples, only
      # containment is owed.
      def assert_curve_tracks_shape(shape, label, tol: 0.05)
        assert_equal "p", shape["g"]&.first, "#{label}: expected a path descriptor"

        curve = resolve_path(shape["g"][1])
        worst = max_deviation(shape["p"], curve)
        assert_operator worst, :<=, tol,
                        "#{label}: the drawn curve strays #{worst.round(4)} mm from the shape's own points"

        box = [ curve.map(&:first).min, curve.map(&:last).min,
                curve.map(&:first).max, curve.map(&:last).max ]
        %w[left top right bottom].each_with_index do |edge, i|
          assert_in_delta shape["b"][i], box[i], tol,
                          "#{label}: the drawn curve misses b's #{edge} edge"
        end
      end

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
