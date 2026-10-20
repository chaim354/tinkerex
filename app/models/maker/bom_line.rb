module Maker
  class BomLine < ApplicationRecord
    self.table_name = "maker_bom_lines"

    UNITS = Maker::InventoryItem::UNITS

    belongs_to :user
    belongs_to :bom, class_name: "Maker::Bom"
    belongs_to :inventory_item, class_name: "Maker::InventoryItem", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true

    before_validation :store_item_unit

    validates :quantity, numericality: { greater_than: 0 }
    validates :unit, inclusion: { in: UNITS }
    validate  :exactly_one_target
    validate  :inventory_item_belongs_to_user, if: -> { inventory_item_id.present? }
    validate  :supplier_belongs_to_user,       if: -> { supplier_id.present? }

    # A STOCK LINE IS COUNTED IN ITS ITEM'S UNIT, AND THE ITEM IS WHERE THAT UNIT IS READ (audit
    # F-S16-2). Consume takes `quantity` off the item's balance, and the short check and the cost
    # estimate compare it with the item's figures, so a stock line has no unit of its own. It used to
    # be a copy that only the web door wrote, once: the v1 door and the desktop composer stored
    # whatever they sent (or the column's "each"), and an edit to the item's unit left every line on
    # the old one — "2 each" in the Qty cell beside a Consume button that took 2 kg. Overriding the
    # generated reader (the precedent is Maker::Project#cover_node_id) puts every reader on the item
    # with no change of its own: both BOM tables, the public CSV and the v1 JSON.
    #
    # THE COLUMN STILL ANSWERS FOR EVERY OTHER LINE. A file or text line's unit is its own, and a
    # stock line that loses its item reads the column from then on — which is why
    # Maker::InventoryItem#release_bom_lines writes the item's unit into it beside the name. The
    # column is NOT kept in step with the item otherwise (no hook on the item, no backfill), because
    # nothing reads a stock line's column while its item exists; `store_item_unit` below only keeps
    # it a valid unit.
    #
    # "STOCK" IS `target_kind`, the test Consume and both tables already use, so the lines answered
    # from the item here are exactly the lines `release_bom_lines` converts: a release changes no
    # line's unit. A dangling id resolves to no item and falls through to the column, so no rule here
    # can lock a row (§14d); a foreign one is refused by `inventory_item_belongs_to_user`.
    def unit
      stock_item&.unit || self[:unit]
    end

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

    def stock_item = (inventory_item if target_kind == :inventory_item)

    # THE COLUMN STAYS A VALID UNIT ON A STOCK LINE TOO. `validates :unit` asks the reader above, so
    # on a stock line it checks the ITEM's unit and would store whatever was sent beside it unseen
    # ("furlong" in a hand-built request, which the v1 door used to refuse). The column is read again
    # the moment the line stops being a stock line, and a v1 PATCH that retargets one to a part name
    # sends no unit: a stray value there would refuse that save. So saving a stock line writes its
    # item's unit into the column. A unit sent for a stock line is therefore replaced, never refused,
    # at every door — the web door's behaviour, which it used to supply on its own.
    def store_item_unit
      self[:unit] = stock_item.unit if stock_item
    end

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
