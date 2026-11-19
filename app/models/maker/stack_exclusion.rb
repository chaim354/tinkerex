module Maker
  # A FILE PULLED OUT OF ITS VERSION STACK, to be shown alone (shop-manual spec §9, "a way to pull
  # one file out"). Maker::VersionStacks sets these aside before it groups, so a stack of three
  # with one pulled out is a stack of two and that file, and a stack of two is no stack at all.
  #
  # KEYED BY `node_id`, NEVER BY NAME OR PATH: a move or rename keeps a node's id (§14b), so a
  # pulled-out file stays out. A tombstoned file is in no stack (only live files are grouped), so
  # its row simply waits: restoring the file restores the pull-out. Maker::AttachmentReaper removes
  # it once the node is reapable (Maker::DeadNodes), the grace every node-keyed maker row gets, and
  # Library::Reset forgets it with the file.
  class StackExclusion < ApplicationRecord
    self.table_name = "maker_stack_exclusions"

    belongs_to :user

    validates :node_id, presence: true, uniqueness: { scope: :user_id }
    validate :a_live_file_of_this_user, on: :create

    # Idempotent: pulling out a file already out answers its row. Raises RecordInvalid for a node
    # that is not a live file of this user.
    def self.pull_out!(user, node_id)
      user.maker_stack_exclusions.find_or_create_by!(node_id: node_id.to_s)
    rescue ActiveRecord::RecordNotUnique
      # Two requests raced past the uniqueness check; the unique index chose one.
      user.maker_stack_exclusions.find_by!(node_id: node_id.to_s)
    end

    # Idempotent: true when a row was removed, false when the file was never pulled out.
    def self.put_back!(user, node_id)
      user.maker_stack_exclusions.where(node_id: node_id.to_s).delete_all.positive?
    end

    private

    def a_live_file_of_this_user
      return if node_id.blank? || user.nil?
      return if user.nodes.present.exists?(node_id:, kind: "file")

      errors.add(:base, "That file isn't in your library.")
    end
  end
end
