require "test_helper"

module Maker
  module Previews
    # THE RENDERERS' COLOURS COME FROM THE DESIGN SYSTEM'S TOKENS, AND THIS IS WHAT HOLDS THEM THERE.
    #
    # One palette is spelled in four places that cannot read each other: the CSS tokens the browser
    # paints the viewer and the card with (application.css), `Maker::Previews::Palette` (Ruby), the
    # STL crate's own constants (Rust, compiled into a binary), and the F3D/resvg/TextThumb calls
    # that use the Ruby ones. Drift between any two is silent — a thumbnail one shade off the viewer's
    # material, a tile whose ground survives the card's multiply as a tinted square — and nothing
    # else in the suite would notice, because no other test asks what colour anything is.
    #
    # STATIC ON PURPOSE. The CI runner image bakes `stl-thumbnailer` when the IMAGE is built, so on
    # CI an STL render comes from whatever crate that image saw, not from this checkout; a Ruby test
    # that asserted STL pixels would test the wrong binary. The crate's own `tests/render.rs`
    # proves its constants are what its pixels come out as; this file proves the constants are ours.
    #
    # EVERY PARSE ASSERTS IT MATCHED FIRST (§14e): a guard whose regex finds nothing compares nil
    # with nil, or nothing with nothing, and passes over a file that no longer says anything.
    class PaletteTest < ActiveSupport::TestCase
      CSS = Rails.root.join("app/assets/stylesheets/application.css")
      CRATE = Rails.root.join("tools/stl-thumbnailer/src/lib.rs")
      HEX = /\A#\h{6}\z/

      test "the palette is three lowercase six-digit hex colours" do
        { PAPER: Palette::PAPER, INK: Palette::INK, MATERIAL: Palette::MATERIAL }.each do |name, value|
          assert_match HEX, value, "Palette::#{name}"
          assert_equal value.downcase, value, "Palette::#{name} — the comparisons below are exact"
        end
        assert_equal "#ffffff", Palette::PAPER,
                     "the ground is multiplied onto the card, so it must be EXACTLY white"
      end

      # EVERY definition, not the first: the token is deliberately not redefined per theme (one
      # material reads on both viewer grounds), and a Graphite override would leave the thumbnails
      # drawn in a colour the dark viewer no longer uses.
      test "MATERIAL is the CSS --model-material, in every theme block that defines it" do
        defs = css.scan(/--model-material:\s*([^;]+);/).flatten.map(&:strip)
        assert_not_empty defs, "application.css no longer defines --model-material"
        defs.each do |value|
          assert_equal Palette::MATERIAL, value.downcase,
                       "--model-material is #{value}; Palette::MATERIAL is #{Palette::MATERIAL}"
        end
      end

      # THE FIRST `:root` BLOCK IS PAPER, the default theme (design-system.md rule 4); Graphite
      # redefines `--fg` to a light ink that would be invisible on a white thumbnail, so the
      # comparison has to be against that block and no other.
      test "INK is Paper's --fg, the first :root block's" do
        block = css[/^\s*:root\s*\{(.*?)^\s*\}/m, 1]
        assert_not_nil block, "application.css has no :root { … } block"
        assert_match(/color-scheme:\s*light/, block, "the first :root block is no longer Paper")

        fg = block[/^\s*--fg:\s*([^;]+);/, 1]
        assert_not_nil fg, "the Paper :root block no longer defines --fg"
        assert_equal Palette::INK, fg.strip.downcase,
                     "Paper's --fg is #{fg.strip}; Palette::INK is #{Palette::INK}"
      end

      test "the STL crate's BG is Palette::PAPER" do
        bytes = crate[/^const BG: \[u8; 3\] = \[(.*?)\];/m, 1]
        assert_not_nil bytes, "tools/stl-thumbnailer/src/lib.rs no longer has `const BG: [u8; 3] = [..];`"
        channels = bytes.split(",").map(&:strip)
        assert_equal 3, channels.size, "BG is not three channels: #{bytes}"
        channels.each { |c| assert_match(/\A0x\h{2}\z/, c, "BG channel #{c.inspect} is not a hex byte") }

        assert_equal Palette::PAPER, hex(channels.map { |c| Integer(c) }),
                     "the crate paints BG = [#{bytes}]"
      end

      # The crate spells MATERIAL as 0..1 floats (`0x7f as f32 / 255.0`, or a bare `0.498`); each is
      # converted back to a byte and ROUNDED, the inverse of what the shader does with it.
      test "the STL crate's MATERIAL is Palette::MATERIAL" do
        terms = crate[/^const MATERIAL: Vec3<f32> = Vec3::new\((.*?)\);/m, 1]
        assert_not_nil terms, "tools/stl-thumbnailer/src/lib.rs no longer has `const MATERIAL: Vec3<f32> = Vec3::new(..);`"
        channels = terms.split(",").map(&:strip).reject(&:empty?)
        assert_equal 3, channels.size, "MATERIAL is not three channels: #{terms}"

        bytes = channels.map do |term|
          unit = if (m = term.match(/\A(0x\h+|\d+) as f32 \/ 255(?:\.0)?\z/))
                   Integer(m[1]) / 255.0
          elsif term.match?(/\A\d*\.\d+\z/)
                   Float(term)
          end
          assert_not_nil unit, "cannot read MATERIAL channel #{term.inspect} — extend this parser"
          (unit * 255).round
        end
        assert_equal Palette::MATERIAL, hex(bytes), "the crate paints MATERIAL = (#{terms.squish})"
      end

      # BOTH ATTRIBUTE COLOURS AND ANY HEX ANYWHERE: a fill reverting to a literal fails the first
      # scan, and a stray `#1c2230` in some new attribute fails the second. The input text holds no
      # `#`, so every hex in the SVG is one of ours.
      test "TextThumb paints Palette::PAPER and Palette::INK and no other colour" do
        svg = TextThumb.to_svg("def hello\n  puts 1 < 2 && 'x'\nend\n", 512)

        painted = svg.scan(/\b(?:fill|stroke|stop-color|color)="([^"]*)"/).flatten.uniq
        assert_not_empty painted, "TextThumb's SVG paints nothing this scan can see"
        assert_equal [ Palette::INK, Palette::PAPER ].sort, painted.sort

        assert_equal [ Palette::INK, Palette::PAPER ].sort, svg.scan(/#\h{6}\b|#\h{3}\b/).uniq.sort
      end

      test "Mesh hands f3d Palette::PAPER as the ground and Palette::MATERIAL as the fallback colour" do
        argv = captured_argv(Mesh::F3D) do
          Mesh.render(File.binread(Rails.root.join("test/fixtures/files/tetra.obj")), size: 64, ext: "obj")
        end
        assert_includes argv, "--background-color=#{Palette::PAPER}"
        assert_includes argv, "--color=#{Palette::MATERIAL}"
      end

      test "SvgRasterizer hands resvg Palette::PAPER as the ground" do
        argv = captured_argv(SvgRasterizer.bin) do
          SvgRasterizer.to_png(%(<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>), size: 8)
        end
        at = argv.index("--background")
        assert_not_nil at, "resvg is no longer given --background"
        assert_equal Palette::PAPER, argv[at + 1]
      end

      private

      def css = File.read(CSS)

      def crate = File.read(CRATE)

      def hex(bytes) = format("#%02x%02x%02x", *bytes)

      FakeStatus = Struct.new(:success?, :exitstatus)

      # The argv a renderer hands `Open3.capture3`, with no binary involved: the fake writes a stand-in
      # PNG at the output path (`--output`'s value for f3d, the last argument for resvg) so the
      # renderer reads it back and returns exactly as it would.
      def captured_argv(bin, &)
        argv = nil
        fake = lambda do |*args, **|
          argv = args
          out = args.index("--output") ? args[args.index("--output") + 1] : args.last
          File.binwrite(out, "\x89PNG\r\n\x1A\n".b)
          [ "", "", FakeStatus.new(true, 0) ]
        end
        replacing(Open3, :capture3, fake, &)
        assert_not_nil argv, "the renderer never called Open3.capture3"
        assert_equal bin, argv.first, "the fake captured some other subprocess"
        argv
      end

      # The house replacement helper (Minitest 6 has no `Object#stub`).
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
