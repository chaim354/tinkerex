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
    # than each choosing its own layers. Members are extracted to a tempdir UNDER THEIR BASENAME
    # (tracespace identifies a layer from its name), one subdirectory per member so two same-named
    # members in different folders cannot collide — and NEVER under the member's own path: a zip's
    # entry names are user data and may say `../`.
    #
    # BOUNDED TWICE MORE, BEFORE ANYTHING IS WRITTEN: MAX_MEMBERS layers and MAX_EXTRACTED_BYTES of
    # DECLARED size, both refused as Unsupported. Declared, not actual, is the point — the whole
    # reason to check is to avoid writing the bytes, so a check that has to read them first checks
    # nothing (the zip-bomb shape).
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

        entries = members.map do |name|
          # `find_entry` answers nil for a name the archive does not hold. `listing_from` read the
          # same central directory, so this cannot happen today — but a NoMethodError on nil below
          # would be a 500 where every other malformed-archive outcome here is `unsupported`.
          zip.find_entry(name) or
            raise ::Maker::GeneratePreviewJob::Unsupported, "the archive does not hold #{name}"
        end

        declared = entries.sum { |entry| entry.size.to_i }
        if declared > MAX_EXTRACTED_BYTES
          raise ::Maker::GeneratePreviewJob::Unsupported,
                "declared #{declared} bytes is past the extraction bound (#{MAX_EXTRACTED_BYTES})"
        end

        Dir.mktmpdir("gerber-board") do |dir|
          paths = entries.each_with_index.map do |entry, i|
            sub = File.join(dir, i.to_s)
            Dir.mkdir(sub)
            # File.basename ONLY — never File.join(dir, entry.name). A member named
            # `../../escape.gtl` would otherwise be written outside the tempdir, by a renderer
            # whose whole input is a file some stranger uploaded. The per-index subdirectory is
            # what lets two folders' `copper_top.gbr` both keep their real basename, which is the
            # name tracespace identifies the layer from.
            path = File.join(sub, File.basename(entry.name))
            File.binwrite(path, entry.get_input_stream.read)
            path
          end
          Maker::Previews::Gerber.run_node("board", *paths)
        end
      end
    end
  end
end
