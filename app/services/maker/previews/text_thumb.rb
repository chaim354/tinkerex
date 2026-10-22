module Maker
  module Previews
    # Text file (every extension in Maker::FileAttachment::TEXT_EXTENSIONS) → a "document" PNG grid
    # thumbnail: the file's first lines drawn as monospace text in the palette's ink on a white page
    # (`Maker::Previews::Palette` — the browser multiplies the page onto the themed card, so the
    # page is exactly `PAPER`, and `INK` is the only other colour it draws). Built as an SVG and
    # rasterized through the SAME resvg step the SVG/DXF/LightBurn thumbnails use (SvgRasterizer) —
    # so NO new binary, and the grid gets a uniform PNG like every other cell. The deployed
    # image already ships DejaVu fonts + fontconfig, so resvg can draw the glyphs.
    #
    # These already preview in the DETAIL view as scrollable raw text; this is only the GRID's
    # at-a-glance thumbnail. `available?` gates on resvg, exactly like Svg.
    module TextThumb
      module_function

      # DERIVED FROM THE ONE VOCABULARY, never listed here (§14d). This was a hand-written
      # `%w[txt md markdown json]` while `FilesController#preview_kind` answered `:text` for 37
      # extensions — so 33 of them rendered the source viewer on the detail page and NOTHING in
      # the grid. Both layers now read the same constant, so the set cannot drift again, and
      # adding an extension is still a one-line edit to ROLE_BY_EXT.
      #
      # A TEXT EXTENSION WITH A RICHER RENDERER IS NOT THIS RENDERER'S TO CLAIM — `Registry`
      # merges its explicit format table OVER these, and `renderer_contract_test.rb` turns red if
      # that ever happens, rather than letting a shadowed claim sit here reading as coverage.
      EXTENSIONS = Maker::FileAttachment::TEXT_EXTENSIONS

      MAX_LINES = 16
      MAX_COLS  = 46 # ~fits a 512px page at the font size below; longer lines clip at the edge

      # WHICH BUILD OF THIS RENDERER PRODUCED A STORED THUMBNAIL (§14h). Text is the bulk of most
      # libraries (~3,300 rows on the live share box), and a finished file's content never changes,
      # so a picture change with no bump here is served from the old render forever.
      #
      #   1 -> (undeclared — `Enqueue::BASE_REVISION`) white page, cool `#1c2230` ink.
      #   2 -> the palette's ink on paper (2026-10-21): `Palette::PAPER` and `Palette::INK`; was a
      #        cool #1c2230.
      THUMBNAIL_REVISION = 2

      # One kind (`thumbnail`); the signature matches the measurable renderers' so
      # `Enqueue.revision_for` has one way to ask.
      def payload_revision(_kind) = THUMBNAIL_REVISION

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
          <rect width="#{size}" height="#{size}" fill="#{Palette::PAPER}"/>
          <g font-family="DejaVu Sans Mono, monospace" font-size="#{fs}" fill="#{Palette::INK}" xml:space="preserve">#{rows}</g>
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
