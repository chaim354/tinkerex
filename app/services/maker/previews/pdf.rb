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

      EXTENSIONS = %w[pdf].freeze

      BIN = ENV.fetch("PDFIUM_BIN", "pdfium").freeze

      def available?
        Open3.capture2e(BIN, "--version")
        true
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      # Page 1 → a size×size-bounded PNG (aspect preserved). Returns { bytes:, content_type:, width:, height: }.
      def render(pdf_bytes, size: 512)
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
