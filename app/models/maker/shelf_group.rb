module Maker
  # A NAMED SET OF SHELVES (2026-10-20). Display only: a project page draws one heading over the
  # panels of a group's folders, and the folders on disk stay flat. Deleting a group leaves its
  # shelves ungrouped (`nullify`), never deleted.
  class ShelfGroup < ApplicationRecord
    self.table_name = "maker_shelf_groups"
    NAME_MAX = 40

    belongs_to :user
    has_many :shelves, class_name: "Maker::Shelf", foreign_key: :shelf_group_id,
                       inverse_of: :shelf_group, dependent: :nullify

    normalizes :name, with: ->(n) { n.to_s.squish }

    validates :name, presence: true, length: { maximum: NAME_MAX }, uniqueness: { scope: :user_id }
  end
end
