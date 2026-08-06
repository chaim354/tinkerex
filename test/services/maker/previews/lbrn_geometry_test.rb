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

      # THE GAP THE TEST ABOVE CANNOT CLOSE, however identical it looks. `BEZIER_SAMPLES` (12,
      # in Lbrn2) divides `DECIMATE_STRIDE` (3) evenly, so the circle's four axis-extreme points
      # sit at flattened indices 0/12/24/36/48 — all multiples of 3 — and survive decimation
      # exactly; its reported bbox comes out identical whether "b" is measured from full or from
      # decimated points. That is a coincidence of two unrelated constants, not anything this
      # code enforces: checked by hand, with `build` measuring "b" from `decimate(points)`
      # instead of `points`, EVERY test in this file — this one included — stayed green.
      # laser-settings.lbrn2's Ellipse has no such coincidence: its four axis extremes fall on
      # sample indices 0/8/16/24 (verified by hand), and only 0 and 24 are multiples of 3 — the
      # x-minimum (idx 16) and y-minimum (idx 8) are NOT retained, so decimating it measurably
      # moves the reported box, from x 40.0..60.0 / y -40.0..-20.0 to x 40.19..60.0 /
      # y -39.81..-20.0. Isolating that one shape — rather than the whole-job union, where a
      # co-located Rect already supplies the same bound — is what lets this assertion fail for
      # the reason it exists.
      #
      # Paired positionally, same reasoning as the test above — laser-settings.lbrn2 has no Text
      # either, so this isn't live here, but the pairing shouldn't depend on that.
      test "a decimated ellipse still reports its FULL-resolution bbox" do
        doc = Lbrn2.parse_document(fixture("laser-settings.lbrn2"))
        full = []
        Lbrn2.each_geometry(doc) do |_c, points, *|
          next if points.length < 2

          xs = points.map(&:first); ys = points.map(&:last)
          full << { n: points.length, bbox: [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) } }
        end

        decimated = build("laser-settings.lbrn2")["shapes"].zip(full)
                                                             .find { |_s, f| f[:n] > LbrnGeometry::DECIMATE_ABOVE }
        assert decimated, "the fixture's ellipse should exceed the decimation threshold"
        s, f = decimated
        assert_equal f[:bbox], s["b"]
      end

      # THE COUPLING THAT MAKES DECIMATION SAFE FOR CURVES, and it spans two files.
      # Lbrn2 flattens each cubic into BEZIER_SAMPLES points, so an original LightBurn vertex lands
      # on every BEZIER_SAMPLES-th index. Keeping every DECIMATE_STRIDE-th point therefore preserves
      # EVERY original vertex exactly when the stride divides the sample count — only intermediate
      # curve samples are dropped. Change either constant so this stops holding and contour bboxes
      # begin to move under decimation, silently, with the drawing losing corners rather than detail.
      test "the decimation stride divides the bezier sample count, so no original vertex is dropped" do
        assert_equal 0, Maker::Previews::Lbrn2::BEZIER_SAMPLES % LbrnGeometry::DECIMATE_STRIDE

        doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
        Lbrn2.each_geometry(doc) do |_c, points, *|
          next unless points.length > LbrnGeometry::DECIMATE_ABOVE

          kept = LbrnGeometry.decimate(points)
          vertices = (0...points.length).step(Maker::Previews::Lbrn2::BEZIER_SAMPLES).map { |i| points[i] }
          assert vertices.all? { |v| kept.include?(v) },
                 "every original vertex must survive decimation, not merely the bbox"
        end
      end

      # Paired positionally, same reasoning as the two decimation tests above.
      test "a contour above the threshold is actually thinned, and a small one is left alone" do
        doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
        counts = []
        Lbrn2.each_geometry(doc) do |_c, points, *|
          next if points.length < 2

          counts << points.length
        end

        pairs = build("bezier-circle.lbrn2")["shapes"].zip(counts)
        big = pairs.find { |_s, n| n > Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }
        small = pairs.find { |_s, n| n <= Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }

        assert big,   "the bezier circle should exceed the threshold"
        assert small, "the 5-point square should not"
        assert_operator big[0]["p"].length, :<, big[1], "a big contour must be thinned"
        assert_equal small[1], small[0]["p"].length,    "a small contour must be untouched"
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

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def build(name) = JSON.parse(LbrnGeometry.render(fixture(name))[:bytes])
    end
  end
end
