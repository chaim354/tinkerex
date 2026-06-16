class CreateMakerBoms < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_boms do |t|
      t.integer :user_id, null: false
      t.integer :project_id, null: false
      t.string  :name, null: false, default: "BOM"
      t.integer :revision, null: false, default: 1
      t.timestamps
    end
    add_index :maker_boms, [ :user_id, :project_id ]
    add_index :maker_boms, [ :project_id, :revision ]
  end
end
