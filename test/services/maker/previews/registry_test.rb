require "test_helper"

module Maker
  module Previews
    class RegistryTest < ActiveSupport::TestCase
      test "resolves the SVG renderer by extension (case-insensitive, dot-tolerant)" do
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("svg")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for("SVG")
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for(".svg")
      end

      test "returns nil for an unsupported extension" do
        assert_nil Maker::Previews::Registry.for("sldprt")
        assert_nil Maker::Previews::Registry.for("stl")
        assert_nil Maker::Previews::Registry.for(nil)
      end

      test "for_filename derives the extension from a filename or node path" do
        assert_equal Maker::Previews::Svg, Maker::Previews::Registry.for_filename("drawing.SVG")
        assert_nil Maker::Previews::Registry.for_filename("model.stl")
      end
    end
  end
end
