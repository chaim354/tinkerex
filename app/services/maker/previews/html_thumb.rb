module Maker
  module Previews
    # AN HTML FILE'S GRID THUMBNAIL IS ONE FIXED DRAWING, NOT ITS SOURCE (2026-11-20; spec
    # docs/superpowers/specs/2026-11-20-html-thumbnail-design.md). The owner chose it: an ink
    # browser window, three dots in its title bar, an orange `</>`. The first sixteen lines of a
    # page — a doctype, a <meta>, a stylesheet — say nothing about what it draws, and a real
    # screenshot would mean running the page on the server.
    #
    # IT NEVER READS THE BYTES. `render` takes them because every renderer does (Registry's
    # contract); the picture is the same for every page, and `html_thumb_test.rb` renders two
    # different pages to prove it.
    #
    # Drawn on a 512 grid on a PURE-WHITE ground (Palette::PAPER — design-system.md rule 5: the
    # card's colour comes through by multiply) and rasterised by the same resvg step TextThumb uses,
    # so no new binary. `DejaVu Sans Mono` is the face the image already ships for TextThumb.
    module HtmlThumb
      module_function

      # DERIVED FROM THE ONE VOCABULARY (§14d), and claimed OVER TextThumb: Registry merges
      # FORMAT_RENDERERS on top, and TextThumb::EXTENSIONS subtracts this list.
      EXTENSIONS = Maker::FileAttachment::HTML_EXTS

      # Decoration of this one drawing, not palette colours: the second and third title-bar dots.
      AMBER = "#e0a526".freeze
      SAGE = "#6b8f5e".freeze

      # NEVER 1, 2 OR 3 (§14h). Before this renderer, TextThumb drew every HTML tile and stamped it
      # with ITS revision: 1, then 2, and 3 while the Shop manual redesign (0edba844) was deployed,
      # before its revert (7b04b903) took TextThumb back to 2. A stored row is current when its
      # revision EQUALS the renderer's (`Enqueue.revision_current?`), so any of those here serves a
      # source-text picture forever. This shipped at 3 and one HTML tile on share kept the
      # redesign's picture (measured 2026-11-20); at 4 every one of them is stale and redraws.
      # `thumbnail_revision_test.rb`'s BURNED table holds all three.
      THUMBNAIL_REVISION = 4

      def payload_revision(_kind) = THUMBNAIL_REVISION

      def available? = Maker::Previews::SvgRasterizer.available?

      # size×size PNG of the drawing. Returns { bytes:, content_type:, width:, height: }.
      #
      # `stylesheet: nil`, GERBER'S OPT-OUT: the rasterizer's default stylesheet pins every stroke
      # to 1.5px for hairline CAD sources, and this drawing's widths are real — through it, the
      # window came out a hairline. Pinned in html_thumb_test.rb.
      def render(_bytes, size: 512)
        png = Maker::Previews::SvgRasterizer.to_png(to_svg(size), size:, stylesheet: nil)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      # The `</>` is two chevrons and a slash in round-capped strokes, NEVER a <text>: a glyph is
      # whatever face the box resolves, and strokes draw the same picture everywhere.
      def to_svg(size)
        <<~SVG
          <svg xmlns="http://www.w3.org/2000/svg" width="#{size}" height="#{size}" viewBox="0 0 512 512">
          <rect width="512" height="512" fill="#{Palette::PAPER}"/>
          <rect x="76" y="112" width="360" height="292" rx="30" fill="#{Palette::PAPER}" stroke="#{Palette::INK}" stroke-width="16"/>
          <line x1="76" y1="176" x2="436" y2="176" stroke="#{Palette::INK}" stroke-width="12"/>
          <circle cx="120" cy="144" r="11" fill="#{Palette::ACCENT}"/>
          <circle cx="154" cy="144" r="11" fill="#{AMBER}"/>
          <circle cx="188" cy="144" r="11" fill="#{SAGE}"/>
          <g fill="none" stroke="#{Palette::ACCENT}" stroke-width="22" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="208,250 162,292 208,334"/>
          <line x1="276" y1="238" x2="236" y2="346"/>
          <polyline points="304,250 350,292 304,334"/>
          </g>
          </svg>
        SVG
      end
    end
  end
end
