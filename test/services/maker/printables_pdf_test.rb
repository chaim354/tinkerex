require "test_helper"

module Maker
  class PrintablesPdfTest < ActiveSupport::TestCase
    TEXT = File.read(Rails.root.join("test/fixtures/files/printables_honeycomb_pdfium.txt"), encoding: "UTF-8")

    test "extracts every field from a real Printables PDF's pdfium text" do
      d = Maker::PrintablesPdf.extract(text: TEXT, filename: "152592-honeycomb-storage-wall-x.pdf",
                                       title: "Honeycomb Storage Wall")
      assert_equal "RostaP", d[:designer]
      assert_equal "CC BY-NC 4.0", d[:license]
      assert_match(/Wall for attaching hooks/, d[:description])
      assert_equal %w[organizer wall hooks storrage], d[:tags]
      assert_equal "https://www.printables.com/model/152592", d[:source_url]
      ps = d[:print_settings]
      assert_equal "0.28 mm", ps["layer_height"]
      assert_equal "0.40 mm", ps["nozzle"]
      assert_equal "PET", ps["material"]
      assert_equal "58 g", ps["filament"]
      assert_equal "3.88 hrs", ps["print_time"]
      assert_equal "Household > Other House Equipment", ps["category"]
      assert_match(/Prusa MINI/, ps["printer"])
    end

    test "non-Printables / blank text yields {} and never raises" do
      assert_equal({}, Maker::PrintablesPdf.extract(text: "random text\nno structure", filename: "x.pdf", title: "X"))
      assert_equal({}, Maker::PrintablesPdf.extract(text: nil, filename: nil, title: nil))
    end

    test "designer is skipped when the title does not anchor above VIEW IN BROWSER" do
      # No title -> can't peel title lines -> no (possibly wrong) designer guessed.
      d = Maker::PrintablesPdf.extract(text: TEXT, filename: "1-x.pdf", title: nil)
      assert_nil d[:designer]
      assert_equal "CC BY-NC 4.0", d[:license] # other fields still extract
    end
  end
end
