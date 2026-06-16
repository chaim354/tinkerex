module Maker
  class CollectionItem < ApplicationRecord
    self.table_name = "maker_collection_items"

    belongs_to :user
    belongs_to :collection, class_name: "Maker::Collection"
    belongs_to :item, class_name: "Maker::Item"

    validates :item_id, uniqueness: { scope: :collection_id }
  end
end
