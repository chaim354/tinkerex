class CreateMakerProjectBlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_project_blocks do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string :key, null: false
      t.string :kind, null: false
      t.string :heading
      t.text :body
      t.string :url
      t.string :line
      t.string :caption
      t.string :node_id
      t.timestamps
    end
    add_index :maker_project_blocks, %i[project_id key], unique: true
    add_index :maker_project_blocks, %i[user_id project_id]
  end
end
