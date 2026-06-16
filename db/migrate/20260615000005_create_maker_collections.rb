class CreateMakerCollections < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_collections do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.text    :description
      t.timestamps
    end
    add_index :maker_collections, [ :user_id, :name ]
  end
end
