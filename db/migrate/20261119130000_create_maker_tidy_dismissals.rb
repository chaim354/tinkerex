# A TIDY-UP SUGGESTION THE MAKER DISMISSED (the Shop manual's §9 tidy-up list, 2026-11-19).
# `kind` is the check (Maker::TidyUp::KINDS), `subject` the stable key of what it is about (a node id,
# a repository's root node id, or "<derived>><source>" for an export and its source), and `state`
# what that subject looked like when it was dismissed. A suggestion stays dismissed only while its
# state is the same, so a NEW occurrence of it (the source edited again, a different set of changed
# paths) comes back by itself; nothing ever has to clear a row for that.
#
# `subject` NAMES NODES BUT IS NOT A `*_id` COLUMN, on purpose: a pair of nodes has no one id, and
# a dismissal is about the suggestion, not a pointer into `nodes` that liveness must answer.
# `project_id` carries no foreign key, like every other maker_* project pointer: Maker::Project's
# `dependent: :destroy` removes the rows (structural_orphan_test.rb).
class CreateMakerTidyDismissals < ActiveRecord::Migration[8.1]
  def change
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
