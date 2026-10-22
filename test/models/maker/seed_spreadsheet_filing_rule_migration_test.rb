require "test_helper"
require Rails.root.join("db/migrate/20261021200000_seed_spreadsheet_filing_rule")

module Maker
  # `.xlsx` REACHES EXISTING USERS' FILING MAPS ONCE — the widening shape, driven with `.new.up` on a
  # fresh fixture, never through the migrator (the test database is already at this version, so that
  # would be a no-op reporting success).
  class SeedSpreadsheetFilingRuleMigrationTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "xlsx-seed-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def run_up = ActiveRecord::Migration.suppress_messages { SeedSpreadsheetFilingRule.new.up }
    def run_down = ActiveRecord::Migration.suppress_messages { SeedSpreadsheetFilingRule.new.down }

    # THE PRE-xlsx WORLD: today's seed without the one key.
    def seed_without_xlsx!(user)
      Maker::FilingRules.seed!(user)
      user.maker_filing_rules.where(ext: "xlsx").delete_all
    end

    test "a seeded user gains xlsx -> docs and keeps their own edits" do
      seed_without_xlsx!(@user)
      @user.maker_filing_rules.find_by!(ext: "csv").update!(folder: "data")
      before = @user.maker_filing_rules.count

      run_up

      assert_equal before + 1, @user.maker_filing_rules.reload.count
      assert_equal "docs", @user.maker_filing_rules.find_by!(ext: "xlsx").folder
      assert_equal "data", @user.maker_filing_rules.find_by!(ext: "csv").folder, "an edited rule survives"
    end

    test "a rule the maker already wrote for xlsx wins" do
      seed_without_xlsx!(@user)
      @user.maker_filing_rules.create!(ext: "xlsx", folder: "sheets")

      run_up

      assert_equal "sheets", @user.maker_filing_rules.find_by!(ext: "xlsx").folder
    end

    # A REMOVED SHELF STAYS REMOVED: no rule names `docs`, so the top-up must not name it either, or
    # Maker::Shelves.ensure! brings the shelf back on the next visit.
    test "a user who files nothing into docs any more is left alone" do
      seed_without_xlsx!(@user)
      @user.maker_filing_rules.where(folder: "docs").delete_all

      run_up

      assert_nil @user.maker_filing_rules.find_by(ext: "xlsx")
    end

    test "a user who has never been seeded gets nothing from the migration and xlsx from seed!" do
      run_up
      assert_equal 0, @user.maker_filing_rules.count

      Maker::FilingRules.seed!(@user)
      assert_equal "docs", @user.maker_filing_rules.find_by!(ext: "xlsx").folder
    end

    test "down removes only the rule up could have written" do
      seed_without_xlsx!(@user)
      run_up
      other = User.create!(email: "xlsx-seed-other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      other.maker_filing_rules.create!(ext: "xlsx", folder: "sheets")

      run_down

      assert_nil @user.maker_filing_rules.find_by(ext: "xlsx")
      assert_equal "sheets", other.maker_filing_rules.find_by!(ext: "xlsx").folder
    end

    # THE COPY, PINNED AGAINST THE MODEL — the tripwire every widening carries.
    test "the migration's copy still equals the vocabulary" do
      role = Maker::FileAttachment::ROLE_BY_EXT.fetch(SeedSpreadsheetFilingRule::EXT)
      assert_equal "spreadsheet", role
      assert_equal SeedSpreadsheetFilingRule::FOLDER, Maker::ProjectFolders::ROLE_FOLDERS.fetch(role)
    end
  end
end
