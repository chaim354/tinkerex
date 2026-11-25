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

      # THE SIZE MUST NOT COST THE PICTURE, EVEN WHEN MEASURING BLOWS THE STACK. A `SystemStackError`
      # is not a `StandardError`, and it escaped `Dimensions.metadata_for` and the job's rescue both.
      #
      # THE OVERFLOW IS RAISED HERE, NOT PROVOKED. resvg must draw this file and stops at 1024
      # levels, while a job thread's walk overflows at 993 groups on the Linux CI runners (831 on the
      # Mac, measured 2026-11-24). So every nested file resvg still draws sits a few groups from the
      # measurer's edge, which is where this test sat at 1000 and where `DimensionsTest`'s twin of it
      # flaked (tinkerex#593). `DimensionsTest` overflows the walk for real, at a depth resvg is never
      # asked to draw. `plate` measures 80 x 40 above, so the nil below is the rescue's doing.
      test "an SVG whose measurer overflows the stack still gets its thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

        calls = 0
        overflow = ->(*) { calls += 1; raise SystemStackError, "stack level too deep" }
        result = replacing(Maker::Previews::SvgGeometry, :build, overflow) do
          Maker::Previews::Svg.render(plate, size: 32, kind: "thumbnail")
        end

        assert_equal 1, calls, "the measurer never ran, so nothing here was rescued"
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
        assert_nil result[:metadata]
      end

      private

      def replacing(owner, name, replacement)
        mod = owner.singleton_class
        own = mod.instance_methods(false).include?(name)
        original = mod.instance_method(name)
        mod.define_method(name, &replacement)
        yield
      ensure
        own ? mod.define_method(name, original) : mod.remove_method(name)
      end
    end
  end
end
