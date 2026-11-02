module Maker
  class Location < ApplicationRecord
    self.table_name = "maker_locations"

    belongs_to :user
    belongs_to :parent, class_name: "Maker::Location", optional: true
    has_many :children, class_name: "Maker::Location", foreign_key: :parent_id,
             dependent: :nullify
    # The `children` nullify above covered only the self-reference; inventory items pointing here
    # were stranded AND locked, because `InventoryItem#location_belongs_to_user` runs whenever
    # `location_id` is present and a dangling id is present. Emptying a shelf must not make every
    # item that sat on it permanently unsavable.
    has_many :inventory_items, class_name: "Maker::InventoryItem", foreign_key: :location_id,
             dependent: :nullify

    validates :name, presence: true
    validate :parent_belongs_to_user, if: -> { parent_id.present? }
    # A LOCATION CANNOT SIT INSIDE ITSELF. Reachable since a location can be re-placed on its edit
    # page (UX audit 2026-11-01, E5): choosing a drawer as its own cabinet's parent would make a ring
    # every "in X" walk loops on. The page offers no such choice; this is the door's answer to a
    # crafted one.
    validate :parent_is_not_inside_this, if: -> { parent_id.present? && persisted? }

    private

    def parent_is_not_inside_this
      seen = Set.new
      current = parent_id
      while current && seen.add?(current)
        return errors.add(:parent_id, "cannot be this location or one inside it") if current == id

        current = Maker::Location.where(id: current, user_id: user_id).pick(:parent_id)
      end
    end

    def parent_belongs_to_user
      unless Maker::Location.exists?(id: parent_id, user_id: user_id)
        errors.add(:parent_id, "must reference your own location")
      end
    end
  end
end
