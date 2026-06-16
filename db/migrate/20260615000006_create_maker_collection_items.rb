class CreateMakerCollectionItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_collection_items do |t|
      t.integer :user_id, null: false
      t.integer :collection_id, null: false
      t.integer :item_id, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_collection_items, [ :collection_id, :item_id ],
              unique: true, name: "index_maker_collection_items_unique"
    add_index :maker_collection_items, [ :user_id, :collection_id, :position ],
              name: "index_maker_collection_items_on_position"
  end
end
