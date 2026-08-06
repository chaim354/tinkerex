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
        assert_equal [ "MAKER" ], m["text"]
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

      test "ellipse job size stays sensible under rotation (samples the perimeter)" do
        # A 45-degrees-rotated circle (Rx=Ry=10) at the origin: true bbox is ~20x20mm. The old
        # two-corner approach gave a degenerate 0x28.3; sampling the perimeter fixes it.
        xml = %(<LightBurnProject><CutSetting><index Value="0"/></CutSetting>) +
              %(<Shape Type="Ellipse" CutIndex="0" Rx="10" Ry="10" XForm="0.7071 0.7071 -0.7071 0.7071 0 0"/></LightBurnProject>)
        job = Maker::Previews::LbrnMetadata.parse(xml)["job"]
        assert_in_delta 20.0, job["width"], 1.0
        assert_in_delta 20.0, job["height"], 1.0
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

      # THE ONE DELIBERATE EXCEPTION TO THE RULE ABOVE. LightBurn writes only values that differ
      # from its defaults, so a single-pass layer says nothing about passes at all — measured over
      # the 58 real exports, 130 of 135 CutSetting blocks omit `numPasses`, and all 5 that carry it
      # say 4. Reporting nil put an EMPTY Passes cell on nearly every layer of every real file,
      # which reads as a parse failure for a number the file states perfectly clearly by omission.
      #
      # This RECOVERS a stated value rather than guessing one, which is exactly why `minPower`
      # (absent in 129 of 135) is left alone: it has no flat default — it tracks maxPower unless a
      # layer ramps power — and the panel already handles its absence by showing one power figure
      # instead of two. Defaulting there would invent data.
      test "an absent numPasses means one pass, not unknown" do
        bare = %(<LightBurnProject><CutSetting type="Cut"><index Value="0"/>) +
               %(<speed Value="20"/><maxPower Value="80"/></CutSetting>) +
               %(<Shape Type="Rect" CutIndex="0" W="10" H="10" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        layer = Maker::Previews::LbrnMetadata.parse(bare)["layers"].first

        assert_equal 1, layer["passes"], "a layer that says nothing about passes runs once"
        refute layer.key?("power_min"), "minPower has no flat default and must stay absent"
      end

      test "an explicit numPasses still wins" do
        bare = %(<LightBurnProject><CutSetting type="Cut"><index Value="0"/>) +
               %(<numPasses Value="4"/></CutSetting>) +
               %(<Shape Type="Rect" CutIndex="0" W="10" H="10" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        assert_equal 4, Maker::Previews::LbrnMetadata.parse(bare)["layers"].first["passes"]
      end
    end
  end
end
