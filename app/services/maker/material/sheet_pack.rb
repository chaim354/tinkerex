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
      # THE LEAST A PLACEMENT TAKES FROM THE FREE LIST, per side (mm). A part with a side of zero (one
      # line in an SVG measures 50 x 0, and the measurer accepts it) overlaps nothing at gap 0: taken
      # at its own size it splits no free rectangle, and every copy lands on the same spot. Far above
      # EPS, so the split sees it; far below anything a drawing or a sum can. The Placement keeps the
      # item's own size, and zero-area parts are placed last, so the sliver never moves a real part.
      CLAIM = 1e-6

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
        options = orientations(w, h)
        sheet[:free].each do |free|
          options.each do |(ow, oh, rotated)|
            next unless ow <= free.w + EPS && oh <= free.h + EPS

            short, long = [ free.w - ow, free.h - oh ].minmax
            score = [ short, long, free.y, free.x ]
            best = [ score, free, ow, oh, rotated ] if best.nil? || (score <=> best[0]).negative?
          end
        end
        return false if best.nil?

        _score, free, ow, oh, rotated = best
        used = Rect.new(x: free.x, y: free.y, w: [ ow, CLAIM ].max, h: [ oh, CLAIM ].max)
        sheet[:free] = carve(sheet[:free], used)
        # The part's own size from the ITEM, never `ow - @gap`: (62.9 + 3.0) - 3.0 is
        # 62.900000000000006, and that noise would reach the utilization sum and the drawing.
        part_w, part_h = rotated ? [ item.height, item.width ] : [ item.width, item.height ]
        sheet[:placements] << Placement.new(item:, x: @gap + used.x, y: @gap + used.y,
                                            width: part_w.to_f, height: part_h.to_f, rotated:)
        true
      end

      # Takes `used` out of the free list and drops every piece that is no longer maximal.
      #
      # ONLY THE PIECES THIS PLACEMENT SPLIT OFF ARE CHECKED, which is what keeps a large layout
      # inside a web request: comparing every rectangle with every other on every placement was
      # roughly cubic (2000 parts of 10-500 mm on a 10 m sheet took 72 s). An untouched rectangle
      # was maximal before and still is, and no piece can contain one, since every piece lies inside
      # a rectangle that was already maximal. The list keeps its order and the check its tie-break,
      # so the layout is the one the full comparison gives. A piece is most often inside another
      # piece, so those are asked first; the answer is the same either way.
      def carve(free_rects, used)
        rects = []
        fresh = []
        free_rects.each do |f|
          if overlap?(f, used)
            split(f, used).each { |piece| fresh << rects.size; rects << piece }
          else
            rects << f
          end
        end
        gone = fresh.select { |i| contained?(rects, i, fresh) || contained?(rects, i, rects.each_index) }
        rects.reject.with_index { |_, i| gone.include?(i) }
      end

      # rects[i] lies inside rects[j] for some j of `among` (of two equal ones, the first is kept).
      def contained?(rects, i, among)
        rect = rects[i]
        among.any? { |j| j != i && contains?(rects[j], rect) && (!contains?(rect, rects[j]) || j < i) }
      end

      # The maximal free rectangles left of `free` once `used`, which overlaps it, is taken out.
      def split(free, used)
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
    end
  end
end
