require "test_helper"
require Dir[Rails.root.join("db/migrate/*_create_maker_addon_state_revisions.rb")].first

# Drives the migration's `up` against a real pre-existing row, rather than trusting the backfill by
# reading the migration file. `addon_state_revision_test.rb` cannot cover this: every revision row
# it sees was created BY that test, never by the migration's own `INSERT`.
#
# GETS A GENUINE "pre-existing row" VIA `down` THEN `up` — NOT A SECOND BARE `up`. This process's
# test database is already migrated (from db/schema.rb, before any test runs), so a second `up`
# would fail on `create_table` before ever reaching the backfill. Making the DDL `if_not_exists:
# true` to dodge that was tried and reverted: `add_column ... if_not_exists: true` SILENTLY SKIPS
# if a column of that name already exists with a different type or default, which would turn a
# loud migration failure into a database quietly diverged from db/schema.rb — this repo's own
# recorded dominant failure shape (CLAUDE.md §14e, §15) — and not a trade worth making to serve a
# test. `down` does not touch `maker_addon_states` at all — it only drops the revisions table and
# removes the `revision` column — so a state seeded BEFORE `down` survives it untouched and is
# sitting there as genuine pre-existing data when `up` runs again: closer to a real deploy than
# re-running `up` on an already-migrated schema ever was.
#
# `Maker::AddonState.reset_column_information` BRACKETS BOTH CALLS. `setup`'s own `create!` has
# already warmed the model's column cache; `down` then removes a column that cache still claims
# exists, and `up` adds it back. Skip either reset and a LATER test in this same worker process
# could inherit a column cache built during the window the column did not exist — which is why
# this file is verified to run cleanly alongside the rest of test/models/maker/ in one process,
# not in isolation.
#
# NO SECOND TEST FOR "a second run does not silently duplicate a revision-1 row" — it was here, and
# it is dropped rather than reworked. It relied on `if_not_exists` to reach the `INSERT` on a
# second `up`; without that, a second bare `up` now fails on `create_table`, a DDL error rather
# than the `RecordNotUnique` the property is actually about, and a `down`/`up` cycle can't
# reproduce "the same `up` sees an already-backfilled row" either, since `down` deletes that row's
# table along with it. The only way left to isolate the property is extracting the backfill into
# its own method so it can be invoked twice without repeating the DDL — a second production change
# to serve a test, on top of the one just reverted for the same reason. The property itself (the
# backfill's `INSERT` has no `WHERE` clause, so it is a one-time fixup, not an idempotent upsert)
# is real but minor next to the one the remaining test guards.
class CreateMakerAddonStateRevisionsMigrationTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "addon-state-revisions-migration@example.com") }

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

    migration = CreateMakerAddonStateRevisions.new
    ActiveRecord::Migration.suppress_messages { migration.down }
    Maker::AddonState.reset_column_information
    ActiveRecord::Migration.suppress_messages { migration.up }
    Maker::AddonState.reset_column_information

    revision = state.revisions.sole
    assert_equal 1, revision.revision
    assert_equal "60", revision.data.dig("params", "h")
    assert_equal state.created_at.to_i, revision.created_at.to_i
  end
end
