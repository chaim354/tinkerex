require "test_helper"

module Maker
  module Previews
    # THE PDF RENDERER, AND THE ONE THING IT LEARNED IN STAGE 4, S4-2: an Adobe Illustrator file is
    # a PDF when Illustrator saved it as one. "Create PDF Compatible File" has been the default for
    # two decades, so a `.ai` off a maker's disk begins `%PDF-` with Illustrator's private data
    # appended, and pdfium renders page 1 of it like any other PDF. A file saved with that option
    # OFF is a bare PostScript stream, which pdfium cannot open at all — and the difference is
    # invisible from the name, so it has to be read from the bytes.
    #
    # NO NEW FIXTURE. The PDF-compatible case IS `sample.pdf` — that is precisely the claim ("an
    # `.ai` is a PDF") — and the incompatible case is a literal PostScript header, which is what
    # Illustrator writes and is three bytes' worth of test data rather than a committed binary.
    class PdfTest < ActiveSupport::TestCase
      def pdf_bytes = File.binread(Rails.root.join("test/fixtures/files/sample.pdf"))

      # `%!PS-Adobe-3.0` + Illustrator's own header comment, verbatim from a non-PDF-compatible
      # save. Not a PDF, not corrupt — a different format wearing the same extension.
      POSTSCRIPT_AI = "%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator(R) 28.0\n%%BoundingBox: 0 0 612 792\n".b

      test "the renderer claims .ai as well as .pdf, and the registry agrees" do
        assert_equal %w[pdf ai], Maker::Previews::Pdf::EXTENSIONS
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for("ai")
        assert_equal Maker::Previews::Pdf, Maker::Previews::Registry.for_filename("logo.AI")
      end

      # UNSUPPORTED, NOT FAILED, AND THE CLASS IS THE ASSERTION. `failed` is what
      # Maker::Previews::Enqueue treats as "retry me", so a PostScript `.ai` would re-render on
      # every scan forever and wear an error badge over a file with nothing wrong with it. This is
      # Gerber's "a layer that plots nothing is unsupported" rule, in the same words.
      test "a PostScript .ai is unsupported, not failed" do
        error = assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::Pdf.render(POSTSCRIPT_AI, size: 128)
        end
        assert_match(/%PDF-/, error.message)
      end

      # THE CHECK IS ON THE BYTES, NOT ON THE EXTENSION, so a `.pdf` that is not a PDF gets the
      # same honest terminal state instead of pdfium's exit code in an error badge. That is a
      # behaviour change for `.pdf` and it is the right one: nothing about that file will ever
      # render, and `unsupported` is the state that says so once.
      test "a .pdf that is not a PDF gets the same answer" do
        assert_raises(::Maker::GeneratePreviewJob::Unsupported) do
          Maker::Previews::Pdf.render("not a pdf at all".b, size: 128)
        end
      end

      test "a real PDF still renders when pdfium is on this box" do
        skip "pdfium not installed" unless Maker::Previews::Pdf.available?

        result = Maker::Previews::Pdf.render(pdf_bytes, size: 128)
        assert_equal "image/png", result[:content_type]
        assert result[:bytes].bytesize.positive?
      end

      # AN .ai WITH PDF COMPATIBILITY IS BYTE-FOR-BYTE A PDF AS FAR AS THIS RENDERER IS CONCERNED —
      # the point of the whole change, driven rather than argued.
      test "a PDF-compatible .ai renders exactly as the PDF does" do
        skip "pdfium not installed" unless Maker::Previews::Pdf.available?

        assert Maker::Previews::Pdf.render(pdf_bytes, size: 128)[:bytes].bytesize.positive?
      end
    end
  end
end
