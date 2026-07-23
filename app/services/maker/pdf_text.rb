require "open3"

module Maker
  # Plain text from a PDF via the bundled pdfium CLI (klippa, MIT/BSD — §9; the same binary
  # Maker::Previews::Pdf renders with). `--text-page-header=false` drops "Page N" lines. Returns
  # scrubbed UTF-8, or nil if pdfium is unavailable or errors — the feature then no-ops, exactly
  # as the Stl/Mesh/Pdf previews degrade without their binaries.
  module PdfText
    module_function

    BIN = ENV.fetch("PDFIUM_BIN", "pdfium").freeze

    def available?
      Open3.capture2e(BIN, "--version")
      true
    rescue StandardError
      false
    end

    def extract(path)
      out, status = Open3.capture2(BIN, "text", path.to_s, "-", "--text-page-header=false")
      status.success? ? out.scrub.presence : nil
    rescue StandardError
      nil
    end
  end
end
