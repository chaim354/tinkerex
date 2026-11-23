require "test_helper"

module Maker
  module Previews
    class SvgTest < ActiveSupport::TestCase
      setup { @svg = File.binread(Rails.root.join("test/fixtures/files/square.svg")) }

      test "available? mirrors the resvg rasterizer" do
        assert_equal Maker::Previews::SvgRasterizer.available?, Maker::Previews::Svg.available?
      end

      test "renders the SVG to a PNG thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        result = Maker::Previews::Svg.render(@svg, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
        assert_equal 256, result[:width]
        assert_equal 256, result[:height]
      end

      def plate = File.binread(Rails.root.join("test/fixtures/files/plate.svg"))

      # THE ABSOLUTE PIN, as GEOMETRY_REVISIONS pins the payloads: 2 is "the row stores the drawing's
      # size". A forgotten bump leaves every stored SVG thumbnail without one, forever (§14h).
      test "the thumbnail is at revision 2, the build that stores the drawing's size" do
        assert_equal 2, Maker::Previews::Svg::THUMBNAIL_REVISION
      end

      test "the thumbnail carries the drawing's size, not the canvas's" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        result = Maker::Previews::Svg.render(plate, size: 64)
        assert_equal "image/png", result[:content_type]
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } }, result[:metadata])
      end

      # THE DELEGATE RULE'S GUARD. Dxf, Lbrn2 and Mage rasterize an SVG they GENERATED; a size
      # measured off that document describes the wrong thing (a DXF's units are resolved before it,
      # a LightBurn bed frame is in it). Their own `render` merges their metadata over it today, which
      # is exactly why only this assertion can see the rule break.
      test "the bare rasterize carries no size, because a delegate's SVG is not the file" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        refute Maker::Previews::Svg.rasterize(plate, size: 64).key?(:metadata)
      end

      test "a drawing with nothing to measure still gets its thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        empty = %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm" viewBox="0 0 10 10"></svg>)
        result = Maker::Previews::Svg.render(empty, size: 32)
        assert_equal "image/png", result[:content_type]
        assert_nil result[:metadata]
      end

      # THE SIZE MUST NOT COST THE PICTURE, EVEN WHEN MEASURING BLOWS THE STACK. 1000 nested groups
      # overflow `SvgGeometry`'s walk in a Thread, where Solid Queue runs the job (about 830 deep,
      # measured 2026-11-23), and a `SystemStackError` is not a `StandardError` — it escaped
      # `Dimensions.metadata_for` and the job's rescue both. resvg draws the file: its own limit is
      # 1024 levels, so this depth is inside the window where only the measurer fails.
      test "an SVG nested deep enough to overflow the measurer still gets its thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        depth = 1000
        nested = %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm" viewBox="0 0 10 10">) +
                 ("<g>" * depth) + %(<rect width="5" height="5"/>) + ("</g>" * depth) + %(</svg>)
        result = Thread.new { Maker::Previews::Svg.render(nested, size: 32, kind: "thumbnail") }.value

        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
        assert_nil result[:metadata]
      end
    end
  end
end
