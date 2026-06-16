class CreateMakerBuildLogEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_build_log_entries do |t|
      t.integer  :user_id, null: false
      t.integer  :project_id, null: false
      t.text     :body, null: false
      t.string   :entry_type, null: false, default: "note"
      t.datetime :logged_at, null: false
      t.timestamps
    end
    add_index :maker_build_log_entries, [ :user_id, :project_id, :logged_at ],
              name: "index_maker_build_log_entries_on_project_logged_at"
  end
end
