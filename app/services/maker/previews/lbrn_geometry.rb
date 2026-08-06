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

      SCHEMA_VERSION = 1

      # Contours at or below this ship every point. Above it they are thinned (DECIMATE_STRIDE).
      #
      # All the savings live in big contours — bookmark.lbrn2 averages 278 points each — and the
      # floor is what stops a 12-point circle degenerating into a triangle. Measured over the 58
      # real exports: thinning above this cuts the worst file from 734 KB to 281 KB gzipped.
      DECIMATE_ABOVE = 32
      DECIMATE_STRIDE = 3

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
            "p" => decimate(points).map { |(x, y)| [ x.round(PRECISION), y.round(PRECISION) ] }
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
          "shapes" => shapes
        }
      end

      def job_box(min_x, min_y, max_x, max_y)
        return { "w" => 0.0, "h" => 0.0, "x" => 0.0, "y" => 0.0 } if min_x == Float::INFINITY

        { "w" => (max_x - min_x).round(PRECISION), "h" => (max_y - min_y).round(PRECISION),
          "x" => min_x.round(PRECISION), "y" => min_y.round(PRECISION) }
      end

      # Every DECIMATE_STRIDE-th point, always keeping the last so a closed contour still closes.
      def decimate(points)
        return points if points.length <= DECIMATE_ABOVE

        out = points.each_slice(DECIMATE_STRIDE).map(&:first)
        out << points.last unless out.last == points.last
        out
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
