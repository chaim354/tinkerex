module Maker
  module Previews
    # Phase-1 renderer: SVG.
    #
    # An SVG is itself a browser-renderable image, so the MVP stores the SVG bytes VERBATIM
    # as the preview asset (content_type image/svg+xml) and marks the preview ready — NO
    # rasterization, hence NO native dependency. This keeps the pipeline green on a box with
    # no SVG rasterizer installed.
    #
    # TODO (deferred — see renderer registry seam): a true PNG thumbnail via the `resvg` CLI
    # (MIT/Apache, pure-Rust) + image_processing (~> 2.0, already in the Gemfile). When that
    # toolchain is available, `available?` would gate on the binary and `render` would emit a
    # square PNG. See docs/research-format-processing.md §4 and docs/.../preview-pipeline.md.
    module Svg
      module_function

      # Pure-Ruby, no external binary → always available in the MVP.
      def available? = true

      EXTENSIONS = %w[svg].freeze

      # Returns { bytes:, content_type:, width:, height: }. width/height are the SVG's
      # natural pixel dimensions when declared on the root element, else nil.
      def render(svg_bytes, size: 512)
        bytes = svg_bytes.b
        w, h = natural_dimensions(bytes)
        { bytes:, content_type: "image/svg+xml", width: w, height: h }
      end

      # Cheap regex sniff of the root <svg width=".." height=".."> (integer px only). No XML
      # parse / no native dep; nil when absent or non-integer (e.g. "100%").
      def natural_dimensions(bytes)
        head = bytes[0, 2048].to_s
        w = head[/<svg\b[^>]*\bwidth\s*=\s*["'](\d+)/i, 1]
        h = head[/<svg\b[^>]*\bheight\s*=\s*["'](\d+)/i, 1]
        [ w&.to_i, h&.to_i ]
      end
    end
  end
end
