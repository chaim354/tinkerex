module Maker
  class InventoryItem < ApplicationRecord
    self.table_name = "maker_inventory_items"

    UNITS = %w[each g kg m mm cm ml l pack roll sheet other].freeze

    belongs_to :user
    belongs_to :location, class_name: "Maker::Location", optional: true
    belongs_to :supplier, class_name: "Maker::Supplier", optional: true
    has_many :transactions, -> { order(created_at: :asc, id: :asc) },
             class_name: "Maker::InventoryTransaction", foreign_key: :inventory_item_id,
             dependent: :delete_all
    # NO `dependent:` HERE ON PURPOSE — `release_bom_lines` below does the work, and the two
    # statements it runs have to happen in that order. Adding `dependent: :nullify` to this line
    # would be actively wrong; see the comment on that method before "tidying" it.
    has_many :bom_lines, class_name: "Maker::BomLine", foreign_key: :inventory_item_id

    before_destroy :release_bom_lines

    validates :name, presence: true
    validates :unit, inclusion: { in: UNITS }
    validates :quantity_cached, :min_quantity, numericality: true
    validate :location_belongs_to_user, if: -> { location_id.present? }
    validate :supplier_belongs_to_user, if: -> { supplier_id.present? }

    # quantity_cached <= min_quantity  ==>  needs restocking.
    scope :low_stock, -> { where("quantity_cached <= min_quantity") }

    # Recompute the denormalized balance from the immutable ledger (drift repair / migration).
    def rebuild_quantity_cached!
      total = transactions.sum(:delta)
      update_column(:quantity_cached, total)
      total
    end

    private

    # A BOM line whose inventory item is destroyed survives as a FREE-TEXT line. It is neither
    # nullified nor destroyed, and both of those obvious answers are wrong:
    #
    # `dependent: :nullify` swaps one permanent lock for another. `exactly_one_target` requires
    # exactly one of inventory_item_id / node_id / part_name, so a nulled line has NONE and fails
    # validation on every subsequent save — the same unsavable row this fix exists to prevent,
    # wearing a different error message. `dependent: :destroy` is worse: a BOM records what the
    # project needs, and deleting a stock row is a statement about the shelf, not about the design.
    #
    # Carrying the item's name into `part_name` leaves a valid, editable line saying what it said
    # before ("4 × M3 bolt"), in a shape `resolved_target` already renders. It MUST run before the
    # pointer is dropped, because the name belongs to the row about to disappear — which is equally
    # why lines already stranded by this bug cannot be repaired after the fact (docs/STATUS.md).
    def release_bom_lines
      mine = bom_lines.where(user_id: user_id)
      # Scoped to this user, unlike the plain `dependent: :nullify` on Supplier/Location, because
      # this half WRITES (an item name) rather than only clearing a pointer. Clearing a foreign
      # pointer can at worst repair an illegal cross-tenant reference; copying a name into a row
      # another user owns would be a disclosure. `*_belongs_to_user` makes such a row unreachable
      # today, so the scope costs one clause and removes the question.
      #
      # Only lines that would otherwise be left with NO target get a name; blank is checked
      # alongside NULL because these are nullable strings the API accepts as "" and
      # `exactly_one_target` asks `present?`, not `nil?`.
      mine.where(node_id: [ nil, "" ], part_name: [ nil, "" ])
          .update_all(part_name: name, updated_at: Time.current)
      mine.update_all(inventory_item_id: nil, updated_at: Time.current)
    end

    def location_belongs_to_user
      unless Maker::Location.exists?(id: location_id, user_id: user_id)
        errors.add(:location_id, "must reference your own location")
      end
    end

    def supplier_belongs_to_user
      unless Maker::Supplier.exists?(id: supplier_id, user_id: user_id)
        errors.add(:supplier_id, "must reference your own supplier")
      end
    end
  end
end
