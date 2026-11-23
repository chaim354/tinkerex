require "test_helper"

module Maker
  module Material
    # RECTANGLES ONTO SHEETS (spec 2026-11-22, "Packing"). Every expected layout below was worked by
    # hand against MaxRects best-short-side-fit; the property test at the end pins the four promises
    # on random input, so a layout change that breaks one cannot hide behind the hand-checked cases.
    class SheetPackTest < ActiveSupport::TestCase
      Item = Data.define(:label, :width, :height)

      def items(count, width, height, prefix: "p") = Array.new(count) { |i| Item.new(label: "#{prefix}#{i}", width:, height:) }

      def pack(list, w, h, gap: 0, rotate: false) = SheetPack.call(list, sheet_width: w, sheet_height: h, gap:, rotate:)

      test "four squares fill one sheet, corner to corner" do
        result = pack(items(4, 100, 100), 200, 200)

        assert_equal 1, result.sheets.size
        assert_equal [ [ 0.0, 0.0 ], [ 0.0, 100.0 ], [ 100.0, 0.0 ], [ 100.0, 100.0 ] ],
                     result.sheets.first.map { |pl| [ pl.x, pl.y ] }.sort
        assert_empty result.unplaced
      end

      test "a fifth square opens a second sheet" do
        assert_equal [ 4, 1 ], pack(items(5, 100, 100), 200, 200).sheets.map(&:size)
      end

      # LARGEST AREA FIRST: the 200 x 200 sheet holds this set in either order, so the sheet count
      # alone cannot see the order; the first placement's label can.
      test "a large part and two small ones share a sheet" do
        list = items(2, 100, 100) + [ Item.new(label: "lid", width: 200, height: 100) ]
        result = pack(list, 200, 200)

        assert_equal 1, result.sheets.size
        assert_equal "lid", result.sheets.first.first.item.label
      end

      # THE GAP IS KEPT BETWEEN PARTS AND FROM EVERY EDGE: two 98 mm squares side by side need
      # 2 + 98 + 2 + 98 + 2 = 202 mm, so a 200 mm sheet holds one with gap 2 — and four with gap 1
      # (1 + 98 + 1 + 98 + 1 = 199).
      test "the gap holds between parts and at the edges" do
        assert_equal 4, pack(items(4, 98, 98), 200, 200, gap: 2).sheets.size
        one = pack(items(4, 98, 98), 200, 200, gap: 1)
        assert_equal 1, one.sheets.size
        assert_equal [ 1.0, 100.0 ], one.sheets.first.map(&:x).uniq.sort
      end

      test "rotation is tried only when allowed" do
        list = items(2, 150, 50)

        rotated = pack(list, 100, 200, rotate: true)
        assert_equal 1, rotated.sheets.size
        assert rotated.sheets.first.all?(&:rotated)
        assert_equal [ [ 50.0, 150.0 ] ], rotated.sheets.first.map { |pl| [ pl.width, pl.height ] }.uniq

        upright = pack(list, 100, 200, rotate: false)
        assert_empty upright.sheets
        assert_equal list, upright.unplaced
      end

      test "a part too big for the sheet is unplaced, by the usable area inside the gap" do
        big = Item.new(label: "big", width: 400, height: 400)
        assert_equal [ big ], pack([ big ], 300, 300).unplaced

        assert_equal 1, pack([ Item.new(label: "fits", width: 296, height: 296) ], 300, 300, gap: 2).sheets.size
        assert_equal 1, pack([ Item.new(label: "no", width: 297, height: 296) ], 300, 300, gap: 2).unplaced.size
      end

      # A SIDE OF ZERO STILL CLAIMS A SPOT (SheetPack::CLAIM): one line in an SVG measures 50 x 0,
      # and at gap 0 its own size overlaps nothing, so every copy landed on (0, 0) and the sheet
      # drawing showed one. The placement still reports the part's own size.
      test "a part with a side of zero takes a spot of its own, at its own size" do
        placed = pack(items(3, 50, 0), 300, 300).sheets.flatten

        assert_equal [ [ 0.0, 0.0 ], [ 50.0, 0.0 ], [ 100.0, 0.0 ] ], placed.map { |pl| [ pl.x, pl.y ] }.sort
        assert_equal [ [ 50.0, 0.0 ] ] * 3, placed.map { |pl| [ pl.width, pl.height ] }
      end

      # ONLY THE PIECES A PLACEMENT SPLITS OFF ARE PRUNED. Comparing every free rectangle with every
      # other on every placement was roughly cubic, and the Material estimate packs inside a web
      # request, re-figured as the user types (MAX_PLACEMENTS copies, sheets to 10 m a side).
      # Measured 2026-11-23 on this set: the full prune took 57 s, this one 0.46 s, so the bound sits
      # about 10x from each. It is this many parts because the gap between the two grows only
      # linearly with the count: at 900 parts it is 80x, too narrow for 10x on both sides.
      test "a large varied layout packs well inside a web request" do
        rng = Random.new(20261123)
        list = Array.new(1250) { |i| Item.new(label: "b#{i}", width: rng.rand(10.0..500.0).round(1), height: rng.rand(10.0..500.0).round(1)) }

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = pack(list, 10_000, 10_000, gap: 3)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        assert_equal list.size, result.sheets.sum(&:size)
        assert_operator elapsed, :<, 5.0, "packing #{list.size} parts took #{elapsed.round(2)} s"
      end

      test "the same input lays out the same way every time" do
        list = items(7, 120, 40) + items(5, 60, 60, prefix: "q")
        layout = ->(r) { r.sheets.map { |s| s.map { |pl| [ pl.item.label, pl.x, pl.y, pl.rotated ] } } }

        assert_equal layout.(pack(list, 300, 200, gap: 3, rotate: true)),
                     layout.(pack(list, 300, 200, gap: 3, rotate: true))
      end

      # THE FOUR PROMISES, over random input: inside the usable area, at least `gap` apart, every
      # fitting copy placed exactly once, and nothing else.
      [ true, false ].each do |rotate|
        test "the promises hold on random parts (rotate #{rotate})" do
          rng = Random.new(20261122)
          list = Array.new(80) { |i| Item.new(label: "r#{i}", width: rng.rand(5.0..180.0).round(1), height: rng.rand(5.0..180.0).round(1)) }
          w, h, gap = 300.0, 200.0, 3.0
          result = pack(list, w, h, gap:, rotate:)
          eps = 1e-6

          placed = result.sheets.flatten
          assert_equal list.size, placed.size + result.unplaced.size
          assert_equal placed.size, placed.map { |pl| pl.item.object_id }.uniq.size, "a copy was placed twice"

          result.sheets.each do |sheet|
            sheet.each do |pl|
              assert_operator pl.x, :>=, gap - eps
              assert_operator pl.y, :>=, gap - eps
              assert_operator pl.x + pl.width, :<=, w - gap + eps
              assert_operator pl.y + pl.height, :<=, h - gap + eps
              dims = pl.rotated ? [ pl.item.height, pl.item.width ] : [ pl.item.width, pl.item.height ]
              assert_equal dims, [ pl.width, pl.height ]
            end
            sheet.combination(2).each do |a, b|
              apart = a.x + a.width + gap <= b.x + eps || b.x + b.width + gap <= a.x + eps ||
                      a.y + a.height + gap <= b.y + eps || b.y + b.height + gap <= a.y + eps
              assert apart, "#{a.item.label} and #{b.item.label} are closer than the gap"
            end
          end
          result.unplaced.each do |item|
            fits = [ [ item.width, item.height ], ([ item.height, item.width ] if rotate) ].compact
                    .any? { |(iw, ih)| iw <= w - 2 * gap + eps && ih <= h - 2 * gap + eps }
            refute fits, "#{item.label} fits an empty sheet but was not placed"
          end
        end
      end
    end
  end
end
