module Maker
  module Material
    # RECTANGLES ONTO SHEETS, for the Material estimate tool (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md, "Packing").
    #
    # MAXRECTS, BEST SHORT SIDE FIT: every sheet keeps the list of maximal free rectangles; each part
    # goes where the shorter leftover side is smallest, ties to the lower then the leftmost spot. It
    # places a part ANYWHERE on a sheet, which is what a laser or a CNC can cut. The Cut List add-on's
    # guillotine shelves are the right model for a saw and overcount for these machines.
    #
    # THE GAP INFLATES EVERY PART by `gap` on each side's length and packs into a usable sheet of
    # (W - gap) x (H - gap) offset by (gap, gap). That keeps `gap` between neighbours AND from every
    # edge, and a part fits only if w <= W - 2·gap in some allowed orientation.
    #
    # Largest area first, and a part never moves between sheets once placed. Ties in the order break
    # on the longer side, then the label, then input order, so a layout is a function of its input.
    class SheetPack
      EPS = 1e-9

      # x/y/width/height are the PART's own (mm, rotated when `rotated`), on the full sheet.
      Placement = Data.define(:item, :x, :y, :width, :height, :rotated)
      # `sheets` is an Array of Arrays of Placement; `unplaced` the items no sheet can hold.
      Result = Data.define(:sheets, :unplaced)
      Rect = Data.define(:x, :y, :w, :h) do
        def right = x + w
        def bottom = y + h
      end

      def self.call(items, sheet_width:, sheet_height:, gap:, rotate:)
        new(items, sheet_width:, sheet_height:, gap:, rotate:).call
      end

      def initialize(items, sheet_width:, sheet_height:, gap:, rotate:)
        @items = items
        @gap = gap.to_f
        @usable_w = sheet_width.to_f - @gap
        @usable_h = sheet_height.to_f - @gap
        @rotate = rotate
      end

      def call
        sheets = []
        unplaced = []
        ordered.each do |item|
          w = item.width + @gap
          h = item.height + @gap
          unless fits_empty_sheet?(w, h)
            unplaced << item
            next
          end
          next if sheets.any? { |sheet| place(sheet, item, w, h) }

          sheet = { free: [ Rect.new(x: 0.0, y: 0.0, w: @usable_w, h: @usable_h) ], placements: [] }
          place(sheet, item, w, h) or raise "a part that fits an empty sheet did not fit one"
          sheets << sheet
        end
        Result.new(sheets: sheets.map { |s| s[:placements] }, unplaced:)
      end

      private

      def ordered
        @items.each_with_index
              .sort_by { |item, i| [ -(item.width * item.height), -[ item.width, item.height ].max, item.label.to_s, i ] }
              .map(&:first)
      end

      def orientations(w, h)
        @rotate && (w - h).abs > EPS ? [ [ w, h, false ], [ h, w, true ] ] : [ [ w, h, false ] ]
      end

      def fits_empty_sheet?(w, h)
        orientations(w, h).any? { |(ow, oh, _)| ow <= @usable_w + EPS && oh <= @usable_h + EPS }
      end

      # Places `item` (inflated to w x h) on `sheet` at its best free spot. false when none fits.
      def place(sheet, item, w, h)
        best = nil
        sheet[:free].each do |free|
          orientations(w, h).each do |(ow, oh, rotated)|
            next unless ow <= free.w + EPS && oh <= free.h + EPS

            short, long = [ free.w - ow, free.h - oh ].minmax
            score = [ short, long, free.y, free.x ]
            best = [ score, free, ow, oh, rotated ] if best.nil? || (score <=> best[0]).negative?
          end
        end
        return false if best.nil?

        _score, free, ow, oh, rotated = best
        used = Rect.new(x: free.x, y: free.y, w: ow, h: oh)
        sheet[:free] = prune(sheet[:free].flat_map { |f| split(f, used) })
        # The part's own size from the ITEM, never `ow - @gap`: (62.9 + 3.0) - 3.0 is
        # 62.900000000000006, and that noise would reach the utilization sum and the drawing.
        part_w, part_h = rotated ? [ item.height, item.width ] : [ item.width, item.height ]
        sheet[:placements] << Placement.new(item:, x: @gap + used.x, y: @gap + used.y,
                                            width: part_w.to_f, height: part_h.to_f, rotated:)
        true
      end

      # The maximal free rectangles left of `free` once `used` is taken out of it.
      def split(free, used)
        return [ free ] unless overlap?(free, used)

        parts = []
        parts << Rect.new(x: free.x, y: free.y, w: used.x - free.x, h: free.h) if used.x > free.x + EPS
        parts << Rect.new(x: used.right, y: free.y, w: free.right - used.right, h: free.h) if used.right < free.right - EPS
        parts << Rect.new(x: free.x, y: free.y, w: free.w, h: used.y - free.y) if used.y > free.y + EPS
        parts << Rect.new(x: free.x, y: used.bottom, w: free.w, h: free.bottom - used.bottom) if used.bottom < free.bottom - EPS
        parts
      end

      def overlap?(a, b)
        a.x < b.right - EPS && b.x < a.right - EPS && a.y < b.bottom - EPS && b.y < a.bottom - EPS
      end

      def contains?(outer, inner)
        inner.x >= outer.x - EPS && inner.y >= outer.y - EPS &&
          inner.right <= outer.right + EPS && inner.bottom <= outer.bottom + EPS
      end

      # Drops every free rectangle another one contains (keeping the first of two equal ones).
      def prune(rects)
        rects.each_with_index.reject do |rect, i|
          rects.each_with_index.any? { |other, j| i != j && contains?(other, rect) && (!contains?(rect, other) || j < i) }
        end.map(&:first)
      end
    end
  end
end
