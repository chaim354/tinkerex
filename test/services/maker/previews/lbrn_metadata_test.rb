require "test_helper"

module Maker
  module Previews
    class LbrnMetadataTest < ActiveSupport::TestCase
      setup { @bytes = File.binread(Rails.root.join("test/fixtures/files/laser-settings.lbrn2")) }

      test "parses root-level project fields" do
        m = Maker::Previews::LbrnMetadata.parse(@bytes)
        assert_equal "1.7.00", m["app_version"]
        assert_equal "1", m["format_version"]
        assert_equal "Ortur LM2", m["machine"]
        assert_equal 3.0, m["material_height"]
        assert_equal 3, m["shape_count"]
        assert_equal ["MAKER"], m["text"]
      end

      test "keeps only layers referenced by a shape, in index order" do
        layers = Maker::Previews::LbrnMetadata.parse(@bytes)["layers"]
        assert_equal 2, layers.length, "the unused CutSetting (index 2) is dropped"
        assert_equal %w[0 1], layers.map { |l| l["index"] }
      end

      test "parses per-layer settings incl. mode mapping (Scan -> Fill) and colour" do
        layers = Maker::Previews::LbrnMetadata.parse(@bytes)["layers"]
        c00, c01 = layers
        assert_equal({ "index"=>"0", "name"=>"C00", "color"=>"#ff0000", "mode"=>"Cut",
                       "speed"=>15.0, "power_max"=>85.0, "power_min"=>85.0, "passes"=>2 }, c00)
        assert_equal "Fill", c01["mode"], "LightBurn 'Scan' shows as 'Fill'"
        assert_equal "#00ff00", c01["color"]
        assert_equal 200.0, c01["speed"]
      end

      test "computes job size from the shape bounding box (mm)" do
        job = Maker::Previews::LbrnMetadata.parse(@bytes)["job"]
        assert_equal 40.0, job["width"]
        assert_equal 20.0, job["height"]
      end

      test "returns nil for a non-LightBurn document" do
        assert_nil Maker::Previews::LbrnMetadata.parse("<svg><rect/></svg>")
      end

      test "returns nil (never raises) for malformed input" do
        assert_nil Maker::Previews::LbrnMetadata.parse("<<<not xml")
        assert_nil Maker::Previews::LbrnMetadata.parse("")
      end

      test "omits fields it cannot find rather than emitting nils" do
        bare = %(<LightBurnProject><CutSetting><index Value="0"/></CutSetting>) +
               %(<Shape Type="Rect" CutIndex="0" W="10" H="10" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        m = Maker::Previews::LbrnMetadata.parse(bare)
        refute m.key?("machine")
        refute m["layers"].first.key?("speed")
      end
    end
  end
end
