require "test_helper"

module Maker
  class BomLineTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "line@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
      @bom = @project.boms.create!(user: @user)
      @inv = @user.maker_inventory_items.create!(name: "M3 bolt", quantity_cached: 40)
      @sup = @user.maker_suppliers.create!(name: "Digikey")
    end

    test "an inventory-item line is valid" do
      line = @bom.lines.build(user: @user, inventory_item_id: @inv.id, quantity: 4, reference: "B1")
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a design-file line (node_id) is valid" do
      line = @bom.lines.build(user: @user, node_id: "node-step", quantity: 1)
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a free-text part line is valid (with optional supplier)" do
      line = @bom.lines.build(user: @user, part_name: "Generic LED", supplier_id: @sup.id, quantity: 10)
      assert line.valid?, line.errors.full_messages.to_sentence
    end

    test "a line with NO target is invalid" do
      line = @bom.lines.build(user: @user, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:base], "a line must link exactly one of: inventory item, design file, or free-text part"
    end

    test "a line with TWO targets is invalid" do
      line = @bom.lines.build(user: @user, inventory_item_id: @inv.id, node_id: "node-x", quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:base], "a line must link exactly one of: inventory item, design file, or free-text part"
    end

    test "supplier_id alone (no part_name) does not count as a target" do
      line = @bom.lines.build(user: @user, supplier_id: @sup.id, quantity: 1)
      assert_not line.valid?
    end

    test "quantity must be positive" do
      line = @bom.lines.build(user: @user, node_id: "n", quantity: 0)
      assert_not line.valid?
    end

    test "the inventory item must belong to the same user" do
      other = User.create!(email: "o@example.com")
      foreign = other.maker_inventory_items.create!(name: "Theirs")
      line = @bom.lines.build(user: @user, inventory_item_id: foreign.id, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:inventory_item_id], "must reference your own inventory item"
    end

    test "the supplier must belong to the same user" do
      other = User.create!(email: "o2@example.com")
      foreign = other.maker_suppliers.create!(name: "Theirs")
      line = @bom.lines.build(user: @user, part_name: "x", supplier_id: foreign.id, quantity: 1)
      assert_not line.valid?
      assert_includes line.errors[:supplier_id], "must reference your own supplier"
    end

    test "target_kind reports which target shape a line uses" do
      assert_equal :inventory_item, @bom.lines.build(inventory_item_id: @inv.id).target_kind
      assert_equal :design_file,    @bom.lines.build(node_id: "n").target_kind
      assert_equal :free_text,      @bom.lines.build(part_name: "x").target_kind
      assert_nil @bom.lines.build.target_kind
    end

    # A STOCK LINE IS COUNTED IN ITS ITEM'S UNIT, READ FROM THE ITEM (audit F-S16-2). Consume takes
    # `quantity` off the item's balance, so the unit a line reports is the item's. It used to be a
    # copy written once, and only the web door wrote it: a v1 or desktop create kept the unit it
    # sent, and an edit to the item's unit after the line existed left every line on the old one.
    # The edit is driven here because no rule at create time could ever reach it.
    test "a stock line reports its item's unit, and follows an edit to it" do
      kg = @user.maker_inventory_items.create!(name: "PETG", unit: "kg")
      line = @bom.lines.create!(user: @user, inventory_item: kg, quantity: 2, unit: "each")
      assert_equal "kg", line.unit

      kg.update!(unit: "g")
      assert_equal "g", line.reload.unit
    end

    test "a file or a text line keeps the unit it was given" do
      assert_equal "m",    @bom.lines.create!(user: @user, part_name: "Wire", quantity: 3, unit: "m").reload.unit
      assert_equal "pack", @bom.lines.create!(user: @user, node_id: "n", quantity: 1, unit: "pack").reload.unit
    end

    # THE COLUMN STILL HOLDS A VALID UNIT ON A STOCK LINE, although nothing reads it there.
    # `validates :unit` asks the reader, which answers with the item's unit, so a stray value sent
    # for a stock line would pass and be stored. The column is read again the moment the line stops
    # being a stock line, and a retarget (a v1 PATCH to a part name, which sends no unit) is a save
    # like any other: a stray unit there refuses it.
    test "a stock line stores its item's unit, so a line retargeted off the item keeps a valid one" do
      kg = @user.maker_inventory_items.create!(name: "PETG", unit: "kg")
      line = @bom.lines.create!(user: @user, inventory_item: kg, quantity: 2, unit: "furlong")

      line.update!(inventory_item_id: nil, part_name: "PETG offcut")
      assert_equal :free_text, line.target_kind
      assert_equal "kg", line.reload.unit
    end

    test "resolved_target returns the linked inventory item with its balance" do
      line = @bom.lines.create!(user: @user, inventory_item_id: @inv.id, quantity: 4)
      resolved = line.resolved_target
      assert_equal :inventory_item, resolved[:kind]
      assert_equal @inv.id, resolved[:inventory_item][:id]
      assert_equal 40, resolved[:inventory_item][:quantity_cached]
    end

    test "resolved_target for a free-text line includes the supplier name" do
      line = @bom.lines.create!(user: @user, part_name: "Generic LED", supplier_id: @sup.id, quantity: 10)
      resolved = line.resolved_target
      assert_equal :free_text, resolved[:kind]
      assert_equal "Generic LED", resolved[:part_name]
      assert_equal "Digikey", resolved[:supplier_name]
    end

    test "destroying the bom destroys its lines" do
      @bom.lines.create!(user: @user, node_id: "n", quantity: 1)
      assert_difference -> { Maker::BomLine.count }, -1 do
        @bom.destroy
      end
    end
  end
end
