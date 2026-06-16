class AddIncomingVersionUniqueIndexToConflicts < ActiveRecord::Migration[8.1]
  # N-way conflict model: a node with 3+ concurrent divergent edits must keep EVERY divergent
  # incoming version reachable, not just the last. We now allow multiple Conflict rows per node
  # (one per divergent incoming version) instead of overwriting a single row's incoming_version_id.
  #
  # This unique index keys a conflict by its incoming version so re-finalizing the same version
  # (an idempotent retry) reuses the row instead of duplicating it, while two genuinely different
  # divergent versions get two rows. Adapter-agnostic (SQLite + Postgres).
  def change
    add_index :conflicts, [ :user_id, :node_id, :incoming_version_id ],
              unique: true, name: "index_conflicts_on_user_node_incoming"
  end
end
