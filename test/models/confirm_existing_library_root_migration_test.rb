require "test_helper"
require Rails.root.join("db/migrate/20261020180100_confirm_existing_library_root")

# AN EXISTING DEPLOYMENT IS CONFIRMED BY CONSTRUCTION, A FRESH ONE IS NOT (K §2). Driven directly
# (`.new.up`) rather than through the migrator, which would see this version already applied and
# report success without running anything (§14e's vacuous shape) -- seed_pcb_filing_rules_migration
# _test.rb's pattern.
class ConfirmExistingLibraryRootMigrationTest < ActiveSupport::TestCase
  KEY = Tinkerex::LibraryRoot::KEY

  setup do
    ActiveRecord::Migration.verbose = false
    Setting.forget(KEY)
  end

  teardown { ActiveRecord::Migration.verbose = true }

  test "with an account present it confirms the whole mount" do
    User.create!(email: "existing-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                 omniauth_signup: true)

    ConfirmExistingLibraryRoot.new.up

    assert_equal [ "" ], Setting.where(key: KEY).pluck(:value)
  end

  test "with no account it writes nothing, so a fresh install is pending" do
    User.delete_all

    ConfirmExistingLibraryRoot.new.up

    assert_not Setting.exists?(key: KEY)
  end

  test "running it twice leaves one row" do
    User.create!(email: "twice-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                 omniauth_signup: true)

    2.times { ConfirmExistingLibraryRoot.new.up }

    assert_equal 1, Setting.where(key: KEY).count
  end
end
