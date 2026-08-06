require "json"

module Maker
  module Previews
    # LightBurn (.lbrn/.lbrn2) -> a compact geometry payload for the browser's Measure view.
    #
    # This is the SECOND artifact derived from one .lbrn2, alongside the thumbnail: same file,
    # same traversal, different shape. It exists because a measuring client needs coordinates and
    # the thumbnail is a PNG — LightBurn's own embedded render, which has no mapping back to mm.
    #
    # BUILT ON `Lbrn2.each_geometry`, NEVER ON A PRIVATE WALK. That is CLAUDE.md's one-traversal
    # rule and it is not stylistic: `LbrnMetadata` once kept a second copy of this traversal and
    # independently inherited every dialect bug the parser had, so a file could render one way and
    # report a size computed from different geometry with nothing to catch it. The test asserting
    # this payload's bboxes union to `Lbrn2.job_size` is what keeps the two tied together.
    module LbrnGeometry
      module_function

      # The WIRE CONTRACT, checked by lbrnmeasure_controller.js against its own copy of this
      # number. Bump only when the payload's SHAPE changes in a way the shipped client cannot
      # read — and bump both files together, since that coupling is inherent to a wire format.
      SCHEMA_VERSION = 1

      # WHICH BUILD OF THIS FILE PRODUCED A STORED PAYLOAD. Bump on ANY change that alters the
      # output, whether or not the schema moves: `Maker::Previews::Enqueue` compares it against
      # `maker_previews.renderer_revision` and re-renders whatever no longer matches.
      #
      # THIS IS THE ONE TO BUMP, and SCHEMA_VERSION is the easy thing to reach for instead. They
      # answer different questions — the schema says whether the CLIENT can parse a payload, this
      # says whether the SERVER should still be serving one. Revision 2 changed every coordinate
      # while touching no key at all: a schema bump would have been wrong (shipped clients read it
      # fine), and having neither is what left four already-measured files serving mangled curves
      # after the fix deployed, until they were found and destroyed by hand.
      #
      #   1  index-stride thinning — mangled any contour mixing straight and curved edges
      #   2  error-bounded simplification against SIMPLIFY_TOLERANCE
      #   3  carries per-layer colours so the Measure view draws in LightBurn's palette
      PAYLOAD_REVISION = 3

      # HOW FAR THE DRAWN LINE MAY STRAY FROM THE REAL CONTOUR, in mm. Thinning is bounded by this
      # and by nothing else — see `simplify`.
      #
      # 0.01 mm is an order of magnitude below a hobby laser's positional accuracy (~0.05 mm) and
      # two below a typical kerf (~0.1-0.2 mm), so it is invisible in the only terms this file's
      # readers care about. Measured over the 58 real exports: median payload 7.5 KB gzipped,
      # worst 200 KB — the worst case is 29% SMALLER than the index-stride scheme this replaced,
      # while bounding the error at 0.01 mm instead of that scheme's measured 58.7 mm.
      #
      # THIS REPLACED A FIXED INDEX STRIDE, AND THE REASON MATTERS. That scheme kept every third
      # point and justified itself with `Lbrn2::BEZIER_SAMPLES % 3 == 0`: since each cubic
      # flattens to 12 points, an original vertex lands on every 12th index, so all of them
      # survive. True — but ONLY for a contour built entirely of `B` ops. `Lbrn2.polylines`
      # appends 12 points per BEZIER segment and exactly ONE per `L` (straight) segment, so a
      # single straight edge shifts every later index by one and the alignment collapses. And for
      # an `L` segment that one point IS a vertex: dropping a curve sample flattens a curve
      # slightly, dropping a vertex cuts the corner off entirely. Over the corpus that displaced
      # 1148 of 5259 thinned contours by more than 5% of their own size.
      SIMPLIFY_TOLERANCE = 0.01

      # Circularity, for the readout's diameter. THREE conditions, and the point count is the one
      # most likely to be trimmed as redundant — it is not. A square's four corners are all
      # equidistant from its centre (so are any regular polygon's vertices), so the radius test
      # ALONE calls every square round. A Rect emits 5 points, a bezier circle 49, an Ellipse 33.
      # Accepted: a genuine 16-gon reports as round. It is that many mm across either way.
      MIN_CIRCLE_POINTS = 12
      CIRCLE_TOLERANCE = 0.02

      # mm, to 0.01.
      PRECISION = 2

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def render(lbrn2_bytes)
        doc = Lbrn2.parse_document(lbrn2_bytes)
        { bytes: JSON.generate(build(doc)), content_type: "application/json" }
      end

      def build(doc)
        # A rootless document means parse_document could not make sense of the bytes at all — the
        # SAME condition Lbrn2.to_svg raises ParseError for, and this artifact must match it.
        # Without this check, each_geometry's own `return if doc.root.nil?` yields nothing,
        # silently, and the method below returns the ordinary empty-payload shape — turning a
        # corrupt upload into a READY Measure view claiming "No measurable geometry in this file"
        # instead of a failed preview: a lie about the file. A document that DOES have a root but
        # genuinely contains no shapes is a DIFFERENT, honest case — it reaches that same empty
        # payload by actually walking a real (if sparse) document, and the client has a message
        # for it. Keep the two distinct; do not collapse an empty project into a parse failure.
        raise Lbrn2::ParseError, "not a LightBurn project" if doc.root.nil?

        shapes = []
        min_x = min_y = Float::INFINITY
        max_x = max_y = -Float::INFINITY

        Lbrn2.each_geometry(doc) do |cut, points, closed, _ellipse, image, object_id|
          next if points.length < 2

          xs = points.map(&:first)
          ys = points.map(&:last)
          x0, y0, x1, y1 = xs.min, ys.min, xs.max, ys.max
          min_x = x0 if x0 < min_x
          min_y = y0 if y0 < min_y
          max_x = x1 if x1 > max_x
          max_y = y1 if y1 > max_y

          entry = {
            "o" => object_id,
            "c" => cut,
            "b" => [ x0, y0, x1, y1 ].map { |v| v.round(PRECISION) },
            "k" => closed ? 1 : 0,
            "i" => image ? 1 : 0,
            "p" => simplify(points).map { |(x, y)| [ x.round(PRECISION), y.round(PRECISION) ] }
          }
          # EVERY MEASUREMENT COMES FROM THE FULL-RESOLUTION POINTS, above and here. Decimation
          # is a drawing concession; it must never move a reported number. An implementation that
          # thins first and measures after passes any "does it draw" test while silently
          # under-reporting every curve.
          d = diameter(points, closed, x0, y0, x1, y1)
          entry["d"] = d.round(PRECISION) if d

          shapes << entry
        end

        {
          "v" => SCHEMA_VERSION,
          "job" => job_box(min_x, min_y, max_x, max_y),
          # CutIndex -> the colour LightBurn draws that layer in, for the layers this file
          # actually uses. SENT FROM THE SERVER RATHER THAN LOOKED UP IN THE CLIENT, so the
          # palette has exactly one definition — a second copy in JS is this repo's recorded
          # failure shape (§14d's third extension->role table, which drifted). It also means a
          # file that DOES override a layer's colour is honoured without the client knowing
          # such a thing is possible.
          "colors" => layer_colors(doc, shapes),
          "shapes" => shapes
        }
      end

      # CutIndex -> colour, for the layers this document actually draws.
      #
      # `cut_colors` is resolved ONCE, not per layer: it walks every CutSetting element, so calling
      # it inside the map below would re-walk them for each distinct layer in the file.
      def layer_colors(doc, shapes)
        from_file = Lbrn2.cut_colors(doc)
        shapes.filter_map { |s| s["c"] }.uniq
              .to_h { |cut| [ cut, from_file[cut] || Lbrn2.layer_color(cut) ] }
              .compact
      end

      def job_box(min_x, min_y, max_x, max_y)
        return { "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 } if min_x == Float::INFINITY

        { "w" => (max_x - min_x).round(PRECISION), "h" => (max_y - min_y).round(PRECISION),
          "x" => min_x.round(PRECISION), "y" => min_y.round(PRECISION) }
      end

      # Ramer-Douglas-Peucker: keep the point FARTHEST from the current chord, recurse on both
      # halves, discard anything within SIMPLIFY_TOLERANCE of the line it would sit on.
      #
      # WHY THIS SHAPE OF ALGORITHM RATHER THAN A CHEAPER ONE. It selects by geometric error, not
      # by position in the array, so it cannot care whether a point came from an `L` op or a `B`
      # op — which is precisely the distinction the index-stride scheme was blind to. A corner is
      # by definition the farthest point from any chord spanning it, so corners are kept by
      # construction rather than by index luck, and the redundant middles of a flattened curve
      # collapse. It also compresses BETTER here: 26,682 points where the stride left 62,773, on
      # the same file, while being correct.
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
