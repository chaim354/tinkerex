module Maker
  # A FOLDER PINNED TO THE SIDEBAR'S PLACES (structural redesign spec §4.1, 2026-10-08).
  #
  # KEYED BY `node_id`, NEVER BY PATH: a move keeps a node's id (§14b), so a renamed or moved
  # folder keeps its pin. A pin whose folder is tombstoned is HIDDEN, not deleted — the sidebar
  # reads only live folders (ShellHelper#sidebar_pins) — so restoring the folder restores the pin.
  # Maker::AttachmentReaper removes it only once the node is reapable (Maker::DeadNodes), the same
  # grace an attachment gets.
  class Pin < ApplicationRecord
    self.table_name = "maker_pins"

    CAP = 12

    belongs_to :user

    before_create { self.position = (user.maker_pins.maximum(:position) || -1) + 1 }

    validates :node_id, presence: true, uniqueness: { scope: :user_id }
    validate :a_live_folder_of_this_user, on: :create
    validate :under_the_cap, on: :create

    scope :ordered, -> { order(:position, :id) }

    private

    def a_live_folder_of_this_user
      return if node_id.blank? || user.nil?
      return if user.nodes.present.exists?(node_id:, kind: "dir")

      errors.add(:base, "That folder isn't in your library.")
    end

    def under_the_cap
      return if user.nil? || user.maker_pins.count < CAP

      errors.add(:base, "The sidebar holds #{CAP} pinned places. Unpin one first.")
    end
  end
end
