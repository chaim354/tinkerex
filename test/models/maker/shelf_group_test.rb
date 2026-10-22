require "test_helper"

module Maker
  # A shelf group is display text over a run of project-page panels (2026-10-20). Deleting one
  # leaves its shelves standing, ungrouped.
  class ShelfGroupTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "shg-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    test "the name is squished" do
      assert_equal "Fab rication", @user.maker_shelf_groups.create!(name: "  Fab   rication ").name
    end

    test "a blank name and a name over the limit are refused" do
      assert_not @user.maker_shelf_groups.new(name: "   ").valid?
      assert @user.maker_shelf_groups.new(name: "x" * Maker::ShelfGroup::NAME_MAX).valid?
      assert_not @user.maker_shelf_groups.new(name: "x" * (Maker::ShelfGroup::NAME_MAX + 1)).valid?
    end

    test "a name is unique per user" do
      @user.maker_shelf_groups.create!(name: "Fabrication")
      assert_not @user.maker_shelf_groups.new(name: "Fabrication").valid?
    end

    test "destroying a group ungroups its shelves and keeps them" do
      group = @user.maker_shelf_groups.create!(name: "Fabrication")
      laser = @user.maker_shelves.create!(name: "laser", shelf_group: group)
      cnc = @user.maker_shelves.create!(name: "cnc", shelf_group: group)

      group.destroy!

      assert_equal [ nil, nil ], [ laser.reload.shelf_group_id, cnc.reload.shelf_group_id ]
      # And the rows stay editable: a dangling id would lock them (§14d).
      assert laser.update(default_view: "list")
    end
  end
end
