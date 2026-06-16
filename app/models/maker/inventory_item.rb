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
