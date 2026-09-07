require "test_helper"
require Rails.root.join("db/migrate/20260907120100_seed_bench_filing_rules_and_rederive_roles")

module Maker
  # THE BENCH'S OWN FORMATS REACH EXISTING USERS ONCE (stage 4, S4-2): a filing-rule top-up in
  # SeedPcbFilingRules' shape and an attachment-role re-derive in RederiveCodeRoles' shape, both in
  # one migration because they are one fact.
  #
  # `seed!`'s `exists?` GUARD MUST NOT BE WEAKENED INTO A TOP-UP. /settings/filing promises that a
  # removed rule "will file into other until you add a new one", so a per-extension fill-in on every
  # read would resurrect a rule the user deliberately deleted. A migration runs ONCE, which is what
  # makes the top-up safe.
  #
  # THE MIGRATION IS DRIVEN DIRECTLY (`.new.up`), NOT THROUGH THE MIGRATOR. The test database is
  # already at this version, so re-running it through the migrator would be a no-op reporting
  # success — the vacuous shape §14e names. Calling `up` on a fresh fixture asks the real question.
  class SeedBenchFilingRulesMigrationTest < ActiveSupport::TestCase
    NEW_KEYS = SeedBenchFilingRulesAndRederiveRoles::RULES.keys

    setup do
      @user = User.create!(email: "bench-seed-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Catan")
    end

    def run_up = ActiveRecord::Migration.suppress_messages { SeedBenchFilingRulesAndRederiveRoles.new.up }
    def run_down = ActiveRecord::Migration.suppress_messages { SeedBenchFilingRulesAndRederiveRoles.new.down }

    # THE PRE-S4-2 WORLD, REBUILT: exactly the rows `seed!` would have written before these five
    # keys existed. Built by REMOVING them from what the seed writes TODAY — both halves of it,
    # ROLE_BY_EXT and BEYOND_ROLE_BY_EXT — rather than by hard-coding a list, so it cannot drift out
    # of step with what a user of that era actually held.
    def seed_without_bench!(user)
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

    test "an already-seeded user gains every bench rule and keeps their own edits" do
      seed_without_bench!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      before = @user.maker_filing_rules.count

      run_up

      assert_equal before + NEW_KEYS.size, @user.maker_filing_rules.reload.count
      assert_equal "cnc",    @user.maker_filing_rules.find_by!(ext: "mage").folder
      assert_equal "laser",  @user.maker_filing_rules.find_by!(ext: "lbrn").folder
      assert_equal "design", @user.maker_filing_rules.find_by!(ext: "ai").folder
      assert_equal "pcb",    @user.maker_filing_rules.find_by!(ext: "kicad_sch").folder
      assert_equal "pcb",    @user.maker_filing_rules.find_by!(ext: "kicad_pcb").folder
      # THE EDIT SURVIVES. `insert_all` with `unique_by:` is ON CONFLICT DO NOTHING, not an upsert —
      # this line is what says the difference matters.
      assert_equal "prints", @user.maker_filing_rules.find_by!(ext: "stl").folder
    end

    # A USER WITH NO ROWS IS SKIPPED, and that is the same argument from the other side: their map
    # has never been seeded, so their first read seeds the WHOLE table (these five included).
    # Inserting rows for them here would hand them a PARTIAL map that `seed!`'s `exists?` guard then
    # refuses to complete — the one state that guard is documented to leave alone.
    # `count`, NEVER `reload`/`assert_empty` ON THE ASSOCIATION ITSELF (the pcb test's recorded
    # trap): `insert_all` does not touch a LOADED association's cache, so loading it as empty here
    # would make `Maker::FilingRules.for` below answer from a stale empty array and this test would
    # fail for a reason that has nothing to do with the migration.
    test "a user who has never been seeded gets nothing from the migration and everything from seed!" do
      assert_equal 0, @user.maker_filing_rules.count

      run_up

      assert_equal 0, @user.maker_filing_rules.count, "an unseeded user must not get a PARTIAL map"
      assert_equal "cnc", Maker::FilingRules.for(@user)["mage"]
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "kicad_sch").folder
    end

    # THE USER WHO ALREADY ADDED `.mage` BY HAND at /settings/filing before this ran: their folder
    # survives and no duplicate row appears. ON CONFLICT DO NOTHING is not an upsert, and this is
    # what says the difference matters. (It does not pin `unique_by:` — the bare form skips too;
    # what naming the index buys is that only the EXPECTED collision is swallowed, which no test
    # here can demonstrate. The pcb migration's own header carries the two SQL statements.)
    test "a user who already added .mage by hand keeps their folder" do
      seed_without_bench!(@user)
      @user.maker_filing_rules.create!(ext: "mage", folder: "cnc-projects")
      before = @user.maker_filing_rules.count

      run_up

      assert_equal "cnc-projects", @user.maker_filing_rules.find_by!(ext: "mage").folder
      assert_equal before + NEW_KEYS.size - 1, @user.maker_filing_rules.reload.count
    end

    # A ROLLBACK TAKES ONLY WHAT `up` COULD HAVE WRITTEN. The folder column is free-form, so a maker
    # can map any extension into `pcb` by hand — `.stp` before this ran, `.xnc` after it — and
    # `down` spelled as "every pcb row" would delete both (SeedPcbFilingRules' recorded lesson,
    # probed there). Restricted to these EXTENSIONS filing into the folder `up` gave them, it
    # leaves them alone.
    test "down removes the bench rules and leaves a hand-made one that files into the same folder" do
      seed_without_bench!(@user)
      @user.maker_filing_rules.create!(ext: "xnc", folder: "pcb")
      @user.maker_filing_rules.find_by!(ext: "stp").update!(folder: "pcb")
      run_up
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "kicad_sch").folder

      run_down

      assert_nil @user.maker_filing_rules.find_by(ext: "kicad_sch"), "the migration's own row is gone"
      assert_nil @user.maker_filing_rules.find_by(ext: "mage")
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "xnc").folder, "a hand-made rule survives"
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "stp").folder, "an edited rule survives"
    end

    test "attachment roles are re-derived only from other, and only for these extensions" do
      mage  = attach("catan.mage", "other")
      lbrn  = attach("tray.lbrn", "other")
      ai    = attach("logo.ai", "other")
      board = attach("board.gbrjob", "pcb")
      # A ROLE SET DELIBERATELY IS NEVER REWRITTEN — the whole point of keying on the PRIOR role
      # rather than on the extension alone.
      deliberate = attach("deliberate.mage", "image")

      run_up

      assert_equal "cnc_design", mage.reload.role
      assert_equal "laser",      lbrn.reload.role
      assert_equal "vector",     ai.reload.role
      assert_equal "pcb",        board.reload.role, "an extension this migration does not name is untouched"
      assert_equal "image",      deliberate.reload.role, "a role set deliberately is never re-derived"
    end

    test "a ghost attachment whose node is gone is skipped rather than raising" do
      ghost = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "other")
      real = attach("catan.mage", "other")

      run_up

      assert_equal "other", ghost.reload.role, "a row whose node is gone is skipped, not crashed on"
      assert_equal "cnc_design", real.reload.role
    end

    test "down returns only the roles up could have written" do
      mage = attach("catan.mage", "other")
      original = attach("outline.ai", "vector") # already `vector` before this migration existed
      run_up
      assert_equal "cnc_design", mage.reload.role

      run_down

      assert_equal "other", mage.reload.role
      assert_equal "other", original.reload.role,
                   "down cannot tell this one apart from a row up wrote — an accepted cost of a " \
                   "reversible data migration, recorded rather than hidden"
    end

    # THE COPY, PINNED AGAINST THE MODEL. The migration names its own lists on purpose (a data
    # migration runs against code that has moved on), and this is the only thing that would notice
    # the copy drifting — the six `rederive_*`/`seed_*` migrations each carry the identical pairing
    # for the identical reason. BOTH ARMS ARE REACHABLE: three keys have a role, two never can.
    test "the migration's copy still equals the model's vocabulary" do
      SeedBenchFilingRulesAndRederiveRoles::RULES.each do |ext, (folder, _prior, new_role)|
        if new_role
          assert_equal new_role, Maker::FileAttachment::ROLE_BY_EXT.fetch(ext),
                       "#{ext}'s role drifted from the migration's copy"
          assert_equal folder, Maker::ProjectFolders::ROLE_FOLDERS.fetch(new_role),
                       "#{ext}'s folder drifted from ROLE_FOLDERS"
        else
          assert_equal folder, Maker::FilingRules::BEYOND_ROLE_BY_EXT.fetch(ext)
          assert_nil Maker::FileAttachment::ROLE_BY_EXT[ext],
                     "#{ext} gained a role — EXT_RE should have refused it"
        end
      end
    end

    # EACH USER'S MAP IS THEIR OWN — the migration loops over users, and a bug that wrote every row
    # against one user_id would still produce the right TOTAL count.
    test "the top-up reaches every seeded user separately" do
      other = User.create!(email: "bench-seed-other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      seed_without_bench!(@user)
      seed_without_bench!(other)

      run_up

      assert_equal "cnc", @user.maker_filing_rules.find_by!(ext: "mage").folder
      assert_equal "cnc", other.maker_filing_rules.find_by!(ext: "mage").folder
      assert_equal "pcb", other.maker_filing_rules.find_by!(ext: "kicad_pcb").folder
    end
  end
end
