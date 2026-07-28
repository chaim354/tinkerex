require "test_helper"

module Maker
  module Previews
    class MageTest < ActiveSupport::TestCase
      setup { @mage = File.binread(Rails.root.join("test/fixtures/files/sample.mage")) }

      test "is always available (the embedded-PNG path needs no toolchain)" do
        assert Maker::Previews::Mage.available?
      end

      test "claims the .mage extension" do
        assert_equal %w[mage], Maker::Previews::Mage::EXTENSIONS
        assert_equal Maker::Previews::Mage, Maker::Previews::Registry.for("mage")
      end

      test "renders the embedded thumbnail PNG" do
        result = Maker::Previews::Mage.render(@mage, size: 512)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      test "raises NoThumbnail when there is neither a thumbnail nor a usable SVG toolchain" do
        # The geometry fallback IS the SVG path, so where resvg is absent this stays exactly the
        # terminal condition it always was. `available?` deliberately does NOT drop to
        # Svg.available? the way Lbrn2's does: the embedded-thumbnail path is what every real
        # file takes and it needs nothing installed, so gating the whole renderer on resvg would
        # forfeit a guarantee this renderer currently makes.
        bare = %(<MillMageProject><Toolpaths/></MillMageProject>)
        original = ENV["RESVG_BIN"]
        ENV["RESVG_BIN"] = "/nonexistent/resvg-binary"
        Maker::Previews::SvgRasterizer.reset_bin!
        assert_raises(Maker::Previews::Mage::NoThumbnail) do
          Maker::Previews::Mage.render(bare, size: 512)
        end
      ensure
        ENV["RESVG_BIN"] = original
        Maker::Previews::SvgRasterizer.reset_bin!
      end

      # --- The geometry dialect is LightBurn's ----------------------------------------------
      # Verified against a real MillMage 0.8.01 export (62 shapes): XForm-as-element 62 /
      # as-attribute 0, real-style vert lists 59 / old-style 0, plus VertID/PrimID instancing and
      # L/B/LineClosed prims. Rendering it through Lbrn2's walker reproduces MillMage's own
      # embedded thumbnail. mage.rb's old claim that MillMage needed "a different, larger parse"
      # was simply wrong, and it cost .mage both a job size and a settings panel.

      class RealExportTest < ActiveSupport::TestCase
        setup { @real = File.binread(Rails.root.join("test/fixtures/files/real-export.mage")) }

        def fixture_with(from, to)
          File.read(Rails.root.join("test/fixtures/files/real-export.mage")).sub(from, to)
        end

        test "job size comes out of the shared walker" do
          meta = Maker::Previews::MageMetadata.parse(@real)
          assert_equal({ "width" => 100.0, "height" => 60.0 }, meta["job"])
          assert_equal 2, meta["shape_count"]
        end

        test "reads the project header" do
          meta = Maker::Previews::MageMetadata.parse(@real)
          assert_equal "0.8.01", meta["app_version"]
          assert_equal "lowrider v4", meta["machine"]
          assert_equal 12.0, meta["material_height"]
        end

        test "reads each Operation and its ToolDef" do
          op = Maker::Previews::MageMetadata.parse(@real)["operations"].sole
          assert_equal "Pocket", op["name"]
          assert_equal "Pocket", op["type"]
          assert_equal "1.5 mm endmil", op["tool"]
          assert_equal "End Mill", op["tool_type"]
          assert_equal 1.5, op["tool_diameter"]
          assert_equal 14.8, op["feed_rate"]
          assert_equal 8.0, op["plunge_rate"]
          assert_equal 20000.0, op["spindle_speed"]
          assert_equal 1.0, op["pass_depth"]
          assert_equal 2.0, op["final_depth"]
        end

        test "an operation's own value WINS over the ToolDef's" do
          # The ToolDef is a reusable library entry; the operation is this job. MillMage writes
          # both, and in the real file the tool says feedRate 14.8000001907348633 while the
          # operation says 14.8 — read the ToolDef and the panel shows a number the machine will
          # not actually run.
          op = Maker::Previews::MageMetadata.parse(fixture_with(%(<feedRate Value="14.8"/>), %(<feedRate Value="99"/>)))["operations"].sole
          assert_equal 99.0, op["feed_rate"], "the operation's own value, not the ToolDef's"
        end

        test "falls back to a ToolDef value the operation does not restate" do
          # stepOver exists ONLY on the ToolDef here, so it proves the fallback is real and not
          # just the operation shadowing every field anyway.
          op = Maker::Previews::MageMetadata.parse(fixture_with(%(<stepOver Value="0.6000000238418579"/>), %(<stepOver Value="0.75"/>)))["operations"].sole
          assert_equal 0.75, op["step_over"]
        end

        test "renders geometry when the file carries no embedded thumbnail" do
          skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

          # This used to raise NoThumbnail, sending the preview to a terminal `failed`.
          refute_match(/<Thumbnail/, @real, "fixture must have no embedded thumbnail")
          result = Maker::Previews::Mage.render(@real, size: 256)
          assert_equal "image/png", result[:content_type]
          assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
          assert_equal 100.0, result[:metadata]["job"]["width"]
        end

        test "an embedded thumbnail still wins, and metadata rides along either way" do
          png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
          withthumb = fixture_with("<Operation", %(<Thumbnail Source="#{png_b64}"/><Operation))
          result = Maker::Previews::Mage.render(withthumb, size: 256)
          assert_equal 1, result[:width], "the embedded 1x1 PNG verbatim, not a re-render"
          assert_equal 100.0, result[:metadata]["job"]["width"]
        end

        test "a file whose embedded image exceeds libxml2's 10MB attribute cap still parses" do
          # The same trap as .lbrn2: past ~10MB in one attribute libxml2 aborts the document and
          # `recover` hands back a TRUNCATED tree, so every Shape after the image disappears with
          # no error anywhere.
          big = "A" * 11_000_000
          xml = %(<MillMageProject AppVersion="0.8.01">) +
                %(<Shape Type="Bitmap" OpIndex="0" W="5" H="5" Data="#{big}"><XForm>1 0 0 1 0 0</XForm></Shape>) +
                %(<Shape Type="Rect" OpIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>) +
                %(</MillMageProject>)
          meta = Maker::Previews::MageMetadata.parse(xml)
          assert_equal 2, meta["shape_count"], "the Rect after the oversized attribute must survive"
          assert_equal 40.0, meta["job"]["width"]
        end

        test "parse returns nil for anything that is not a MillMage project" do
          assert_nil Maker::Previews::MageMetadata.parse(%(<LightBurnProject AppVersion="1.6"/>))
          assert_nil Maker::Previews::MageMetadata.parse("\x00\x01 not xml".b)
        end
      end
    end
  end
end
