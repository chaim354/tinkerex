require "test_helper"

module Maker
  class ShelvesTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shv-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # ROLE_FOLDERS.values.uniq is the seed's folder order and ends in `other` (measured
    # 2026-10-20: cnc laser design models cad code docs images archives pcb other).
    test "a new user gets one shelf per seeded folder, in the seed's order" do
      Maker::Shelves.ensure!(@user)
      assert_equal Maker::ProjectFolders::ROLE_FOLDERS.values.uniq,
                   @user.maker_shelves.order(:position).pluck(:name)
    end

    test "other gets a shelf though no rule names it" do
      Maker::FilingRules.seed!(@user)
      assert_not @user.maker_filing_rules.exists?(folder: "other")
      Maker::Shelves.ensure!(@user)
      assert @user.maker_shelves.exists?(name: "other")
    end

    test "a folder a rule names gains a shelf, after the seeded ones" do
      Maker::Shelves.ensure!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      Maker::Shelves.ensure!(@user)
      last = @user.maker_shelves.order(:position).last
      assert_equal "prints", last.name
    end

    test "ensure! is idempotent" do
      Maker::Shelves.ensure!(@user)
      assert_no_difference -> { @user.maker_shelves.count } do
        Maker::Shelves.ensure!(@user)
      end
    end

    test "by_name answers view and group per folder name and writes nothing" do
      group = @user.maker_shelf_groups.create!(name: "Fabrication", position: 2)
      @user.maker_shelves.create!(name: "laser", default_view: "list", shelf_group: group)
      @user.maker_shelves.create!(name: "docs")
      map = assert_no_difference(-> { @user.maker_shelves.count }) { Maker::Shelves.by_name(@user) }
      assert_equal Maker::Shelves::Entry.new(view: "list", group: "Fabrication", group_position: 2), map["laser"]
      assert_equal Maker::Shelves::Entry.new(view: nil, group: nil, group_position: nil), map["docs"]
    end

    # REMOVING EVERY SHELF BUT `other` IS A CHOICE THAT HOLDS (found in review): with no rules
    # left, Maker::FilingRules.seed! used to read the user as never seeded and bring every
    # default back on the next read.
    test "a user left with only other is not reseeded" do
      Maker::Shelves.ensure!(@user)
      @user.maker_shelves.where.not(name: "other").find_each do |shelf|
        @user.maker_filing_rules.where(folder: shelf.name).delete_all
        shelf.destroy!
      end
      Maker::Shelves.ensure!(@user)
      assert_equal [ "other" ], @user.maker_shelves.pluck(:name)
      assert_equal({}, Maker::FilingRules.for(@user))
    end

    test "count_for counts what the page will show, without writing" do
      assert_no_difference -> { @user.maker_shelves.count } do
        assert_equal Maker::ProjectFolders::ROLE_FOLDERS.values.uniq.size, Maker::Shelves.count_for(@user)
      end
      Maker::FilingRules.seed!(@user)
      @user.maker_filing_rules.find_by!(ext: "stl").update!(folder: "prints")
      expected = (@user.maker_filing_rules.distinct.pluck(:folder) | [ "other" ]).size
      assert_equal expected, Maker::Shelves.count_for(@user)
      Maker::Shelves.ensure!(@user)
      assert_equal @user.maker_shelves.count, Maker::Shelves.count_for(@user)
    end
  end
end
