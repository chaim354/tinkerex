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

    # THE UNIT GOES WITH THE NAME (audit F-S16-2). A stock line reads its unit from its item, so
    # once the pointer is dropped the line has only its own column to answer from — and the column
    # is not kept in step with the item. The item's unit is edited after the line exists so that
    # the column is stale when the item goes: without the copy, "2 g" of PETG would come back as
    # "2 kg", the unit the line was last saved in.
    test "destroying an item carries its unit onto the converted line" do
      project = @user.maker_projects.create!(name: "Lamp1f")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "PETG", unit: "kg")
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 2)
      item.update!(unit: "g")
      item.destroy!

      line.reload
      assert_equal :free_text, line.target_kind
      assert_equal "PETG", line.part_name
      assert_equal "g", line.unit
    end

    # `maker_bom_lines` has its own `supplier_id` and `resolved_target`'s free-text shape already
    # renders `supplier_id`/`supplier_name`, so a conversion that left it nil dropped half of what
    # makes a line orderable into a column that was sitting there waiting for it. The rollup
    # assertion is the one that matters — it is the shape a caller actually reads.
    test "destroying an item carries its supplier onto the converted line" do
      project = @user.maker_projects.create!(name: "Lamp1c")
      bom = project.boms.create!(user: @user)
      sup = @user.maker_suppliers.create!(name: "Digikey")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: sup)
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4)
      item.destroy!

      line.reload
      assert_equal sup.id, line.supplier_id
      assert_equal({ kind: :free_text, part_name: "M3 bolt", supplier_id: sup.id,
                     supplier_name: "Digikey" }, line.resolved_target)
    end

    # Same principle as not overwriting a `part_name` that was already set: a supplier named on the
    # line is the user's own annotation about this line, the item's is only a fallback.
    test "destroying an item does not overwrite a supplier the line already named" do
      project = @user.maker_projects.create!(name: "Lamp1d")
      bom = project.boms.create!(user: @user)
      item_sup = @user.maker_suppliers.create!(name: "Digikey")
      line_sup = @user.maker_suppliers.create!(name: "Local hardware store")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: item_sup)
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4,
                               supplier_id: line_sup.id)
      item.destroy!

      assert_equal line_sup.id, line.reload.supplier_id
    end

    # THE CARRY MUST NOT RE-CREATE THE BUG IT IS PART OF FIXING. An item stranded before this fix
    # can itself hold a dangling supplier_id — nothing backfilled those — and copying that onto the
    # line would leave `supplier_belongs_to_user` failing on every save of the row this method just
    # rescued. The unlock is asserted first, because that is the harm.
    test "an item whose own supplier reference is dangling does not pass the lock on" do
      project = @user.maker_projects.create!(name: "Lamp1e")
      bom = project.boms.create!(user: @user)
      item = @user.maker_inventory_items.create!(name: "M3 bolt")
      item.update_columns(supplier_id: 999_999)
      line = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 4)
      item.destroy!

      line.reload.notes = "any hardware store"
      assert line.save, line.errors.full_messages.to_sentence
      assert_nil line.reload.supplier_id, "a dangling supplier must not be copied onto the line"
      assert_equal "M3 bolt", line.part_name
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
    # is converted. Reaching this state needs update_columns because the two-target shape the guard
    # protects against is one `exactly_one_target` refuses to create. The supplier is held back for
    # the same reason as the name: this line is not becoming a free-text part, and `resolved_target`
    # renders no supplier for a design-file line, so the value would be invisible as well as wrong.
    #
    # THE ORDINARY LINE BESIDE IT IS LOAD-BEARING, not scenery. Without it nothing is convertible,
    # `converting.any?` is false, and the whole write block is skipped — so a mutation that wrote
    # the supplier to every line the item touched rather than only the converted ones stayed GREEN.
    # Caught by mutation-checking, not by reading.
    test "a BOM line that already has its own target is not converted" do
      project = @user.maker_projects.create!(name: "Lamp3")
      bom = project.boms.create!(user: @user)
      sup = @user.maker_suppliers.create!(name: "Digikey")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: sup)
      line = bom.lines.create!(user: @user, node_id: "node-step", quantity: 1)
      line.update_columns(inventory_item_id: item.id)
      convertible = bom.lines.create!(user: @user, inventory_item_id: item.id, quantity: 2)
      item.destroy!

      line.reload
      assert_nil line.part_name
      assert_nil line.supplier_id, "a line keeping its own target is not being converted"
      assert_equal :design_file, line.target_kind
      assert_equal sup.id, convertible.reload.supplier_id, "the convertible sibling still converts"
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
