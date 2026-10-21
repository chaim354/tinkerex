require "test_helper"

module Maker
  # A SHELF IS A FOLDER INSIDE EVERY PROJECT (2026-10-20), so its name answers the same question
  # Maker::FilingRule#folder answers, through the SAME check (Maker::FilingRule.plain_segment?).
  # The model catalog's shelves are Maker::ModelIntake::SHELVES and are tested beside it.
  class ShelfTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shelf-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def other_user!
      User.create!(email: "shelf-o-#{SecureRandom.hex(4)}@example.com",
                   confirmed_at: Time.current, omniauth_signup: true)
    end

    test "the name is normalised the way a filing rule's folder is" do
      assert_equal "laser", @user.maker_shelves.create!(name: " Laser ").name
    end

    test "a reserved name, a slash and a blank are refused" do
      { ".trash" => "isn't allowed", "a/b" => "isn't allowed", "" => "can't be blank" }.each do |bad, msg|
        shelf = @user.maker_shelves.new(name: bad)
        assert_not shelf.valid?, "#{bad.inspect} should be refused"
        assert_includes shelf.errors[:name].join, msg
      end
    end

    test "a name is unique per user, and another user may hold the same one" do
      @user.maker_shelves.create!(name: "laser")
      assert_not @user.maker_shelves.new(name: "Laser").valid?
      assert other_user!.maker_shelves.new(name: "laser").valid?
    end

    test "the default view is automatic or one of the project views" do
      Maker::Project::VIEWS.each do |view|
        assert @user.maker_shelves.new(name: "s-#{view}", default_view: view).valid?, view
      end
      automatic = @user.maker_shelves.create!(name: "auto", default_view: "")
      assert_nil automatic.default_view
      grid = @user.maker_shelves.new(name: "grid", default_view: "grid")
      assert_not grid.valid?
      assert_predicate grid.errors[:default_view], :any?
    end

    # §14d: a `*_belongs_to_user` check guarded on presence, safe because ShelfGroup nullifies.
    test "another user's group is refused" do
      theirs = other_user!.maker_shelf_groups.create!(name: "Theirs")
      shelf = @user.maker_shelves.new(name: "laser", shelf_group_id: theirs.id)
      assert_not shelf.valid?
      assert_includes shelf.errors[:shelf_group_id], "isn't one of your groups"

      mine = @user.maker_shelf_groups.create!(name: "Mine")
      assert @user.maker_shelves.new(name: "laser", shelf_group: mine).valid?
    end

    test "only other is the fallback" do
      assert_predicate @user.maker_shelves.new(name: "other"), :fallback?
      assert_not_predicate @user.maker_shelves.new(name: "laser"), :fallback?
    end
  end
end
