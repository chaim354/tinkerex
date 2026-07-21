# One saved addon "thing" — its structured state (for reload) plus a tied bundle of output files
# (maker_addon_files). Every addon persists the same way through this one model.
class CreateMakerAddonStates < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_addon_states do |t|
      t.references :user, null: false, foreign_key: true
      t.string :addon_key, null: false
      t.string :name, null: false
      t.json :data, null: false, default: {}
      t.timestamps
    end
    add_index :maker_addon_states, [ :user_id, :addon_key ]
  end
end
