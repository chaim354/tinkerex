require "test_helper"
require Rails.root.join("db/migrate/20261021120100_mark_oldest_account_admin")

# AN EXISTING DEPLOYMENT GETS ITS ADMIN WITHOUT A CONSOLE VISIT. Driven directly (`.new.up`) rather
# than through the migrator, which would see the version already applied and run nothing (§14e's
# vacuous shape) -- confirm_existing_library_root_migration_test.rb's pattern.
class MarkOldestAccountAdminMigrationTest < ActiveSupport::TestCase
  setup do
    ActiveRecord::Migration.verbose = false
    User.delete_all
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  teardown do
    ActiveRecord::Migration.verbose = true
    @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  def account!(email) = User.create!(email:, confirmed_at: Time.current, omniauth_signup: true)

  test "the oldest account becomes the admin and no other" do
    oldest = account!("oldest@example.com")
    newer = account!("newer@example.com")

    MarkOldestAccountAdmin.new.up

    assert oldest.reload.admin?
    assert_not newer.reload.admin?
  end

  test "with no account it marks nobody" do
    MarkOldestAccountAdmin.new.up

    assert_equal 0, User.where(admin: true).count
  end

  test "where an admin already exists it marks nobody else, so a re-run adds none" do
    account!("oldest@example.com")
    chosen = account!("chosen@example.com")
    chosen.update!(admin: true)

    2.times { MarkOldestAccountAdmin.new.up }

    assert_equal [ chosen.id ], User.where(admin: true).pluck(:id)
  end

  # OVH's demo can be its oldest row. Marked, it would be an admin the predicate ignores and the
  # server would have none; passed over, the oldest real account gets the role.
  test "the demo account is passed over for the oldest real account" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    demo = account!("demo@example.com")
    real = account!("real@example.com")

    MarkOldestAccountAdmin.new.up

    assert_not demo.reload.admin?
    assert real.reload.admin?
  end
end
