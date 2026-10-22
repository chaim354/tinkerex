module Maker
  # A SHELF IS A FOLDER INSIDE EVERY PROJECT (2026-10-20): `Projects/<project>/<name>/`, where the
  # intake sweep files whatever Maker::FilingRule rows name it. Its `name` IS that folder name and
  # joins the rules by string, so the sweep (Maker::ProjectFolders.folder_for) did not change.
  # `default_view` is how the folder's panel opens on a project page (nil = automatic), and a
  # group puts its shelves' panels under one heading there. Rows are made on read by
  # Maker::Shelves.ensure!. NOT the model catalog's shelves: those are Maker::ModelIntake::SHELVES.
  class Shelf < ApplicationRecord
    self.table_name = "maker_shelves"

    belongs_to :user
    belongs_to :shelf_group, class_name: "Maker::ShelfGroup", optional: true

    normalizes :name, with: ->(n) { n.to_s.strip.downcase }
    normalizes :default_view, with: ->(v) { v.presence }

    validates :name, presence: true, uniqueness: { scope: :user_id }
    validates :default_view, inclusion: { in: Maker::Project::VIEWS }, allow_nil: true
    validate :name_is_a_folder_name
    # GUARDED ON PRESENCE, AND SAFE ONLY BECAUSE ShelfGroup NULLIFIES (§14d): a dangling id would
    # be present and lock every later edit of this row.
    validate :group_is_this_users, if: -> { shelf_group_id.present? }

    # `other` is where an extension with no shelf files, so it cannot be removed.
    def fallback? = name == Maker::Shelves::FALLBACK

    private

    def name_is_a_folder_name
      return if name.blank?
      return if Maker::FilingRule.plain_segment?(name)

      errors.add(:name, "isn't allowed - #{name.inspect} can't be a folder name")
    end

    def group_is_this_users
      return if user && user.maker_shelf_groups.exists?(id: shelf_group_id)

      errors.add(:shelf_group_id, "isn't one of your groups")
    end
  end
end
