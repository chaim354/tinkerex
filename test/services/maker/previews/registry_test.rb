require "test_helper"

module Maker
  module Previews
    class RegistryTest < ActiveSupport::TestCase
      test "resolves the SVG renderer by extension (case-insensitive, dot-tolerant)" do
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("svg")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("SVG")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for(".svg")
      end

      test "resolves the Phase-2 renderers by extension" do
        assert_equal Maker::Previews::Lbrn2,   Maker::Previews::Registry.for("lbrn2")
        assert_equal Maker::Previews::Lbrn2,   Maker::Previews::Registry.for("lbrn")
        assert_equal Maker::Previews::Dxf,     Maker::Previews::Registry.for("dxf")
        assert_equal Maker::Previews::ThreeMf, Maker::Previews::Registry.for("3mf")
      end

      test "resolves obj/STEP/IGES to the F3D Mesh renderer, and STL to the euc Stl renderer" do
        %w[obj step stp iges igs].each do |ext|
          assert_equal Maker::Previews::Mesh, Maker::Previews::Registry.for(ext), ext
        end
        # STL uses the pure-CPU euc rasterizer (no GL/Mesa), not F3D.
        assert_equal Maker::Previews::Stl, Maker::Previews::Registry.for("stl")
      end

      test "returns nil for an unsupported extension" do
        assert_nil Maker::Previews::Registry.for("sldprt")
        assert_nil Maker::Previews::Registry.for("dwg")
        assert_nil Maker::Previews::Registry.for(nil)
      end

      test "for_filename derives the extension from a filename or node path" do
        assert_equal Maker::Previews::Svg,   Maker::Previews::Registry.for_filename("drawing.SVG")
        assert_equal Maker::Previews::Mesh,  Maker::Previews::Registry.for_filename("part.STEP")
        assert_nil Maker::Previews::Registry.for_filename("part.sldprt")
      end
    end
  end
end
