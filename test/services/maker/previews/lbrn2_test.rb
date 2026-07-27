require "test_helper"

module Maker
  module Previews
    class Lbrn2Test < ActiveSupport::TestCase
      setup { @lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2")) }

      test "is available whenever the SVG path is (pure-Ruby XML→SVG, no native dep)" do
        assert_equal Maker::Previews::Svg.available?, Maker::Previews::Lbrn2.available?
      end

      test "render falls back to the geometry parser (PNG) when there is no embedded thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?

        # The fixture has no <Thumbnail>, so this exercises the geometry -> SVG -> PNG fallback.
        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
      end

      test "render uses the embedded thumbnail when the LightBurn file carries one" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        with_thumb = %(<LightBurnProject><Thumbnail Source="#{png_b64}"/><Shape Type="Rect" W="1" H="1"/></LightBurnProject>)
        result = Maker::Previews::Lbrn2.render(with_thumb, size: 512)
        assert_equal "image/png", result[:content_type]
        assert_equal 1, result[:width], "the embedded 1x1 PNG is returned verbatim, not a re-render"
      end

      test "maps Rect / Ellipse / Line shapes into SVG primitives" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        assert_includes svg, "<polygon"  # Rect → polygon
        assert_includes svg, "<ellipse"
        assert_includes svg, "<polyline" # Line → polyline
      end

      test "applies CutSetting colors per CutIndex" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        # CutIndex 0 → color 255 (0x0000FF packed little-endian) → red #ff0000.
        assert_includes svg, "#ff0000"
        # CutIndex 1 → color 65280 (0x00FF00) → green #00ff00.
        assert_includes svg, "#00ff00"
      end

      test "sizes the viewBox to the shapes' bounding box" do
        svg = Maker::Previews::Lbrn2.to_svg(@lbrn2)
        assert_match(/viewBox="[-\d. ]+"/, svg)
      end

      test "normalize_color handles packed ints and hex strings" do
        assert_equal "#ff0000", Maker::Previews::Lbrn2.normalize_color("255")
        assert_equal "#00ff00", Maker::Previews::Lbrn2.normalize_color("65280")
        assert_equal "#abcdef", Maker::Previews::Lbrn2.normalize_color("#abcdef")
        assert_equal "#000000", Maker::Previews::Lbrn2.normalize_color(nil)
      end

      test "an empty project still produces a valid SVG (does not crash)" do
        empty = %(<?xml version="1.0"?><LightBurnProject></LightBurnProject>)
        svg = Maker::Previews::Lbrn2.to_svg(empty)
        assert_includes svg, "<svg"
      end

      test "raises ParseError on input that is not XML at all" do
        assert_raises(Maker::Previews::Lbrn2::ParseError) do
          Maker::Previews::Lbrn2.to_svg("\x00\x01\x02 not xml".b)
        end
      end

      test "render attaches parsed metadata alongside the image (geometry path)" do
        skip "resvg not installed on this box" unless Maker::Previews::Lbrn2.available?
        result = Maker::Previews::Lbrn2.render(@lbrn2, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_kind_of Hash, result[:metadata]
        assert result[:metadata]["layers"].present?, "layers parsed from the fixture"
      end

      test "render attaches metadata even when the embedded thumbnail is used" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        xml = %(<LightBurnProject AppVersion="1.7.00"><Thumbnail Source="#{png_b64}"/>) +
              %(<CutSetting type="Cut"><index Value="0"/><speed Value="12"/><color Value="255"/></CutSetting>) +
              %(<Shape Type="Rect" CutIndex="0" W="5" H="5" XForm="1 0 0 1 0 0"/></LightBurnProject>)
        result = Maker::Previews::Lbrn2.render(xml, size: 512)
        assert_equal 1, result[:width], "embedded 1x1 PNG returned verbatim"
        assert_equal "1.7.00", result[:metadata]["app_version"], "metadata parsed from XML regardless of image path"
      end

      # --- The dialect LightBurn actually writes ------------------------------------------
      # sample.lbrn2 is hand-authored in a form LightBurn has never emitted. Across 58 real
      # exports (1.4.04 -> 1.7.08) the counts were: XForm-as-attribute 0 / as-element 9,517,
      # and old-style "V0x0y0" vert lists 0 / real-style "V<x> <y>" 6,112. Result: 9,436 real
      # shapes rendered 96 SVG elements (1.0%). These tests pin the real dialect.

      class RealExportTest < ActiveSupport::TestCase
        setup { @real = File.binread(Rails.root.join("test/fixtures/files/real-export.lbrn2")) }

        def drawn(svg) = svg.scan(/<(?:polygon|polyline|ellipse|path)\b/).length

        test "reads XForm from a child element, not just an attribute" do
          # The Rect is 40x20 centred at (50,30) by <XForm>1 0 0 1 50 30</XForm>. With the
          # transform missed it collapses to the origin, so its corners read -20..20 / -10..10.
          svg = Maker::Previews::Lbrn2.to_svg(@real)
          assert_includes svg, "<polygon", "the Rect should still be drawn"
          xs = svg[/<polygon points="([^"]+)"/, 1].split.map { |p| p.split(",").first.to_f }
          assert_equal [ 30.0, 70.0 ], [ xs.min, xs.max ],
                       "Rect must sit at x 30..70 (centre 50), i.e. the XForm child was applied"
        end

        test "parses the real VertList dialect and honours PrimList connectivity" do
          svg = Maker::Previews::Lbrn2.to_svg(@real)
          assert_operator drawn(svg), :>=, 4,
                          "Rect + path + instanced path + grouped path should all be drawn"
        end

        test "a Shape with VertID but no VertList instances the shared geometry" do
          # The instance repeats path #7 translated +100 in x, so the bbox must reach x=110.
          meta = Maker::Previews::LbrnMetadata.parse(@real)
          assert_equal 110.0, meta["job"]["width"], "instanced geometry must contribute to the bbox"
        end

        test "a Group's XForm places its Children" do
          # The group scales its 5x5 child by 2 and lifts it to y 100..110.
          meta = Maker::Previews::LbrnMetadata.parse(@real)
          assert_equal 110.0, meta["job"]["height"], "grouped geometry must be placed by the group XForm"
        end

        test "a group does not smear its children's vertices into one stray polyline" do
          # <Children> sits inside the Group <Shape>, so a `.//VertList` / shape.text lookup
          # would hand the group every descendant vertex and draw a scribble through them.
          svg = Maker::Previews::Lbrn2.to_svg(@real)
          assert_equal 4, drawn(svg), "exactly the four leaf shapes, no phantom group outline"
        end

        test "bezier segments bulge past their endpoints in the bounding box" do
          # Two vertices on y=0 with control handles at y=8 -> the curve peaks at y=6.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <Shape Type="Path" CutIndex="0" VertID="1" PrimID="1">
                <XForm>1 0 0 1 0 0</XForm>
                <VertList>V0 0c0x0c0y8c1x1V10 0c0x1c1x10c1y8</VertList>
                <PrimList>B0 1</PrimList>
              </Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_in_delta 6.0, meta["job"]["height"], 0.15,
                          "a curve flattened to its endpoints would report height 0"
        end

        test "Text geometry comes from its BackupPath outline" do
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <Shape Type="Text" CutIndex="0" Str="HI" H="10" HasBackupPath="1">
                <BackupPath Type="Path" CutIndex="0">
                  <XForm>1 0 0 1 0 0</XForm>
                  <VertList>V0 0c0x1c1x1V20 0c0x1c1x1V20 10c0x1c1x1</VertList>
                  <PrimList>L0 1L1 2</PrimList>
                </BackupPath>
              </Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 20.0, "height" => 10.0 }, meta["job"],
                       "<BackupPath> is not a <Shape>, so a //Shape sweep never sees text outlines")
        end

        test "a Text inside a group is placed by its BackupPath alone, not by the group too" do
          # The BackupPath's XForm is already in DOCUMENT space — here it is exactly the group's
          # transform applied to the Text's own (0.5 * 40 + 100 = 120). Composing it with either
          # the group or the Text again would push the outline off the sheet, which is what put
          # logo.lbrn2's "CJS BUILDS" outside its gear.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <Shape Type="Group" CutIndex="0">
                <XForm>0.5 0 0 0.5 100 100</XForm>
                <Children>
                  <Shape Type="Text" CutIndex="0" Str="HI" H="10" HasBackupPath="1">
                    <BackupPath Type="Path" CutIndex="0">
                      <XForm>0.5 0 0 0.5 120 100</XForm>
                      <VertList>V0 0c0x1c1x1V20 0c0x1c1x1V20 20c0x1c1x1</VertList>
                      <PrimList>L0 1L1 2</PrimList>
                    </BackupPath>
                    <XForm>1 0 0 1 40 0</XForm>
                  </Shape>
                </Children>
              </Shape>
            </LightBurnProject>
          XML
          svg = Maker::Previews::Lbrn2.to_svg(xml)
          xs = svg[/<polyline points="([^"]+)"/, 1].split.map { |p| p.split(",").first.to_f }
          assert_equal [ 120.0, 130.0 ], [ xs.min, xs.max ],
                       "outline spans x 120..130 — the BackupPath XForm applied exactly once"
        end

        test "a hidden layer is left out, as it is in LightBurn's own render" do
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <CutSetting type="Cut"><index Value="0"/><color Value="255"/></CutSetting>
              <CutSetting type="Cut"><index Value="1"/><color Value="65280"/><hide Value="1"/></CutSetting>
              <Shape Type="Rect" CutIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>
              <Shape Type="Rect" CutIndex="1" W="400" H="400"><XForm>1 0 0 1 0 0</XForm></Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 40.0, "height" => 20.0 }, meta["job"],
                       "the hidden layer must not inflate the job size")
          assert_equal 1, Maker::Previews::Lbrn2.to_svg(xml).scan(/<polygon\b/).length
        end

        test "hiding the Cut layer at an index does not hide the Image layer at that same index" do
          # <CutSetting> and <CutSetting_Img> BOTH carry index 0 — the vector and image layers
          # for that one number — and either can be hidden alone. Keyed on the index alone, this
          # file (gavrielengage's shape) renders as a blank page with no job size at all.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <CutSetting type="Cut"><index Value="0"/><hide Value="1"/></CutSetting>
              <CutSetting_Img type="Image"><index Value="0"/></CutSetting_Img>
              <Shape Type="Rect" CutIndex="0" W="400" H="400"><XForm>1 0 0 1 0 0</XForm></Shape>
              <Shape Type="Bitmap" CutIndex="0" W="30" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 30.0, "height" => 20.0 }, meta["job"],
                       "the visible Bitmap survives; the hidden Rect on the same index does not")
        end

        test "hiding the Image layer at an index does not hide the Cut layer at that same index" do
          # power cover: the exact reverse of the case above, which is what settles that the two
          # are independent rather than one being an alias for the other.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <CutSetting type="Cut"><index Value="0"/></CutSetting>
              <CutSetting_Img type="Image"><index Value="0"/><hide Value="1"/></CutSetting_Img>
              <Shape Type="Rect" CutIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>
              <Shape Type="Bitmap" CutIndex="0" W="400" H="400"><XForm>1 0 0 1 0 0</XForm></Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 40.0, "height" => 20.0 }, meta["job"])
        end

        test "a no-output layer IS still drawn — doOutput is not hide" do
          # The tempting generalisation. `doOutput="0"` means "on the canvas, but don't fire the
          # laser" — a registration mark or alignment box, which LightBurn still renders and
          # which still bounds the drawing. Folding it in with `hide` agreed with LightBurn's
          # own thumbnails on 41 of 57 files; `hide` alone agrees on 54.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <CutSetting type="Cut"><index Value="0"/><color Value="255"/></CutSetting>
              <CutSetting type="Cut"><index Value="1"/><color Value="65280"/><doOutput Value="0"/></CutSetting>
              <Shape Type="Rect" CutIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>
              <Shape Type="Rect" CutIndex="1" W="400" H="400"><XForm>1 0 0 1 0 0</XForm></Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 400.0, "height" => 400.0 }, meta["job"])
          assert_equal 2, Maker::Previews::Lbrn2.to_svg(xml).scan(/<polygon\b/).length
        end

        test "an image layer's colour is read from CutSetting_Img" do
          # An image layer is written as <CutSetting_Img>, so an exact //CutSetting match drops
          # its colour and leaves it out of the laser-settings panel entirely.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <CutSetting_Img type="Image"><index Value="0"/><color Value="65280"/></CutSetting_Img>
              <Shape Type="Rect" CutIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>
            </LightBurnProject>
          XML
          assert_includes Maker::Previews::Lbrn2.to_svg(xml), "#00ff00"
        end

        test "a Bitmap contributes its W/H box" do
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <Shape Type="Bitmap" CutIndex="0" W="30" H="20" Data="AAAA">
                <XForm>1 0 0 1 0 0</XForm>
              </Shape>
            </LightBurnProject>
          XML
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal({ "width" => 30.0, "height" => 20.0 }, meta["job"])
        end

        test "a file whose embedded image exceeds libxml2's 10MB attribute cap still parses" do
          # LightBurn inlines a placed photo as base64 in Bitmap@Data. Past ~10MB libxml2
          # aborts the document ("Buffer size limit exceeded, try XML_PARSE_HUGE") and
          # `recover` hands back a TRUNCATED tree — every Shape after the image vanishes, so
          # the file silently reports no geometry and no laser settings at all.
          big = "A" * 11_000_000
          xml = %(<LightBurnProject AppVersion="1.6.00">) +
                %(<Shape Type="Bitmap" CutIndex="0" W="5" H="5" Data="#{big}"><XForm>1 0 0 1 0 0</XForm></Shape>) +
                %(<Shape Type="Rect" CutIndex="0" W="40" H="20"><XForm>1 0 0 1 0 0</XForm></Shape>) +
                %(</LightBurnProject>)
          meta = Maker::Previews::LbrnMetadata.parse(xml)
          assert_equal 2, meta["shape_count"], "the Rect after the oversized attribute must survive"
          assert_equal 40.0, meta["job"]["width"]
        end
      end
    end
  end
end
