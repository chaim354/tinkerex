# The tie: one addon_state, many library nodes, each with a role. This is what groups all the
# files an addon outputs at one go (for boxes: the SVG output AND the parameters that made it).
class CreateMakerAddonFiles < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_addon_files do |t|
      t.references :addon_state, null: false, foreign_key: { to_table: :maker_addon_states }
      t.string :node_id, null: false            # a library node (string UUID)
      t.string :role, null: false               # "output" | "parameters" | ...
      t.string :content_type
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_addon_files, [ :addon_state_id, :node_id ], unique: true
  end
end
