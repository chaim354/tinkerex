module Maker
  module Previews
    # DXF (.dxf) -> the Measure view's geometry payload.
    #
    # The thin half of the DXF measure leg: `Dxf.each_geometry` does the reading, `Geometry` owns
    # the payload's shape, and this module is only the two things that belong to neither — putting
    # the traversal's model-space output into the client's space (millimetres, Y-down), which is
    # the points AND the curve descriptor that rides beside them, and answering what colour each
    # layer is.
    #
    # THE SAME TRAVERSAL THE THUMBNAIL USES. See `Dxf.each_geometry`: a second parse here would be
    # free to drift from the picture beside it, which is §14b's `LbrnMetadata` bug. It takes the
    # pairs THIS module already lexed, so the file is read once per render rather than twice.
    module DxfGeometry
      module_function

      # WHICH BUILD OF *THIS FILE* PRODUCED A STORED PAYLOAD — see `LbrnGeometry::FORMAT_REVISION`
      # for the full argument. A change in the SHARED payload builder does NOT belong here; it
      # belongs in `Geometry::SHARED_REVISION`, which the line below adds in.
      #
      #   1  original
      FORMAT_REVISION = 1

      # What `Enqueue` actually reads — see `Geometry::SHARED_REVISION`.
      PAYLOAD_REVISION = Geometry::SHARED_REVISION + FORMAT_REVISION

      # Returns { bytes:, content_type: } — the shape GeneratePreviewJob attaches.
      def render(dxf_bytes)
        Geometry.encode(build(dxf_bytes))
      end

      # ONE HASH, HANDED TO BOTH — the traversal fills it while the block runs and `Geometry.build`
      # reads it after, which is the ordering both sides document. Two hashes, or a snapshot taken
      # at either end, emits an empty tally on every file and nothing anywhere goes red: the shapes
      # are still right, and `"u"` is simply never there to be missed.
      def build(dxf_bytes)
        pairs = Dxf.tokenize(dxf_bytes)
        scale = Dxf.mm_per_unit(pairs)
        colors = Dxf.layer_colors(pairs)
        unreadable = {}

        Geometry.build(colors: ->(layers) { layers.to_h { |l| [ l, colors[l] ] } }, unreadable:) do |out|
          Dxf.each_geometry(pairs, unreadable:) do |layer, points, closed, curve, object_id|
            out.add(layer:, points: to_client_space(points, scale), closed:, object_id:,
                    curve: curve_to_client_space(curve, scale))
          end
        end
      end

      # DXF model space -> the client's drawing space: scale to millimetres, then flip Y.
      #
      # BOTH STEPS HAPPEN HERE RATHER THAN IN THE TRAVERSAL, because the thumbnail needs the flip
      # WITHOUT the scale (its viewBox is unit-agnostic) — see `Dxf.each_geometry`. The flip is
      # the same `-y` the SVG path applies, so a measured contour and a drawn one sit the same way
      # up; without it every DXF would measure correctly and draw upside down.
      #
      # `* scale` before the flip or after is arithmetically identical; it reads better as
      # "make it millimetres, then make it Y-down".
      def to_client_space(points, scale)
        points.map { |(x, y)| [ x * scale, -y * scale ] }
      end

      # A DXF curve descriptor -> the payload's wire form, in the client's space. The same scale
      # and the same Y-flip `to_client_space` applies to the points, for the same reason: the
      # traversal yields model space because the thumbnail wants the flip WITHOUT the scale.
      #
      # A FULL-CIRCLE ARC IS ENCODED AS AN ELLIPSE, AND THAT IS NOT A ROUNDING CONVENIENCE.
      # `Dxf.arc_points` turns a0 == a1 into a 360-degree sweep — its own comment: "the whole
      # circle, not a zero-length arc" — whose start and end points are IDENTICAL. SVG's rule for
      # an arc whose endpoints coincide is to omit the segment ENTIRELY, so an `A` command here
      # would export a path that draws nothing: no error, nothing logged, a shape simply missing
      # from a file somebody cuts. (`Dxf.arc_svg` still has that bug for the thumbnail; fixing it
      # needs a THUMBNAIL_REVISION bump and is out of scope — see the design.)
      def curve_to_client_space(curve, scale)
        return nil if curve.nil?

        cx = curve[:cx] * scale
        cy = -curve[:cy] * scale
        r = curve[:r] * scale
        return Geometry.ellipse_curve(cx, cy, r, r) if curve[:type] == :circle || curve[:sweep] >= 360

        # THE Y-FLIP MIRRORS THE START ANGLE ABOUT THE X AXIS AND REVERSES THE SWEEP. A DXF point
        # at angle `a` lands at (Cx + r·cos a, −Cy − r·sin a), which with cy = −Cy is
        # (cx + r·cos(−a), cy + r·sin(−a)) — so the client-space start angle is −a0 and the
        # client-space sweep is −sweep, `Dxf.arc_points` having already resolved sweep as the
        # POSITIVE counter-clockwise run from a0 to a1. Spelled `(360 - a0) % 360` rather than
        # `-a0 % 360` because the latter answers −0.0 for a0 = 0: the same angle, put on the wire
        # as a negative zero.
        #
        # A NEGATIVE DELTA IS WHAT MAKES THE CLIENT'S SWEEP FLAG 0 — the direction `Dxf.arc_svg`
        # writes for the thumbnail, and the one a review of 3,960 real arcs confirmed. A POSITIVE
        # delta here draws the complementary arc: same endpoints, wrong side.
        Geometry.arc_curve(cx, cy, r, (360 - curve[:a0]) % 360, -curve[:sweep])
      end
    end
  end
end
