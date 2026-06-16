module Maker
  class Tagging < ApplicationRecord
    self.table_name = "maker_taggings"

    belongs_to :user
    belongs_to :tag, class_name: "Maker::Tag"
    belongs_to :taggable, polymorphic: true

    validates :tag_id, uniqueness: { scope: %i[taggable_type taggable_id] }
  end
end
