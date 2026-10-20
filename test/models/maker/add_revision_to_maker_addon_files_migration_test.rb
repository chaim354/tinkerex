require "test_helper"
require Dir[Rails.root.join("db/migrate/*_add_revision_to_maker_addon_files.rb")].first

# Drives the migration's `up` against real pre-existing rows rather than trusting the backfill by
# reading it. Same shape as create_maker_addon_state_revisions_migration_test.rb, whose header
# carries the argument for `down` then `up` (never a second bare `up`, which fails on the DDL
# before reaching the backfill) and for resetting the column cache around both calls.
#
# THE STATES SIT AT REVISIONS 3 AND 2, NEVER 1, AND THAT IS THE WHOLE TEST. The column defaults to
# 1, so a row whose state is at revision 1 reads 1 whether or not the backfill ran: "skip the
# UPDATE" would stay green (§15, default equals expected). Two states at two different numbers also
# refuse a backfill that stamps one value on every row; the UPDATE must be correlated, each row
# taking its own state's number.
class AddRevisionToMakerAddonFilesMigrationTest < ActiveSupport::TestCase
  setup { @user = User.create!(email: "addon-file-revision-migration@example.com") }

  test "backfills every existing row with its own state's current revision" do
    twice = @user.maker_addon_states.create!(addon_key: "boxes", name: "revised twice", data: {}, revision: 3)
    once = @user.maker_addon_states.create!(addon_key: "boxes", name: "revised once", data: {}, revision: 2)
    rows = [
      twice.files.create!(node_id: "n-twice-a", role: "output", position: 0),
      twice.files.create!(node_id: "n-twice-b", role: "output", position: 1),
      once.files.create!(node_id: "n-once", role: "output", position: 0)
    ]

    migration = AddRevisionToMakerAddonFiles.new
    ActiveRecord::Migration.suppress_messages { migration.down }
    Maker::AddonFile.reset_column_information
    ActiveRecord::Migration.suppress_messages { migration.up }
    Maker::AddonFile.reset_column_information

    assert_equal [ 3, 3, 2 ], rows.map { |row| Maker::AddonFile.find(row.id).revision }
  end
end
