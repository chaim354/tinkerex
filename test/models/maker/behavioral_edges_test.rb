require "test_helper"

module Maker
  # Behavioral edge cases not covered by the per-model suites: tag-name normalization,
  # task ownership across kinds, and InventoryTransaction.apply!'s stale-item reload.
  class BehavioralEdgesTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "edges@example.com") }

    # ---- Tag normalization -------------------------------------------------
    test "tag name is normalized: trimmed and downcased on write" do
      tag = @user.maker_tags.create!(name: "  Printed PLA  ")
      assert_equal "printed pla", tag.name
    end

    test "normalization makes case/whitespace variants collide on the per-user unique index" do
      @user.maker_tags.create!(name: "resin")
      dup = @user.maker_tags.build(name: "  RESIN ")
      assert_not dup.valid?, "normalized duplicate should violate uniqueness"
      assert_includes dup.errors[:name], "has already been taken"
    end

    # ---- Task ownership across owner kinds ---------------------------------
    test "a task cannot be owned by another user's ITEM (not just project)" do
      other = User.create!(email: "other-task@example.com")
      foreign_item = other.maker_items.create!(title: "Theirs")
      task = @user.maker_tasks.build(title: "do", taskable: foreign_item)
      assert_not task.valid?
      assert_includes task.errors[:taskable_id], "must reference your own item"
    end

    test "a task CAN be owned by the user's own item" do
      mine = @user.maker_items.create!(title: "Mine")
      task = @user.maker_tasks.build(title: "do", taskable: mine)
      assert task.valid?, task.errors.full_messages.to_sentence
    end

    # ---- InventoryTransaction.apply! stale-item reload ---------------------
    test "apply! reloads a DISTINCT in-memory item instance so its balance is fresh" do
      # Two separate object identities for the same row: `item` (passed to apply!) is NOT
      # the locked instance loaded inside apply!, so apply! must reload `item` to surface
      # the new balance. (The adjust controller relies on this seam — it reloads too, but
      # the model contract should hold on its own.)
      item = @user.maker_inventory_items.create!(name: "bolt", quantity_cached: 0)
      stale = Maker::InventoryItem.find(item.id) # distinct object identity, balance 0

      Maker::InventoryTransaction.apply!(item: stale, user: @user, delta: 9, reason: "restocked")

      assert_equal 9, stale.quantity_cached, "apply! should have reloaded the passed-in item"
    end

    test "apply! returns the persisted ledger row with the right delta and reason" do
      item = @user.maker_inventory_items.create!(name: "bolt")
      txn = Maker::InventoryTransaction.apply!(item: item, user: @user, delta: -3, reason: "consumed",
                                               note: "used 3")
      assert txn.persisted?
      assert_equal(-3, txn.delta)
      assert_equal "consumed", txn.reason
      assert_equal "used 3", txn.note
    end
  end
end
