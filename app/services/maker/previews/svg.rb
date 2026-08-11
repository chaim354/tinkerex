module Maker
  module Previews
    # SVG (`.svg`) -> PNG thumbnail.
    #
    # An SVG is browser-renderable, but we deliberately DO NOT serve it verbatim: the web layer
    # treats user SVG as an XSS vector (SVG can carry <script>) and refuses to inline it, and the
    # grid wants one uniform raster type. So we rasterize to PNG via SvgRasterizer (resvg). Dxf and
    # Lbrn2 build an SVG and delegate here, so this is the single 2D-vector rasterize point.
    #
    # `available?` gates on the rasterizer -> a box without resvg degrades .svg/.dxf/.lbrn to
    # `unsupported` (a non-error terminal state), same as Stl/Mesh without their binaries.
    module Svg
      module_function

      EXTENSIONS = %w[svg].freeze

      def available? = Maker::Previews::SvgRasterizer.available?

      # THE MEASURE PAYLOAD NEEDS NO RASTERIZER — see `GeneratePreviewJob#available_for?`, which
      # is what asks. `available?` stays the answer for the thumbnail (and for the registry
      # contract, which is about rendering an image), so a box without resvg still measures.
      def available_for?(kind) = kind == "geometry" || available?

      # Which build produced a stored artifact — see `Enqueue.revision_for`. PER KIND, so bumping
      # the measure payload does not re-rasterize every SVG thumbnail in the library.
      #
      #   1  original (thumbnail)
      THUMBNAIL_REVISION = 1

      def payload_revision(kind)
        kind == "geometry" ? Maker::Previews::SvgGeometry::PAYLOAD_REVISION : THUMBNAIL_REVISION
      end

      # `kind` selects the ARTIFACT, mirroring Lbrn2's, Mage's and Dxf's branch.
      #
      # THE GEOMETRY ARM DOES NOT NEED resvg, while `available?` reports on exactly that — which
      # is why `available_for?` exists above and why the job asks IT rather than `available?`.
      #
      # NOTE THIS IS ALSO THE DELEGATE TARGET for Dxf and Lbrn2's thumbnail paths, which call
      # `Svg.render(svg_string, size:)` with no `kind:` — so the default must stay "thumbnail" or
      # both of those formats start returning JSON where the job expects a PNG.
      def render(svg_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::SvgGeometry.render(svg_bytes) if kind == "geometry"

        png = Maker::Previews::SvgRasterizer.to_png(svg_bytes, size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end
    end
  end
end
