require "test_helper"
require Dir[Rails.root.join("db/migrate/*_dedupe_and_index_maker_file_attachments.rb")].first

# Drives the migration's up AND down against real rows, the same idiom as
# rederive_laser_roles_migration_test.rb: require the migration file by glob and call `.new.up`
# directly, rather than trusting the file by reading it.
#
# THE SCHEMA IS ALREADY MIGRATED BY THE TIME ANY TEST HERE RUNS. Rails loads the test database from
# db/schema.rb wholesale (ActiveRecord::Migration.maintain_test_schema!) rather than replaying every
# migration file in order, so the unique index this migration adds is already live before the first
# test method in this file executes — same as every other test in the suite. That is why the tests
# that need to construct GENUINE duplicate rows first remove the index by hand
# (`without_unique_index`), putting the table back into the shape it was in the one time this
# migration's `up` ran for real, against a database that had never seen it before. `up` itself has
# to tolerate an index that already exists (see its `if_not_exists:`) for exactly this reason, quite
# apart from the "up is idempotent" requirement below — without it, EVERY test in this file would
# fail the moment `up` tried to (re)add an index the test schema already has.
class DedupeAndIndexMakerFileAttachmentsMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "dedupe-fa-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # A raw attachment row. node_id has no FK to `nodes` — this migration (and this test) never needs
  # a real node behind it, only the four columns the unique index covers.
  def attach(node_id, role: "model", project: @project)
    project.file_attachments.create!(user: @user, node_id:, role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { DedupeAndIndexMakerFileAttachments.new.up }
  end

  def run_rollback
    ActiveRecord::Migration.suppress_messages { DedupeAndIndexMakerFileAttachments.new.down }
  end

  # Puts the table back into the state it was in the one time `up` ran for real: no index yet, so
  # duplicate rows are storable. The removal happens on the SAME connection the wrapping test
  # transaction is using, so it — and every row created inside the block — rolls back with
  # everything else at the end of the test. Nothing to restore by hand (SQLite and Postgres both
  # support transactional DDL; this codebase's own migrations already lean on that — see
  # test/test_helper.rb's transactional-test default, unmodified here).
  def without_unique_index
    ActiveRecord::Base.connection.remove_index(:maker_file_attachments,
                                               name: DedupeAndIndexMakerFileAttachments::INDEX_NAME)
    yield
  end

  test "the migration dedupes, keeping the lowest id" do
    other_project = @user.maker_projects.create!(name: "Bench")
    low = mid = high = control = nil

    without_unique_index do
      low = attach("n-shared")
      mid = attach("n-shared")
      high = attach("n-shared")
      # THE CONTROL SHARES THE node_id ON PURPOSE. A different project attached to the SAME file is
      # a legitimate second row, not a duplicate of the trio above — so this is a stronger check
      # than an unrelated node_id would be: it catches a dedupe that (wrongly) grouped by node_id
      # alone instead of the full (user, attachable_type, attachable_id, node_id) tuple.
      control = attach("n-shared", project: other_project)
      run_migration
    end

    survivors = @project.file_attachments.where(node_id: "n-shared")
    assert_equal 1, survivors.count
    assert_equal low.id, survivors.first.id, "the lowest id must survive, not merely a surviving one"
    assert_not Maker::FileAttachment.exists?(id: mid.id)
    assert_not Maker::FileAttachment.exists?(id: high.id)
    assert Maker::FileAttachment.exists?(id: control.id),
           "a different project's attachment of the same file must be untouched"
    assert_equal other_project.id, control.reload.attachable_id
  end

  test "the migration is a no-op when there are no duplicates" do
    solo = attach("n-solo")
    run_migration
    assert Maker::FileAttachment.exists?(id: solo.id)
    assert_equal 1, Maker::FileAttachment.where(node_id: "n-solo").count
  end

  test "up is idempotent" do
    without_unique_index do
      attach("n-shared")
      attach("n-shared")
      run_migration
      run_migration
    end
    assert_equal 1, @project.file_attachments.where(node_id: "n-shared").count
  end

  # THE POINT OF THE WHOLE MIGRATION, verified directly rather than trusted: the constraint is a
  # real DATABASE index, not merely application-level bookkeeping. `run_migration` here is a no-op
  # (the index is already live via schema.rb, and `up` tolerates that); it is still called so this
  # test does not depend on an unstated assumption that some earlier test already ran it.
  test "the unique index actually exists and bites" do
    run_migration
    attach("n-bites")
    assert_raises(ActiveRecord::RecordNotUnique) { attach("n-bites") }
  end

  # down's ONLY job: drop the index. There is nothing to restore data-wise (see the migration's own
  # comment on why), so the whole test is "the constraint is gone, and re-adding it is what brings
  # it back" — which also doubles as coverage that `down`'s `remove_index` call is spelled right.
  test "down drops the index — a duplicate insert is storable again" do
    run_migration
    run_rollback

    assert_nothing_raised do
      attach("n-after-down")
      attach("n-after-down")
    end
    assert_equal 2, @project.file_attachments.where(node_id: "n-after-down").count
  end
end
