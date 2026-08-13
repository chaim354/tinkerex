require "test_helper"
require Dir[Rails.root.join("db/migrate/*_create_maker_addon_state_revisions.rb")].first

# Drives the migration's `up` against a real pre-existing row, rather than trusting the backfill by
# reading the migration file. `addon_state_revision_test.rb` cannot cover this: every revision row
# it sees was created BY that test, never by the migration's own `INSERT`.
#
# `up`'s three DDL calls all pass `if_not_exists: true` for exactly this test: this process's test
# database already has the table, the index and the column (loaded from db/schema.rb before any
# test runs), so calling the real `up` a second time here would otherwise fail on `create_table`
# before ever reaching the backfill. That changes nothing about a genuine first-run deploy — none
# of the three exist yet then — and it is what lets this test drive the SAME `up` a production
# migrate runs, rather than a hand-copied restatement of its SQL that could silently drift from the
# real thing.
class CreateMakerAddonStateRevisionsMigrationTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "addon-state-revisions-migration@example.com") }

  def run_migration
    ActiveRecord::Migration.suppress_messages { CreateMakerAddonStateRevisions.new.up }
  end

  test "backfills a revision-1 row carrying the state's own data and created_at" do
    # THE HALF MOST LIKELY TO REGRESS TO `now()`, and the reason this is `travel_to`'d three days
    # into the past rather than left at "whenever setup happened to run": a state created and a
    # migration run moments apart, in the same process, land in the same wall-clock SECOND — a
    # `.to_i`-precision comparison against a `CURRENT_TIMESTAMP` mutation was tried first and
    # STAYED GREEN, because both values rounded to the same second. Separating them by days makes
    # a `now()`-style regression fail by three orders of magnitude instead of by nothing.
    state = travel_to(3.days.ago) do
      @user.maker_addon_states.create!(
        addon_key: "boxes", name: "pre-existing", data: { "generator" => "tray", "params" => { "h" => "60" } }
      )
    end
    # A freshly created state has NO revision rows under Task 1 — nothing yet creates one on save
    # (that arrives with the save door) — so this state is exactly what the backfill exists for: a
    # row that predates the migration.
    assert_equal 0, state.revisions.count

    run_migration # runs at the REAL current time — today, not 3 days ago

    revision = state.revisions.reload.sole
    assert_equal 1, revision.revision
    assert_equal "60", revision.data.dig("params", "h")
    assert_equal state.created_at.to_i, revision.created_at.to_i
  end

  # `if_not_exists: true` makes the SCHEMA re-appliable; it says nothing about the DATA. Pin the
  # difference: the backfill's INSERT has no WHERE clause, so it is a one-time fixup, not an
  # idempotent upsert, and a second run against a state that already has its revision-1 row must
  # fail loudly on the unique index rather than duplicating history or silently no-oping.
  test "a state that already has its revision 1 is not silently duplicated by a second run" do
    state = @user.maker_addon_states.create!(addon_key: "boxes", name: "already-done", data: { "h" => "1" })
    run_migration
    first_run_id = state.revisions.reload.sole.id

    assert_raises(ActiveRecord::RecordNotUnique) { run_migration }
    assert_equal first_run_id, state.revisions.reload.sole.id
  end
end
