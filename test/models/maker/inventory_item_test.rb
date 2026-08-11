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

    # THE UNLOCK IS THE ASSERTION THAT CARRIES THE WEIGHT, and it is asserted FIRST so a regression
    # reports the harm rather than a missing string. Nullifying the pointer alone does not unlock
    # the row: `exactly_one_target` then sees no target, so the line is refused on every save — the
    # same permanent lock, wearing a different message.
    test "destroying an item leaves its BOM lines still editable" do
      project = @user.maker_projects.create!(name: "Lamp")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4)
      item.destroy!

      line.reload.notes = "any hardware store"
      assert line.save, line.errors.full_messages.to_sentence
      assert_equal "any hardware store", line.reload.notes
    end

    test "destroying an item carries its name onto the line as a free-text part" do
      project = @user.maker_projects.create!(name: "Lamp1b")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4, reference: "B1")
      item.destroy!

      line.reload
      assert_nil line.inventory_item_id
      assert_equal "M3 bolt", line.part_name
      assert_equal :free_text, line.target_kind
      assert_equal 4, line.quantity
      assert_equal "B1", line.reference
    end

    test "destroying an item keeps its BOM lines rather than deleting them" do
      project = @user.maker_projects.create!(name: "Lamp2")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4)
      assert_no_difference -> { Maker::BomLine.count } do
        item.destroy!
      end
    end

    # A line that already has another target keeps it; only a line that would be left with nothing
    # is given the item's name. Reaching this state needs update_columns because the two-target
    # shape the guard protects against is one `exactly_one_target` refuses to create.
    test "a BOM line that already has its own target is not renamed" do
      project = @user.maker_projects.create!(name: "Lamp3")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      line = bom.lines.create!(user: @user, node_id: "node-step", quantity: 1)
      line.update_columns(inventory_item_id: item.id)
      item.destroy!

      line.reload
      assert_nil line.part_name
      assert_equal :design_file, line.target_kind
    end

    test "destroying an item still deletes its ledger rows" do
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      item.transactions.create!(user: @user, delta: 5, reason: "initial")
      assert_difference -> { Maker::InventoryTransaction.count }, -1 do
        item.destroy!
      end
    end

    # The rename half WRITES this user's item name into a row, so it is scoped to this user while
    # the plain nullifies on Supplier/Location are not — clearing a pointer can only ever repair an
    # illegal reference, but copying a name into someone else's row would disclose it. The illegal
    # row has to be PLANTED with update_columns: `inventory_item_belongs_to_user` refuses to create
    # one, so a test built only from valid rows would pass with the scope removed and prove nothing.
    test "destroying an item never writes its name into another user's BOM line" do
      other = User.create!(email: "other-inv@example.com")
      their_bom = other.maker_projects.create!(name: "Theirs").boms.create!(user: other)
      their_line = their_bom.lines.create!(user: other, node_id: "n", quantity: 1)

      mine = @user.maker_inventory_items.create!(name: "Secret prototype part")
      their_line.update_columns(inventory_item_id: mine.id, node_id: nil)
      mine.destroy!

      assert_nil their_line.reload.part_name, "another user's row must not receive my item's name"
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
