# THE SHELVES ARE THE FILING FOLDERS (2026-10-20). `maker_shelves` held the model catalog's path
# patterns; those became Maker::ModelIntake::SHELVES, fixed in code, after every live user was
# measured holding exactly the four seeds. The name now belongs to the folders the intake sweep
# files into inside each project, each with a default view and an optional group. Rows are made
# on read by Maker::Shelves.ensure!, so nothing is backfilled here.
class ReplaceModelShelvesWithFilingShelves < ActiveRecord::Migration[8.1]
  def up
    drop_table :maker_shelves
    remove_column :users, :shelves_seeded_at

    create_table :maker_shelf_groups do |t|
      t.integer :user_id, null: false
      t.string :name, null: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_shelf_groups, %i[user_id name], unique: true

    create_table :maker_shelves do |t|
      t.integer :user_id, null: false
      t.string :name, null: false
      t.string :default_view
      t.integer :shelf_group_id
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :maker_shelves, %i[user_id name], unique: true
    add_index :maker_shelves, :shelf_group_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
