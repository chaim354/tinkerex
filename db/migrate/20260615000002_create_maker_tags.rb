class CreateMakerTags < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_tags do |t|
      t.integer :user_id, null: false
      t.string  :name, null: false
      t.string  :color
      t.timestamps
    end
    add_index :maker_tags, [ :user_id, :name ], unique: true
  end
end
