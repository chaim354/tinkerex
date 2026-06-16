require "test_helper"

module Maker
  module Previews
    class DxfTest < ActiveSupport::TestCase
      setup { @dxf = File.binread(Rails.root.join("test/fixtures/files/sample.dxf")) }

      test "is available whenever the SVG path is (pure-Ruby DXF→SVG, no native dep)" do
        assert_equal Maker::Previews::Svg.available?, Maker::Previews::Dxf.available?
      end

      test "renders to an SVG asset (delegates to the SVG renderer)" do
        result = Maker::Previews::Dxf.render(@dxf, size: 512)
        assert_equal "image/svg+xml", result[:content_type]
        assert_includes result[:bytes], "<svg"
      end

      test "maps LINE / CIRCLE / LWPOLYLINE / ARC entities to SVG primitives" do
        svg = Maker::Previews::Dxf.to_svg(@dxf)
        assert_includes svg, "<line"
        assert_includes svg, "<circle"
        assert_includes svg, "<polygon" # the fixture's LWPOLYLINE is closed (code 70=1)
        assert_includes svg, "<path"    # ARC → path arc
      end

      test "tokenize pairs group codes with their values" do
        pairs = Maker::Previews::Dxf.tokenize(@dxf)
        assert_includes pairs, [ 0, "LINE" ]
        assert_includes pairs, [ 10, "0.0" ]
      end

      test "parse_entities only collects known entity types" do
        entities = Maker::Previews::Dxf.parse_entities(Maker::Previews::Dxf.tokenize(@dxf))
        types = entities.map { |e| e[:type] }
        assert_equal %w[LINE CIRCLE LWPOLYLINE ARC], types
      end

      test "sizes the viewBox to the entity bounding box" do
        svg = Maker::Previews::Dxf.to_svg(@dxf)
        assert_match(/viewBox="[-\d. ]+"/, svg)
      end

      test "a DXF with no drawable entities still produces a valid SVG (does not crash)" do
        empty = "0\nSECTION\n2\nENTITIES\n0\nENDSEC\n0\nEOF\n"
        svg = Maker::Previews::Dxf.to_svg(empty)
        assert_includes svg, "<svg"
      end
    end
  end
end
