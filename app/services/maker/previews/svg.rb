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

      # Returns { bytes:, content_type:, width:, height: } — a size×size PNG.
      def render(svg_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(svg_bytes, size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end
    end
  end
end
