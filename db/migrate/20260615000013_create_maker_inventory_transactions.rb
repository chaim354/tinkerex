class CreateMakerInventoryTransactions < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_inventory_transactions do |t|
      t.integer  :user_id, null: false
      t.integer  :inventory_item_id, null: false
      t.decimal  :delta, precision: 12, scale: 3, null: false
      t.string   :reason, null: false, default: "adjusted"
      t.integer  :project_id
      t.text     :note
      t.datetime :created_at, null: false   # immutable ledger — no updated_at
    end
    add_index :maker_inventory_transactions, [ :user_id, :inventory_item_id, :created_at ],
              name: "index_maker_inventory_transactions_on_item_created_at"
    add_index :maker_inventory_transactions, [ :user_id, :project_id ]
  end
end
