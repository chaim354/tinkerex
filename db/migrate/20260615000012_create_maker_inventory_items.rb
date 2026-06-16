class CreateMakerInventoryItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_inventory_items do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :part_number
      t.string  :category
      t.string  :unit, null: false, default: "each"
      t.decimal :quantity_cached, precision: 12, scale: 3, null: false, default: 0
      t.decimal :min_quantity, precision: 12, scale: 3, null: false, default: 0
      t.decimal :unit_cost, precision: 12, scale: 4
      t.integer :location_id
      t.integer :supplier_id
      t.text    :notes
      t.timestamps
    end
    add_index :maker_inventory_items, [ :user_id, :name ]
    add_index :maker_inventory_items, [ :user_id, :category ]
    add_index :maker_inventory_items, [ :user_id, :location_id ]
    add_index :maker_inventory_items, [ :user_id, :supplier_id ]
  end
end
