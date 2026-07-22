class CreateMakerNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_notes do |t|
      t.integer :user_id, null: false
      t.string  :node_id, null: false
      t.text    :body,    null: false
      t.timestamps
    end
    add_index :maker_notes, [ :user_id, :node_id ]
  end
end
