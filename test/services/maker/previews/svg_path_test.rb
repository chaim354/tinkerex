require "test_helper"

module Maker
  module Previews
    # `d` is the densest part of SVG and the part most likely to be wrong in a way nothing else
    # notices — a mis-parsed path still draws SOMETHING. Tested on string literals rather than
    # only through a rendered document, which is why SvgPath is a module of its own.
    class SvgPathTest < ActiveSupport::TestCase
      TOL = 0.005

      test "a straight subpath keeps its vertices" do
        assert_equal [ [ [ [ 0.0, 0.0 ], [ 10.0, 0.0 ], [ 10.0, 5.0 ] ], false, nil ] ],
                     SvgPath.parse("M 0 0 L 10 0 L 10 5", TOL)
      end

      # Z REPEATS THE SUBPATH START AS THE LAST POINT, matching what Lbrn2 and Dxf yield.
      # `Geometry.simplify` always keeps first and last, so a closed contour still closes.
      test "Z closes the subpath and repeats its start" do
        points, closed = SvgPath.parse("M 0 0 L 10 0 L 10 10 Z", TOL).first

        assert closed
        assert_equal [ 0.0, 0.0 ], points.last
      end

      # ONE `d` ROUTINELY HOLDS SEVERAL SUBPATHS — a plate with a hole, a letter with a counter.
      # Collapsing them into one contour draws a line joining shapes that are not joined and
      # measures a bbox spanning both.
      test "each subpath becomes its own contour" do
        result = SvgPath.parse("M 0 0 L 5 0 Z M 20 20 L 25 20 Z", TOL)

        assert_equal 2, result.length
        assert_equal [ 0.0, 0.0 ], result[0].first.first
        assert_equal [ 20.0, 20.0 ], result[1].first.first
      end

      # THE TRAP. `M 0 0 10 0 10 10` is a moveto followed by two LINETOS, not three movetos.
      # Read as movetos it yields three empty subpaths and draws nothing at all.
      test "a repeated moveto argument set continues as a lineto" do
        result = SvgPath.parse("M 0 0 10 0 10 10", TOL)

        assert_equal 1, result.length, "extra M argument sets are linetos, not new subpaths"
        assert_equal [ [ 0.0, 0.0 ], [ 10.0, 0.0 ], [ 10.0, 10.0 ] ], result.first.first
      end

      test "a repeated relative moveto continues as a relative lineto" do
        result = SvgPath.parse("m 0 0 10 0 0 10", TOL)

        assert_equal 1, result.length
        assert_equal [ [ 0.0, 0.0 ], [ 10.0, 0.0 ], [ 10.0, 10.0 ] ], result.first.first
      end

      # RELATIVE CONTROL POINTS ARE ALL RELATIVE TO THE CURVE'S START, not chained to each other.
      # Chaining bends every relative curve — and it still draws a curve, so only a coordinate
      # assertion catches it. The endpoint is what pins it: chained, this lands at (30, 0).
      test "relative curve arguments are all relative to the current point" do
        points = SvgPath.parse("M 0 0 c 5 -5 15 -5 20 0", TOL).first.first

        assert_in_delta 20.0, points.last[0], 1e-9, "the endpoint is start + the LAST pair, not a running sum"
        assert_in_delta 0.0, points.last[1], 1e-9
      end

      # H and V take ONE number and keep the other coordinate. Swapping them draws a shape that
      # is still a shape.
      test "H and V move only their own axis" do
        points = SvgPath.parse("M 3 7 H 10 V 20", TOL).first.first

        assert_equal [ [ 3.0, 7.0 ], [ 10.0, 7.0 ], [ 10.0, 20.0 ] ], points
      end

      # S reflects the PREVIOUS curve's second control point about the current point. With the
      # reflection dropped (control == current point) this curve's midpoint moves measurably.
      test "S reflects the previous control point rather than reusing it" do
        reflected = SvgPath.parse("M 0 0 C 0 -10 10 -10 10 0 S 20 10 20 0", TOL).first.first
        # The second segment must bulge DOWNWARD (positive y here), mirroring the first's upward
        # bulge. Without reflection it stays flat against the chord.
        second_half = reflected.select { |(x, _y)| x > 10.0 }

        assert second_half.any? { |(_x, y)| y > 1.0 },
               "the reflected control point must bend the second segment the opposite way"
      end

      # A 180-degree arc across a 20-wide chord is a semicircle of radius 10: its extreme must
      # reach 10 from the chord. A sign or flag error here still produces a smooth curve, so the
      # DIRECTION is the assertion that carries the weight.
      #
      # WHICH WAY IS WHICH COMES FROM THE SPEC, NOT FROM THIS IMPLEMENTATION — the first draft of
      # this test asserted the opposite and was wrong. SVG 1.1 F.6.3: with sweep-flag 1 the angle
      # INCREASES from the start angle. Here the start point (0,0) sits at θ=π about the centre
      # (10,0), so sweep 1 runs π→2π and passes θ=3π/2 where y = cy + ry·sin(θ) = -10, while
      # sweep 0 runs π→0 through θ=π/2 where y = +10. SVG's y axis points DOWN, so sweep 1 is the
      # one that bulges upward on screen.
      test "an elliptical arc sweeps the side its flags name" do
        sweep0 = SvgPath.parse("M 0 0 A 10 10 0 0 0 20 0", TOL).first.first
        sweep1 = SvgPath.parse("M 0 0 A 10 10 0 0 1 20 0", TOL).first.first

        assert_in_delta 10.0, sweep0.map(&:last).max, 0.05, "sweep 0 decreases theta: y reaches +10"
        assert_in_delta 0.0, sweep0.map(&:last).min, 0.05, "sweep 0 must not cross to the other side"
        assert_in_delta(-10.0, sweep1.map(&:last).min, 0.05, "sweep 1 increases theta: y reaches -10")
        assert_in_delta 0.0, sweep1.map(&:last).max, 0.05
      end

      # F.6.6.2: radii too small to span the endpoints are scaled UP until they exactly do.
      # Without it the centre calculation takes the square root of a negative number.
      test "radii too small for the chord are grown rather than failing" do
        points = SvgPath.parse("M 0 0 A 1 1 0 0 0 20 0", TOL).first.first

        assert_equal [ 20.0, 0.0 ], points.last.map { |v| v.round(6) }
        # r=1 cannot span a 20-wide chord, so it grows to exactly 10 and the arc becomes a
        # semicircle — reaching 10 from the chord, on the sweep-0 side (see the test above).
        assert_in_delta 10.0, points.map(&:last).max, 0.1, "the grown radius is half the chord"
      end

      test "a zero radius degenerates to a line rather than dividing by zero" do
        points = SvgPath.parse("M 0 0 A 0 0 0 0 0 20 0", TOL).first.first

        assert_equal [ [ 0.0, 0.0 ], [ 20.0, 0.0 ] ], points
      end

      # CURVE FLATTENING IS BOUNDED BY THE TOLERANCE IT IS GIVEN, and a LOOSER tolerance must
      # produce FEWER points. Without that the parameter is decorative — which is exactly what a
      # fixed sample count would be, and a fixed count undersamples a large curve so its bbox and
      # diameter both read small, silently.
      test "flattening is bounded by the tolerance, not by a fixed sample count" do
        fine = SvgPath.parse("M 0 0 C 0 -50 100 -50 100 0", 0.005).first.first
        coarse = SvgPath.parse("M 0 0 C 0 -50 100 -50 100 0", 5.0).first.first

        assert_operator fine.length, :>, coarse.length,
                        "a tighter tolerance must subdivide further"
        assert_operator max_chord_error(fine), :<=, 0.005 * 4,
                        "the flattened line must stay near the true curve"
      end

      # A big curve needs MORE segments than a small one at the same absolute tolerance. This is
      # the property a fixed sample count cannot have, and it is why measuring a large arc is
      # correct rather than merely smooth-looking.
      test "a larger curve is subdivided more finely than a small one" do
        small = SvgPath.parse("M 0 0 C 0 -1 2 -1 2 0", TOL).first.first
        large = SvgPath.parse("M 0 0 C 0 -100 200 -100 200 0", TOL).first.first

        assert_operator large.length, :>, small.length
      end

      test "numbers may run together without separators" do
        points = SvgPath.parse("M0 0L1.5.5L-.5-.5", TOL).first.first

        assert_equal [ [ 0.0, 0.0 ], [ 1.5, 0.5 ], [ -0.5, -0.5 ] ], points
      end

      test "exponent notation parses as one number" do
        points = SvgPath.parse("M 0 0 L 1e2 -1.5E1", TOL).first.first

        assert_equal [ [ 0.0, 0.0 ], [ 100.0, -15.0 ] ], points
      end

      test "a trailing partial argument set is dropped rather than read past the end" do
        points = SvgPath.parse("M 0 0 L 10 10 L 5", TOL).first.first

        assert_equal [ [ 0.0, 0.0 ], [ 10.0, 10.0 ] ], points
      end

      test "path data that starts with a number is refused rather than anchored at the origin" do
        assert_raises(SvgPath::ParseError) { SvgPath.parse("10 10 L 20 20", TOL) }
      end

      test "empty data yields no contours" do
        assert_equal [], SvgPath.parse("", TOL)
        assert_equal [], SvgPath.parse(nil, TOL)
      end

      # After Z the pen sits at the subpath START, so a following drawing command begins a new
      # subpath THERE. Losing that anchors it at the origin instead.
      test "a command after Z resumes from the subpath start" do
        result = SvgPath.parse("M 5 5 L 10 5 Z L 10 10", TOL)

        assert_equal 2, result.length
        assert_equal [ 5.0, 5.0 ], result[1].first.first
      end

      # ---- the cubic segment list (tinkerex#217) --------------------------------------------

      # ONE SEGMENT LIST PER SUBPATH, BESIDE THE POINTS, and it is `nil` where nothing curves.
      # A run of `L` ops is already described EXACTLY by the points — thinning only drops points
      # within SIMPLIFY_TOLERANCE of the line the browser draws — so a path there would restate
      # the same geometry in a second encoding and be paid for on every contour of every file.
      # The form exists for what has no exact form already. `Lbrn2.curved_segments` makes the same
      # decision for the LightBurn leg, for the same reason.
      test "a straight-only subpath carries no segment list at all" do
        [ "M 0 0 L 10 0 L 10 5", "M 0 0 H 10 V 5 Z", "M 0 0 A 0 0 0 0 0 20 0" ].each do |d|
          assert_nil SvgPath.parse(d, TOL).first[2], "#{d}: nothing in it curves"
        end
      end

      # C IS THE CUBIC THE FILE WROTE, CARRIED THROUGH RATHER THAN REBUILT. 116,244 of them across
      # the live SVG corpus — the single commonest curve command there is.
      #
      # THE ASSERTION RESOLVES THE SEGMENTS RATHER THAN READING THEM, which is the only form of
      # this that carries weight: tinkerex#213's arc descriptor passed its own five-number equality
      # test while drawing 1.37 mm from the shape's own points, because the numbers were never what
      # was wrong. Evaluating the cubics and comparing against the FLATTENED POINTS asks the
      # question the payload actually depends on — those points are what `b`, `d` and the job box
      # are measured from.
      test "C is carried through as the cubic it already is" do
        points, _closed, segments = SvgPath.parse("M 0 0 C 0 -10 10 -10 10 0", TOL).first

        assert_equal [ [ :M, 0.0, 0.0 ], [ :C, 0.0, -10.0, 10.0, -10.0, 10.0, 0.0 ] ], segments
        assert_tracks points, segments, "a single cubic"
      end

      # RELATIVE PAIRS ARE ALL RELATIVE TO THE SAME CURRENT POINT, not chained to each other —
      # `pairs`' own comment says so, and the segments must inherit that rather than re-deriving
      # it. Chained, the endpoint lands at (30, 0) and the segment describes a different curve
      # from the points beside it.
      test "a relative cubic's segment is absolute and unchained" do
        points, _closed, segments = SvgPath.parse("M 0 0 c 5 -5 15 -5 20 0", TOL).first

        assert_equal [ [ :M, 0.0, 0.0 ], [ :C, 5.0, -5.0, 15.0, -5.0, 20.0, 0.0 ] ], segments
        assert_tracks points, segments, "a relative cubic"
      end

      # S REFLECTS THE PREVIOUS CONTROL POINT, and the segment must carry the SAME reflection the
      # points were flattened from. An implementation that reflects for the points and reuses the
      # raw control point for the segment draws a perfectly smooth curve that is not the file's —
      # this repo's recorded failure shape, and invisible to any assertion about the string.
      # 8,011 `S` commands across the live SVG corpus.
      test "S reflects into the segment as well as into the points" do
        points, _closed, segments =
          SvgPath.parse("M 0 0 C 0 -10 10 -10 10 0 S 20 10 20 0", TOL).first

        # The reflection of (10,-10) about the current point (10,0) is (10,10).
        assert_equal [ :C, 10.0, 10.0, 20.0, 10.0, 20.0, 0.0 ], segments.last
        assert_tracks points, segments, "a smooth cubic"
      end

      # Q CONVERTS TO A CUBIC EXACTLY — degree elevation, not a fit: c1 = p0 + ⅔(c − p0) and
      # c2 = p + ⅔(c − p). That exactness is what lets the wire form be cubics-only without
      # approximating anything, so it is asserted BY VALUE as well as by geometry: a curve merely
      # CLOSE to the right one would pass the tracking assertion at a looser tolerance, and the
      # claim being made here is equality.
      test "Q becomes a cubic by exact degree elevation" do
        points, _closed, segments = SvgPath.parse("M 0 0 Q 10 -20 20 0", TOL).first

        _, c1x, c1y, c2x, c2y, x, y = segments.last
        assert_in_delta 20.0 / 3, c1x, 1e-12
        assert_in_delta(-40.0 / 3, c1y, 1e-12)
        assert_in_delta 40.0 / 3, c2x, 1e-12
        assert_in_delta(-40.0 / 3, c2y, 1e-12)
        assert_equal [ 20.0, 0.0 ], [ x, y ]
        assert_tracks points, segments, "a quadratic"
      end

      # THE CONVERSION TO WATCH FOR IS THE NAIVE ONE — using the quadratic's own control point for
      # BOTH cubic controls. It draws a curve of the right family through the right endpoints, so
      # it looks correct; on this curve it misses by a third of the bulge. Stated as an
      # arithmetic fact rather than as a mutation, because it is a property of the formula.
      test "the naive quadratic conversion would miss by a third of the bulge" do
        points = SvgPath.parse("M 0 0 Q 10 -20 20 0", TOL).first.first
        naive = [ [ :M, 0.0, 0.0 ], [ :C, 10.0, -20.0, 10.0, -20.0, 20.0, 0.0 ] ]

        assert_operator deviation(points, resolve(naive)), :>, 4.0,
                        "c1 = c2 = c is not degree elevation, and this is how far off it is"
      end

      # T REFLECTS THE PREVIOUS QUADRATIC's control point, and it must be the QUADRATIC one — the
      # cubic controls the conversion just produced are a different pair, and reflecting those
      # bends the second half the wrong amount. Only 2 `T` commands in the live corpus, which is
      # exactly why it needs a test: nothing real would report it.
      test "T reflects the quadratic control point and converts the same way" do
        points, _closed, segments = SvgPath.parse("M 0 0 Q 10 -20 20 0 T 40 0", TOL).first

        assert_equal 3, segments.length, "M and two cubics"
        assert_tracks points, segments, "a smooth quadratic"
        assert_operator resolve(segments).map(&:last).max, :>, 5.0,
                        "the reflected control must bend the second half the opposite way"
      end

      # AN ARC BECOMES CUBICS, WHICH IS A FEATURE RATHER THAN A CONCESSION: an SVG arc under a
      # non-uniform scale is a different ellipse arc needing a rotation term no primitive wire
      # form carries, and cubics transform affinely under ANY matrix. 859 `A` commands live.
      #
      # THE SEGMENT LIST HOLDS NO `A` — `resolve` raises on any command outside M/L/C/Z, which is
      # what makes "emit the raw arc" a RED rather than a silently-different picture.
      test "A becomes cubics that track the arc it names" do
        %w[0 1].each do |sweep|
          points, _closed, segments = SvgPath.parse("M 0 0 A 10 10 0 0 #{sweep} 20 0", TOL).first

          assert_equal [ :M ] + ([ :C ] * (segments.length - 1)), segments.map(&:first)
          assert_operator segments.length - 1, :<=, 4, "a semicircle needs no more than four cubics"
          assert_tracks points, segments, "a semicircle, sweep #{sweep}"
        end
      end

      # AND THE ARC'S CUBIC COUNT IS BOUNDED BY GEOMETRIC ERROR, NOT BY A COUNT — the rule
      # `docs/invariants/measure-view.md` already states for flattening, one encoding further out.
      # The tangent-based approximation's radial error is r·(2/27)·sin⁶(θ/4)/cos²(θ/4), which is
      # 2.7e-4·r at θ = π/2: 0.054 mm at r = 200, an order of magnitude WORSE than the points it
      # rides beside. A descriptor less faithful than the polyline it replaces is exactly the
      # defect tinkerex#213 shipped, so the split count grows with the radius.
      test "a large arc is split into more cubics than a small one at the same tolerance" do
        small = SvgPath.parse("M 0 0 A 5 5 0 1 1 0 0.001", TOL).first[2]
        large = SvgPath.parse("M 0 0 A 500 500 0 1 1 0 0.001", TOL).first[2]

        assert_operator large.length, :>, small.length,
                        "a fixed cubic count undersamples a large arc, silently"
      end

      # H AND V ARE LINES INSIDE A CURVED CONTOUR, AND THEY MUST SURVIVE AS LINES. A path is
      # CONTINUOUS: the `L`s are how the `C`s are reached, so a mixed contour keeps all of its
      # segments even though a straight-only one keeps none. Dropping them would join the cubics
      # to each other and draw a shape the file does not contain.
      test "H and V become L segments inside a contour that curves" do
        points, _closed, segments =
          SvgPath.parse("M 3 7 H 13 C 20 7 20 17 13 17 V 27", TOL).first

        assert_equal [ :M, :L, :C, :L ], segments.map(&:first)
        assert_equal [ :L, 13.0, 7.0 ], segments[1], "H keeps the current y"
        assert_equal [ :L, 13.0, 27.0 ], segments[3], "V keeps the current x"
        assert_tracks points, segments, "a mixed contour"
      end

      # `Z` RATHER THAN A REPEATED ENDPOINT. The final segment already lands on the start point,
      # so this adds no geometry; what it adds is a CLOSED SUBPATH, which is what makes the drawn
      # <path> fillable and therefore hit-testable the way the <polygon> it replaces was.
      test "Z closes the segment list" do
        points, closed, segments =
          SvgPath.parse("M 0 0 C 0 -10 10 -10 10 0 C 10 10 0 10 0 0 Z", TOL).first

        assert closed
        assert_equal [ :Z ], segments.last
        assert_tracks points, segments, "a closed curve"
      end

      # ONE SEGMENT LIST PER SUBPATH, never one per `d`. A single `d` routinely holds several — a
      # plate with holes, a letter with a counter — and each reaches `Collector#add` as its own
      # entry with its own bbox, so one list covering both would describe geometry the entry it
      # rides on does not contain.
      test "each subpath gets its own segment list" do
        result = SvgPath.parse("M 0 0 C 0 -5 5 -5 5 0 Z M 20 20 C 20 15 25 15 25 20 Z", TOL)

        assert_equal 2, result.length
        assert_equal [ [ :M, 0.0, 0.0 ], [ :C, 0.0, -5.0, 5.0, -5.0, 5.0, 0.0 ], [ :Z ] ], result[0][2]
        assert_equal [ 20.0, 20.0 ], result[1][2].first[1..]
      end

      # A PATH MAY BEGIN WITH A DRAWING COMMAND AND NO MOVETO — a renderer treats the current
      # point (0,0) as the start, and the segment list has to open with an `M` there too. A list
      # whose first command is a `C` is not a path, and `resolve` below raises rather than
      # inventing a start point for it.
      test "a curve with no preceding moveto still opens with an M" do
        points, _closed, segments = SvgPath.parse("C 0 -10 10 -10 10 0", TOL).first

        assert_equal [ :M, 0.0, 0.0 ], segments.first
        assert_tracks points, segments, "an implicit start"
      end

      private

      # The largest distance from any flattened point to the chord of its neighbours — a proxy for
      # how far the drawn line sits from the curve it approximates.
      def max_chord_error(points)
        return 0.0 if points.length < 3

        points.each_cons(3).map { |a, b, c| Geometry.point_segment_distance(b, a, c) }.max
      end

      # THE SEGMENTS RESOLVED THE WAY A RENDERER RESOLVES THEM. STRICT ON PURPOSE: an unknown
      # command RAISES. The wire form is absolute M/L/C/Z and nothing else, and a lenient resolver
      # that skipped an `A` would let a producer start emitting one while every assertion here
      # stayed green — which is exactly how a client that does not understand the command fails,
      # silently.
      def resolve(segments, per_curve: 64)
        pts = []
        cur = start = nil
        segments.each do |(cmd, *nums)|
          case cmd
          when :M, :L
            cur = nums[0, 2]
            start ||= cur
            pts << cur
          when :C
            c1 = nums[0, 2]; c2 = nums[2, 2]; p3 = nums[4, 2]
            (1..per_curve).each { |k| pts << cubic_at(cur, c1, c2, p3, k.to_f / per_curve) }
            cur = p3
          when :Z then pts << (cur = start)
          else raise "unexpected segment #{cmd.inspect} — the wire form is absolute M/L/C/Z only"
          end
        end
        pts
      end

      def cubic_at(p0, c1, c2, p3, t)
        u = 1.0 - t
        [ 0, 1 ].map do |a|
          (u * u * u * p0[a]) + (3 * u * u * t * c1[a]) + (3 * u * t * t * c2[a]) + (t * t * t * p3[a])
        end
      end

      # THE QUESTION THE PAYLOAD ACTUALLY DEPENDS ON, asked BOTH WAYS. One direction alone is
      # satisfied by a curve that covers only part of the contour (every resolved point sits on
      # the polyline, and half the polyline has nothing near it) or by one that wanders past its
      # end; a segment list that is wrong in either direction draws a shape the file does not have.
      #
      # 0.02 user units is where the two roundings land, stated rather than tuned: the points are
      # flattened to within TOL (0.005) of the true curve, and an `A`'s cubics are fitted to the
      # same bound — so 4x TOL leaves headroom against a mutation that misses by whole units.
      def assert_tracks(points, segments, label, tol: 0.02)
        curve = resolve(segments)

        assert_operator deviation(points, curve), :<=, tol,
                        "#{label}: a flattened point sits off the resolved curve"
        assert_operator deviation(curve, points), :<=, tol,
                        "#{label}: the resolved curve strays off the flattened contour"
      end

      # The largest distance from any point of `from` to the polyline `to`. Point-to-SEGMENT, not
      # point-to-point: two samplings of one curve do not share sample positions.
      def deviation(from, to)
        from.map { |p| to.each_cons(2).map { |a, b| Geometry.point_segment_distance(p, a, b) }.min || 0.0 }.max
      end
    end
  end
end
