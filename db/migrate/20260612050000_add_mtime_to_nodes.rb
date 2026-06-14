class AddMtimeToNodes < ActiveRecord::Migration[8.1]
  def change
    # Real modification time, unix **nanoseconds** — a bigint (nanos in 2026 ~1.78e18
    # overflow a 32-bit integer). Preserved + synced so a file's true mtime, not the sync
    # time, is what every device sees.
    add_column :nodes, :mtime, :bigint
    add_column :pending_commits, :mtime, :bigint  # carried through a two-phase commit
  end
end
