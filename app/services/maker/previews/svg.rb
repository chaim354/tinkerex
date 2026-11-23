module Maker
  module Previews
    # SVG (`.svg`) -> PNG thumbnail.
    #
    # An SVG is browser-renderable, but we deliberately DO NOT serve it verbatim: the web layer
    # treats user SVG as an XSS vector (SVG can carry <script>) and refuses to inline it, and the
    # grid wants one uniform raster type. So we rasterize to PNG via SvgRasterizer (resvg). Dxf,
    # Lbrn2 and Mage build an SVG and delegate to `rasterize`, so that is the single 2D-vector
    # rasterize point.
    #
    # `available?` gates on the rasterizer -> a box without resvg degrades .svg/.dxf/.lbrn to
    # `unsupported` (a non-error terminal state), same as Stl/Mesh without their binaries.
    module Svg
      module_function

      EXTENSIONS = %w[svg].freeze

      def available? = Maker::Previews::SvgRasterizer.available?

      # THE MEASURE PAYLOAD NEEDS NO RASTERIZER — see `Maker::Previews::Registry.available_for?`, which
      # is what asks. `available?` stays the answer for the thumbnail (and for the registry
      # contract, which is about rendering an image), so a box without resvg still measures.
      def available_for?(kind) = kind == "geometry" || available?

      # Which build produced a stored artifact — see `Enqueue.revision_for`. PER KIND, so bumping
      # the measure payload does not re-rasterize every SVG thumbnail in the library.
      #
      #   1  original (thumbnail)
      #   2  the row stores the drawing's size (Maker::Previews::Dimensions) for the facts list and the
      #      Material estimate tool. The picture's bytes do not move; the bump is for the metadata.
      #      The no-viewBox unit fix (`SvgGeometry::FORMAT_REVISION` 2 -> 3) moved that size in the
      #      same unmerged branch and DELIBERATELY rides this bump: no deployment had stamped a 2.
      THUMBNAIL_REVISION = 2

      def payload_revision(kind)
        kind == "geometry" ? Maker::Previews::SvgGeometry::PAYLOAD_REVISION : THUMBNAIL_REVISION
      end

      # `kind` selects the ARTIFACT, mirroring Lbrn2's, Mage's and Dxf's branch.
      #
      # THE GEOMETRY ARM DOES NOT NEED resvg, while `available?` reports on exactly that — which
      # is why `available_for?` exists above and why the job asks IT rather than `available?`.
      #
      # THE THUMBNAIL OF AN .svg FILE carries its drawing's size, measured by the same traversal as
      # the Measure payload (`Dimensions.metadata_for`, which never raises). Only this entry adds it:
      # the formats that generate an SVG and rasterize it call `rasterize` below.
      def render(svg_bytes, size: 512, kind: "thumbnail")
        return Maker::Previews::SvgGeometry.render(svg_bytes) if kind == "geometry"

        rasterize(svg_bytes, size:).merge(metadata: Maker::Previews::Dimensions.metadata_for(svg_bytes, ext: "svg"))
      end

      # THE BARE RASTERIZE, AND THE DELEGATE TARGET for Dxf, Lbrn2 and Mage, which build an SVG of
      # their own file and rasterize it here. IT CARRIES NO METADATA, AND MUST NOT: a size measured
      # off a GENERATED document describes that document — a DXF's units are resolved before it, a
      # LightBurn bed frame is in it — not the file the row belongs to. Each delegate states its own.
      def rasterize(svg_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(svg_bytes, size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end
    end
  end
end
