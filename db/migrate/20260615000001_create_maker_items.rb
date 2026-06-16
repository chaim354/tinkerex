class CreateMakerItems < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_items do |t|
      t.integer :user_id, null: false
      t.string  :title, null: false
      t.string  :summary
      t.text    :description
      t.text    :instructions
      t.string  :item_type, null: false, default: "other"
      t.string  :origin, null: false, default: "downloaded"
      t.string  :source_url
      t.string  :source_name
      t.string  :primary_node_id
      t.boolean :favorited, null: false, default: false
      t.timestamps
    end
    add_index :maker_items, [ :user_id, :item_type ]
    add_index :maker_items, [ :user_id, :title ]
    add_index :maker_items, [ :user_id, :favorited ]
  end
end
