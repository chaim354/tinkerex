require "test_helper"

module Maker
  module Previews
    # AN HTML FILE'S TILE IS ONE FIXED DRAWING (spec 2026-11-20-html-thumbnail-design.md). The
    # renderer is handed the page's bytes like every other and must never read them: two different
    # pages are the same picture.
    class HtmlThumbTest < ActiveSupport::TestCase
      test "claims .html and nothing else, from the vocabulary" do
        assert_equal Maker::FileAttachment::HTML_EXTS, HtmlThumb::EXTENSIONS
        assert_equal %w[html], HtmlThumb::EXTENSIONS
      end

      test "every HTML file gets the same picture, whatever the page holds" do
        skip "resvg is not on this box" unless HtmlThumb.available?

        a = HtmlThumb.render("<!doctype html><title>Walnut PC Case</title><p>case</p>", size: 64)
        b = HtmlThumb.render("<p>a different page entirely</p>", size: 64)
        assert_equal "image/png", a[:content_type]
        assert_equal [ 64, 64 ], [ a[:width], a[:height] ]
        assert a[:bytes].start_with?("\x89PNG".b), "not a PNG"
        assert_equal a[:bytes], b[:bytes], "the drawing must not depend on the page"
      end

      # THE `</>` IS STROKES, NOT TEXT: a glyph is whatever face the box resolves, and the first
      # render on a Mac with no DejaVu came out in some other font. Strokes draw the same anywhere.
      test "the drawing is a window with a code mark, scaled from one 512 grid, and uses no font" do
        svg = HtmlThumb.to_svg(128)
        assert_includes svg, %(width="128" height="128" viewBox="0 0 512 512")
        assert_equal 2, svg.scan("<polyline").size, "the < and the >"
        assert_equal 2, svg.scan("<line").size, "the title-bar rule and the /"
        assert_not_includes svg, "<text", "a glyph depends on the box's fonts"
      end

      # GERBER'S CASE (gerber_test.rb): the rasterizer's default stylesheet pins EVERY stroke to
      # 1.5px for hairline CAD sources, and this drawing's widths are real — the first render came
      # out a hairline window. Pinned here because only the caller can be wrong: flip `stylesheet:
      # nil` back to the default and svg_rasterizer_test.rb stays green.
      test "render does not apply the hairline stylesheet" do
        skip "resvg is not on this box" unless HtmlThumb.available?

        hairlined = SvgRasterizer.to_png(HtmlThumb.to_svg(128), size: 128, stylesheet: SvgRasterizer::STYLESHEET)
        assert_not_equal hairlined, HtmlThumb.render("", size: 128)[:bytes],
                         "HtmlThumb.render is applying the hairline stylesheet: a 1.5px window"
      end
    end
  end
end
