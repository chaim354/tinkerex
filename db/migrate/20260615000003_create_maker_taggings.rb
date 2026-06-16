class CreateMakerTaggings < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_taggings do |t|
      t.integer :user_id, null: false
      t.integer :tag_id, null: false
      t.string  :taggable_type, null: false
      t.integer :taggable_id, null: false
      t.timestamps
    end
    add_index :maker_taggings, [ :user_id, :taggable_type, :taggable_id ],
              name: "index_maker_taggings_on_taggable"
    add_index :maker_taggings, [ :tag_id, :taggable_type, :taggable_id ],
              unique: true, name: "index_maker_taggings_unique"
  end
end
