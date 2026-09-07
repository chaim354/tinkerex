require "tmpdir"

module Maker
  module Previews
    # A ZIPPED GERBER EXPORT -> the BOARD's top side as a thumbnail; ANY OTHER ZIP -> `unsupported`.
    # Every CAM tool hands a board over as a zip (files-preview.md), so the artefact a fab house
    # takes is the one whose tile most wants a picture. Registering `zip` means every zip in a
    # library gets one bounded read and a preview row; a zip of firmware terminates in the job's
    # ordinary `unsupported` state (GeneratePreviewJob::Unsupported, the class Mesh raises for GLB)
    # and is never read again until its content changes. That is the price of the board thumbnail,
    # and it is bounded by the job's own 32 MB MAX_PREVIEW_BYTES ceiling before a byte is fetched.
    #
    # Maker::GerberArchive.listing_from DECIDES WHICH MEMBERS ARE THE BOARD (its job-file rule
    # inside the archive), so this renderer and the zip's own file page agree about the stack rather
    # than each choosing its own layers. Members are resolved through the SAME SCRUBBED NAMES the
    # listing answers with (Maker::GerberArchive.entries_by_name) and extracted to a tempdir UNDER
    # THEIR BASENAME (tracespace identifies a layer from its name), one subdirectory per member so
    # two same-named members in different folders cannot collide — and NEVER under the member's own
    # path: a zip's entry names are user data and may say `../`.
    #
    # BOUNDED TWICE MORE: MAX_MEMBERS layers, and MAX_EXTRACTED_BYTES of extracted bytes — both
    # refused as Unsupported.
    #
    # THE BYTE BOUND IS TWO CHECKS AND IT NEEDS BOTH. The DECLARED sizes are checked first, off the
    # central directory, before a byte is inflated: that is the cheap and honest answer for the
    # ordinary oversized export, and it costs nothing because those sizes are already read. But a
    # declared size is a CLAIM MADE BY THE ARCHIVE, and rubyzip does not hold the inflater to it —
    # `Zip::Inflater#read` (3.6.0) never consults `decompressed_size`; only `PassThruDecompressor`,
    # for STORED entries, does. Measured in review: a hand-built 407 KB zip whose central directory
    # declared `size: 100` passed the pre-check and then inflated 209 MB into the tempdir, ran for
    # 104 s and got node OOM-killed. So the ACTUAL read is capped as well, per member and against a
    # RUNNING TOTAL — `read(remaining + 1)` comes back one byte longer than the budget exactly when
    # this member would overrun it, and the member is refused BEFORE it is written. Neither check
    # replaces the other: the pre-check alone is not a bound at all, and the capped read alone would
    # inflate up to the whole 64 MB budget for an archive that says up front it is far bigger.
    module GerberZip
      module_function

      EXTENSIONS = %w[zip].freeze
      MAX_MEMBERS = 64
      MAX_EXTRACTED_BYTES = 64 * 1024 * 1024

      # The same node + bundle question, asked once. A zip has no separate toolchain.
      def available? = Maker::Previews::Gerber.available?

      THUMBNAIL_REVISION = 1

      def payload_revision(_kind) = THUMBNAIL_REVISION

      def render(bytes, size: 512)
        svg = svg_for(bytes)
        png = Maker::Previews::SvgRasterizer.to_png(svg, size:, stylesheet: nil)
        { bytes: png.b, content_type: "image/png", width: size, height: size }
      end

      def svg_for(bytes)
        listing = Maker::GerberArchive.listing_from(bytes) or
          raise ::Maker::GeneratePreviewJob::Unsupported, "not a Gerber export"
        zip = Maker::GerberArchive.open_zip(bytes) or
          raise ::Maker::GeneratePreviewJob::Unsupported, "not a readable zip"

        members = listing.stacked
        if members.size > MAX_MEMBERS
          raise ::Maker::GeneratePreviewJob::Unsupported,
                "#{members.size} layers is past MAX_MEMBERS (#{MAX_MEMBERS})"
        end

        # RESOLVED THROUGH THE LISTING'S OWN SCRUBBED NAMES, NEVER `zip.find_entry`. `listing.stacked`
        # holds names forced to UTF-8 and scrubbed; `find_entry` matches the RAW ASCII-8BIT name it
        # read off the archive, so a member called `Cámara_top.gbr` missed and the whole board came
        # back `unsupported` — a real board with a thumbnail-shaped hole in it, not a hypothetical
        # (probed in review). One place scrubs (Maker::GerberArchive.entries_by_name) and both
        # readers ask it, so the two cannot drift apart again.
        #
        # The nil arm stays: an archive whose stacked name has no entry would otherwise be a
        # NoMethodError 500 where every other malformed-archive outcome here is `unsupported`.
        by_name = Maker::GerberArchive.entries_by_name(zip)
        entries = members.map do |name|
          by_name[name] or
            raise ::Maker::GeneratePreviewJob::Unsupported, "the archive does not hold #{name}"
        end

        declared = entries.sum { |entry| entry.size.to_i }
        if declared > MAX_EXTRACTED_BYTES
          raise ::Maker::GeneratePreviewJob::Unsupported,
                "declared #{declared} bytes is past the extraction bound (#{MAX_EXTRACTED_BYTES})"
        end

        Dir.mktmpdir("gerber-board") do |dir|
          written = 0
          paths = entries.each_with_index.map do |entry, i|
            sub = File.join(dir, i.to_s)
            Dir.mkdir(sub)
            # File.basename ONLY — never File.join(dir, entry.name). A member named
            # `../../escape.gtl` would otherwise be written outside the tempdir, by a renderer
            # whose whole input is a file some stranger uploaded. The per-index subdirectory is
            # what lets two folders' `copper_top.gbr` both keep their real basename, which is the
            # name tracespace identifies the layer from.
            path = File.join(sub, File.basename(entry.name))
            # THE BOUND THAT ACTUALLY BINDS (see the header). `remaining + 1` is the whole trick:
            # a member that fits comes back at most `remaining` bytes long, and one that does not
            # comes back exactly one byte longer — so the overrun is detectable without ever
            # holding more than the budget, and `binwrite` never runs for it. `to_s` because
            # `read(n)` answers nil at EOF for an empty member.
            remaining = MAX_EXTRACTED_BYTES - written
            body = entry.get_input_stream.read(remaining + 1).to_s
            if body.bytesize > remaining
              raise ::Maker::GeneratePreviewJob::Unsupported,
                    "a member inflated past the extraction bound (#{MAX_EXTRACTED_BYTES})"
            end
            written += body.bytesize
            File.binwrite(path, body)
            path
          end
          Maker::Previews::Gerber.run_node("board", *paths)
        end
      end
    end
  end
end
