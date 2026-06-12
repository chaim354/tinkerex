class AddModeToNodes < ActiveRecord::Migration[8.1]
  def change
    add_column :nodes, :mode, :integer            # POSIX permission bits (synced)
    add_column :pending_commits, :mode, :integer  # carried through a two-phase commit
  end
end
