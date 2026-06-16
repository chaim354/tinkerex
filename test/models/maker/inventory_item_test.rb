require "test_helper"

module Maker
  class InventoryItemTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "inv@example.com") }

    test "valid with a name" do
      assert @user.maker_inventory_items.build(name: "M3x10 bolt").valid?
    end

    test "name is required" do
      assert_not @user.maker_inventory_items.build(name: nil).valid?
    end

    test "unit must be in the allowed set" do
      assert_not @user.maker_inventory_items.build(name: "x", unit: "furlong").valid?
    end

    test "defaults unit to each and quantity_cached to 0" do
      item = @user.maker_inventory_items.create!(name: "x")
      assert_equal "each", item.unit
      assert_equal 0, item.quantity_cached
      assert_equal 0, item.min_quantity
    end

    test "location must belong to the same user" do
      other = User.create!(email: "o@example.com")
      loc = other.maker_locations.create!(name: "Theirs")
      item = @user.maker_inventory_items.build(name: "x", location_id: loc.id)
      assert_not item.valid?
      assert_includes item.errors[:location_id], "must reference your own location"
    end

    test "supplier must belong to the same user" do
      other = User.create!(email: "o2@example.com")
      sup = other.maker_suppliers.create!(name: "Theirs")
      item = @user.maker_inventory_items.build(name: "x", supplier_id: sup.id)
      assert_not item.valid?
      assert_includes item.errors[:supplier_id], "must reference your own supplier"
    end

    test "low_stock scope returns items at or below min_quantity" do
      low  = @user.maker_inventory_items.create!(name: "low",  min_quantity: 10, quantity_cached: 3)
      ok   = @user.maker_inventory_items.create!(name: "ok",   min_quantity: 10, quantity_cached: 50)
      edge = @user.maker_inventory_items.create!(name: "edge", min_quantity: 10, quantity_cached: 10)
      names = @user.maker_inventory_items.low_stock.pluck(:name)
      assert_includes names, "low"
      assert_includes names, "edge"
      assert_not_includes names, "ok"
    end

    test "rebuild_quantity_cached! recomputes from the ledger" do
      item = @user.maker_inventory_items.create!(name: "x", quantity_cached: 999)
      item.transactions.create!(user: @user, delta: 5, reason: "initial")
      item.transactions.create!(user: @user, delta: -2, reason: "consumed")
      item.update_column(:quantity_cached, 999) # simulate drift
      assert_equal 3, item.rebuild_quantity_cached!
      assert_equal 3, item.reload.quantity_cached
    end
  end
end
