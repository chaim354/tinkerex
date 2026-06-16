module Maker
  class Tag < ApplicationRecord
    self.table_name = "maker_tags"

    belongs_to :user
    has_many :taggings, class_name: "Maker::Tagging", dependent: :destroy

    normalizes :name, with: ->(n) { n.to_s.strip.downcase }
    validates :name, presence: true, uniqueness: { scope: :user_id }
  end
end
