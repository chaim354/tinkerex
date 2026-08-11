module Maker
  class Supplier < ApplicationRecord
    self.table_name = "maker_suppliers"

    belongs_to :user

    # WITHOUT THESE, DESTROYING A SUPPLIER LOCKS EVERY ROW THAT REFERENCED IT — not just against
    # editing the reference, against editing ANYTHING. Both referrers run a `supplier_belongs_to_user`
    # validation guarded by `if: supplier_id.present?`, and a dangling id is still present, so the
    # check runs and fails on every subsequent save: renaming an item, adjusting a min_quantity,
    # fixing a typo in a BOM line's notes, all refused with an error about a field the form may not
    # even show. Nullify is safe on both sides — `supplier_id` is optional on each, and on a BomLine
    # it is an annotation rather than one of `exactly_one_target`'s three target shapes, so clearing
    # it cannot make the line targetless the way clearing `inventory_item_id` would (see
    # Maker::InventoryItem#release_bom_lines).
    has_many :inventory_items, class_name: "Maker::InventoryItem", foreign_key: :supplier_id,
             dependent: :nullify
    has_many :bom_lines, class_name: "Maker::BomLine", foreign_key: :supplier_id,
             dependent: :nullify

    validates :name, presence: true
  end
end
