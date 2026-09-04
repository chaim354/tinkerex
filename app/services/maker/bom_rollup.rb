module Maker
  # The totals a bill of materials shows (stage 2, S2-4), computed once over lines the caller has
  # ALREADY LOADED with their inventory items — this class issues no query, so it cannot become the
  # per-line read page_query_budget_test.rb forbids.
  class BomRollup
    Short = Data.define(:line, :on_hand)

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
      lines.filter_map do |l|
        next unless l.target_kind == :inventory_item && l.inventory_item
        on_hand = l.inventory_item.quantity_cached
        Short.new(line: l, on_hand:) if on_hand < l.quantity
      end
    end
  end
end
