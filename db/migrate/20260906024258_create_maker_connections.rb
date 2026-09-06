class CreateMakerConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_connections do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string :from_label, null: false
      t.string :to_label, null: false
      t.string :wire
      t.text :note
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_connections, %i[user_id project_id position]
  end
end
