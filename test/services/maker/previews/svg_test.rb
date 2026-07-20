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
    end
  end
end
