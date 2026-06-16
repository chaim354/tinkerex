module Maker
  class Collection < ApplicationRecord
    self.table_name = "maker_collections"

    belongs_to :user
    has_many :collection_items, -> { order(:position) },
             class_name: "Maker::CollectionItem", dependent: :destroy
    has_many :items, through: :collection_items, class_name: "Maker::Item"

    validates :name, presence: true
  end
end
