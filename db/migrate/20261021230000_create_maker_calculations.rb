# A CALCULATOR RESULT SAVED ONTO A PROJECT (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md).
# The modal posts the expression it evaluated, the number it showed and that number's unit; the
# project page's Calculations panel lists them. `result` is a double, the same IEEE value the
# browser computed, so "Open in calculator" and the panel agree to the last digit. `unit` is "" for a
# plain number rather than NULL, so the panel never has to ask which of two spellings means none.
# `inch_fraction` is the display the maker chose (16 or 32 for the nearest 1/16 or 1/32 in), NULL
# for decimal. `project_id` carries no foreign key, like every other maker_* project pointer:
# Maker::Project's `dependent: :destroy` is what removes the rows (structural_orphan_test.rb).
class CreateMakerCalculations < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_calculations do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :project, null: false, index: false
      t.string :label, null: false
      t.text :expression, null: false
      t.float :result, null: false
      t.string :unit, null: false, default: ""
      t.integer :inch_fraction
      t.timestamps
    end
    add_index :maker_calculations, %i[user_id project_id created_at], name: "index_maker_calculations_on_project_created_at"
  end
end
