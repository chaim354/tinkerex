require "test_helper"

module Maker
  module Previews
    # `d` is the densest part of SVG and the part most likely to be wrong in a way nothing else
    # notices — a mis-parsed path still draws SOMETHING. Tested on string literals rather than
    # only through a rendered document, which is why SvgPath is a module of its own.
    class SvgPathTest < ActiveSupport::TestCase
      TOL = 0.005

      test "a straight subpath keeps its vertices" do
        assert_equal [ [ [ [ 0.0, 0.0 ], [ 10.0, 0.0 ], [ 10.0, 5.0 ] ], false ] ],
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

      private

      # The largest distance from any flattened point to the chord of its neighbours — a proxy for
      # how far the drawn line sits from the curve it approximates.
      def max_chord_error(points)
        return 0.0 if points.length < 3

        points.each_cons(3).map { |a, b, c| Geometry.point_segment_distance(b, a, c) }.max
      end
    end
  end
end
