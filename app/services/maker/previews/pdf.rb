require "open3"
require "tempfile"

module Maker
  module Previews
    # PDF → page-1 PNG grid thumbnail via the bundled `pdfium` binary (klippa pdfium-cli: MIT wrapper +
    # BSD-3 pdfium — permissive, CLAUDE.md §9). The self-contained WASM build embeds pdfium, so there
    # is no libpdfium.so to ship alongside and NO GPL/AGPL PDF stack (poppler/mupdf/ghostscript).
    #
    # This is only the GRID thumbnail. The DETAIL view embeds the whole PDF for the browser's own
    # viewer (FilesController's :pdf kind) — that path needs no server tool at all.
    #
    # `available?` gates on the binary (overridable via PDFIUM_BIN); a box without it degrades PDF to
    # `unsupported`, the same graceful path Stl/Mesh take without their binaries.
    module Pdf
      module_function

      RenderError = Class.new(StandardError)

      # `.ai` IS A PDF WHEN ILLUSTRATOR SAVED IT AS ONE, AND ONLY THEN (stage 4, S4-2; story 2.3).
      # "Create PDF Compatible File" is Illustrator's default and has been for two decades, so the
      # `.ai` files on a real share (25 of them, 2026-09-07) begin `%PDF-` with Illustrator's own
      # private stream appended — pdfium renders page 1 of one exactly as it renders any PDF. The
      # extension alone cannot tell that from a bare PostScript save, so the bytes decide (below).
      #
      # THIS IS THE GRID/POSTER THUMBNAIL ONLY. `FilesController#preview_kind` answers `:thumbnail`
      # for `.ai` (nothing above it claims the extension) rather than `:pdf`: the `:pdf` branch
      # embeds the file for the BROWSER's own viewer, and a browser handed `application/…` bytes
      # named `.ai` downloads it. Rendering the first page as a picture is the honest offer.
      EXTENSIONS = %w[pdf ai].freeze

      # Byte 0. The PDF spec puts the header there; every Illustrator export this was checked
      # against does too. A tolerant "somewhere in the first 1024 bytes" scan was considered and
      # refused: it buys a file nobody has produced and costs the ability to say plainly what this
      # renderer accepts.
      MAGIC = "%PDF-".b.freeze

      BIN = ENV.fetch("PDFIUM_BIN", "pdfium").freeze

      def available?
        Open3.capture2e(BIN, "--version")
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # Page 1 → a size×size-bounded PNG (aspect preserved). Returns { bytes:, content_type:, width:, height: }.
      def render(pdf_bytes, size: 512)
        # UNSUPPORTED, NOT FAILED, AND THE DIFFERENCE IS WHETHER IT RETRIES FOREVER.
        # Maker::Previews::Enqueue treats `failed` as "retry me", so a PostScript `.ai` would
        # re-render on every scan, forever, wearing an error badge over a file with nothing wrong
        # with it. `unsupported` is this job's word for "no preview for this file here" and is
        # terminal. Maker::Previews::Gerber makes the identical call for a layer that plots
        # nothing, and Maker::Previews::GerberZip for a zip that is not a board.
        #
        # ON THE BYTES, NOT ON THE EXTENSION: a `.pdf` that is not a PDF gets the same terminal
        # state instead of pdfium's exit code rendered as an error. That is a behaviour change for
        # `.pdf` and it is the right one — nothing about those bytes will ever render.
        unless pdf_bytes.to_s.b.start_with?(MAGIC)
          raise ::Maker::GeneratePreviewJob::Unsupported,
                "not a PDF (no %PDF- header at byte 0) — an Illustrator file saved without " \
                "PDF compatibility, or a file whose extension is wrong"
        end

        Tempfile.create([ "pdf-in", ".pdf" ]) do |fin|
          fin.binmode
          fin.write(pdf_bytes.b)
          fin.flush

          out_path = "#{fin.path}.png"
          begin
            _stdout, stderr, status = Open3.capture3(
              BIN, "render", fin.path, out_path,
              "--pages", "first", "--file-type", "png",
              "--max-width", size.to_s, "--max-height", size.to_s
            )
            unless status.success? && File.exist?(out_path) && File.size?(out_path)
              raise RenderError, "pdfium failed (#{status.exitstatus}): #{stderr.to_s[0, 300]}"
            end

            { bytes: File.binread(out_path), content_type: "image/png", width: size, height: size }
          ensure
            File.delete(out_path) if File.exist?(out_path)
          end
        end
      rescue Errno::ENOENT => e
        raise RenderError, "pdfium not runnable: #{e.message}"
      end
    end
  end
end
