require "test_helper"

module Maker
  class LocationTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "loc@example.com") }

    test "valid with a name" do
      assert @user.maker_locations.build(name: "Shelf A").valid?
    end

    test "name is required" do
      assert_not @user.maker_locations.build(name: nil).valid?
    end

    test "a location can nest under a parent bin" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      bin = @user.maker_locations.create!(name: "Bin 1", parent: shelf)
      assert_equal shelf, bin.parent
      assert_equal [ "Bin 1" ], shelf.children.pluck(:name)
    end

    test "the parent must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_locations.create!(name: "Theirs")
      bin = @user.maker_locations.build(name: "Bin", parent_id: foreign.id)
      assert_not bin.valid?
      assert_includes bin.errors[:parent_id], "must reference your own location"
    end

    test "destroying a parent nullifies its children's parent_id (children survive)" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      bin = @user.maker_locations.create!(name: "Bin 1", parent: shelf)
      shelf.destroy
      assert Maker::Location.exists?(bin.id)
      assert_nil bin.reload.parent_id
    end

    # The unlock, not the nil, is the point — see the equivalent test in supplier_test.rb.
    test "destroying a location leaves the items that sat there still editable" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", location: shelf)
      shelf.destroy!

      item.reload.min_quantity = 25
      assert item.save, item.errors.full_messages.to_sentence
      assert_equal 25, item.reload.min_quantity
    end

    test "destroying a location nullifies its inventory items' location_id" do
      shelf = @user.maker_locations.create!(name: "Shelf A")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", location: shelf)
      shelf.destroy!
      assert_nil item.reload.location_id
      assert Maker::InventoryItem.exists?(item.id), "the item itself must survive"
    end

    test "scoped to the user via the association" do
      @user.maker_locations.create!(name: "mine")
      other = User.create!(email: "o2@example.com")
      other.maker_locations.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_locations.pluck(:name)
    end
  end
end
