class CreateMakerStackExclusions < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_stack_exclusions do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :node_id, null: false
      t.timestamps
    end
    add_index :maker_stack_exclusions, %i[user_id node_id], unique: true
  end
end
