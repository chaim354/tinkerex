class CreateMakerPrintRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_print_runs do |t|
      t.integer :user_id,        null: false
      t.integer :model_id,       null: false
      t.date    :printed_on,     null: false
      t.string  :printer
      t.string  :material
      t.string  :outcome,        null: false
      t.decimal :duration_hours, precision: 6, scale: 2
      t.integer :filament_grams
      t.text    :notes
      t.timestamps
    end
    add_index :maker_print_runs, [ :model_id, :printed_on ]
    add_index :maker_print_runs, :user_id
  end
end
