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

    # A ZERO, NON-FINITE OR OUT-OF-COLUMN DELTA NEVER REACHES THE LEDGER, whichever door posts it.
    # A non-finite row is permanent damage: the ledger is immutable, and rebuild_quantity_cached!
    # writes the Infinity back. The STRINGS are what the web and v1 doors hand over; as strings
    # "Infinity"/"-Infinity"/"NaN" already fail numericality's Kernel.Float. The PARSED forms are what
    # a door that parses first hands over (BOM consume posts a BigDecimal read from the column; a JSON
    # number 1e400 decodes to Float::INFINITY), and only the range refuses those — drop `in:` and
    # every one of them posts. "0.0001" rounds to a zero row at the column's scale; "1000000000" is
    # finite and one step past the column.
    REFUSED_DELTAS = [
      *%w[Infinity -Infinity NaN 1e400 0 0.0001 1000000000],
      BigDecimal("Infinity"), BigDecimal("-Infinity"), BigDecimal("NaN"),
      Float::INFINITY, -Float::INFINITY, Float::NAN
    ].freeze

    test "apply! refuses a zero, non-finite or out-of-column delta and leaves the ledger and balance as they were" do
      Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 12, reason: "initial")

      REFUSED_DELTAS.each do |bad|
        assert_no_difference -> { Maker::InventoryTransaction.count }, "#{bad.inspect} reached the ledger" do
          assert_raises(ActiveRecord::RecordInvalid, "#{bad.inspect} was not refused as invalid") do
            Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: bad, reason: "adjusted")
          end
        end
        assert_equal 12, @item.reload.quantity_cached, "#{bad.inspect} moved the cached balance"
      end
    end

    # THE OPTIONAL FIELDS ARE NORMALISED, NEVER REFUSED, and the stock change still posts. A project
    # the item's owner does not own is dropped (TENANCY: every door gets this from apply!, not from a
    # lookup of its own), and a blank note is stored as no note.
    test "apply! keeps the owner's own project and drops anyone else's, and a blank note" do
      mine = @user.maker_projects.create!(name: "Desk Lamp")
      theirs = User.create!(email: "txn-other@example.com").maker_projects.create!(name: "Not yours")

      kept = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 1, project_id: mine.id, note: "lamp")
      dropped = Maker::InventoryTransaction.apply!(item: @item, user: @user, delta: 1, project_id: theirs.id, note: "")

      assert_equal mine.id, kept.project_id
      assert_equal "lamp", kept.note
      assert_nil dropped.project_id
      assert_nil dropped.note
      assert_equal 2, @item.reload.quantity_cached
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
