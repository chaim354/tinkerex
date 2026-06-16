module Maker
  class Location < ApplicationRecord
    self.table_name = "maker_locations"

    belongs_to :user
    belongs_to :parent, class_name: "Maker::Location", optional: true
    has_many :children, class_name: "Maker::Location", foreign_key: :parent_id,
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
