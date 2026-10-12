require "test_helper"

module Maker
  class PrintablesPdfTest < ActiveSupport::TestCase
    TEXT = File.read(Rails.root.join("test/fixtures/files/printables_pdfium_synthetic.txt"), encoding: "UTF-8")

    # The fixture is SYNTHETIC: its words were written for this suite, and only its line structure
    # copies what pdfium produced for a real Printables PDF. The real dump it replaced was a
    # third-party CC BY-NC page, which a commercial repository cannot redistribute.
    test "extracts every field from a Printables PDF's pdfium text" do
      d = Maker::PrintablesPdf.extract(text: TEXT, filename: "100001-hex-pegboard-panel-x.pdf",
                                       title: "Hex Pegboard Panel")
      assert_equal "Fixture Maker", d[:designer]
      assert_equal "CC BY-NC 4.0", d[:license]
      assert_match(/Interlocking hex panel/, d[:description])
      assert_equal %w[organizer pegboard hooks storage], d[:tags]
      assert_equal "https://www.printables.com/model/100001", d[:source_url]
      ps = d[:print_settings]
      assert_equal "0.20 mm", ps["layer_height"]
      assert_equal "0.40 mm", ps["nozzle"]
      assert_equal "PETG", ps["material"]
      assert_equal "41 g", ps["filament"]
      assert_equal "2.15 hrs", ps["print_time"]
      assert_equal "Household > Other House Equipment", ps["category"]
      assert_equal "Original Prusa MK4", ps["printer"]
    end

    test "non-Printables / blank text yields {} and never raises" do
      assert_equal({}, Maker::PrintablesPdf.extract(text: "random text\nno structure", filename: "x.pdf", title: "X"))
      assert_equal({}, Maker::PrintablesPdf.extract(text: nil, filename: nil, title: nil))
    end

    test "designer is nil (not a wrapped last line) when the whole preamble is title words" do
      # Repro of the negative-index wraparound: every line above VIEW IN BROWSER is a title word,
      # so j runs off the top; it must omit designer, not return lines[-1].
      d = Maker::PrintablesPdf.extract(text: "Foo\nBar\nVIEW IN BROWSER\n", filename: "1-x.pdf", title: "Foo Bar")
      assert_nil d[:designer]
    end

    test "designer is skipped when the title does not anchor above VIEW IN BROWSER" do
      # No title -> can't peel title lines -> no (possibly wrong) designer guessed.
      d = Maker::PrintablesPdf.extract(text: TEXT, filename: "1-x.pdf", title: nil)
      assert_nil d[:designer]
      assert_equal "CC BY-NC 4.0", d[:license] # other fields still extract
    end
  end
end
