module Maker
  class BomLine < ApplicationRecord
    self.table_name = "maker_bom_lines"

    UNITS = Maker::InventoryItem::UNITS

    belongs_to :user
    belongs_to :bom, class_name: "Maker::Bom"
    belongs_to :inventory_item, class_name: "Maker::InventoryItem", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true

    validates :quantity, numericality: { greater_than: 0 }
    validates :unit, inclusion: { in: UNITS }
    validate  :exactly_one_target
    validate  :inventory_item_belongs_to_user, if: -> { inventory_item_id.present? }
    validate  :supplier_belongs_to_user,       if: -> { supplier_id.present? }

    # Which of the three target shapes this line uses (nil if none/invalid).
    def target_kind
      kinds = []
      kinds << :inventory_item if inventory_item_id.present?
      kinds << :design_file    if node_id.present?
      kinds << :free_text      if part_name.present?
      kinds.one? ? kinds.first : nil
    end

    # Resolve the line's target for the roll-up view (one hash per line).
    def resolved_target
      case target_kind
      when :inventory_item
        item = inventory_item
        { kind: :inventory_item,
          inventory_item: item && {
            id: item.id, name: item.name, part_number: item.part_number,
            unit: item.unit, quantity_cached: item.quantity_cached
          } }
      when :design_file
        { kind: :design_file, node_id: node_id }
      when :free_text
        { kind: :free_text, part_name: part_name,
          supplier_id: supplier_id, supplier_name: supplier&.name }
      else
        { kind: nil }
      end
    end

    private

    def exactly_one_target
      count = [ inventory_item_id.present?, node_id.present?, part_name.present? ].count(true)
      unless count == 1
        errors.add(:base,
          "a line must link exactly one of: inventory item, design file, or free-text part")
      end
    end

    def inventory_item_belongs_to_user
      unless Maker::InventoryItem.exists?(id: inventory_item_id, user_id: user_id)
        errors.add(:inventory_item_id, "must reference your own inventory item")
      end
    end

    def supplier_belongs_to_user
      unless Maker::Supplier.exists?(id: supplier_id, user_id: user_id)
        errors.add(:supplier_id, "must reference your own supplier")
      end
    end
  end
end
