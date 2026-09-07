require "test_helper"
require "tmpdir"
require "support/gerber_fixture"

module Maker
  module Previews
    # THE ZIPPED-EXPORT THUMBNAIL — the board's top side, composed by tracespace under node from the
    # members `Maker::GerberArchive` says are the stack.
    #
    # THE EXTRACTION RULES ARE THE POINT OF THIS FILE. A zip's entry names are USER DATA: this
    # renderer is handed whatever a stranger uploaded, so the escape case below is a security
    # assertion, not a robustness one. The bounds are asserted on the DECLARED sizes, because a
    # bound that has to read the bytes first is not a bound.
    class GerberZipTest < ActiveSupport::TestCase
      include GerberFixture

      def skip_without_node
        skip "node not available (Maker::Previews::Gerber.available? is false — needs node on " \
             "PATH/NODE_BIN and tools/gerber-svg/tracespace.mjs from bin/build-tracespace)" unless
          Maker::Previews::GerberZip.available?
      end

      def skip_without_resvg
        skip "resvg not installed on this box" unless Maker::Previews::SvgRasterizer.available?
      end

      test "available? follows the layer renderer's toolchain" do
        assert_equal Maker::Previews::Gerber.available?, Maker::Previews::GerberZip.available?
      end

      test "a Fusion export renders a board SVG" do
        skip_without_node

        svg = Maker::Previews::GerberZip.svg_for(fusion_zip)
        assert_includes svg, "<svg"
        assert_includes svg, "<path", "the copper layer is a stroked path (measured)"
      end

      test "render returns a 512px PNG" do
        skip_without_node
        skip_without_resvg

        result = Maker::Previews::GerberZip.render(fusion_zip)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b, "expected a PNG signature"
        assert_equal 512, result[:width]
        assert_equal 512, result[:height]
      end

      # THE COMMITTED FIXTURE IS THE SAME ARCHIVE, and asserting that here is what lets
      # renderer_contract_test.rb use the file on disk while every case in this suite builds one in
      # memory. Not byte-equality: rubyzip stamps a DOS timestamp, which is why the fixture is
      # committed rather than rebuilt per run in the first place.
      test "the committed fixture holds the same board as the in-memory one" do
        committed = File.binread(Rails.root.join("test/fixtures/files/gerber-export.zip"))
        assert_equal Maker::GerberArchive.listing_from(fusion_zip).stacked,
                     Maker::GerberArchive.listing_from(committed).stacked
      end

      test "a zip with no Gerber member is unsupported" do
        assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::GerberZip.svg_for(gerber_zip("src/main.c" => "int main(){}"))
        end
      end

      test "bytes that are not a zip at all are unsupported" do
        assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::GerberZip.svg_for("PK not really")
        end
      end

      # A MEMBER NAME IS USER DATA AND MAY SAY `../`. It is written under its BASENAME in a
      # per-member subdirectory of the tempdir, so the traversal cannot leave it — and the layer
      # still renders, because the basename is what tracespace identifies a layer from anyway.
      #
      # THE NEGATIVE ASSERTION IS THE ONE THAT CARRIES THE WEIGHT: `Dir.mktmpdir` cleans up after
      # itself, so a file written OUTSIDE it survives the block and is what this looks for. Two
      # levels up from a tempdir under /var/folders/... is a real, writable directory on macOS and
      # /tmp on Linux, so this is not a hypothetical.
      test "a member named ../escape.gtl renders and writes nothing outside the tempdir" do
        skip_without_node

        # The renderer's tempdir is a direct child of Dir.tmpdir, so `File.join(dir, name)` for a
        # `../../escape.gtl` member resolves to exactly this — one level ABOVE the temp directory.
        escaped = File.expand_path("../escape.gtl", Dir.tmpdir)
        File.delete(escaped) if File.exist?(escaped)

        svg = Maker::Previews::GerberZip.svg_for(
          gerber_zip("../../escape.gtl" => GerberFixture::MINIMAL_GERBER)
        )
        assert_includes svg, "<svg"
        assert_not File.exist?(escaped),
                   "a zip member's own path was used as the write destination — #{escaped} escaped"
      end

      # BOUNDED BEFORE ANY WRITE. 65 tiny members is one past MAX_MEMBERS, and the refusal must
      # happen without extracting: the message names the count, and nothing is written because the
      # raise precedes `Dir.mktmpdir` entirely.
      test "a zip past MAX_MEMBERS is unsupported" do
        members = (1..(Maker::Previews::GerberZip::MAX_MEMBERS + 1)).to_h do |i|
          [ "layers/l#{i}.gbr", GerberFixture::MINIMAL_GERBER ]
        end

        error = assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::GerberZip.svg_for(gerber_zip(members))
        end
        assert_match(/MAX_MEMBERS/, error.message)
        assert_match(/#{Maker::Previews::GerberZip::MAX_MEMBERS + 1} layers/, error.message)
      end

      # THE BYTE BOUND IS ON THE DECLARED SIZE, so it is checked against the central directory and
      # never by reading. Driven by lowering the constant rather than by building a 64 MB archive —
      # the same shape and a test that runs in milliseconds.
      test "a zip whose declared size is past the extraction bound is unsupported" do
        original = Maker::Previews::GerberZip::MAX_EXTRACTED_BYTES
        Maker::Previews::GerberZip.send(:remove_const, :MAX_EXTRACTED_BYTES)
        Maker::Previews::GerberZip.const_set(:MAX_EXTRACTED_BYTES, 8)

        error = assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::GerberZip.svg_for(fusion_zip)
        end
        assert_match(/extraction bound/, error.message)
      ensure
        Maker::Previews::GerberZip.send(:remove_const, :MAX_EXTRACTED_BYTES)
        Maker::Previews::GerberZip.const_set(:MAX_EXTRACTED_BYTES, original)
      end

      # TWO MEMBERS SHARING A BASENAME must both survive: each goes into its own numbered
      # subdirectory, so the second cannot overwrite the first. Collapsing that to one directory
      # renders a board missing a layer, silently.
      test "two same-named members in different folders both reach the render" do
        skip_without_node

        svg = Maker::Previews::GerberZip.svg_for(
          gerber_zip("a/copper_top.gbr" => GerberFixture::MINIMAL_GERBER,
                     "b/copper_top.gbr" => GerberFixture::MINIMAL_GERBER)
        )
        assert_includes svg, "<svg"
      end
    end
  end
end
