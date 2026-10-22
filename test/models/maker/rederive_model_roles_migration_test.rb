require "test_helper"
require Rails.root.join("db/migrate/20260906140000_rederive_model_roles_and_seed_filing_rules")

module Maker
  # THE VIEWER'S THIRTEEN NEW FORMATS REACH EXISTING USERS ONCE (Online3DViewer, 2026-09-06): a
  # filing-rule top-up in SeedPcbFilingRules' shape and an attachment-role re-derive in
  # RederiveCodeRoles' shape, both in one migration because they are one fact. Driven directly
  # (`.new.up` / `.new.down`), as every migration test here is.
  class RederiveModelRolesMigrationTest < ActiveSupport::TestCase
    NEW_EXTS = RederiveModelRolesAndSeedFilingRules::MODEL_EXTS

    setup do
      @user = User.create!(email: "model-seed-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    def run_up = ActiveRecord::Migration.suppress_messages { RederiveModelRolesAndSeedFilingRules.new.up }
    def run_down = ActiveRecord::Migration.suppress_messages { RederiveModelRolesAndSeedFilingRules.new.down }

    # THE PRE-WIDENING WORLD, REBUILT: the rows `seed!` wrote before these extensions existed, built
    # by REMOVING them from today's vocabulary rather than by hard-coding a list.
    def seed_without_new_models!(user)
      now = Time.current
      rows = Maker::FileAttachment::ROLE_BY_EXT.filter_map do |ext, role|
        next if NEW_EXTS.include?(ext)

        { user_id: user.id, ext:, folder: Maker::ProjectFolders::ROLE_FOLDERS.fetch(role),
          created_at: now, updated_at: now }
      end
      Maker::FilingRule.insert_all(rows)
    end

    def attach(name, role)
      node_id = SecureRandom.uuid
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1, size: 1)
      @project.file_attachments.create!(user: @user, node_id:, role:)
    end

    test "an already-seeded user gains every new model rule and keeps their own edits" do
      seed_without_new_models!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      assert_nil @user.maker_filing_rules.find_by(ext: "glb")

      run_up

      NEW_EXTS.each do |ext|
        assert_equal "models", @user.maker_filing_rules.find_by!(ext:).folder, ext
      end
      assert_equal "prints", @user.maker_filing_rules.find_by!(ext: "stl").folder, "an edit survives the top-up"
      assert_equal "models", Maker::ProjectFolders.folder_for(@user, "scan.glb")
    end

    test "a user who has never been seeded gets nothing from the migration and everything from seed!" do
      run_up
      assert_equal 0, @user.maker_filing_rules.count

      assert_equal "models", Maker::ProjectFolders.folder_for(@user, "scan.glb"), "the first read seeds the full table"
    end

    test "an other attachment on a new-format node becomes model; a deliberate role and a ghost are untouched" do
      scan = attach("scan.glb", "other")
      kept = attach("scan.ply", "instructions")
      text = attach("notes.txt", "other")
      ghost = ghost_attachment!(@project, user: @user, node_id: "ghost", role: "other")

      run_up

      assert_equal "model", scan.reload.role
      assert_equal "instructions", kept.reload.role, "a role set deliberately is never re-derived"
      assert_equal "other", text.reload.role
      assert_equal "other", ghost.reload.role, "a row whose node is gone is skipped, not crashed on"
    end

    # A ROLLBACK TAKES ONLY WHAT `up` COULD HAVE WRITTEN: these extensions filing into models, and
    # these extensions' roles. A hand-made rule that files something else into models survives, and
    # an .stl that was `model` all along stays `model`.
    test "down removes only the migration's own rules and roles" do
      seed_without_new_models!(@user)
      @user.maker_filing_rules.create!(ext: "xyz", folder: "models")
      original = attach("base.stl", "model")
      scan = attach("scan.glb", "other")
      run_up
      assert_equal "model", scan.reload.role

      run_down

      assert_nil @user.maker_filing_rules.find_by(ext: "glb"), "the migration's own rule is gone"
      assert_equal "models", @user.maker_filing_rules.find_by!(ext: "xyz").folder, "a hand-made rule survives"
      assert_equal "models", @user.maker_filing_rules.find_by!(ext: "stl").folder, "an original rule survives"
      assert_equal "other", scan.reload.role
      assert_equal "model", original.reload.role, "a model that was never re-derived is not reverted"
    end

    test "running up twice is a no-op the second time" do
      seed_without_new_models!(@user)
      attach("scan.glb", "other")
      run_up
      before = [ @user.maker_filing_rules.count, @project.file_attachments.pluck(:role).sort ]

      run_up

      assert_equal before, [ @user.maker_filing_rules.count, @project.file_attachments.pluck(:role).sort ]
    end

    # THE COPY, PINNED AGAINST THE MODEL PER KEY, the form the other seven migration tests use:
    # every extension the migration copied is still `model`. A self-contained migration that drifted
    # from ROLE_BY_EXT would file the wrong extensions and re-derive the wrong roles.
    #
    # NOT AN EQUALITY WITH TODAY'S `model` ROLE ANY MORE (F-S33-1, 2026-10-19): that form reddened
    # this test of a migration that had already run on the next model widening. The vocabulary may
    # grow past the copy now: attachment rows stored `other` follow it by
    # Maker::FileAttachment.classify_unclassified!, and existing users' FILING rule for a new key is
    # a new top-up, never an edit of this one.
    test "every extension the migration copied is still model, and its folder is ROLE_FOLDERS'" do
      assert_equal 13, NEW_EXTS.size, "the list is the whole subject of this test"
      NEW_EXTS.each do |ext|
        assert_equal RederiveModelRolesAndSeedFilingRules::NEW_ROLE,
                     Maker::FileAttachment::ROLE_BY_EXT[ext], "migration copies #{ext} as model"
      end
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.fetch("model"), RederiveModelRolesAndSeedFilingRules::FOLDER
    end
  end
end
