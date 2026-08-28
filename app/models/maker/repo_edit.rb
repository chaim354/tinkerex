module Maker
  # A file this app wrote into a git working tree, still waiting to be committed.
  #
  # THIS TABLE IS A HINT, NEVER AN AUTHORITY. It answers "which files did tinkerex touch", and
  # nothing else -- whether a path actually differs from HEAD is asked of git every time the commit
  # box opens (spec part 6 step 5). Treating a row as proof of a pending change is how the box
  # starts lying about the repository.
  class RepoEdit < ApplicationRecord
    self.table_name = "maker_repo_edits"

    belongs_to :user

    scope :pending_for, ->(user, repo_root_node_id) {
      where(user:, repo_root_node_id:).order(:updated_at)
    }

    # Idempotent by construction. A maker saves the same file repeatedly; that is one pending
    # edit, re-stamped, not N rows.
    def self.record!(user:, repo_root_node_id:, node_id:)
      row = find_or_initialize_by(user:, node_id:)
      row.repo_root_node_id = repo_root_node_id
      row.touch if row.persisted?
      row.save!
      row
    end
  end
end
