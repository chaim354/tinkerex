module Maker
  # ONE IMMUTABLE SNAPSHOT of a saved state's params. Never updated: the row records what was saved
  # at revision N, and a later save appends N+1 rather than rewriting this one. There is no
  # `updated_at` column, so the schema enforces that rather than a callback somebody can remove.
  class AddonStateRevision < ApplicationRecord
    self.table_name = "maker_addon_state_revisions"

    belongs_to :addon_state, class_name: "Maker::AddonState"

    validates :revision, presence: true, numericality: { only_integer: true, greater_than: 0 }
  end
end
