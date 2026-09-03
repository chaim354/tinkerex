require "json"

module Maker
  module Previews
    # THE ONE DEFINITION OF THE MEASURE PAYLOAD, shared by every format that can be measured.
    #
    # A measuring client needs coordinates in millimetres; a thumbnail is a picture with no mapping
    # back to mm. This module owns everything about that payload that is NOT format-specific — the
    # wire shape, the drawing-only thinning, the circularity test, the job box — so the four
    # formats differ only in HOW THEY READ THEIR OWN FILE, never in what a measurement means.
    #
    # WHY THIS IS A MODULE AND NOT FOUR COPIES. `LbrnGeometry` was the first and for a while the
    # only one; adding .mage, .dxf and .svg by copying it would have put four independent
    # implementations of `simplify` and `diameter` in the tree, which is precisely §14b's
    # `LbrnMetadata` second-copy bug with three extra copies. A ⌀ that means one thing on a
    # LightBurn file and another on a DXF is worse than no ⌀ at all.
    #
    # EACH FORMAT SUPPLIES A TRAVERSAL AND NOTHING ELSE. It calls `build` with a block, pushes
    # contours into the collector, and gets the finished payload back:
    #
    #   Geometry.build(colors: ->(layers) { ... }) do |out|
    #     out.add(layer:, points:, closed:, image:, object_id:)
    #   end
    #
    # `points` MUST ALREADY BE IN MILLIMETRES, in the client's own Y-down drawing space. Unit
    # resolution is the format's job because only the format knows where its units are recorded
    # (LightBurn is mm by definition, DXF has $INSUNITS, SVG has width/height + viewBox) — and
    # doing it here would mean this module taking a scale factor it could never validate.
    module Geometry
      module_function

      # The WIRE CONTRACT, checked by measure_controller.js against its own copy of this number.
      # Bump only when the payload's SHAPE changes in a way the shipped client cannot read — and
      # bump both files together, since that coupling is inherent to a wire format.
      #
      # ONE NUMBER FOR ALL FOUR FORMATS, deliberately: the client has one parser, so a per-format
      # schema would be three numbers it never checks.
      SCHEMA_VERSION = 1

      # HOW FAR THE DRAWN LINE MAY STRAY FROM THE REAL CONTOUR, in mm. Thinning is bounded by this
      # and by nothing else — see `simplify`.
      #
      # 0.01 mm is an order of magnitude below a hobby laser's positional accuracy (~0.05 mm) and
      # two below a typical kerf (~0.1-0.2 mm), so it is invisible in the only terms this file's
      # readers care about. Measured over the 58 real LightBurn exports: median payload 7.5 KB
      # gzipped, worst 200 KB — the worst case is 29% SMALLER than the index-stride scheme this
      # replaced, while bounding the error at 0.01 mm instead of that scheme's measured 58.7 mm.
      #
      # THIS REPLACED A FIXED INDEX STRIDE, AND THE REASON MATTERS — it is the trap any future
      # format will fall into too. That scheme kept every third point and justified itself with
      # `Lbrn2::BEZIER_SAMPLES % 3 == 0`: since each cubic flattens to 12 points, an original
      # vertex lands on every 12th index, so all of them survive. True — but ONLY for a contour
      # built entirely of curve ops. `Lbrn2.polylines` appends 12 points per BEZIER segment and
      # exactly ONE per `L` (straight) segment, so a single straight edge shifts every later index
      # by one and the alignment collapses. And for a straight segment that one point IS a vertex:
      # dropping a curve sample flattens a curve slightly, dropping a vertex cuts the corner off
      # entirely. Over the corpus that displaced 1148 of 5259 thinned contours by more than 5% of
      # their own size. Every format here flattens curves to points, so every format has that same
      # mix of vertex-points and sample-points, and none of them may be thinned by position.
      SIMPLIFY_TOLERANCE = 0.01

      # Circularity, for the readout's diameter. THREE conditions, and the point count is the one
      # most likely to be trimmed as redundant — it is not. A square's four corners are all
      # equidistant from its centre (so are any regular polygon's vertices), so the radius test
      # ALONE calls every square round. A LightBurn Rect emits 5 points, a bezier circle 49, an
      # Ellipse 33; an SVG <circle> and a DXF CIRCLE flatten to CIRCLE_SAMPLES.
      # Accepted: a genuine 16-gon reports as round. It is that many mm across either way.
      MIN_CIRCLE_POINTS = 12
      CIRCLE_TOLERANCE = 0.02

      # mm, to 0.01.
      PRECISION = 2

      # THE WIRE FORM OF A CURVE DESCRIPTOR, WITH ONE DEFINITION HERE RATHER THAN THREE IN THE
      # FORMAT MODULES. A format supplies the numbers; the encoding lives here, so `["e", ...]` is
      # not a string spelled in LbrnGeometry, DxfGeometry and SvgGeometry that must then agree —
      # the N-copies-that-must-agree defect §14b records as four skip-list strings and §14d as five
      # port_writable? branches.
      #
      # ALREADY IN CLIENT SPACE — millimetres, Y-down. `measure_controller.js` branches on NO file
      # type and must not learn what a DXF Y-flip is; each format's geometry module puts its
      # descriptor into this space exactly as it already does for its points.
      #
      # A DRAWING HINT, NEVER A MEASUREMENT. `b`, `d` and the job box are computed from the
      # FULL-RESOLUTION points above and are untouched by anything here — the same contract
      # `Lbrn2.each_geometry` and `Dxf.each_geometry` already state about the descriptors they
      # yield ("a richer rendering of the same points, never a substitute for them"). A client
      # ignoring `"g"` draws what it drew before this existed and reports identical numbers.
      #
      # AND NOTHING INFERS ONE FROM THE POINTS. A shape gets a descriptor because the FILE said
      # <Ellipse> / CIRCLE / ARC / <circle>, never because it measured round. `Geometry.diameter`'s
      # accepted consequence — a genuine 16-gon reports as round — stays confined to the `d` LABEL
      # and must never reach exported geometry, where it would substitute a circle for a designed
      # polygon in a file somebody cuts.
      def ellipse_curve(cx, cy, rx, ry)
        [ "e", *[ cx, cy, rx, ry ].map { |v| v.round(PRECISION) } ]
      end

      # SVG `A`-command parameters, resolved. Centre-plus-angles would push the Y-flip's
      # orientation reversal onto the client, which is the one thing the client may not know.
      def arc_curve(x0, y0, x1, y1, r, large_arc, sweep)
        [ "a", *[ x0, y0, x1, y1, r ].map { |v| v.round(PRECISION) }, large_arc, sweep ]
      end

      # A CHANGE IN THIS FILE IS A CHANGE TO EVERY FORMAT'S OUTPUT, so it must bump EVERY format's
      # PAYLOAD_REVISION, not one of them. `Maker::Previews::Enqueue` compares a stored artifact's
      # `renderer_revision` against the renderer that would build it now — so a fix to `simplify`
      # that bumped only LbrnGeometry would leave every already-measured .dxf and .svg serving
      # output from the old algorithm, FOREVER, because a finished design's content never changes.
      #
      # BUMP THIS AND ALL OF THEM MOVE, because each format's number is `SHARED_REVISION + its
      # own`. It was three hand-edited integers held together by the paragraph above, and prose is
      # not a mechanism: `(Lbrn=5, Dxf=1, Svg=1)` after a shared change is a reachable state that
      # nothing anywhere reports — silent, permanent, and per-backend. The repo already writes the
      # rule down one file over, in `Mage.payload_revision`: a second constant is free to drift
      # from the code that produces the bytes it claims to version, so delegate instead of
      # declaring. This is that, as arithmetic, for the three formats that cannot delegate outright
      # (each has its OWN revision too).
      #
      # SEEDED AT 0, DELIBERATELY: the totals it produced on introduction were exactly the three
      # integers it replaced (4 / 1 / 1), so introducing it re-rendered nothing. Any edit here
      # bumps it by one and re-measures the library once, which is the whole point — and the log
      # below the next paragraph is where an edit says what it changed.
      #
      # RESIDUAL, STATED RATHER THAN HIDDEN: this makes the CORRECT edit one line; it does not stop
      # an editor bumping a format's FORMAT_REVISION for a change that actually lives here. The
      # absolute-value pins in `GeometryTest` are what make that mistake visible.
      #   1  shapes gained the optional `g` curve descriptor (Collector#add's `curve:`)
      SHARED_REVISION = 1

      # Listed so the next editor has the set in front of them rather than having to grep for it;
      # `GeometryTest` asserts this list matches the renderers that actually build a geometry
      # payload, so a fifth format cannot be added without appearing here — and therefore cannot
      # be added without picking up the shared term above.
      REVISIONED_BY = %w[LbrnGeometry DxfGeometry SvgGeometry].freeze

      # Collects one contour at a time from a format's traversal. Not a bare Array because it also
      # tracks the running document bbox, which must be computed from FULL-RESOLUTION points.
      class Collector
        attr_reader :shapes

        def initialize
          @shapes = []
          @min_x = @min_y = Float::INFINITY
          @max_x = @max_y = -Float::INFINITY
        end

        # One measurable contour. `points` are [[x, y], ...] in mm.
        #
        # A contour of fewer than two points is DROPPED rather than rejected: a degenerate shape
        # (a zero-length line, a Rect with no W/H) is ordinary in a real file and must not fail the
        # whole render. It still consumed its object_id, which is why ids are never dense — see
        # `Lbrn2.each_geometry`.
        def add(layer:, points:, closed:, object_id:, image: false, curve: nil)
          return if points.length < 2

          xs = points.map(&:first)
          ys = points.map(&:last)
          x0, y0, x1, y1 = xs.min, ys.min, xs.max, ys.max
          @min_x = x0 if x0 < @min_x
          @min_y = y0 if y0 < @min_y
          @max_x = x1 if x1 > @max_x
          @max_y = y1 if y1 > @max_y

          entry = {
            "o" => object_id,
            "c" => layer,
            "b" => [ x0, y0, x1, y1 ].map { |v| v.round(PRECISION) },
            "k" => closed ? 1 : 0,
            "i" => image ? 1 : 0,
            "p" => Geometry.simplify(points).map { |(x, y)| [ x.round(PRECISION), y.round(PRECISION) ] }
          }
          # EVERY MEASUREMENT COMES FROM THE FULL-RESOLUTION POINTS, above and here. Decimation is
          # a drawing concession; it must never move a reported number. An implementation that
          # thins first and measures after passes any "does it draw" test while silently
          # under-reporting every curve — and `d` is the sharper case, because a 0.2 mm hole thins
          # to fewer than MIN_CIRCLE_POINTS and would lose its diameter entirely.
          d = Geometry.diameter(points, closed, x0, y0, x1, y1)
          entry["d"] = d.round(PRECISION) if d
          # ABSENT RATHER THAN NULL when a format has no exact primitive to offer — which is most
          # shapes in most files. See Geometry.ellipse_curve for what this is and is not.
          entry["g"] = curve if curve

          @shapes << entry
        end

        def job_box
          return { "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 } if @min_x == Float::INFINITY

          { "w" => (@max_x - @min_x).round(PRECISION), "h" => (@max_y - @min_y).round(PRECISION),
            "x" => @min_x.round(PRECISION), "y" => @min_y.round(PRECISION) }
        end

        # The distinct layer keys this document actually drew, in first-seen order — what a
        # `colors:` resolver is asked about. Asking about USED layers rather than every layer the
        # file declares keeps the map to what the client can actually paint with.
        def layers = @shapes.filter_map { |s| s["c"] }.uniq
      end

      # Run a format's traversal and assemble the payload.
      #
      # `colors:` is a callable taking the used layer keys and returning a { key => "#rrggbb" }
      # map, or nil for a format with no colour information to offer. SENT FROM THE SERVER RATHER
      # THAN LOOKED UP IN THE CLIENT so a palette has exactly one definition — a second copy in JS
      # is this repo's recorded failure shape (§14d's third extension→role table, which drifted).
      # It also means a file that OVERRIDES a layer's colour is honoured without the client
      # knowing such a thing is possible.
      def build(colors: nil)
        out = Collector.new
        yield out

        { "v" => SCHEMA_VERSION,
          "job" => out.job_box,
          "colors" => (colors&.call(out.layers) || {}).compact,
          "shapes" => out.shapes }
      end

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def encode(payload) = { bytes: JSON.generate(payload), content_type: "application/json" }

      # Ramer-Douglas-Peucker: keep the point FARTHEST from the current chord, recurse on both
      # halves, discard anything within SIMPLIFY_TOLERANCE of the line it would sit on.
      #
      # WHY THIS SHAPE OF ALGORITHM RATHER THAN A CHEAPER ONE. It selects by geometric error, not
      # by position in the array, so it cannot care whether a point came from a straight op or a
      # curve op — which is precisely the distinction the index-stride scheme was blind to. A
      # corner is by definition the farthest point from any chord spanning it, so corners are kept
      # by construction rather than by index luck, and the redundant middles of a flattened curve
      # collapse. It also compresses BETTER: 26,682 points where the stride left 62,773, on the
      # same file, while being correct.
      #
      # ITERATIVE, WITH AN EXPLICIT STACK, deliberately. The textbook form recurses once per kept
      # point, and a nearly-degenerate contour (every point marginally outside the tolerance)
      # recurses to its own length — real contours here run to thousands of points, which is close
      # enough to Ruby's stack limit not to want to find out. The stack costs two integers a frame.
      #
      # First and last points are always kept, so a closed contour still closes.
      def simplify(points)
        return points if points.length < 3

        keep = Array.new(points.length, false)
        keep[0] = keep[-1] = true
        stack = [ [ 0, points.length - 1 ] ]

        until stack.empty?
          first, last = stack.pop
          next if last <= first + 1

          far_i = nil
          far_d = SIMPLIFY_TOLERANCE
          ((first + 1)...last).each do |i|
            d = point_segment_distance(points[i], points[first], points[last])
            if d > far_d
              far_d = d
              far_i = i
            end
          end
          next if far_i.nil?

          keep[far_i] = true
          stack.push([ first, far_i ], [ far_i, last ])
        end

        points.each_with_index.filter_map { |p, i| p if keep[i] }
      end

      # Distance from `point` to the SEGMENT ab — not to the infinite line, which would report a
      # point beyond either end as closer than it is and let `simplify` discard a real extreme.
      def point_segment_distance(point, seg_a, seg_b)
        px, py = point
        ax, ay = seg_a
        bx, by = seg_b
        dx = bx - ax
        dy = by - ay
        # A degenerate chord is ordinary here, not a guard against bad data: a CLOSED contour
        # starts with first == last, so the very first call always has one.
        return Math.hypot(px - ax, py - ay) if dx.abs < 1e-12 && dy.abs < 1e-12

        t = ((((px - ax) * dx) + ((py - ay) * dy)) / ((dx * dx) + (dy * dy))).clamp(0.0, 1.0)
        Math.hypot(px - (ax + (t * dx)), py - (ay + (t * dy)))
      end

      # The contour's diameter in mm when it is round, else nil. See MIN_CIRCLE_POINTS.
      #
      # Measured from the BBOX CENTRE, not the centroid. A closed contour repeats its first point
      # as its last, so a centroid is pulled toward that vertex by one duplicate — small, but it
      # is a bias with no reason to exist when the bbox centre is exact for any symmetric shape.
      def diameter(points, closed, x0, y0, x1, y1)
        return nil unless closed && points.length >= MIN_CIRCLE_POINTS

        width = x1 - x0
        height = y1 - y0
        return nil if width <= 0 || height <= 0

        cx = (x0 + x1) / 2.0
        cy = (y0 + y1) / 2.0
        radii = points.map { |(x, y)| Math.hypot(x - cx, y - cy) }
        mean = radii.sum / radii.length
        return nil if mean <= 0
        return nil if radii.any? { |r| ((r - mean) / mean).abs > CIRCLE_TOLERANCE }

        (width + height) / 2.0
      end
    end
  end
end
