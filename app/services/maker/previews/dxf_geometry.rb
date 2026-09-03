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

      def build(dxf_bytes)
        pairs = Dxf.tokenize(dxf_bytes)
        scale = Dxf.mm_per_unit(pairs)
        colors = Dxf.layer_colors(pairs)

        Geometry.build(colors: ->(layers) { layers.to_h { |l| [ l, colors[l] ] } }) do |out|
          Dxf.each_geometry(pairs) do |layer, points, closed, curve, object_id|
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

        x0, y0 = arc_endpoint(curve, curve[:a0], scale)
        x1, y1 = arc_endpoint(curve, curve[:a1], scale)
        # THE SWEEP FLAG IS 0 BECAUSE THE Y-FLIP REVERSES ORIENTATION: DXF sweeps counter-clockwise
        # from a0 to a1, which is clockwise once drawn. `Dxf.arc_svg` writes the same 0 for the
        # same reason. A 1 here draws the complementary arc — same endpoints, wrong side.
        Geometry.arc_curve(x0, y0, x1, y1, r, curve[:sweep] > 180 ? 1 : 0, 0)
      end

      # One end of an arc, in client space. Computed from the centre and the angle rather than
      # taken from the flattened points, so the endpoint is the arc's true one and not its first
      # sample — the same reason every reported number comes from full-resolution data.
      def arc_endpoint(curve, degrees, scale)
        t = degrees * Math::PI / 180
        [ (curve[:cx] + (curve[:r] * Math.cos(t))) * scale,
          -(curve[:cy] + (curve[:r] * Math.sin(t))) * scale ]
      end
    end
  end
end
