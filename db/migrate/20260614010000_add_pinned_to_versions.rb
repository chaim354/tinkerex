class AddPinnedToVersions < ActiveRecord::Migration[8.1]
  # Additive: a pinned version is exempt from retention pruning (research item #11).
  # Default false → existing behavior unchanged; the keep-set invariant ANDs this in.
  def change
    add_column :versions, :pinned, :boolean, default: false, null: false
  end
end
