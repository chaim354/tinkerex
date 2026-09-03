require "strscan"

module Maker
  module Previews
    # SVG path data (`d="M 0 0 L 10 0 ..."`) → flattened polylines in the path's own user units.
    #
    # SEPARATED FROM `SvgGeometry` BECAUSE IT IS THE HALF THAT IS PURE ARITHMETIC — no document, no
    # transforms, no units, no colours. `d` is the densest part of the format and the part most
    # likely to be wrong in a way nothing else notices, so it is testable on its own with string
    # literals rather than only through a rendered file.
    #
    # RETURNS ONE CONTOUR PER SUBPATH, each `[points, closed, segments_or_nil]`. A single `d`
    # routinely holds several — a letter with a counter, a plate with holes — and collapsing them
    # into one contour would draw a line joining shapes that are not joined, and measure a bbox
    # spanning both.
    #
    # THE THIRD ELEMENT IS THE SUBPATH'S OWN CUBIC SEGMENT LIST, and it is why this module stopped
    # throwing its control points away. Every curve command here already resolves to ABSOLUTE
    # coordinates before it is flattened, so the normalisation work was done and the handles were
    # dropped one line later: 116,244 `C`, 8,011 `S`, 1,459 `Q`, 859 `A` and 2 `T` across the live
    # corpus, every one of them reaching the client as a run of short chords.
    #
    # `[[:M, x, y], [:L, x, y], [:C, c1x, c1y, c2x, c2y, x, y], [:Z]]` AND NOTHING ELSE — the
    # alphabet `Geometry.path_curve` encodes. Every input reduces to it: `C` already is a cubic,
    # `S` and `T` reflect the previous control point into one, `Q` converts EXACTLY by degree
    # elevation, and an `A` becomes a bounded number of cubics. One segment kind is what makes an
    # affine placement a transform of control points and nothing else.
    #
    # nil WHERE NOTHING IN THE SUBPATH CURVES — see `curved`.
    module SvgPath
      module_function

      ParseError = Class.new(StandardError)

      # An SVG number: optional sign, digits with optional fraction, optional exponent.
      #
      # `.5` AND `1.` ARE BOTH LEGAL, and so is `1.5.5` meaning TWO numbers (1.5 and .5) — path
      # data separates numbers by position, not only by delimiter, so a regex that demands a
      # separator silently mis-parses real files from real tools. Matching greedily per number and
      # letting the scanner continue from where each match ends handles all three.
      NUMBER = /[+-]?(?:\d*\.\d+|\d+\.?)(?:[eE][+-]?\d+)?/
      COMMAND = /[MmZzLlHhVvCcSsQqTtAa]/

      # How many arguments each command consumes per repetition. A command may be followed by
      # several argument sets — `L 1 2 3 4` is two linetos — which is why this is a count rather
      # than a fixed parse.
      ARITY = {
        "M" => 2, "L" => 2, "T" => 2, "H" => 1, "V" => 1,
        "C" => 6, "S" => 4, "Q" => 4, "A" => 7, "Z" => 0
      }.freeze

      # Deepest adaptive subdivision of one curve segment. 2^16 segments is far past any real
      # curve's need; the bound exists so a degenerate control polygon cannot recurse forever.
      MAX_DEPTH = 16

      # Parse `d` into [[points, closed, segments_or_nil], ...].
      #
      # `tolerance` is the flatness bound for curve subdivision, IN THE PATH'S OWN USER UNITS. The
      # caller converts from millimetres because only it knows the scale — see `SvgGeometry`.
      def parse(data, tolerance)
        tokens = lex(data.to_s)
        return [] if tokens.empty?

        state = State.new(tolerance)
        each_command(tokens) { |cmd, args| state.apply(cmd, args) }
        state.finish
      end

      # [["M", [0.0, 0.0]], ...] — commands paired with the argument sets they were given.
      def lex(data)
        out = []
        scanner = StringScanner.new(data)
        until scanner.eos?
          scanner.skip(/[\s,]+/)
          break if scanner.eos?

          if (cmd = scanner.scan(COMMAND))
            out << [ cmd, [] ]
          elsif (num = scanner.scan(NUMBER))
            # A number before any command is malformed data, not a shape. Dropping it keeps a
            # broken `d` from silently anchoring the whole subpath at the origin.
            raise ParseError, "path data starts with a number" if out.empty?

            out.last.last << num.to_f
          else
            # An unknown byte cannot be resolved into a position, and guessing would place
            # geometry somewhere the file does not put it. Skip the byte and keep going: a real
            # file with one stray character should still measure.
            scanner.getch
          end
        end
        out
      end

      # Split each command's flat argument list into ARITY-sized sets, yielding one per set.
      #
      # A REPEATED `M` BECOMES `L`, and this is the rule most often missed. `M 0 0 10 0 10 10` is a
      # moveto followed by two LINETOS, not three movetos — read as movetos it produces three
      # empty subpaths and draws nothing at all. Lowercase `m` likewise continues as `l`.
      def each_command(tokens)
        tokens.each do |cmd, args|
          arity = ARITY.fetch(cmd.upcase, 0)
          if arity.zero?
            yield cmd, []
            next
          end

          sets = args.each_slice(arity).to_a
          # A trailing partial set is malformed; drop it rather than reading past the end.
          sets.pop if sets.last && sets.last.length < arity
          sets.each_with_index do |set, i|
            effective = if i.positive? && cmd == "M" then "L"
            elsif i.positive? && cmd == "m" then "l"
            else cmd
            end
            yield effective, set
          end
        end
      end

      # The pen: current point, subpath start, last control point (for the S/T shorthands), the
      # subpath's flattened points AND its cubic segments, and the subpaths closed so far.
      #
      # THE SEGMENTS ARE ACCUMULATED BESIDE THE POINTS, IN THE SAME METHODS, ON PURPOSE. Every
      # command below already holds the absolute control points it is about to sample from; a
      # second pass reconstructing them from `d` would be a second parser free to disagree with
      # this one about what the file says — §14b's `LbrnMetadata` bug, in the densest part of the
      # format. Written side by side, dropping one of the two is visible in the diff.
      class State
        def initialize(tolerance)
          @tolerance = tolerance
          @subpaths = []
          @current = nil
          @segments = nil
          @start = nil
          @x = @y = 0.0
          @last_control = nil
        end

        def finish
          flush
          @subpaths
        end

        def apply(cmd, args)
          rel = cmd == cmd.downcase
          case cmd.upcase
          when "M" then move_to(*resolve(args, rel))
          when "L" then line_to(*resolve(args, rel))
          when "H" then line_to(rel ? @x + args[0] : args[0], @y)
          when "V" then line_to(@x, rel ? @y + args[0] : args[0])
          when "C" then cubic(*pairs(args, rel))
          when "S" then smooth_cubic(*pairs(args, rel))
          when "Q" then quadratic(*pairs(args, rel))
          when "T" then smooth_quadratic(*resolve(args, rel))
          when "A" then arc(args, rel)
          when "Z" then close
          end
          @last_control = nil unless %w[C S Q T].include?(cmd.upcase)
        end

        private

        # Absolute [x, y] for one coordinate pair.
        def resolve(args, rel)
          rel ? [ @x + args[0], @y + args[1] ] : [ args[0], args[1] ]
        end

        # Absolute [[x, y], ...] for a run of coordinate pairs. RELATIVE PAIRS ARE ALL RELATIVE TO
        # THE SAME CURRENT POINT, not chained to each other — `c` offsets both control points and
        # the endpoint from where the curve STARTS. Chaining them bends every relative curve.
        def pairs(args, rel)
          args.each_slice(2).map { |(dx, dy)| rel ? [ @x + dx, @y + dy ] : [ dx, dy ] }
        end

        # THE SUBPATH THE PEN DRAWS INTO, opened lazily. A path may begin with a drawing command
        # and no moveto: treating the current point (0,0) as the start is what a renderer does,
        # and refusing would drop the whole subpath. The DESCRIPTOR's own `M` is minted here in
        # the same breath — a segment list whose first command is a `C` is not a path, and the
        # three commands that can open a subpath implicitly would otherwise each have to remember
        # to mint one.
        def ensure_subpath
          @current ||= [ [ @x, @y ] ]
          @start ||= [ @x, @y ]
          @segments ||= [ [ :M, @x, @y ] ]
        end

        def move_to(x, y)
          flush
          @current = [ [ x, y ] ]
          @start = [ x, y ]
          @segments = [ [ :M, x, y ] ]
          @x = x
          @y = y
        end

        def line_to(x, y)
          ensure_subpath
          @current << [ x, y ]
          # A STRAIGHT SEGMENT IS KEPT EVEN THOUGH A STRAIGHT-ONLY SUBPATH IS DROPPED WHOLE. A path
          # is CONTINUOUS: these are how the cubics are reached, so a MIXED contour keeps all of
          # them. `curved` decides the whole-subpath question, once, at the end.
          @segments << [ :L, x, y ]
          @x = x
          @y = y
        end

        def cubic(c1, c2, to)
          ensure_subpath
          SvgPath.flatten_cubic([ @x, @y ], c1, c2, to, @tolerance, @current)
          # THE SAME FOUR POINTS `flatten_cubic` SAMPLES, unsampled, and already absolute — `pairs`
          # resolved them, so this inherits its rule that relative pairs are all relative to the
          # SAME current point rather than chained to each other. A control point that misses that
          # still yields a perfectly well-formed curve; it is simply not the file's, which is this
          # repo's recorded failure shape.
          @segments << [ :C, c1[0], c1[1], c2[0], c2[1], to[0], to[1] ]
          @last_control = c2
          @x, @y = to
        end

        # S: the first control point is the REFLECTION of the previous curve's second control
        # point about the current point. With no previous curve it coincides with the current
        # point — per spec, and the difference is visible on any path starting `M ... S`.
        def smooth_cubic(c2, to)
          c1 = reflected
          cubic(c1, c2, to)
        end

        def quadratic(c, to)
          ensure_subpath
          SvgPath.flatten_quadratic([ @x, @y ], c, to, @tolerance, @current)
          @segments << SvgPath.quadratic_as_cubic([ @x, @y ], c, to)
          # THE QUADRATIC's OWN CONTROL POINT, NOT THE CUBIC's SECOND ONE. `T` reflects the
          # previous QUADRATIC control point (SVG 1.1 8.3.7); storing what the conversion above
          # just produced would reflect a different point and bend every `T` by the wrong amount.
          @last_control = c
          @x, @y = to
        end

        def smooth_quadratic(x, y)
          quadratic(reflected, [ x, y ])
        end

        def reflected
          return [ @x, @y ] if @last_control.nil?

          [ (2 * @x) - @last_control[0], (2 * @y) - @last_control[1] ]
        end

        def arc(args, rel)
          rx, ry, rotation, large, sweep, x, y = args
          to = rel ? [ @x + x, @y + y ] : [ x, y ]
          ensure_subpath
          from = [ @x, @y ]
          SvgPath.flatten_arc(from, rx, ry, rotation, large, sweep, to, @tolerance, @current)
          @segments.concat(SvgPath.arc_cubics(from, rx, ry, rotation, large, sweep, to, @tolerance))
          @x, @y = to
        end

        def close
          return if @current.nil?

          # A CLOSED SUBPATH REPEATS ITS START AS ITS LAST POINT, matching what Lbrn2 and Dxf
          # yield. `Geometry.simplify` always keeps the first and last point, so the contour still
          # closes after thinning.
          @current << @start.dup if @current.last != @start
          # `Z` RATHER THAN A REPEATED ENDPOINT. The line above already lands the points on the
          # start; what this adds is a CLOSED SUBPATH, which is what makes the drawn <path>
          # fillable and therefore hit-testable the way the <polygon> it replaces was.
          @segments << [ :Z ]
          @subpaths << [ @current, true, SvgPath.curved(@segments) ]
          @current = nil
          @segments = nil
          @x, @y = @start
          # `Z` returns the pen to the subpath start; a following drawing command begins a NEW
          # subpath THERE, without an intervening moveto. Dropping @start here would anchor it at
          # the origin instead.
        end

        def flush
          return if @current.nil?

          @subpaths << [ @current, false, SvgPath.curved(@segments) ] if @current.length >= 2
          @current = nil
          @segments = nil
        end
      end

      # ---- the segment list -----------------------------------------------------------------

      # A SUBPATH'S SEGMENTS, OR nil WHEN NOTHING IN IT CURVES — a DECISION, not an omission. A run
      # of `L` ops is already described EXACTLY by the points beside it (thinning only drops points
      # within `Geometry::SIMPLIFY_TOLERANCE` of the line the browser draws), so a path descriptor
      # there would restate the same geometry in a second encoding and be paid for on every contour
      # of every file. The form exists for what has no exact form already.
      #
      # A CONTOUR THAT MIXES STRAIGHT AND CURVED COMMANDS KEEPS ALL OF ITS SEGMENTS, because a path
      # is continuous and the `L`s are how the `C`s are reached.
      #
      # `Lbrn2.curved_segments` IS THE SAME DECISION ON THE OTHER PRODUCER LEG, and the two are
      # deliberately separate rather than shared: each is one `any?` over a list only that traversal
      # holds, at the point where it knows a contour is finished. If a THIRD producer arrives — a
      # DXF spline is the one already flagged as newly eligible — fold all three into
      # `Geometry.path_curve` instead of adding a copy.
      def curved(segments)
        segments&.any? { |(cmd, *)| cmd == :C } ? segments : nil
      end

      # A QUADRATIC IS A CUBIC EXACTLY, and this is why the wire form can be cubics-only without
      # approximating anything: c1 = p0 + ⅔(c − p0), c2 = p + ⅔(c − p) — degree elevation, an
      # identity, not a fit.
      #
      # THE CONVERSION TO WATCH FOR IS THE NAIVE ONE, using the quadratic's own control point for
      # BOTH cubic controls. It passes through the right endpoints with the right tangents and
      # draws a curve of the right family, so it looks correct and misses by a THIRD of the bulge —
      # 5 units on a 20-unit bulge, measured in `svg_path_test.rb`.
      def quadratic_as_cubic(p0, c, to)
        [ :C,
          p0[0] + (2.0 / 3.0 * (c[0] - p0[0])), p0[1] + (2.0 / 3.0 * (c[1] - p0[1])),
          to[0] + (2.0 / 3.0 * (c[0] - to[0])), to[1] + (2.0 / 3.0 * (c[1] - to[1])),
          to[0], to[1] ]
      end

      # ---- curve flattening ---------------------------------------------------------------

      # ADAPTIVE BY FLATNESS, not a fixed sample count, and the difference is the whole reason
      # this measures well. A fixed count (Lbrn2 uses 12 per cubic) oversamples a 1 mm curve and
      # UNDERSAMPLES a 300 mm one — and an undersampled curve's chord sits inside the true curve,
      # so its bbox and its diameter both read small, silently. Subdividing until the control
      # polygon is within `tolerance` of the chord bounds the error in the same units the payload
      # reports, whatever the curve's size.
      #
      # Appends to `out` and does NOT append the start point — the caller already has it as the
      # current point, and appending it again would put a duplicate at every segment join.
      def flatten_cubic(p0, p1, p2, p3, tolerance, out, depth = 0)
        if depth >= MAX_DEPTH || cubic_flat?(p0, p1, p2, p3, tolerance)
          out << p3
          return
        end

        p01 = mid(p0, p1); p12 = mid(p1, p2); p23 = mid(p2, p3)
        p012 = mid(p01, p12); p123 = mid(p12, p23)
        mid_point = mid(p012, p123)
        flatten_cubic(p0, p01, p012, mid_point, tolerance, out, depth + 1)
        flatten_cubic(mid_point, p123, p23, p3, tolerance, out, depth + 1)
      end

      def flatten_quadratic(p0, p1, p2, tolerance, out, depth = 0)
        if depth >= MAX_DEPTH || Geometry.point_segment_distance(p1, p0, p2) <= tolerance
          out << p2
          return
        end

        p01 = mid(p0, p1); p12 = mid(p1, p2)
        mid_point = mid(p01, p12)
        flatten_quadratic(p0, p01, mid_point, tolerance, out, depth + 1)
        flatten_quadratic(mid_point, p12, p2, tolerance, out, depth + 1)
      end

      # Flat when BOTH control points lie within `tolerance` of the chord. Checking only one lets
      # an S-shaped segment — whose control points sit on opposite sides — pass as flat while
      # bulging in both directions.
      def cubic_flat?(p0, p1, p2, p3, tolerance)
        Geometry.point_segment_distance(p1, p0, p3) <= tolerance &&
          Geometry.point_segment_distance(p2, p0, p3) <= tolerance
      end

      def mid(a, b) = [ (a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0 ]

      # SVG's ENDPOINT arc parameterization → centre parameterization → sampled points.
      def flatten_arc(from, rx, ry, rotation_deg, large, sweep, to, tolerance, out)
        params = arc_params(from, rx, ry, rotation_deg, large, sweep, to)
        if params.nil?
          out << to
          return
        end

        cx, cy, rx, ry, phi, theta1, delta = params
        steps = arc_steps([ rx, ry ].max, delta.abs, tolerance)
        (1..steps).each { |i| out << arc_point(cx, cy, rx, ry, phi, theta1 + (delta * i / steps)) }
      end

      # THE ENDPOINT PARAMETERIZATION SVG WRITES → THE CENTRE ONE EVERYTHING HERE COMPUTES FROM, as
      # [cx, cy, rx, ry, phi, theta1, delta], or nil where the arc degenerates to a straight line.
      # Implements SVG 1.1 appendix F.6.5/F.6.6, including its two correction rules: a zero radius
      # degenerates to a line, and radii too small to span the endpoints are scaled up until they
      # exactly do.
      #
      # ONE DEFINITION, READ BY BOTH `flatten_arc` AND `arc_cubics`. A second copy of F.6.5 would
      # let the sampled points and the emitted cubics disagree about where the same arc is — and
      # since `b`, `d` and the job box come from the points while the client DRAWS the cubics, the
      # disagreement would surface as a picture that contradicts the readout beside it, which is
      # the failure `Geometry.path_curve` exists to end rather than to relocate.
      def arc_params(from, rx, ry, rotation_deg, large, sweep, to)
        rx = rx.abs
        ry = ry.abs
        return nil if rx.zero? || ry.zero? || (from[0] == to[0] && from[1] == to[1])

        phi = rotation_deg * Math::PI / 180
        cos_phi = Math.cos(phi)
        sin_phi = Math.sin(phi)

        dx2 = (from[0] - to[0]) / 2.0
        dy2 = (from[1] - to[1]) / 2.0
        x1p = (cos_phi * dx2) + (sin_phi * dy2)
        y1p = (-sin_phi * dx2) + (cos_phi * dy2)

        # F.6.6.2 — grow radii that cannot reach across the chord.
        lambda_ = ((x1p * x1p) / (rx * rx)) + ((y1p * y1p) / (ry * ry))
        if lambda_ > 1
          scale = Math.sqrt(lambda_)
          rx *= scale
          ry *= scale
        end

        num = (rx * rx * ry * ry) - (rx * rx * y1p * y1p) - (ry * ry * x1p * x1p)
        den = (rx * rx * y1p * y1p) + (ry * ry * x1p * x1p)
        factor = den.zero? ? 0.0 : Math.sqrt([ num / den, 0.0 ].max)
        # F.6.5.2: the sign is + when the two flags DIFFER and - when they agree. Written as two
        # named booleans because the inline form (`large != 0 == (sweep != 0)`) leans on Ruby's
        # left-associative comparison chaining to mean the right thing, which is not a thing to
        # leave a future reader to verify.
        large_flag = !large.to_i.zero?
        sweep_flag = !sweep.to_i.zero?
        factor = -factor if large_flag == sweep_flag

        cxp = factor * rx * y1p / ry
        cyp = -factor * ry * x1p / rx
        cx = (cos_phi * cxp) - (sin_phi * cyp) + ((from[0] + to[0]) / 2.0)
        cy = (sin_phi * cxp) + (cos_phi * cyp) + ((from[1] + to[1]) / 2.0)

        theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        delta %= 2 * Math::PI
        if sweep.to_i.zero?
          delta -= 2 * Math::PI if delta.positive?
        elsif delta.negative?
          delta += 2 * Math::PI
        end

        [ cx, cy, rx, ry, phi, theta1, delta ]
      end

      # A point on the centre-parameterised ellipse at angle `t`.
      def arc_point(cx, cy, rx, ry, phi, t)
        cos_phi = Math.cos(phi)
        sin_phi = Math.sin(phi)
        [ (cos_phi * rx * Math.cos(t)) - (sin_phi * ry * Math.sin(t)) + cx,
          (sin_phi * rx * Math.cos(t)) + (cos_phi * ry * Math.sin(t)) + cy ]
      end

      # d/dt of `arc_point` — the ellipse's tangent vector, which is what the cubic fit below
      # scales to place its control points.
      def arc_tangent(rx, ry, phi, t)
        cos_phi = Math.cos(phi)
        sin_phi = Math.sin(phi)
        [ (-cos_phi * rx * Math.sin(t)) - (sin_phi * ry * Math.cos(t)),
          (-sin_phi * rx * Math.sin(t)) + (cos_phi * ry * Math.cos(t)) ]
      end

      # AN `A` COMMAND AS CUBICS — the wire form has no arc, and that is a feature rather than a
      # concession. Two reasons, both recorded:
      #
      #   * AN SVG ARC UNDER A NON-UNIFORM SCALE IS A DIFFERENT ELLIPSE ARC, needing a rotation
      #     term neither the `"e"` nor the `"a"` wire form carries — the case `Dxf.transform_curve`
      #     has to DROP a descriptor for. A cubic transforms affinely under ANY matrix, so
      #     converting sidesteps the whole question and lets a rotated or skewed `<path>` keep its
      #     descriptor (`SvgGeometry.walk`).
      #   * ENDPOINT PARAMETERISATION IS ILL-CONDITIONED UNDER ROUNDING. `Geometry.arc_curve`'s own
      #     comment measures 1.37 mm of drawn error at r = 200 from rounding resolved `A` endpoints
      #     at PRECISION. A cubic evaluates to a convex combination of its own four points, so the
      #     same rounding moves the drawn curve by at most PRECISION's half-step, at any radius.
      #
      # A DEGENERATE ARC BECOMES AN `L`, matching what `flatten_arc` appends for it — and, since a
      # subpath of nothing but degenerate arcs then holds no `:C`, `curved` drops it entirely.
      def arc_cubics(from, rx, ry, rotation_deg, large, sweep, to, tolerance)
        params = arc_params(from, rx, ry, rotation_deg, large, sweep, to)
        return [ [ :L, to[0], to[1] ] ] if params.nil?

        cx, cy, rx, ry, phi, theta1, delta = params
        n = arc_cubic_steps([ rx, ry ].max, delta.abs, tolerance)
        step = delta / n
        # The tangent-scaling constant for a sub-arc of `step` radians: the cubic that matches the
        # ellipse's position AND tangent at both ends. Exact for a straight `step` of 0, and the
        # source of the residual error `cubic_arc_error` bounds for everything else.
        alpha = 4.0 / 3.0 * Math.tan(step / 4.0)
        (0...n).map do |i|
          t0 = theta1 + (step * i)
          t1 = t0 + step
          p0 = arc_point(cx, cy, rx, ry, phi, t0)
          p1 = arc_point(cx, cy, rx, ry, phi, t1)
          d0 = arc_tangent(rx, ry, phi, t0)
          d1 = arc_tangent(rx, ry, phi, t1)
          [ :C,
            p0[0] + (alpha * d0[0]), p0[1] + (alpha * d0[1]),
            p1[0] - (alpha * d1[0]), p1[1] - (alpha * d1[1]),
            p1[0], p1[1] ]
        end
      end

      # A CEILING ON A CEILING. The π/2 floor is what makes a circle four cubics — the split every
      # renderer uses — and 32 is the stop that keeps a pathological radius from generating
      # thousands of segments on a payload with a size budget.
      MAX_ARC_CUBICS = 32

      # CUBICS PER ARC, BOUNDED BY GEOMETRIC ERROR RATHER THAN BY A FIXED COUNT — the same rule
      # `flatten_cubic` above follows for the points, and the one
      # `docs/invariants/measure-view.md` states for every curve in this app.
      #
      # FOUR PER FULL TURN IS THE FLOOR, NOT THE ANSWER. The tangent-based fit's radial error is
      # 2.7e-4·r at π/2 (see `cubic_arc_error`) — 0.054 mm at r = 200 mm, an order of magnitude
      # WORSE than the `p` points it rides beside, which are flattened to `tolerance` and thinned
      # at 0.01 mm. A descriptor less faithful than the polyline it replaces is precisely the
      # defect tinkerex#213 shipped, so the count grows with the radius instead. In practice that
      # is four for anything under about an 18 mm radius and six for a 200 mm one.
      def arc_cubic_steps(radius, radians, tolerance)
        n = (radians / (Math::PI / 2)).ceil.clamp(1, 4)
        n += 1 while n < MAX_ARC_CUBICS && cubic_arc_error(radius, radians / n) > tolerance
        n
      end

      # The maximum radial deviation of one tangent-matched cubic from the arc it approximates:
      # r·(2/27)·sin⁶(θ/4)/cos²(θ/4). 2.7e-4·r at θ = π/2, and it falls as roughly θ⁶, which is why
      # one extra split buys an order of magnitude.
      def cubic_arc_error(radius, theta)
        cos = Math.cos(theta / 4.0).abs
        return Float::INFINITY if cos < 1e-9

        radius * (2.0 / 27.0) * (Math.sin(theta / 4.0)**6) / (cos * cos)
      end

      # Signed angle between two vectors, as F.6.5.4 defines it.
      def angle(ux, uy, vx, vy)
        dot = (ux * vx) + (uy * vy)
        len = Math.sqrt(((ux * ux) + (uy * uy)) * ((vx * vx) + (vy * vy)))
        return 0.0 if len.zero?

        a = Math.acos((dot / len).clamp(-1.0, 1.0))
        ((ux * vy) - (uy * vx)).negative? ? -a : a
      end

      # Segments needed so an arc of `radius` spanning `radians` stays within `tolerance` of its
      # chords: sagitta = r(1 - cos(θ/2n)). Same bound as `Dxf.arc_samples`, but absolute here
      # because this parser knows its scale (the caller converts the mm tolerance into user units)
      # while the DXF traversal deliberately does not.
      def arc_steps(radius, radians, tolerance)
        return 1 if radius <= 0 || radians <= 0

        ratio = (tolerance / radius).clamp(1e-9, 0.5)
        (radians / (2 * Math.acos(1 - ratio))).ceil.clamp(1, 512)
      end
    end
  end
end
