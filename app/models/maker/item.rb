module Maker
  class Item < ApplicationRecord
    self.table_name = "maker_items"

    belongs_to :user

    ITEM_TYPES = %w[model_3d cad lightburn electronics other].freeze
    ORIGINS    = %w[self_made downloaded modified].freeze

    has_many :file_attachments, -> { order(:position) },
             as: :attachable, class_name: "Maker::FileAttachment", dependent: :destroy
    has_many :taggings, as: :taggable, class_name: "Maker::Tagging", dependent: :destroy
    has_many :collection_items, class_name: "Maker::CollectionItem", dependent: :destroy
    has_many :tags, through: :taggings, class_name: "Maker::Tag"
    # §14d: without a `dependent:`, a destroyed item leaves a DANGLING taskable_id, and
    # `Task#taskable_belongs_to_owner` (guarded on `taskable_id.present?`) then refuses every later
    # save of that task — the row is permanently uneditable. `:nullify`, not `:destroy`: `taskable`
    # is `optional: true`, so an ownerless task is a valid, already-blessed state, and destroying
    # the task would delete the user's own to-do along with the item it happened to mention.
    has_many :tasks, as: :taskable, class_name: "Maker::Task", dependent: :nullify

    validates :title, presence: true
    validates :item_type, inclusion: { in: ITEM_TYPES }
    validates :origin, inclusion: { in: ORIGINS }

    scope :of_type, ->(t) { where(item_type: t) if t.present? }
    scope :favorited, -> { where(favorited: true) }
  end
end
