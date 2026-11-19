module Maker
  # The totals a bill of materials shows (stage 2, S2-4), computed once over lines the caller has
  # ALREADY LOADED with their inventory items — this class issues no query, so it cannot become the
  # per-line read page_query_budget_test.rb forbids.
  #
  # THE LINES NEED NOT COME FROM ONE BOM. Maker::ToBuy hands it every line of every open project's
  # current BOM at once, which is what #short_by_item is for.
  class BomRollup
    Short = Data.define(:line, :on_hand)

    # One item's demand across every line naming it: `needed` is the sum of those lines'
    # quantities, `lines` are the lines themselves (in the order given), and `short` is what buying
    # would close.
    ItemShort = Data.define(:item, :needed, :on_hand, :lines) do
      def short = needed - on_hand
    end

    attr_reader :lines

    def initialize(lines)
      @lines = lines.to_a
    end

    def count = lines.size
    def by_kind = @by_kind ||= lines.group_by(&:target_kind).transform_values(&:size)   # { inventory_item: 3, design_file: 1, free_text: 1 }
    def stock_count = by_kind.fetch(:inventory_item, 0)
    def file_count = by_kind.fetch(:design_file, 0)
    def text_count = by_kind.fetch(:free_text, 0)

    # Sum of quantity × the item's unit_cost over stock lines whose item HAS a cost; nil when no line
    # is costed, so a view can say nothing rather than "$0.00".
    def estimated_cost
      costed = lines.select { |l| l.target_kind == :inventory_item && l.inventory_item&.unit_cost }
      return nil if costed.empty?
      costed.sum { |l| l.quantity * l.inventory_item.unit_cost }
    end

    # Stock lines whose item's cached balance is below the line's quantity — what a build cannot
    # start with. A dangling item (deleted; the line is text by then) never appears here.
    def short
      stock_lines.filter_map do |l|
        on_hand = l.inventory_item.quantity_cached
        Short.new(line: l, on_hand:) if on_hand < l.quantity
      end
    end

    # The same comparison as #short, made ONCE PER ITEM against the summed quantity of every line
    # naming it, in the order each item first appears. Each line here is judged alone by #short, so
    # two lines of 2 against 3 on hand are both fine there; asked together they are 1 short, and a
    # shopping list has to say so. Summing each line's own shortfall instead counts the stock on
    # hand once per line. Every item #short reports is here too, since a sum is never below one of
    # its terms; free-text and design-file lines have no balance to fall short of, and are not.
    def short_by_item
      stock_lines.group_by(&:inventory_item_id).filter_map do |_, item_lines|
        item = item_lines.first.inventory_item
        needed = item_lines.sum(&:quantity)
        ItemShort.new(item:, needed:, on_hand: item.quantity_cached, lines: item_lines) if item.quantity_cached < needed
      end
    end

    private

    # Lines that draw on stock: the stock kind, with an item that still resolves.
    def stock_lines = @stock_lines ||= lines.select { |l| l.target_kind == :inventory_item && l.inventory_item }
  end
end
