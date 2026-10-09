class CreateMakerPins < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_pins do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :node_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_pins, %i[user_id node_id], unique: true
    add_index :maker_pins, %i[user_id position]
  end
end
