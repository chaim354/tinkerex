require "test_helper"

module Maker
  module Previews
    class SvgTest < ActiveSupport::TestCase
      setup { @svg = File.binread(Rails.root.join("test/fixtures/files/square.svg")) }

      test "is always available (no native rasterizer needed — SVG is browser-renderable)" do
        assert Maker::Previews::Svg.available?
      end

      test "stores the SVG bytes verbatim as an image/svg+xml asset" do
        result = Maker::Previews::Svg.render(@svg, size: 512)
        assert_equal "image/svg+xml", result[:content_type]
        assert_equal @svg.b, result[:bytes].b
      end

      test "reports natural dimensions when present in the SVG" do
        result = Maker::Previews::Svg.render(@svg, size: 512)
        assert_equal 100, result[:width]
        assert_equal 100, result[:height]
      end

      test "dimensions are nil when the SVG has no width/height" do
        bare = %(<svg xmlns="http://www.w3.org/2000/svg"><rect width="1" height="1"/></svg>)
        result = Maker::Previews::Svg.render(bare, size: 512)
        assert_nil result[:width]
        assert_nil result[:height]
      end
    end
  end
end
