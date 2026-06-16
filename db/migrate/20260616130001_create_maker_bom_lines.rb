class CreateMakerBomLines < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_bom_lines do |t|
      t.integer :user_id, null: false
      t.integer :bom_id, null: false
      t.string  :reference                 # designator, e.g. "R1", "M3x10"
      t.decimal :quantity, precision: 12, scale: 3, null: false, default: 1
      t.string  :unit, null: false, default: "each"
      # exactly ONE of the three target shapes is set (enforced by model validation):
      t.integer :inventory_item_id         # (1) link an inventory item
      t.string  :node_id                   # (2) link a design file by its stable node_id
      t.string  :part_name                 # (3a) free-text part name …
      t.integer :supplier_id               # (3b) … with an optional supplier
      t.text    :notes
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_bom_lines, [ :user_id, :bom_id, :position ],
              name: "index_maker_bom_lines_on_bom_position"
    add_index :maker_bom_lines, [ :user_id, :inventory_item_id ]
  end
end
