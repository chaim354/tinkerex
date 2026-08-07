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

        # --- Measure ------------------------------------------------------------------------

        test "renders a geometry payload for the Measure view" do
          result = Maker::Previews::Mage.render(@real, kind: "geometry")
          payload = JSON.parse(result[:bytes])

          assert_equal "application/json", result[:content_type]
          assert_equal Maker::Previews::Geometry::SCHEMA_VERSION, payload["v"]
          assert_equal 2, payload["shapes"].length
          assert_in_delta 20.0, payload["shapes"].last["d"], 0.05, "the fixture's circle must measure"
        end

        # THE GUARD THAT TIES THE PAYLOAD TO THE PANEL. Both read the SAME walker, so the Measure
        # view and the CNC panel cannot report different sizes — §14b's LbrnMetadata second-copy
        # bug is the precedent. job_size rounds to 1dp and the payload carries 2, so round ONCE
        # then demand equality; a tolerance band would let a real divergence hide inside it.
        test "the payload's bboxes union to exactly the reported job size" do
          expected = Maker::Previews::MageMetadata.parse(@real)["job"]
          boxes = JSON.parse(Maker::Previews::Mage.render(@real, kind: "geometry")[:bytes])["shapes"]
                      .map { |s| s["b"] }

          w = boxes.map { |b| b[2] }.max - boxes.map { |b| b[0] }.min
          h = boxes.map { |b| b[3] }.max - boxes.map { |b| b[1] }.min
          assert_equal expected["width"],  w.round(1)
          assert_equal expected["height"], h.round(1)
        end

        # A MillMage Shape carries `OpIndex`, NOT `CutIndex` — measured on this fixture:
        # CutIndex uniq [nil], OpIndex uniq ["0"]. The thumbnail never noticed, because a
        # MillMage file has no <CutSetting> either, so both a nil and a real index fall through
        # to DEFAULT_STROKE and draw the same black. The Measure view is where it surfaces: the
        # layer key groups shapes and keys the colour map, so every contour landed in one
        # nameless layer.
        test "a shape's layer comes from OpIndex, which is where MillMage records it" do
          payload = JSON.parse(Maker::Previews::Mage.render(@real, kind: "geometry")[:bytes])

          assert_equal [ "0" ], payload["shapes"].map { |s| s["c"] }.uniq
          assert_not_includes payload["shapes"].map { |s| s["c"] }, nil
        end

        # MILLMAGE GETS NO COLOURS, DELIBERATELY. LightBurn's LAYER_PALETTE was recovered from
        # the embedded thumbnails of 58 real LightBurn exports; MillMage is a different
        # application with its own layer bar, and its <Operation> elements carry no colour field.
        # Painting OpIndex 2 in LightBurn's red would be a claim about MillMage that nothing
        # supports — the same mistake §14h names in the other direction, where a recoloured
        # LightBurn layer gets no name because "Blue" beside a green swatch contradicts itself.
        # The client falls back to black, which claims nothing.
        test "MillMage layers borrow no colours from LightBurn's palette" do
          payload = JSON.parse(Maker::Previews::Mage.render(@real, kind: "geometry")[:bytes])

          assert_equal({}, payload["colors"])
          assert Maker::Previews::Lbrn2.layer_color("0"),
                 "LightBurn DOES define a colour for this index — so an empty map is a refusal, not an absence"
        end

        test "geometry and thumbnail revisions move independently" do
          assert_equal Maker::Previews::LbrnGeometry::PAYLOAD_REVISION,
                       Maker::Previews::Mage.payload_revision("geometry")
          assert_equal Maker::Previews::Mage::THUMBNAIL_REVISION,
                       Maker::Previews::Mage.payload_revision("thumbnail")
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
