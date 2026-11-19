# THE TIDY-UP LIST LEFT WITH THE SHOP MANUAL'S LOOK (2026-11-19): its dismissals have no reader.
# A DROP THAT RUNS FORWARD, never a deleted create migration (CLAUDE.md §10): the create ran on every
# live deployment the morning it shipped, so rewriting history would leave those databases with a
# table and a schema_migrations row that no file names. `down` recreates the table as it was.
class DropMakerTidyDismissals < ActiveRecord::Migration[8.1]
  def up
    drop_table :maker_tidy_dismissals
  end

  def down
    create_table :maker_tidy_dismissals do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.references :project, null: false, index: false
      t.string :kind, null: false
      t.string :subject, null: false
      t.string :state
      t.timestamps
    end
    add_index :maker_tidy_dismissals, %i[project_id kind subject], unique: true,
              name: "index_maker_tidy_dismissals_uniqueness"
  end
end
