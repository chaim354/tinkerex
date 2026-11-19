module Maker
  # THE TO BUY LIST: every inventory item the user's open projects need more of than they hold, ONE
  # ROW PER ITEM however many projects ask for it, with which projects those are and how many each
  # needs. Built for the redesign's Inventory and Home (spec 2026-11-18 §9, "To buy").
  #
  #   Maker::ToBuy.for(user) # => [Row(item:, short:, needed:, on_hand:, needs: [Need(project:, quantity:)])]
  #
  # WHAT COUNTS:
  # - Projects: Maker::Project.open (planning, active, paused). Done and archived are out; the
  #   scope's own comment says why.
  # - Lines: each project's CURRENT BOM only (Maker::Project#current_bom, via Bom.current_ids_for).
  #   An older revision is history; adding it would ask for parts twice.
  # - Items, never typed-in parts. A free-text line has no balance, so nothing can say it is short,
  #   and listing every one would put parts bought long ago on the list for ever. A design-file line
  #   is something to make, not to buy. This is Maker::BomRollup#short's own rule.
  #
  # THE ARITHMETIC IS Maker::BomRollup#short_by_item, run over every line at once: `needed` sums the
  # quantities across projects and `short` is needed minus on hand, so an item two projects each
  # have enough of ALONE still appears when together they do not.
  #
  # FOUR QUERIES WHATEVER THE SIZE: the projects, their current BOM ids, the lines, the items
  # (the last is a preload, skipped when no line names an item). Rows come back sorted by item name.
  # Constancy in N is pinned by test/services/maker/to_buy_test.rb.
  class ToBuy
    Need = Data.define(:project, :quantity)

    Row = Data.define(:item, :short, :needed, :on_hand, :needs) do
      # What closing the gap costs at the item's unit cost; nil when the item has none.
      def cost = item.unit_cost && short * item.unit_cost
    end

    def self.for(user) = new(user).rows

    def initialize(user)
      @user = user
    end

    def rows
      projects = @user.maker_projects.open.order(:name, :id).to_a
      project_of_bom = Maker::Bom.current_ids_for(projects)
      return [] if project_of_bom.empty?

      # Only lines that name an item are loaded; BomRollup still decides which of them are stock.
      lines = @user.maker_bom_lines.where(bom_id: project_of_bom.keys).where.not(inventory_item_id: nil)
                   .includes(:inventory_item).to_a
      rank = projects.each_with_index.to_h { |p, i| [ p.id, i ] }
      by_id = projects.index_by(&:id)

      Maker::BomRollup.new(lines).short_by_item.map do |s|
        needs = s.lines.group_by { |l| project_of_bom.fetch(l.bom_id) }
                 .sort_by { |project_id, _| rank.fetch(project_id) }
                 .map { |project_id, ls| Need.new(project: by_id.fetch(project_id), quantity: ls.sum(&:quantity)) }
        Row.new(item: s.item, short: s.short, needed: s.needed, on_hand: s.on_hand, needs:)
      end.sort_by { |row| [ row.item.name.downcase, row.item.id ] }
    end
  end
end
