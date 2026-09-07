# THE SWEEP'S OWN THREE COLUMNS (stage 4, S4-2; stories 1.5, 4.1, 4.3).
#
# EVERY DEFAULT REPRODUCES TODAY'S BEHAVIOUR, which is the stage's rule: `autofile` true is what
# every project does now, and a never-swept project has no timestamp and no count. A deployment
# that runs this migration and nothing else sees no change at all.
#
# NO INDEX ON ANY OF THEM, DELIBERATELY. Nothing queries by them: the sweep already holds the
# project row (`Maker::ProjectIntake` is constructed per project) and the page reads them off the
# record it loaded. An index led by `user_id` here would also be a strict prefix of an existing one
# and trip `architecture_invariants_test.rb`'s prefix guard for no read it serves.
#
# `last_sweep_moves` IS AN INTEGER WITH NO DEFAULT, NOT `default: 0`, and the difference is a test's
# ability to fail. NULL means "no sweep has ever finished here" and 0 means "one finished and moved
# nothing" — two different facts, and §15's own warning about timestamps compared at `.to_i` is the
# reason to keep a column that is nil until something writes it.
class AddSweepFieldsToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :autofile, :boolean, default: true, null: false
    add_column :maker_projects, :last_swept_at, :datetime
    add_column :maker_projects, :last_sweep_moves, :integer
  end
end
