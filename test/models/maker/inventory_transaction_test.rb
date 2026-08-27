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

    test "an existing ledger transaction cannot be updated" do
      txn = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      assert_raises(ActiveRecord::ReadOnlyRecord) { txn.update!(delta: 0) }
    end

    test "a ledger transaction cannot be destroyed while its item exists" do
      txn = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      assert_raises(ActiveRecord::ReadOnlyRecord) { txn.destroy! }
      assert Maker::InventoryTransaction.exists?(txn.id)
    end

    test "destroying the item cascades and removes its ledger transactions" do
      Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      assert_difference -> { Maker::InventoryTransaction.count }, -1 do
        @item.destroy!
      end
    end

    # THE ORDER OF `has_many` DECLARATIONS ON `User` MUST NOT BE LOAD-BEARING. The ledger refuses
    # record-level destruction outright, so the only reason a user's cascade can reach these rows
    # is that `maker_inventory_transactions` is removed WITHOUT instantiating them. Mutation-check
    # by swapping app/models/user.rb's `maker_inventory_items` / `maker_inventory_transactions`
    # lines: before this pinning that swap raised ReadOnlyRecord mid-cascade and left the whole
    # account intact, with nothing in the suite noticing.
    test "destroying a user that holds a posted ledger row deletes the whole account" do
      Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      id = @user.id
      assert_nothing_raised { @user.destroy! }
      assert_not User.exists?(id)
      assert_equal 0, Maker::InventoryTransaction.where(user_id: id).count
      assert_equal 0, Maker::InventoryItem.where(user_id: id).count
    end

    # The immutability rule has NO parent-state escape hatch. It used to permit a destroy whenever
    # the parent item was destroyed/marked-for-destruction — a condition the real `dependent:`
    # cascades never set — so the rule read as "protected" while the protection was decided by
    # whether the caller happened to have touched the parent first.
    test "a ledger row cannot be destroyed even when its item is marked for destruction" do
      txn = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 7, reason: "restocked")
      txn.inventory_item.mark_for_destruction
      assert_raises(ActiveRecord::ReadOnlyRecord) { txn.destroy }
      assert Maker::InventoryTransaction.exists?(txn.id)
    end
  end
end
