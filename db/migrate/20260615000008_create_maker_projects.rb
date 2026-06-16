class CreateMakerProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_projects do |t|
      t.integer  :user_id, null: false
      t.string   :name, null: false
      t.string   :slug, null: false
      t.text     :description
      t.string   :status, null: false, default: "planning"
      t.datetime :archived_at
      t.timestamps
    end
    add_index :maker_projects, [ :user_id, :slug ], unique: true
    add_index :maker_projects, [ :user_id, :status ]
  end
end
