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
    # RETURNS ONE POLYLINE PER SUBPATH, each `[points, closed]`. A single `d` routinely holds
    # several — a letter with a counter, a plate with holes — and collapsing them into one contour
    # would draw a line joining shapes that are not joined, and measure a bbox spanning both.
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

      # Parse `d` into [[points, closed], ...].
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

      # The pen: current point, subpath start, last control point (for the S/T shorthands), and
      # the subpaths closed so far.
      class State
        def initialize(tolerance)
          @tolerance = tolerance
          @subpaths = []
          @current = nil
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

        def move_to(x, y)
          flush
          @current = [ [ x, y ] ]
          @start = [ x, y ]
          @x = x
          @y = y
        end

        def line_to(x, y)
          # A path may begin with a drawing command and no moveto. Treating the current point
          # (0,0) as the start is what a renderer does; refusing would drop the whole subpath.
          @current ||= [ [ @x, @y ] ]
          @start ||= [ @x, @y ]
          @current << [ x, y ]
          @x = x
          @y = y
        end

        def cubic(c1, c2, to)
          @current ||= [ [ @x, @y ] ]
          @start ||= [ @x, @y ]
          SvgPath.flatten_cubic([ @x, @y ], c1, c2, to, @tolerance, @current)
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
          @current ||= [ [ @x, @y ] ]
          @start ||= [ @x, @y ]
          SvgPath.flatten_quadratic([ @x, @y ], c, to, @tolerance, @current)
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
          @current ||= [ [ @x, @y ] ]
          @start ||= [ @x, @y ]
          SvgPath.flatten_arc([ @x, @y ], rx, ry, rotation, large, sweep, to, @tolerance, @current)
          @x, @y = to
        end

        def close
          return if @current.nil?

          # A CLOSED SUBPATH REPEATS ITS START AS ITS LAST POINT, matching what Lbrn2 and Dxf
          # yield. `Geometry.simplify` always keeps the first and last point, so the contour still
          # closes after thinning.
          @current << @start.dup if @current.last != @start
          @subpaths << [ @current, true ]
          @current = nil
          @x, @y = @start
          # `Z` returns the pen to the subpath start; a following drawing command begins a NEW
          # subpath THERE, without an intervening moveto. Dropping @start here would anchor it at
          # the origin instead.
        end

        def flush
          return if @current.nil?

          @subpaths << [ @current, false ] if @current.length >= 2
          @current = nil
        end
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
      # Implements SVG 1.1 appendix F.6.5/F.6.6, including its two correction rules:
      # a zero radius degenerates to a line, and radii too small to span the endpoints are
      # scaled up until they exactly do.
      def flatten_arc(from, rx, ry, rotation_deg, large, sweep, to, tolerance, out)
        rx = rx.abs
        ry = ry.abs
        if rx.zero? || ry.zero? || (from[0] == to[0] && from[1] == to[1])
          out << to
          return
        end

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

        steps = arc_steps([ rx, ry ].max, delta.abs, tolerance)
        (1..steps).each do |i|
          t = theta1 + (delta * i / steps)
          x = (cos_phi * rx * Math.cos(t)) - (sin_phi * ry * Math.sin(t)) + cx
          y = (sin_phi * rx * Math.cos(t)) + (cos_phi * ry * Math.sin(t)) + cy
          out << [ x, y ]
        end
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
