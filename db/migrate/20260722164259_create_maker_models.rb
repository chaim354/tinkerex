class CreateMakerModels < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_models do |t|
      t.integer :user_id,        null: false
      t.string  :title,          null: false
      t.string  :slug,           null: false
      t.string  :source_url
      t.string  :designer
      t.string  :license
      t.string  :print_status,   null: false, default: "want_to_print"
      t.text    :notes
      t.string  :folder_node_id
      t.string  :cover_node_id
      t.timestamps
    end
    add_index :maker_models, [ :user_id, :slug ], unique: true
    add_index :maker_models, [ :user_id, :print_status ]
  end
end
