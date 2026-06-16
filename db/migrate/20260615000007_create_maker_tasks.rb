class CreateMakerTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_tasks do |t|
      t.integer  :user_id, null: false
      t.string   :title, null: false
      t.text     :notes
      t.string   :status, null: false, default: "todo"
      t.integer  :position, null: false, default: 0
      t.datetime :completed_at
      t.string   :taskable_type
      t.integer  :taskable_id
      t.timestamps
    end
    add_index :maker_tasks, [ :user_id, :status ]
    add_index :maker_tasks, [ :user_id, :taskable_type, :taskable_id ],
              name: "index_maker_tasks_on_taskable"
  end
end
