module Maker
  class Item < ApplicationRecord
    self.table_name = "maker_items"

    belongs_to :user

    ITEM_TYPES = %w[model_3d cad lightburn electronics other].freeze
    ORIGINS    = %w[self_made downloaded modified].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"

    validates :title, presence: true
    validates :item_type, inclusion: { in: ITEM_TYPES }
    validates :origin, inclusion: { in: ORIGINS }

    scope :of_type, ->(t) { where(item_type: t) if t.present? }
    scope :favorited, -> { where(favorited: true) }
  end
end
