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
          next if expected.nil?

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
        assert job.key?("x") && job.key?("y"), "the client needs an origin for its viewBox"
      end

      test "render returns JSON bytes the job can attach" do
        result = LbrnGeometry.render(fixture("real-export.lbrn2"))

        assert_equal "application/json", result[:content_type]
        assert result[:bytes].bytesize.positive?
        assert_equal 4, JSON.parse(result[:bytes])["shapes"].length
      end

      test "decimation thins big contours but never moves a reported bbox" do
        doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
        full = {}
        Lbrn2.each_geometry(doc) do |_c, points, _k, _e, _i, oid|
          xs = points.map(&:first); ys = points.map(&:last)
          full[oid] = [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) }
        end

        build("bezier-circle.lbrn2")["shapes"].each do |s|
          assert_equal full[s["o"]], s["b"], "the reported bbox must equal the FULL-resolution bbox"

          s["p"].each do |(x, y)|
            assert_operator x, :>=, s["b"][0] - 0.01
            assert_operator y, :>=, s["b"][1] - 0.01
            assert_operator x, :<=, s["b"][2] + 0.01
            assert_operator y, :<=, s["b"][3] + 0.01
          end
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
      test "a decimated ellipse still reports its FULL-resolution bbox" do
        doc = Lbrn2.parse_document(fixture("laser-settings.lbrn2"))
        counts = {}
        full = {}
        Lbrn2.each_geometry(doc) do |_c, points, _k, _e, _i, oid|
          counts[oid] = points.length
          xs = points.map(&:first); ys = points.map(&:last)
          full[oid] = [ xs.min, ys.min, xs.max, ys.max ].map { |v| v.round(2) }
        end

        decimated = build("laser-settings.lbrn2")["shapes"].find { |s| counts[s["o"]] > LbrnGeometry::DECIMATE_ABOVE }
        assert decimated, "the fixture's ellipse should exceed the decimation threshold"
        assert_equal full[decimated["o"]], decimated["b"]
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

      test "a contour above the threshold is actually thinned, and a small one is left alone" do
        shapes = build("bezier-circle.lbrn2")["shapes"]
        doc = Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
        counts = {}
        Lbrn2.each_geometry(doc) { |_c, points, _k, _e, _i, oid| counts[oid] = points.length }

        big = shapes.find { |s| counts[s["o"]] > Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }
        small = shapes.find { |s| counts[s["o"]] <= Maker::Previews::LbrnGeometry::DECIMATE_ABOVE }

        assert big,   "the bezier circle should exceed the threshold"
        assert small, "the 5-point square should not"
        assert_operator big["p"].length, :<, counts[big["o"]], "a big contour must be thinned"
        assert_equal counts[small["o"]], small["p"].length,    "a small contour must be untouched"
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
      # (the same value the point-count-floor test above already uses) this shape's "d" flips
      # from nil to 19.0 — verified by hand — which is what makes this assertion, unlike the
      # others, actually exercise the tolerance comparison rather than never reaching it.
      test "an ellipse just outside the tolerance reports no diameter" do
        xml = %(<LightBurnProject AppVersion="1.6.00">) +
              %(<Shape Type="Ellipse" CutIndex="0" Rx="10" Ry="9"><XForm>1 0 0 1 0 0</XForm></Shape>) +
              %(</LightBurnProject>)
        shapes = JSON.parse(LbrnGeometry.render(xml)[:bytes])["shapes"]

        assert_equal 1, shapes.length
        assert_nil shapes.first["d"], "a 10x9 ellipse is ~5.5% off-round — outside the shipped 2% tolerance"
      end

      private

      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      def build(name) = JSON.parse(LbrnGeometry.render(fixture(name))[:bytes])
    end
  end
end
