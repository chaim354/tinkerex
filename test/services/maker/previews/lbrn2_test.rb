require "test_helper"

module Maker
  module Previews
    class Lbrn2Test < ActiveSupport::TestCase
      setup { @lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2")) }

      test "is available whenever the SVG path is (pure-Ruby XML→SVG, no native dep)" do
        assert_equal Maker::Previews::Svg.available?, Maker::Previews::Lbrn2.available?
      end

      test "render produces a PNG thumbnail (delegates to the SVG rasterizer)" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?

        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
      end

      test "maps Rect / Ellipse / Line shapes into SVG primitives" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        assert_includes svg, "<polygon"  # Rect → polygon
        assert_includes svg, "<ellipse"
        assert_includes svg, "<polyline" # Line → polyline
      end

      test "applies CutSetting colors per CutIndex" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        # CutIndex 0 → color 255 (0x0000FF packed little-endian) → red #ff0000.
        assert_includes svg, "#ff0000"
        # CutIndex 1 → color 65280 (0x00FF00) → green #00ff00.
        assert_includes svg, "#00ff00"
      end

      test "sizes the viewBox to the shapes' bounding box" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        assert_match(/viewBox="[-\d. ]+"/, svg)
      end

      test "normalize_color handles packed ints and hex strings" do
        assert_equal "#ff0000", Maker::Previews::Lbrn2.normalize_color("255")
        assert_equal "#00ff00", Maker::Previews::Lbrn2.normalize_color("65280")
        assert_equal "#abcdef", Maker::Previews::Lbrn2.normalize_color("#abcdef")
        assert_equal "#000000", Maker::Previews::Lbrn2.normalize_color(nil)
      end

      test "an empty project still produces a valid SVG (does not crash)" do
        empty = %(<?xml version="1.0"?><LightBurnProject></LightBurnProject>)
        svg = Maker::Previews::Lbrn2.to_svg(empty)
        assert_includes svg, "<svg"
      end

      test "raises ParseError on input that is not XML at all" do
        assert_raises(Maker::Previews::Lbrn2::ParseError) do
          Maker::Previews::Lbrn2.to_svg("\x00\x01\x02 not xml".b)
        end
      end
    end
  end
end
