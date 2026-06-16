class CreateMakerLocations < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_locations do |t|
      t.integer :user_id, null: false
      t.integer :parent_id
      t.string  :name, null: false
      t.text    :description
      t.timestamps
    end
    add_index :maker_locations, [ :user_id, :parent_id ]
    add_index :maker_locations, [ :user_id, :name ]
  end
end
