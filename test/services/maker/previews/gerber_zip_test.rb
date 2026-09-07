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
    # assertion, not a robustness one. THE BYTE BOUND IS TWO CASES BECAUSE IT IS TWO CHECKS: the
    # cheap pre-check on the DECLARED sizes, and — since a declared size is only what the archive
    # CLAIMS, and rubyzip's inflater never holds it to that — the capped read that actually binds.
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

      # THE PRE-CHECK: the DECLARED sizes, read off the central directory, refused before a byte is
      # inflated. Driven by lowering the constant rather than by building a 64 MB archive — the same
      # shape and a test that runs in milliseconds. What this case CANNOT show is that the bound
      # holds when the declaration is false; that is the next one.
      test "a zip whose declared size is past the extraction bound is unsupported" do
        error = with_extraction_bound(8) do
          assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
            Maker::Previews::GerberZip.svg_for(fusion_zip)
          end
        end
        assert_match(/extraction bound/, error.message)
      end

      # A DECLARED SIZE IS A CLAIM BY THE ARCHIVE, AND THE PRE-CHECK ABOVE TAKES IT ON TRUST.
      # rubyzip 3.6.0's `Zip::Inflater#read` never consults `decompressed_size` — only
      # `PassThruDecompressor`, for STORED entries, does — so a zip whose central directory lies
      # passes that check and then inflates without limit: measured in review at 209 MB written into
      # the tempdir and 104 s of node from a 407 KB archive, ending in an OOM kill. This is the case
      # for the bound that actually binds, the capped read.
      #
      # THE FIXTURE IS WRITTEN NORMALLY AND THEN PATCHED, so `listing_from` and `entries_by_name`
      # still parse it and the member still reaches the extraction loop. NOT the 32-bit size fields
      # at local+22 / central+24: rubyzip 3.6.0 writes 0xFFFFFFFF into both and puts the real sizes
      # in a ZIP64 EXTRA FIELD (measured — every archive it writes, at any size), so those four
      # bytes are not where the declared size lives. Patching them leaves `entry.size` reading out
      # of the zip64 record and, worse, makes rubyzip report the true uncompressed size as
      # `compressed_size`. The zip64 record is patched instead, in BOTH the local header and the
      # central directory, so the archive stays internally consistent the way a real one would be.
      #
      # 1 MB AGAINST A 4 MB PAYLOAD RATHER THAN 64 MB AGAINST 200: the mutation has to be
      # affordable. Restore the uncapped `read` and this case goes red having written ~4 MB, not
      # ~200 MB.
      #
      # REPLACING `run_node` WITH A RAISER IS THE "NOTHING WAS WRITTEN" ASSERTION. The refusal has
      # to happen inside the extraction loop, before the renderer is reached; if the cap is gone the
      # loop completes, `run_node` is called, and the sentinel — not Unsupported — comes out.
      test "a member that inflates past the extraction bound is refused before anything is rendered" do
        bound = 1024 * 1024
        bomb = size_lying_zip(GerberFixture::MINIMAL_GERBER * 40_000, declared: 100)
        entry = Maker::GerberArchive.entries_by_name(Maker::GerberArchive.open_zip(bomb))["board.gtl"]
        assert_equal 100, entry.size, "fixture: the archive has to DECLARE a tiny size"

        error = with_extraction_bound(bound) do
          replacing(Maker::Previews::Gerber, :run_node,
                    ->(*) { raise "run_node was reached — the bound did not refuse the member" }) do
            assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
              Maker::Previews::GerberZip.svg_for(bomb)
            end
          end
        end
        assert_match(/extraction bound/, error.message)
        assert_match(/#{bound}/, error.message, "the message names the bound it refused against")
      end

      # A NON-ASCII MEMBER NAME. `listing_from` reports names SCRUBBED to UTF-8 while `Zip::Entry`
      # keeps the raw ASCII-8BIT bytes it read, so `zip.find_entry(scrubbed)` MISSED and this board
      # answered "the archive does not hold Cámara_top.gbr" with nothing wrong with it (probed:
      # `find_entry` answers nil for the scrubbed spelling and the entry for the raw one). The one
      # scrubbing door, `Maker::GerberArchive.entries_by_name`, is what both readers now ask.
      test "a member whose name is not ASCII still resolves to its entry" do
        skip_without_node

        svg = Maker::Previews::GerberZip.svg_for(
          gerber_zip("Cámara_top.gbr" => GerberFixture::MINIMAL_GERBER)
        )
        assert_includes svg, "<svg"
        assert_includes svg, "<path", "the layer rendered, so its entry was found"
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

      # ONE SPELLING OF THE CONSTANT SWAP, shared by the two byte-bound cases above. `remove_const`
      # first, because `const_set` over an existing constant warns.
      def with_extraction_bound(bytes)
        original = Maker::Previews::GerberZip::MAX_EXTRACTED_BYTES
        Maker::Previews::GerberZip.send(:remove_const, :MAX_EXTRACTED_BYTES)
        Maker::Previews::GerberZip.const_set(:MAX_EXTRACTED_BYTES, bytes)
        yield
      ensure
        Maker::Previews::GerberZip.send(:remove_const, :MAX_EXTRACTED_BYTES)
        Maker::Previews::GerberZip.const_set(:MAX_EXTRACTED_BYTES, original)
      end

      # The house mutation-check helper (project_repo_card_test.rb, readme_test.rb and
      # project_folder_listing_test.rb carry the same body; there is no shared copy in
      # test_helper.rb). Minitest 6 has no Object#stub. `Maker::Previews::Gerber` is a
      # `module_function` module, so its methods live on the singleton class exactly like an
      # object's do.
      def replacing(owner, name, replacement)
        mod = owner.singleton_class
        own = mod.instance_methods(false).include?(name)
        original = mod.instance_method(name)
        mod.define_method(name, &replacement)
        yield
      ensure
        own ? mod.define_method(name, original) : mod.remove_method(name)
      end

      # A ZIP THAT LIES ABOUT ITS UNCOMPRESSED SIZE. Written by rubyzip so it is a real, parseable
      # archive, then patched in place — see the case above for why the zip64 extra field is the
      # thing to patch and the 32-bit size fields are not.
      ZIP64_EXTRA_ID = 0x0001

      def size_lying_zip(body, declared:, name: "board.gtl")
        buf = gerber_zip(name => body).b
        eocd = buf.rindex("PK\x05\x06".b) or flunk "fixture: no end-of-central-directory record"
        cd = buf[eocd + 16, 4].unpack1("V")
        # Local file header: 30 fixed bytes, name length at +26, extra length at +28.
        assert declare_zip64_size!(buf, 0, 30, 26, 28, declared),
               "fixture: no zip64 extra field in the local header"
        # Central directory record: 46 fixed bytes, name length at +28, extra length at +30.
        assert declare_zip64_size!(buf, cd, 46, 28, 30, declared),
               "fixture: no zip64 extra field in the central directory"
        buf
      end

      # Walks one record's extra fields ([id][len][payload]…) to the zip64 one and overwrites its
      # first member, the uncompressed size. Walked rather than assumed to be first: an extra block
      # holds whatever the writer put there, in whatever order.
      def declare_zip64_size!(buf, start, fixed_len, name_off, extra_off, declared)
        pos = start + fixed_len + buf[start + name_off, 2].unpack1("v")
        stop = pos + buf[start + extra_off, 2].unpack1("v")
        while pos + 4 <= stop
          id, len = buf[pos, 4].unpack("vv")
          if id == ZIP64_EXTRA_ID
            buf[pos + 4, 8] = [ declared ].pack("Q<")
            return true
          end
          pos += 4 + len
        end
        false
      end
    end
  end
end
