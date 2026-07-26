require "test_helper"

module Maker
  module Previews
    class Lbrn2Test < ActiveSupport::TestCase
      setup { @lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2")) }

      test "is available whenever the SVG path is (pure-Ruby XML→SVG, no native dep)" do
        assert_equal Maker::Previews::Svg.available?, Maker::Previews::Lbrn2.available?
      end

      test "render falls back to the geometry parser (PNG) when there is no embedded thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?

        # The fixture has no <Thumbnail>, so this exercises the geometry -> SVG -> PNG fallback.
        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
      end

      test "render uses the embedded thumbnail when the LightBurn file carries one" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        with_thumb = %(<LightBurnProject><Thumbnail Source="#{png_b64}"/><Shape Type="Rect" W="1" H="1"/></LightBurnProject>)
        result = Maker::Previews::Lbrn2.render(with_thumb, size: 512)
        assert_equal "image/png", result[:content_type]
        assert_equal 1, result[:width], "the embedded 1x1 PNG is returned verbatim, not a re-render"
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

      test "render attaches parsed metadata alongside the image (geometry path)" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?
        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_kind_of Hash, result[:metadata]
        assert result[:metadata]["layers"].present?, "layers parsed from the fixture"
      end

      test "render attaches metadata even when the embedded thumbnail is used" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        xml = %(<LightBurnProject AppVersion="1.7.00"><Thumbnail Source="#{png_b64}"/>) +
              %(<CutSetting type="Cut"><index Value="0"/><speed Value="12"/><color Value="255"/></CutSetting>) +
              %(<Shape Type="Rect" CutIndex="0" W="5" H="5" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        result = Maker::Previews::Lbrn2.render(xml, size: 512)
        assert_equal 1, result[:width], "embedded 1x1 PNG returned verbatim"
        assert_equal "1.7.00", result[:metadata]["app_version"], "metadata parsed from XML regardless of image path"
      end
    end
  end
end
