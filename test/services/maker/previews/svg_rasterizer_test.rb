require "test_helper"

module Maker
  module Previews
    class SvgRasterizerTest < ActiveSupport::TestCase
      SQUARE = %(<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" viewBox="0 0 10 10"><rect width="10" height="10" fill="#000"/></svg>).freeze

      test "available? reflects whether the resvg binary is runnable" do
        assert_includes [ true, false ], Maker::Previews::SvgRasterizer.available?
      end

      test "to_png returns real PNG bytes (magic header) at the requested size" do
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?

        png = Maker::Previews::SvgRasterizer.to_png(SQUARE, size: 64)
        assert_equal "\x89PNG\r\n\x1A\n".b, png[0, 8].b, "expected a PNG signature"
        assert_operator png.bytesize, :>, 0
      end

      # A HAIRLINE STROKE IS WHAT THE STYLESHEET EXISTS FOR, so it is what proves the flag is
      # really omitted: at 0.02 units in a 100-unit viewBox this line is sub-pixel at 64px and the
      # default render pins it to 1.5 device pixels, while `stylesheet: nil` leaves it as drawn.
      # Two different pictures, therefore two different byte strings.
      #
      # ASSERTING THE BYTES, NOT THE ARGV, is deliberate: an argv assertion passes for a `--stylesheet`
      # pointing at an empty file, which is a different claim (see `to_png`'s own comment).
      HAIRLINE = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><path d="M10 50 L90 50" stroke="#000" stroke-width="0.02" fill="none"/></svg>).freeze

      test "stylesheet: nil renders without the hairline rule" do
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?

        default = Maker::Previews::SvgRasterizer.to_png(HAIRLINE, size: 64)
        bare    = Maker::Previews::SvgRasterizer.to_png(HAIRLINE, size: 64, stylesheet: nil)

        assert_equal "\x89PNG\r\n\x1A\n".b, bare[0, 8].b, "expected a PNG signature"
        assert_not_equal default, bare,
                         "the --stylesheet flag is still being passed — a caller with real stroke " \
                         "widths (Maker::Previews::Gerber) cannot opt out"
      end

      test "malformed SVG raises RasterizeError, not an arbitrary exception" do
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?

        assert_raises(Maker::Previews::SvgRasterizer::RasterizeError) do
          Maker::Previews::SvgRasterizer.to_png("not an svg at all", size: 64)
        end
      end

      test "a missing binary makes available? false and to_png raise RasterizeError" do
        original = ENV["RESVG_BIN"]
        ENV["RESVG_BIN"] = "/nonexistent/resvg-binary"
        Maker::Previews::SvgRasterizer.reset_bin!
        assert_not Maker::Previews::SvgRasterizer.available?
        assert_raises(Maker::Previews::SvgRasterizer::RasterizeError) do
          Maker::Previews::SvgRasterizer.to_png("<svg/>", size: 64)
        end
      ensure
        ENV["RESVG_BIN"] = original
        Maker::Previews::SvgRasterizer.reset_bin!
      end
    end
  end
end
