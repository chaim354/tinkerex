require "test_helper"

module Maker
  module Previews
    # THE ONE MEASURER AND READER OF A FLAT FILE'S SIZE (spec 2026-11-22-material-estimate-design.md).
    # Every expected number is a literal measured off the fixture, so a change in what any traversal
    # reports shows up here as a number, not as "still returns a Hash".
    class DimensionsTest < ActiveSupport::TestCase
      def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))

      test "an SVG measures as its DRAWING, never its canvas" do
        # plate.svg's canvas is 100 x 60 mm; what it draws is 80 x 40. The canvas must not win.
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.measure("plate.svg", fixture("plate.svg")))
      end

      test "a DXF measures in millimetres through its own walk" do
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.measure("plate.dxf", fixture("plate.dxf")))
      end

      test "LightBurn and MillMage keep the size keys their metadata already stores" do
        assert_equal({ "job" => { "width" => 60.0, "height" => 40.0 } },
                     Dimensions.measure("nested-plate.lbrn2", fixture("nested-plate.lbrn2")))
        assert_equal({ "job" => { "width" => 100.0, "height" => 60.0 } },
                     Dimensions.measure("real-export.mage", fixture("real-export.mage")))
      end

      test "a multi-page file reads back one page per page, the saved one current, an empty one unsized" do
        facts = Dimensions.from_metadata(Dimensions.measure("pages.lbrn2", fixture("pages.lbrn2")))

        assert facts.multi_page?
        assert_equal [ "Page 1", "Back", "Page 3" ], facts.pages.map(&:name)
        assert_equal [ [ 205.0, 50.0 ], [ 50.0, 50.0 ], [ nil, nil ] ], facts.pages.map { |p| [ p.width, p.height ] }
        assert_equal [ false, true, false ], facts.pages.map(&:current)
        assert_equal [ "Page 1", "Back" ], facts.sized_pages.map(&:name)
      end

      test "a one-page file is one unnamed page" do
        facts = Dimensions.from_metadata({ "job" => { "width" => 12.5, "height" => 3.0 } })

        refute facts.multi_page?
        assert_equal [ [ nil, 12.5, 3.0, true ] ], facts.pages.map { |p| [ p.name, p.width, p.height, p.current ] }
      end

      test "the extension decides, case-insensitively" do
        assert Dimensions.measurable_name?("PLATE.SVG")
        assert Dimensions.measurable_name?("old.lbrn")
        refute Dimensions.measurable_name?("bracket.stl")
        refute Dimensions.measurable_name?("README")
        assert_equal 80.0, Dimensions.measure("PLATE.SVG", fixture("plate.svg"))["job"]["width"]
      end

      test "a file it cannot measure says why, in words a person reads" do
        cases = {
          [ "bracket.stl", "solid x" ]          => Dimensions::UNSUPPORTED,
          [ "broken.svg", "not xml at all" ]    => "not a readable SVG",
          [ "broken.lbrn2", "garbage" ]         => "not a readable LightBurn file",
          [ "broken.mage", "garbage" ]          => "not a readable MillMage file",
          [ "empty.svg", %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm"/>) ] => Dimensions::NO_SHAPES
        }
        cases.each do |(name, bytes), reason|
          error = assert_raises(Dimensions::Unmeasurable, name) { Dimensions.measure(name, bytes) }
          assert_equal reason, error.message, name
        end
      end

      test "metadata_for never raises, because a size must never cost a file its thumbnail" do
        assert_nil Dimensions.metadata_for("not xml at all", ext: "svg")
        assert_nil Dimensions.metadata_for("garbage", ext: "lbrn2")
        assert_equal({ "job" => { "width" => 80.0, "height" => 40.0 } },
                     Dimensions.metadata_for(fixture("plate.svg"), ext: "svg"))
      end

      # A STACK OVERFLOW IS NOT A `StandardError`, so "never raises" has to name it. `SvgGeometry`
      # recurses once per nested `<g>`; measured 2026-11-23, a Thread overflows at about 830 groups
      # and the main thread at about 1920, so the walk runs INSIDE A THREAD, as Solid Queue runs a
      # job — on the main thread 1000 groups measure fine and this would prove nothing. The first
      # assertion establishes that precondition rather than assuming it, so a box with a bigger
      # stack fails here by name instead of passing over a file that never overflowed.
      test "metadata_for survives an SVG nested deep enough to overflow a job thread's stack" do
        svg = nested_svg(DEEP_NESTING)
        overflowed = Thread.new do
          SvgGeometry.build(svg)
          false
        rescue SystemStackError
          true
        end.value
        assert overflowed, "#{DEEP_NESTING} nested groups no longer overflow a thread here; raise the depth"

        assert_nil Thread.new { Dimensions.metadata_for(svg, ext: "svg") }.value
      end

      test "from_metadata reads only two finite, non-negative numbers, at least one above zero" do
        assert_nil Dimensions.from_metadata(nil)
        assert_nil Dimensions.from_metadata("job")
        assert_nil Dimensions.from_metadata({})
        assert_nil Dimensions.from_metadata({ "job" => { "width" => 0, "height" => 0 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => "abc", "height" => 4 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => -3, "height" => 4 } })
        assert_nil Dimensions.from_metadata({ "job" => { "width" => Float::INFINITY, "height" => 4 } })
        # A straight line measures: 50 x 0 is a real extent, and the packer inflates it by the gap.
        assert_equal [ 50.0, 0.0 ], Dimensions.from_metadata({ "job" => { "width" => 50, "height" => 0 } })
                                              .pages.first.then { |p| [ p.width, p.height ] }
      end

      test "job_metadata wraps a size the caller already holds, or answers nil for an empty drawing" do
        assert_equal({ "job" => { "width" => 1.0, "height" => 2.0 } },
                     Dimensions.job_metadata({ "width" => 1.0, "height" => 2.0 }))
        assert_nil Dimensions.job_metadata(nil)
        assert_nil Dimensions.job_metadata({ "width" => 0.0, "height" => 0.0 })
      end

      # THE RECIPE DISCRIMINATOR (spec Part 1): metadata holding only a size is not a recipe, so an
      # SVG's row draws no Laser settings panel. LightBurn's metadata can omit `layers` (.compact),
      # so this keys on "anything besides the size keys", never on `layers`.
      test "recipe? is true only for metadata with something besides a size" do
        refute Dimensions.recipe?(nil)
        refute Dimensions.recipe?({ "job" => { "width" => 1, "height" => 1 } })
        refute Dimensions.recipe?({ "job" => { "width" => 1, "height" => 1 }, "pages" => [] })
        assert Dimensions.recipe?(Maker::Previews::LbrnMetadata.parse(fixture("nested-plate.lbrn2")))
        assert Dimensions.recipe?({ "app_version" => "1.7.00", "job" => { "width" => 1, "height" => 1 } })
      end

      # Past a job thread's overflow (about 830 here) and under the main thread's (about 1920) — the
      # same depth `SvgTest` renders, which must also stay under resvg's own limit of 1024 levels.
      DEEP_NESTING = 1000

      private

      def nested_svg(depth)
        %(<svg xmlns="http://www.w3.org/2000/svg" width="10mm" height="10mm" viewBox="0 0 10 10">) +
          ("<g>" * depth) + %(<rect width="5" height="5"/>) + ("</g>" * depth) + %(</svg>)
      end
    end
  end
end
