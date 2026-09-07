require "test_helper"
require Rails.root.join("db/migrate/20260906120000_seed_pcb_filing_rules")

module Maker
  # THE DATA MIGRATION THAT GIVES EXISTING USERS THE `pcb` FILING RULES, and the reason it is a
  # migration rather than a change to `Maker::FilingRules.seed!`.
  #
  # `seed!`'s `exists?` GUARD MUST NOT BE WEAKENED INTO A TOP-UP. /settings/filing promises that a
  # removed rule "will file into other until you add a new one", so a per-extension fill-in on every
  # read would resurrect a rule the user deliberately deleted — and `seed!`'s own header already
  # rejects that design at length. A migration runs ONCE, which is what makes the top-up safe.
  #
  # THE MIGRATION IS DRIVEN DIRECTLY (`.new.up`), NOT THROUGH THE MIGRATOR. The test database is
  # already at this version, so re-running it through the migrator would be a no-op reporting
  # success — the vacuous shape §14e names. Calling `up` on a fresh fixture asks the real question.
  class SeedPcbFilingRulesMigrationTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pcb-seed-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # THE PRE-pcb WORLD, REBUILT: exactly the rows `seed!` would have written before the `pcb` role
    # existed. Built by REMOVING the pcb entries from today's vocabulary rather than by hard-coding
    # a list, so it cannot drift out of step with what a user of that era actually held.
    def seed_without_pcb!(user)
      now = Time.current
      rows = Maker::FileAttachment::ROLE_BY_EXT.filter_map do |ext, role|
        next if role == "pcb"

        { user_id: user.id, ext:, folder: Maker::ProjectFolders::ROLE_FOLDERS.fetch(role),
          created_at: now, updated_at: now }
      end
      Maker::FilingRule.insert_all(rows)
    end

    test "an already-seeded user gains every pcb rule and keeps their own edits" do
      seed_without_pcb!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      before = @user.maker_filing_rules.count

      SeedPcbFilingRules.new.up

      assert_equal before + SeedPcbFilingRules::PCB_EXTS.size, @user.maker_filing_rules.reload.count
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "gtl").folder
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "gbrjob").folder
      # THE EDIT SURVIVES. `insert_all` with `unique_by:` is ON CONFLICT DO NOTHING, not an upsert —
      # this line is what says the difference matters.
      assert_equal "prints", @user.maker_filing_rules.find_by!(ext: "stl").folder
    end

    # A USER WITH NO ROWS IS SKIPPED, and that is the same argument from the other side: their map
    # has never been seeded, so their first read seeds the WHOLE table (pcb included, from
    # ROLE_BY_EXT). Inserting 24 rows for them here would hand them a PARTIAL map that `seed!`'s
    # `exists?` guard then refuses to complete — the one state that guard is documented to leave
    # alone, and a user who would then have pcb rules and no `.stl` rule at all.
    # `count`, NEVER `reload`/`assert_empty` ON THE ASSOCIATION ITSELF. `pluck` on a LOADED
    # association reads the records already in memory, and `insert_all` (which is what both `seed!`
    # and the migration use) does not touch that cache — so loading it as empty here would make
    # `Maker::FilingRules.for` below answer from a stale empty array and this test would fail for a
    # reason that has nothing to do with the migration. Found by hitting it.
    test "a user who has never been seeded gets nothing from the migration and everything from seed!" do
      assert_equal 0, @user.maker_filing_rules.count

      SeedPcbFilingRules.new.up

      assert_equal 0, @user.maker_filing_rules.count, "an unseeded user must not get a PARTIAL map"
      assert_equal "pcb", Maker::FilingRules.for(@user)["gtl"]
      # THE WHOLE TABLE IS BOTH HALVES OF THE SEED since stage 4, S4-2 — ROLE_BY_EXT plus
      # `Maker::FilingRules::BEYOND_ROLE_BY_EXT`, the keys the vocabulary itself cannot carry.
      assert_equal Maker::FileAttachment::ROLE_BY_EXT.size + Maker::FilingRules::BEYOND_ROLE_BY_EXT.size,
                   @user.maker_filing_rules.count
    end

    # THE USER WHO ALREADY ADDED `.drl` BY HAND at /settings/filing before this ran: their folder
    # survives and no duplicate row appears. ON CONFLICT DO NOTHING is not an upsert, and this is
    # what says the difference matters.
    #
    # THIS DOES NOT PIN `unique_by:`, AND SAYING SO IS THE POINT. Mutation-checked by dropping the
    # kwarg: the test stays GREEN, because `insert_all`'s bare form emits `ON CONFLICT DO NOTHING`
    # with no target and skips just the same (measured — the migration's own header carries the two
    # SQL statements). The reason to name the index is that it narrows WHICH collision is swallowed,
    # which no test here can demonstrate. A test whose failure this claim depends on would be a
    # guard that does not work; recording the boundary is the honest alternative.
    test "a user who already holds a pcb row keeps their folder and the migration does not raise" do
      seed_without_pcb!(@user)
      @user.maker_filing_rules.create!(ext: "drl", folder: "cnc")
      before = @user.maker_filing_rules.count

      SeedPcbFilingRules.new.up

      assert_equal "cnc", @user.maker_filing_rules.find_by!(ext: "drl").folder
      assert_equal before + SeedPcbFilingRules::PCB_EXTS.size - 1, @user.maker_filing_rules.reload.count
    end

    test "down removes the pcb rules and leaves the rest" do
      seed_without_pcb!(@user)
      SeedPcbFilingRules.new.up
      before = @user.maker_filing_rules.reload.count

      SeedPcbFilingRules.new.down

      assert_equal before - SeedPcbFilingRules::PCB_EXTS.size, @user.maker_filing_rules.reload.count
      assert_nil @user.maker_filing_rules.find_by(ext: "gtl")
      assert_equal "models", @user.maker_filing_rules.find_by!(ext: "stl").folder
    end

    # THE COPY, PINNED AGAINST THE MODEL. The migration names its own extension list and folder on
    # purpose (a data migration runs against code that has moved on), and this is the only thing
    # that would notice the copy drifting — the five `rederive_*_roles` migrations each carry the
    # identical pairing for the identical reason.
    # A ROLLBACK TAKES ONLY WHAT `up` COULD HAVE WRITTEN. The folder column is free-form, so a
    # maker can map any extension into pcb by hand -- `.stp` before this ran, `.xnc` after it, the
    # extension file_attachment.rb's own comment invites -- and `down` spelled as "every pcb row"
    # deleted both (the review probed it). Restricted to the pcb EXTENSIONS, it leaves them alone.
    test "down leaves a hand-made rule that files into pcb, and takes only the migration's own" do
      seed_without_pcb!(@user)
      @user.maker_filing_rules.create!(ext: "xnc", folder: "pcb")
      @user.maker_filing_rules.find_by!(ext: "stp").update!(folder: "pcb")
      SeedPcbFilingRules.new.up
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "gtl").folder

      SeedPcbFilingRules.new.down

      assert_nil @user.maker_filing_rules.find_by(ext: "gtl"), "the migration's own row is gone"
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "xnc").folder, "a hand-made rule survives"
      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "stp").folder, "an edited rule survives"
    end

    test "the migration's extension list is exactly the pcb role, and its folder is ROLE_FOLDERS'" do
      assert_equal Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, role| role == "pcb" }.keys.sort,
                   SeedPcbFilingRules::PCB_EXTS.sort
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.fetch("pcb"), SeedPcbFilingRules::FOLDER
    end

    # EACH USER'S MAP IS THEIR OWN — the migration loops over users, and a bug that wrote every row
    # against one user_id would still produce the right TOTAL count.
    test "the top-up reaches every seeded user separately" do
      other = User.create!(email: "pcb-seed-other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      seed_without_pcb!(@user)
      seed_without_pcb!(other)

      SeedPcbFilingRules.new.up

      assert_equal "pcb", @user.maker_filing_rules.find_by!(ext: "gtl").folder
      assert_equal "pcb", other.maker_filing_rules.find_by!(ext: "gtl").folder
    end
  end
end
