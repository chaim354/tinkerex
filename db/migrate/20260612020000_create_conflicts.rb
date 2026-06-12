class CreateConflicts < ActiveRecord::Migration[8.1]
  def change
    create_table :conflicts do |t|
      t.integer :user_id, null: false
      t.string :node_id, null: false
      t.string :current_version_id, null: false   # what the node currently points to (theirs)
      t.string :incoming_version_id, null: false   # the conflicting new version (mine)
      t.datetime :resolved_at                       # nil while the user still needs to decide
      t.timestamps
    end
    add_index :conflicts, [:user_id, :node_id]
    add_index :conflicts, [:user_id, :resolved_at]
  end
end
