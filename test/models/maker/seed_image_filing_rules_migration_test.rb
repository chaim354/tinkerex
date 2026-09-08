require "test_helper"
require Rails.root.join("db/migrate/20260908120100_seed_image_filing_rules_and_rederive_roles")

module Maker
  # AN iPHONE'S AND A SCANNER'S RASTERS REACH EXISTING USERS ONCE (tinkerex#285) — the S4-2
  # widening's shape, driven the same way: `.new.up` on a fresh fixture, never through the migrator
  # (the test database is already at this version, so that would be a no-op reporting success).
  class SeedImageFilingRulesMigrationTest < ActiveSupport::TestCase
    NEW_KEYS = SeedImageFilingRulesAndRederiveRoles::RULES.keys

    setup do
      @user = User.create!(email: "image-seed-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Phone shots")
    end

    def run_up = ActiveRecord::Migration.suppress_messages { SeedImageFilingRulesAndRederiveRoles.new.up }
    def run_down = ActiveRecord::Migration.suppress_messages { SeedImageFilingRulesAndRederiveRoles.new.down }

    # THE PRE-#285 WORLD, REBUILT by removing the four keys from what the seed writes today.
    def seed_without_image_keys!(user)
      now = Time.current
      from_vocabulary = Maker::FileAttachment::ROLE_BY_EXT.map do |ext, role|
        [ ext, Maker::ProjectFolders::ROLE_FOLDERS.fetch(role) ]
      end
      rows = (from_vocabulary + Maker::FilingRules::BEYOND_ROLE_BY_EXT.to_a).filter_map do |ext, folder|
        next if NEW_KEYS.include?(ext)

        { user_id: user.id, ext:, folder:, created_at: now, updated_at: now }
      end
      Maker::FilingRule.insert_all(rows)
    end

    def attach(name, role)
      node_id = SecureRandom.uuid
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)
      @project.file_attachments.create!(user: @user, node_id:, role:)
    end

    test "an already-seeded user gains the four image rules and keeps their own edits" do
      seed_without_image_keys!(@user)
      @user.maker_filing_rules.find_by!(ext: "png").update!(folder: "photos")
      before = @user.maker_filing_rules.count

      run_up

      assert_equal before + NEW_KEYS.size, @user.maker_filing_rules.reload.count
      NEW_KEYS.each { |ext| assert_equal "images", @user.maker_filing_rules.find_by!(ext:).folder }
      assert_equal "photos", @user.maker_filing_rules.find_by!(ext: "png").folder, "an edited rule survives"
    end

    test "a user who has never been seeded gets nothing from the migration and everything from seed!" do
      run_up
      assert_equal 0, @user.maker_filing_rules.count

      Maker::FilingRules.seed!(@user)
      NEW_KEYS.each { |ext| assert_equal "images", @user.maker_filing_rules.find_by!(ext:).folder }
    end

    test "attachment roles are re-derived only from other, and only for these extensions" do
      heic  = attach("IMG_0001.heic", "other")
      tiff  = attach("scan.tiff", "other")
      png   = attach("lid.png", "image")
      other = attach("telemetry.bin", "other")
      deliberate = attach("deliberate.heic", "document")

      run_up

      assert_equal "image", heic.reload.role
      assert_equal "image", tiff.reload.role
      assert_equal "image", png.reload.role
      assert_equal "other", other.reload.role, "an extension this migration does not name is untouched"
      assert_equal "document", deliberate.reload.role, "a role set deliberately is never re-derived"
    end

    test "a ghost attachment whose node is gone is skipped rather than raising" do
      ghost = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "other")
      real = attach("IMG_0002.heic", "other")

      run_up

      assert_equal "other", ghost.reload.role
      assert_equal "image", real.reload.role
    end

    test "down returns the roles up wrote and removes the rules it seeded" do
      seed_without_image_keys!(@user)
      heic = attach("IMG_0003.heic", "other")
      run_up
      assert_equal "image", heic.reload.role

      run_down

      assert_equal "other", heic.reload.role
      NEW_KEYS.each { |ext| assert_nil @user.maker_filing_rules.find_by(ext:), "#{ext}'s rule is gone" }
    end

    # THE COPY, PINNED AGAINST THE MODEL — the same tripwire every widening carries.
    test "the migration's copy still equals the model's vocabulary" do
      SeedImageFilingRulesAndRederiveRoles::RULES.each do |ext, (folder, _prior, new_role)|
        assert_equal new_role, Maker::FileAttachment::ROLE_BY_EXT.fetch(ext), "#{ext}'s role drifted"
        assert_equal folder, Maker::ProjectFolders::ROLE_FOLDERS.fetch(new_role), "#{ext}'s folder drifted"
      end
    end

    test "the top-up reaches every seeded user separately" do
      other = User.create!(email: "image-seed-other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      seed_without_image_keys!(@user)
      seed_without_image_keys!(other)

      run_up

      assert_equal "images", @user.maker_filing_rules.find_by!(ext: "heic").folder
      assert_equal "images", other.maker_filing_rules.find_by!(ext: "tiff").folder
    end
  end
end
