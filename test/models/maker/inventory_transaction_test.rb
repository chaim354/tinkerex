require "test_helper"

module Maker
  class InventoryTransactionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "txn@example.com")
      @item = @user.maker_inventory_items.create!(name: "M3 bolt", quantity_cached: 0)
    end

    test "creating a transaction increments the item's cached balance atomically" do
      @item.transactions.create!(user: @user, delta: 25, reason: "initial")
      assert_equal 25, @item.reload.quantity_cached
      @item.transactions.create!(user: @user, delta: -4, reason: "consumed")
      assert_equal 21, @item.reload.quantity_cached
    end

    test "delta is required" do
      assert_not @item.transactions.build(user: @user, delta: nil).valid?
    end

    test "reason must be in the allowed set" do
      assert_not @item.transactions.build(user: @user, delta: 1, reason: "bogus").valid?
    end

    test "the ledger is immutable (no updated_at column)" do
      assert_not Maker::InventoryTransaction.column_names.include?("updated_at")
    end

    test "Apply helper inserts the row and updates the balance in one transaction" do
      txn = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      assert txn.persisted?
      assert_equal 7, @item.reload.quantity_cached
    end

    test "a failed balance update rolls back the ledger insert" do
      # An out-of-range reason fails validation BEFORE any write, so the count is unchanged.
      assert_no_difference -> { Maker::InventoryTransaction.count } do
        assert_raises(ActiveRecord::RecordInvalid) do
          Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 1, reason: "bogus")
        end
      end
      assert_equal 0, @item.reload.quantity_cached
    end

    test "project_id is a soft reference (optional, nullable)" do
      txn = @item.transactions.create!(user: @user, delta: -1, reason: "consumed", project_id: nil)
      assert_nil txn.project_id
    end

    test "concurrent-style sequential applies sum correctly" do
      10.times { Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 3, reason: "restocked") }
      assert_equal 30, @item.reload.quantity_cached
    end
  end
end
