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
