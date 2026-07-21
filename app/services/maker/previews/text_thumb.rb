module Maker
  module Previews
    # Text file (txt/md/markdown/json) → a "document" PNG grid thumbnail: the file's first lines drawn
    # as monospace text on a white page. Built as an SVG and rasterized through the SAME resvg step the
    # SVG/DXF/LightBurn thumbnails use (SvgRasterizer) — so NO new binary, and the grid gets a uniform
    # PNG like every other cell. The deployed image already ships DejaVu fonts + fontconfig, so resvg
    # can draw the glyphs.
    #
    # These already preview in the DETAIL view as scrollable raw text; this is only the GRID's
    # at-a-glance thumbnail. `available?` gates on resvg, exactly like Svg.
    module TextThumb
      module_function

      EXTENSIONS = %w[txt md markdown json].freeze

      MAX_LINES = 16
      MAX_COLS  = 46 # ~fits a 512px page at the font size below; longer lines clip at the edge

      def available? = Maker::Previews::SvgRasterizer.available?

      # size×size PNG of the file's first lines. Returns { bytes:, content_type:, width:, height: }.
      def render(bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(to_svg(bytes, size), size:)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      def to_svg(bytes, size)
        pad = (size * 0.055).round
        fs  = [ (size / 30.0).round, 1 ].max # font size
        lh  = (fs * 1.45).round              # line height
        rows = text_lines(bytes).each_with_index.map do |line, i|
          %(<text x="#{pad}" y="#{pad + fs + i * lh}">#{xml_escape(line)}</text>)
        end.join
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="0 0 #{size} #{size}">
          <rect width="#{size}" height="#{size}" fill="#ffffff"/>
          <g font-family="DejaVu Sans Mono, monospace" font-size="#{fs}" fill="#1c2230" xml:space="preserve">#{rows}</g>
          </svg>
        SVG
      end

      # First MAX_LINES lines, each clipped to MAX_COLS: tabs expanded, control chars dropped (by
      # codepoint, keeping normal printable text), coerced to valid UTF-8 (a maker's file may be
      # latin-1 or binary-ish).
      def text_lines(bytes)
        text = bytes.to_s.dup.force_encoding("UTF-8")
        text = text.scrub("?") unless text.valid_encoding?
        text.split("\n", MAX_LINES + 1).first(MAX_LINES).map do |line|
          printable = line.tr("\t", "  ").chars.reject { |c| c.ord < 32 || c.ord == 127 }.join
          printable[0, MAX_COLS].to_s
        end
      end

      def xml_escape(str)
        str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
      end
    end
  end
end
