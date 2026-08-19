module Maker
  module Previews
    # DXF (.dxf) -> the Measure view's geometry payload.
    #
    # The thin half of the DXF measure leg: `Dxf.each_geometry` does the reading, `Geometry` owns
    # the payload's shape, and this module is only the two things that belong to neither — putting
    # the points into the client's space (millimetres, Y-down) and answering what colour each
    # layer is.
    #
    # THE SAME TRAVERSAL THE THUMBNAIL USES. See `Dxf.each_geometry`: a second parse here would be
    # free to drift from the picture beside it, which is §14b's `LbrnMetadata` bug.
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
          Dxf.each_geometry(dxf_bytes) do |layer, points, closed, _curve, object_id|
            out.add(layer:, points: to_client_space(points, scale), closed:, object_id:)
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
    end
  end
end
