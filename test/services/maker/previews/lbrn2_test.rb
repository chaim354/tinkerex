require "test_helper"

module Maker
  module Previews
    class Lbrn2Test < ActiveSupport::TestCase
      setup { @lbrn2 = File.binread(Rails.root.join("test/fixtures/files/sample.lbrn2")) }

      # AVAILABLE UNCONDITIONALLY, THE SAME ANSWER MAGE GIVES, AND FOR THE SAME REASON: a
      # LightBurn file carries its own full-colour render in <Thumbnail Source="base64png">, and
      # pulling that out is pure Ruby. Gating the whole renderer on resvg marked a file whose PNG
      # was sitting right there `unsupported` -- a terminal status -- while the byte-identical
      # situation in a .mage rendered fine. `available?` asks whether THIS BOX has any path to a
      # thumbnail, and for these two formats it always does.
      #
      # Svg and Dxf keep `available? = SvgRasterizer.available?` and that is not an inconsistency:
      # they have no embedded raster to fall back ON, so for them the rasterizer is the only path.
      test "is available with no rasterizer on the box, because the embedded raster needs none" do
        without_svg_rasterizer do
          assert_not Maker::Previews::Svg.available?,
                     "precondition: the rasterizer must read absent, or this proves nothing"
          assert Maker::Previews::Lbrn2.available?
        end
      end

      test "answers availability identically to Mage, with or without a rasterizer" do
        assert_equal Maker::Previews::Mage.available?, Maker::Previews::Lbrn2.available?
        without_svg_rasterizer do
          assert_equal Maker::Previews::Mage.available?, Maker::Previews::Lbrn2.available?
        end
      end

      # The fallback IS the SVG path, so where resvg is absent this is terminal -- the same
      # NoThumbnail Mage and ThreeMf already raise for the same condition, rather than a fourth
      # spelling the job would have to classify.
      test "raises NoThumbnail with neither an embedded raster nor a rasterizer" do
        bare = %(<LightBurnProject><Shape Type="Rect" W="1" H="1"/></LightBurnProject>)
        without_svg_rasterizer do
          assert_raises(Maker::Previews::Lbrn2::NoThumbnail) do
            Maker::Previews::Lbrn2.render(bare, size: 512)
          end
        end
      end

      test "renders the embedded raster with no rasterizer on the box" do
        png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        xml = %(<LightBurnProject><Thumbnail Source="#{png_b64}"/><Shape Type="Rect" W="1" H="1"/></LightBurnProject>)
        without_svg_rasterizer do
          result = Maker::Previews::Lbrn2.render(xml, size: 512)
          assert_equal "image/png", result[:content_type]
          assert_equal 1, result[:width], "the embedded PNG verbatim, not a re-render"
        end
      end

      test "render falls back to the geometry parser (PNG) when there is no embedded thumbnail" do
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?

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
        skip "resvg not installed on this box" unless Maker::Previews::Svg.available?
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

        # EVERY <VertList> IS PARSED EXACTLY ONCE, and this is a guard on WORK DONE rather than
        # on output — the only kind that can see this regression, because parsing twice produces
        # the identical drawing at double the cost, so no assertion about the result can fail.
        # Measured on `reference card.lbrn2` (2.69 MB, 641 inline lists): re-parsing was ~9% of
        # every instancing file's render, ~20% of that one's.
        #
        # HAND-ROLLED, NOT Object#stub: minitest 6 dropped minitest/mock, so `stub` does not exist
        # in this suite (requiring it is a LoadError) — same reason test_helper's
        # `with_concurrent_file_attachment` counts calls this way.
        test "a VertList is parsed exactly once per document" do
          calls = 0
          mod = Maker::Previews::Lbrn2.singleton_class
          original = mod.instance_method(:parse_vertlist)
          mod.define_method(:parse_vertlist) { |text| calls += 1; original.bind(self).call(text) }

          begin
            doc = Maker::Previews::Lbrn2.parse_document(@real)
            Maker::Previews::Lbrn2.each_geometry(doc) { |*| }
          ensure
            mod.define_method(:parse_vertlist, original)
          end

          lists = Maker::Previews::Lbrn2.parse_document(@real).xpath("//VertList").length
          assert_operator lists, :>, 0, "fixture precondition: the document must have inline lists"
          assert_equal lists, calls,
                       "expected one parse per <VertList>, got #{calls} for #{lists} lists"
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

        # A 1x1 red PNG. Small enough to inline, real enough to survive the PNG-magic check.
        PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".freeze

        def bitmap_xml(data, xform: "1 0 0 1 55 55")
          %(<LightBurnProject AppVersion="1.6.00">) +
            %(<Shape Type="Bitmap" CutIndex="0" W="10" H="10" Data="#{data}"><XForm>#{xform}</XForm></Shape>) +
            %(</LightBurnProject>)
        end

        # A PLACED PHOTO IS THE PICTURE, NOT ITS OUTLINE. `emit_shape` treated Bitmap exactly like
        # Rect — four corners, `fill="none"` — so a .lbrn2 built around a traced or engraved image
        # previewed as an empty box. Only reachable when the file carries no <Thumbnail> of its
        # own, which is the path this whole renderer exists for.
        test "a Bitmap renders its actual image, not an empty box" do
          svg = Maker::Previews::Lbrn2.to_svg(bitmap_xml(PNG_B64))
          assert_includes svg, "<image "
          assert_includes svg, "data:image/png;base64,#{PNG_B64}"
          assert_not_includes svg, "<polygon", "the bbox outline is replaced by the image, not drawn under it"
        end

        # The bitmap still has to BOUND the drawing whether or not its bytes are usable, because
        # job_size and the viewBox are measured from the same walk.
        test "an embedded Bitmap still contributes its box to the job size" do
          meta = Maker::Previews::LbrnMetadata.parse(bitmap_xml(PNG_B64))
          assert_equal({ "width" => 10.0, "height" => 10.0 }, meta["job"])
        end

        # `Data` IS ATTACKER-CONTROLLED — it is whatever bytes are in an uploaded file, and it is
        # about to be interpolated into an SVG attribute. A quote would close the attribute early
        # and let the rest of the value become markup. Base64 has no quote, so the guard is to
        # REQUIRE the base64 alphabet rather than to escape afterwards.
        test "a Bitmap whose Data is not base64 falls back to the outline and injects nothing" do
          svg = Maker::Previews::Lbrn2.to_svg(bitmap_xml(%(x"/><script>alert(1)</script>)))
          assert_not_includes svg, "<script"
          assert_not_includes svg, "<image "
          assert_includes svg, "<polygon", "an unusable image still draws its box, as before"
        end

        # Base64 that decodes to something that is not a PNG is not an image we can hand a
        # rasterizer, and `data:image/png` would be a lie about it.
        test "a Bitmap whose Data is not a PNG falls back to the outline" do
          svg = Maker::Previews::Lbrn2.to_svg(bitmap_xml(Base64.strict_encode64("GIF89a not really")))
          assert_not_includes svg, "<image "
          assert_includes svg, "<polygon"
        end

        # ORIENTATION, MEASURED RATHER THAN REASONED. `apply` negates y, so whether the raster
        # needs flipping back is a real question and getting it wrong stands every placed photo on
        # its head — invisibly, on the symmetric test grid the reference ships, which is exactly
        # why that fixture could not settle it. jlucaso1/lbrn2-to-svg carries `-0.252` in its own
        # image matrix, so the answer is genuinely not obvious from either implementation.
        #
        # An 8x8 PNG, red over blue, rasterized and sampled: red must land on top. Hand-built so
        # the test needs no image gem, and skipped rather than faked where the toolchain is
        # absent — the same trade every other rasterizing test here makes.
        test "a Bitmap is not upside down" do
          skip "resvg not installed" unless Maker::Previews::Svg.available?
          skip "vips not installed" unless system("vips", "--version", out: File::NULL, err: File::NULL)

          xml = bitmap_xml(red_over_blue_png_b64, xform: "1 0 0 1 50 50")
          Dir.mktmpdir do |dir|
            svg = File.join(dir, "o.svg")
            png = File.join(dir, "o.png")
            File.write(svg, Maker::Previews::Lbrn2.to_svg(xml, size: 256))
            assert system("resvg", "--background", "white", "--width", "120", "--height", "120",
                          svg, png, out: File::NULL, err: File::NULL)
            assert_equal "255 0 0", sample(png, 60, 30), "the image's own top row must render at the top"
            assert_equal "0 0 255", sample(png, 60, 90)
          end
        end

        def sample(png, x, y)
          Open3.capture2("vips", "getpoint", png, x.to_s, y.to_s).first.split[0, 3].join(" ")
        end

        # 8x8, top half red, bottom half blue — a raw PNG assembled by hand (IHDR + IDAT + IEND)
        # so this needs no image library at test time.
        def red_over_blue_png_b64
          w = h = 8
          raw = (0...h).map { |y|
            "\x00".b + ((y < h / 2 ? "\xFF\x00\x00" : "\x00\x00\xFF").b * w)
          }.join
          chunk = lambda do |type, data|
            [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N")
          end
          png = "\x89PNG\r\n\x1A\n".b +
                chunk.call("IHDR".b, [ w, h, 8, 2, 0, 0, 0 ].pack("NNC5")) +
                chunk.call("IDAT".b, Zlib::Deflate.deflate(raw)) +
                chunk.call("IEND".b, "".b)
          Base64.strict_encode64(png)
        end

        # An <image> is an axis-aligned rectangle; a rotated one would need the transform carried
        # through, and drawing it unrotated would put the photo somewhere it is not. The ellipse
        # path already makes exactly this call (`axis_aligned?`), so this follows its precedent.
        test "a ROTATED Bitmap keeps the outline rather than placing the image wrong" do
          rot = "0.866 -0.5 0.5 0.866 55 55"
          svg = Maker::Previews::Lbrn2.to_svg(bitmap_xml(PNG_B64, xform: rot))
          assert_not_includes svg, "<image "
          assert_includes svg, "<polygon"
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

        test "bezier-circle fixture parses as one closed circle and one closed square" do
          doc = Maker::Previews::Lbrn2.parse_document(fixture("bezier-circle.lbrn2"))
          shapes = []
          Maker::Previews::Lbrn2.each_geometry(doc) { |_c, pts, closed, *| shapes << [ pts, closed ] }

          assert_equal 2, shapes.length, "expected exactly the circle and the square"

          circle, square = shapes.sort_by { |(pts, _)| pts.map(&:first).min }
          assert circle[1], "circle contour must be closed"
          assert square[1], "square contour must be closed"

          assert_operator circle[0].length, :>=, 12, "a 4-segment bezier circle must flatten to >= 12 points"
          assert_equal 5, square[0].length, "a Rect emits 4 corners plus the closing point"

          # THE ASSERTION THAT MAKES THIS FIXTURE WORTH HAVING. The bbox is pinned by the four
          # on-axis vertices, so it stays 20x20 even if the curve between them is wrong — swapping
          # c0/c1 yields a four-lobed shape with radii 4.14..10.0 and every other assertion here
          # still passes. Roundness is the whole point of the fixture; assert it directly.
          circle[0].each { |(x, y)| assert_in_delta 10.0, Math.hypot(x, y), 0.01 }

          # Both are 20 x 20 mm. That is the whole point of this fixture.
          { "circle" => circle, "square" => square }.each do |name, (pts, _)|
            xs = pts.map(&:first); ys = pts.map(&:last)
            assert_in_delta 20.0, xs.max - xs.min, 0.05, "#{name} width"
            assert_in_delta 20.0, ys.max - ys.min, 0.05, "#{name} height"
          end
        end

        test "text-backup-path fixture yields two contours from the BackupPath, plus the Rect beside it" do
          doc = Maker::Previews::Lbrn2.parse_document(fixture("text-backup-path.lbrn2"))
          contours = []
          Maker::Previews::Lbrn2.each_geometry(doc) { |_c, pts, *| contours << pts }

          assert_equal 3, contours.length,
                       "2 contours from the Text's BackupPath (the Text itself emits nothing) " \
                       "+ 1 from the Rect placed beside it for the object-id density check below"

          # Measured over all THREE contours, including the Rect's — this only still reads "the
          # two letters" because the Rect sits INSIDE their span (see the fixture's own comment).
          # If the Rect ever moved outside it, these numbers would move and say so loudly.
          all_x = contours.flatten(1).map(&:first)
          all_y = contours.flatten(1).map(&:last)
          assert_in_delta 30.0, all_x.max - all_x.min, 0.01, "the two letters span 30 mm"
          assert_in_delta 10.0, all_y.max - all_y.min, 0.01, "the two letters share one 10mm y-span"
        end

        test "each_geometry yields an object id that groups a Text with its BackupPath" do
          doc = Maker::Previews::Lbrn2.parse_document(fixture("text-backup-path.lbrn2"))
          ids = []
          Maker::Previews::Lbrn2.each_geometry(doc) { |_c, _p, _k, _e, _i, oid| ids << oid }

          # Document order: the Text's two BackupPath contours (the letters) yield first, then
          # the Rect placed beside them.
          assert_equal 3, ids.length

          # THE GROUPING CLAIM, checked POSITIONALLY rather than via a deduplicated count. A
          # count alone cannot tell "the two letters share one id, and the Rect gets its own"
          # apart from "the second letter collides with the Rect's id while the first is split
          # off alone" — both give ids.uniq.length == 2. That second, WRONG shape is exactly
          # what a per-contour-id mutation produced here, undetected, until this was asserted
          # positionally: [1, 2, 2] has 2 unique values and is dense from 1, same as the correct
          # [1, 1, 2], so neither an aggregate count nor a density check catches it.
          assert_equal ids[0], ids[1],
                       "both BackupPath contours belong to ONE object (the Text), so alt-click reports the whole word"
          assert_not_equal ids[0], ids[2], "the Rect beside the Text must be a different object"

          # THE ASSERTION THAT CATCHES THE ORIGINAL BUG, and the reason the Rect is in this
          # fixture at all. A Text yields no geometry of its own, so its counter tick is
          # observable ONLY through the BackupPath reusing it. Give the BackupPath a fresh id
          # instead and the Text's tick is burned unobserved, leaving a GAP: the ids become
          # [2, 2, 3] rather than [1, 1, 2]. With only one Shape in the fixture, both behaviours
          # look like "two the same" and nothing could tell them apart — which is why the Rect
          # had to be added at all.
          assert_equal (1..ids.uniq.length).to_a, ids.uniq.sort,
                       "in THIS fixture the ids must be dense from 1 — a gap would mean the " \
                       "BackupPath burned a fresh tick instead of reusing the Text's (real files " \
                       "are NOT guaranteed dense; see each_geometry's doc comment)"
        end

        test "each_geometry gives separate shapes separate object ids, and Groups consume none" do
          doc = Maker::Previews::Lbrn2.parse_document(fixture("real-export.lbrn2"))
          ids = []
          Maker::Previews::Lbrn2.each_geometry(doc) { |_c, _p, _k, _e, _i, oid| ids << oid }

          # real-export.lbrn2: a Rect, two Paths (one an instance), and a Group holding one Path.
          # The Group emits nothing itself, so four drawable shapes -> four distinct ids.
          assert_equal 4, ids.length
          assert_equal 4, ids.uniq.length, "each non-Group Shape gets its own object id"
        end

        test "a shape after a Group keeps counting where the group left off" do
          # real-export.lbrn2 CANNOT catch a Counter regression: its Group is the LAST shape, so
          # nothing ever yields after a group returns, which is the only place either bug below is
          # observable. This fixture puts a plain Shape after the Group specifically to expose it.
          xml = <<~XML
            <LightBurnProject AppVersion="1.6.00">
              <Shape Type="Rect" CutIndex="0" W="5" H="5"><XForm>1 0 0 1 0 0</XForm></Shape>
              <Shape Type="Group" CutIndex="0">
                <XForm>1 0 0 1 0 0</XForm>
                <Children>
                  <Shape Type="Rect" CutIndex="0" W="5" H="5"><XForm>1 0 0 1 20 0</XForm></Shape>
                </Children>
              </Shape>
              <Shape Type="Rect" CutIndex="0" W="5" H="5"><XForm>1 0 0 1 40 0</XForm></Shape>
            </LightBurnProject>
          XML
          ids = []
          Maker::Previews::Lbrn2.each_geometry(Maker::Previews::Lbrn2.parse_document(xml)) { |_c, _p, _k, _e, _i, oid| ids << oid }
          # A Group consuming a tick gives [1, 3, 4]; a plain-Integer counter gives [1, 2, 2]
          # (the outer frame's own counter rewinds to 1 when the recursive call returns, so the
          # Rect after the Group repeats the id already spent inside it).
          assert_equal [ 1, 2, 3 ], ids
        end

        test "the existing callers are unaffected by the new yielded value" do
          # job_size destructures 4 params, to_svg 5. Ruby block arity is lenient, so a 6th value
          # must change neither — asserted as an EXACT size, not merely "truthy": a caller
          # silently reading the wrong positional param (e.g. treating `image` as `object_id`)
          # would still return SOME hash and pass a weaker check without ever being wrong in a
          # way that fails it.
          sizes = {
            "real-export.lbrn2" => { "width" => 110.0, "height" => 110.0 },
            "sample.lbrn2" => { "width" => 100.0, "height" => 40.0 },
            "laser-settings.lbrn2" => { "width" => 40.0, "height" => 20.0 }
          }
          sizes.each do |name, expected|
            bytes = fixture(name)
            doc = Maker::Previews::Lbrn2.parse_document(bytes)
            assert_equal expected, Maker::Previews::Lbrn2.job_size(doc), "#{name} job size must be unchanged"
            assert_match(/<svg/, Maker::Previews::Lbrn2.to_svg(bytes), "#{name} must still render SVG")
          end
        end

        # --- The `kind:` seam (Task 5) -------------------------------------------------------
        # `kind` selects the ARTIFACT: "geometry" is the JSON coordinate payload behind the
        # Measure view, and every other value (including the default) is the existing
        # thumbnail/PNG path. Pinned here, beside the dialect tests, because real-export.lbrn2
        # is the one fixture whose shape count ("geometry") and whose "still a PNG" path
        # (default) are both already asserted elsewhere in this file.

        test "render(kind: geometry) returns the JSON payload" do
          result = Maker::Previews::Lbrn2.render(fixture("real-export.lbrn2"), kind: "geometry")

          assert_equal "application/json", result[:content_type]
          assert_equal 4, JSON.parse(result[:bytes])["shapes"].length
        end

        test "render defaults to the thumbnail and is unchanged by the new kwarg" do
          result = Maker::Previews::Lbrn2.render(fixture("real-export.lbrn2"))

          assert_equal "image/png", result[:content_type]
          assert result[:metadata].present?, "the thumbnail path still carries LbrnMetadata"
        end

        test "geometry is an accepted preview kind and json maps to a .json asset" do
          assert_includes Maker::Preview::KINDS, "geometry"
          assert_equal ".json", Maker::GeneratePreviewJob.new.send(:asset_ext, "application/json")
        end

        def fixture(name) = File.binread(Rails.root.join("test/fixtures/files", name))
      end
    end
  end
end
