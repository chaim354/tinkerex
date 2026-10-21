require "test_helper"

module Maker
  # Stage 3, S3-1: the per-user extension map's seed-then-read service. `Maker::ProjectFolders
  # .folder_for(user, name)`'s own tests (project_folders_test.rb) cover the ext-lookup half built
  # on top of this; this file is about seeding and re-reading the map itself.
  class FilingRulesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "filing-rules-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # THE COUNT IS THE VOCABULARY PLUS THE KEYS THE VOCABULARY CANNOT CARRY (stage 4, S4-2) — the
    # name says both halves because a name reading "exactly ROLE_BY_EXT.size" stopped being true
    # the moment BEYOND_ROLE_BY_EXT existed.
    test "the first read seeds one row per ROLE_BY_EXT key plus every key beyond it" do
      assert_empty @user.maker_filing_rules

      Maker::FilingRules.for(@user)

      assert_equal Maker::FileAttachment::ROLE_BY_EXT.size + Maker::FilingRules::BEYOND_ROLE_BY_EXT.size,
                   @user.maker_filing_rules.count
    end

    # THE KEYS THE VOCABULARY CANNOT CARRY ARE SEEDED BESIDE IT, NOT INSTEAD OF IT (stage 4, S4-2).
    # A user seeded today gets a `pcb` destination for their KiCad files; a user seeded before this
    # gets one from the migration. `Maker::FilingRules.seed!`'s `exists?` guard is untouched — the
    # top-up is a migration, which runs once, because the Shelves page promises a REMOVED rule
    # files into `other` and a per-read fill-in would resurrect it.
    test "a KiCad schematic and board have a destination the vocabulary could never give them" do
      map = Maker::FilingRules.for(@user)
      assert_equal "pcb", map["kicad_sch"]
      assert_equal "pcb", map["kicad_pcb"]
      assert_equal "pcb", Maker::ProjectFolders.folder_for(@user, "board.kicad_pcb")
      assert_equal "other", Maker::FileAttachment.role_for("board.kicad_pcb"),
                   "the ROLE is untouched — EXT_RE still refuses these two"
    end

    # EVERY EXTRA KEY IS A LEGAL ROW. The seed writes with insert_all, which runs no validation,
    # so a key the settings form would itself refuse could be seeded and then be uneditable.
    test "every extra seed key passes the model's own validation" do
      Maker::FilingRules::BEYOND_ROLE_BY_EXT.each do |ext, folder|
        rule = @user.maker_filing_rules.new(ext:, folder:)
        assert rule.valid?, "#{ext} => #{folder}: #{rule.errors.full_messages}"
      end
    end

    # IDEMPOTENT ON THE HAPPY PATH -- the `exists?` guard means the second call's insert_all never
    # runs, so there is no RecordNotUnique to rescue and no duplicate row to produce.
    test "a second read seeds nothing" do
      Maker::FilingRules.for(@user)
      first_count = @user.maker_filing_rules.count

      Maker::FilingRules.for(@user)

      assert_equal first_count, @user.maker_filing_rules.reload.count
    end

    test "an edit survives a re-read" do
      Maker::FilingRules.for(@user)
      rule = @user.maker_filing_rules.find_by!(ext: "stl")
      rule.update!(folder: "prints")

      assert_equal "prints", Maker::FilingRules.for(@user)["stl"]
    end

    # THE SEED'S VALUES COME FROM ProjectFolders::ROLE_FOLDERS OVER FileAttachment::ROLE_BY_EXT --
    # a few spot checks rather than reproducing the whole map, since project_folders_test.rb
    # already pins the role->folder decisions this derives from.
    test "the seed maps each extension through its role to ROLE_FOLDERS' folder" do
      map = Maker::FilingRules.for(@user)

      assert_equal "models", map["stl"]
      assert_equal "design", map["svg"]
      assert_equal "docs", map["pdf"]
      assert_equal "docs", map["md"]
      assert_equal "code", map["py"]
      assert_equal "cnc", map["gcode"]
    end

    # `exists?` GUARDS THE WHOLE BATCH, NOT A PER-ROW FILL-IN -- a user who somehow already holds
    # ONE row (in practice unreachable through the UI, since the add form only renders on a page
    # that has already called seed!, but reachable through a direct POST or the console) never gets
    # the other ROLE_BY_EXT.size - 1 seeded, and their own row is never overwritten. Documented
    # rather than assumed: the alternative (fill in only the missing extensions) is a real design
    # this file's own header rejects, because it would let a reseed silently overrule an edit the
    # instant that edit happened to be the user's very first row.
    test "seed! never touches a user who already holds any row, even a non-default one" do
      @user.maker_filing_rules.create!(ext: "stl", folder: "custom")

      Maker::FilingRules.seed!(@user)

      assert_equal 1, @user.maker_filing_rules.count
      assert_equal "custom", @user.maker_filing_rules.find_by!(ext: "stl").folder
    end

    test "each user's map is their own" do
      Maker::FilingRules.for(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")

      other = User.create!(email: "filing-rules-other-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)

      assert_equal "models", Maker::FilingRules.for(other)["stl"]
    end
  end
end
