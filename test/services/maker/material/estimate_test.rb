require "test_helper"

module Maker
  module Material
    # ONE ESTIMATE, BUILT FROM ONE REQUEST'S FORM (spec 2026-11-22, "State and requests" and
    # "Limits"). The hidden fields are user-supplied, so every number is re-read here; a forged one
    # only ever changes the forger's own estimate, and these tests pin that it cannot do worse.
    class EstimateTest < ActiveSupport::TestCase
      def row(name: "a.svg", width: "100", height: "50", qty: "1", **rest) = { "name" => name, "width" => width, "height" => height, "qty" => qty }.merge(rest.transform_keys(&:to_s))

      def estimate(rows, **stock)
        parts = rows.each_with_index.to_h { |r, i| [ i.to_s, r ] }
        Estimate.from_params(parts:, stock: { "sheet_width" => "200", "sheet_height" => "100", "gap" => "0",
                                              "unit" => "mm", "rotate" => "0" }.merge(stock.transform_keys(&:to_s)))
      end

      test "a first visit sends nothing and gets the default stock" do
        est = Estimate.from_params(parts: nil, stock: {})
        assert_equal Estimate::DEFAULT_STOCK, est.stock
        assert_empty est.parts
        assert_empty est.errors
      end

      test "parts read in index order, quantities clamped" do
        parts = { "1" => row(name: "b.svg", qty: "9999"), "0" => row(name: "a.svg", qty: "0"), "2" => row(name: "c.svg", qty: "abc") }
        est = Estimate.from_params(parts:, stock: {})

        assert_equal %w[a.svg b.svg c.svg], est.parts.map(&:name)
        assert_equal [ 1, Estimate::MAX_QTY, 1 ], est.parts.map(&:qty)
      end

      test "a forged or unreadable size is refused, never packed" do
        est = estimate([ row(width: "-5"), row(width: "abc"), row(width: "20000"), row(width: "0", height: "0") ])
        assert_equal [ "size could not be read" ], est.parts.map(&:reason).uniq
        assert_empty est.measured_parts
      end

      test "a forged shape where a hash is expected is ignored, never raised on" do
        [ "x", 5, [ "x" ], [ %w[a b] ], { "0" => [ "x" ] }, { "0" => "x" }, { "0" => nil } ].each do |forged|
          assert_empty Estimate.from_params(parts: forged, stock: {}).parts, "parts: #{forged.inspect}"
        end
        [ "x", 3, [ "x" ] ].each do |forged|
          assert_equal Estimate::DEFAULT_STOCK, Estimate.from_params(parts: nil, stock: forged).stock, "stock: #{forged.inspect}"
        end
        assert_equal [ "a.svg" ], Estimate.from_params(parts: { "0" => [ "x" ], "1" => row }, stock: {}).parts.map(&:name)
      end

      test "a straight line is a part" do
        assert estimate([ row(width: "50", height: "0") ]).parts.first.measured?
      end

      test "a refused row stays refused, with its reason" do
        part = estimate([ row(reason: "no measurable shapes", width: "", height: "") ]).parts.first
        refute part.measured?
        assert_equal "no measurable shapes", part.reason
      end

      test "five 100 x 50 parts need two 200 x 100 sheets, and the arithmetic adds up" do
        est = estimate([ row(qty: "5") ])

        assert_empty est.errors
        assert_equal 5, est.copies
        assert_equal 2, est.sheets.size
        assert_in_delta 25_000.0, est.total_area_mm2, 1e-6
        assert_in_delta 0.625, est.utilization, 1e-9
      end

      test "inches convert to millimetres for the packer" do
        est = estimate([ row(width: "100", height: "100") ], sheet_width: "12", sheet_height: "12", gap: "0.125", unit: "in")
        assert_in_delta 304.8, est.stock.width_mm, 1e-9
        assert_in_delta 3.175, est.stock.gap_mm, 1e-9
        assert_equal 1, est.sheets.size
      end

      test "a part too big for the sheet is named, kept out of the count and kept in the area" do
        est = estimate([ row(name: "big.svg", width: "400", height: "400", qty: "2") ])
        assert_empty est.sheets
        assert_equal [ [ "big.svg", 2 ] ], est.unplaced.map { |part, n| [ part.name, n ] }
        assert_in_delta 320_000.0, est.total_area_mm2, 1e-6
      end

      # UTILIZATION IS THE PLACED PARTS' OWN AREA over the sheets used: never the gap-inflated size
      # the packer works in, and never an unplaced part's area (which the total keeps). With a gap
      # of 5 one 100 x 50 part fills a 200 x 100 sheet, so two sheets hold 10,000 of 40,000 mm².
      # Gap-inflated would read 0.28875; dividing the total area would read 12.25.
      test "utilization counts only the placed parts' own area" do
        est = estimate([ row(qty: "2"), row(name: "big.svg", width: "400", height: "400", qty: "3") ], gap: "5")
        assert_equal 2, est.sheets.size
        assert_in_delta 490_000.0, est.total_area_mm2, 1e-6
        assert_in_delta 0.25, est.utilization, 1e-9
      end

      test "a bad sheet or gap is an error and nothing is packed" do
        assert_equal [ "Enter the sheet's width and height." ], estimate([ row ], sheet_width: "").errors
        assert_equal [ "Each side of the sheet must be between 1 and 10,000 mm." ], estimate([ row ], sheet_width: "0.5").errors
        assert_equal [ "The gap must be between 0 and 100 mm." ], estimate([ row ], gap: "101").errors
        assert_nil estimate([ row ], gap: "101").pack
      end

      test "more copies than the limit is an error, not a slow request" do
        est = estimate(Array.new(5) { row(qty: "500") })
        assert_equal [ "Too many copies to lay out: 2,500. The limit is 2,000." ], est.errors
        assert_nil est.pack
      end

      test "adding past the list's limit says how many were left out" do
        full = Estimate.new(parts: Array.new(Estimate::MAX_PARTS - 1) { Part.measured(name: "x", width: 1.0, height: 1.0) },
                            stock: Estimate::DEFAULT_STOCK)
        more = Array.new(4) { Part.measured(name: "y", width: 1.0, height: 1.0) }
        added = full.adding(more)

        assert_equal Estimate::MAX_PARTS, added.parts.size
        assert_equal [ "Left out 3 parts: the list holds at most 200." ], added.notes
      end

      test "without removes one row by index and ignores an index that is not one" do
        est = estimate([ row(name: "a.svg"), row(name: "b.svg") ])
        assert_equal [ "b.svg" ], est.without(0).parts.map(&:name)
        assert_equal 2, est.without(7).parts.size
        assert_equal 2, est.without(nil).parts.size
      end
    end
  end
end
