class CreateMakerSheets < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_sheets do |t|
      t.integer :user_id, null: false
      t.integer :project_id, null: false
      t.string  :name, null: false
      t.integer :position, null: false, default: 0
      # The whole workbook as one blob: {"columns" => [...], "cells" => [[...], ...]}. `t.json`
      # is real JSON on Postgres and text on SQLite, matching maker_previews.metadata.
      t.json    :data
      t.timestamps
    end

    add_index :maker_sheets, [ :user_id, :project_id, :position ],
              name: "index_maker_sheets_on_project_position"
  end
end
