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

    private

    def parent_belongs_to_user
      unless Maker::Location.exists?(id: parent_id, user_id: user_id)
        errors.add(:parent_id, "must reference your own location")
      end
    end
  end
end
