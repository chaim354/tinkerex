require "test_helper"

module Maker
  class SupplierTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "sup@example.com") }

    test "valid with a name" do
      assert @user.maker_suppliers.build(name: "McMaster-Carr").valid?
    end

    test "name is required" do
      assert_not @user.maker_suppliers.build(name: nil).valid?
    end

    test "stores url and notes" do
      s = @user.maker_suppliers.create!(name: "Digikey", url: "https://digikey.com", notes: "fast")
      assert_equal "https://digikey.com", s.url
      assert_equal "fast", s.notes
    end

    test "scoped to the user via the association" do
      @user.maker_suppliers.create!(name: "mine")
      other = User.create!(email: "o@example.com")
      other.maker_suppliers.create!(name: "theirs")
      assert_equal [ "mine" ], @user.maker_suppliers.pluck(:name)
    end

    # THE UNLOCK IS THE ASSERTION THAT CARRIES THE WEIGHT. A test that only checks supplier_id
    # went nil would pass against a fix that left the row unsavable for some other reason, and
    # "unsavable forever" is the actual harm: `supplier_belongs_to_user` runs on EVERY save while
    # the id is present, so a dangling one refuses edits to unrelated fields.
    test "destroying a supplier leaves its inventory items still editable" do
      sup = @user.maker_suppliers.create!(name: "Digikey")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: sup, min_quantity: 5)
      sup.destroy!

      item.reload.name = "M3x10 bolt"
      assert item.save, item.errors.full_messages.to_sentence
      assert_equal "M3x10 bolt", item.reload.name
    end

    test "destroying a supplier nullifies its inventory items' supplier_id" do
      sup = @user.maker_suppliers.create!(name: "Digikey")
      item = @user.maker_inventory_items.create!(name: "M3 bolt", supplier: sup)
      sup.destroy!
      assert_nil item.reload.supplier_id
      assert Maker::InventoryItem.exists?(item.id), "the item itself must survive"
    end

    test "destroying a supplier leaves its BOM lines still editable" do
      sup = @user.maker_suppliers.create!(name: "Digikey")
      project = @user.maker_projects.create!(name: "Lamp")
      bom = project.boms.create!(user: @user)
      line = bom.lines.create!(user: @user, part_name: "Generic LED", supplier_id: sup.id, quantity: 10)
      sup.destroy!

      line.reload
      assert_nil line.supplier_id
      line.notes = "reorder in bulk"
      assert line.save, line.errors.full_messages.to_sentence
      # The free-text target is untouched, so the line still says what it needs.
      assert_equal :free_text, line.reload.target_kind
    end

    # Nullify is keyed on the supplier's own id, which is globally unique, and no row may point at
    # another user's supplier in the first place (`supplier_belongs_to_user`, proven end-to-end in
    # test/integration/v1/maker/cross_tenant_fk_test.rb). This pins the resulting property.
    test "destroying one user's supplier does not touch another user's rows" do
      other = User.create!(email: "other-sup@example.com")
      their_sup = other.maker_suppliers.create!(name: "Theirs")
      their_item = other.maker_inventory_items.create!(name: "Their bolt", supplier: their_sup)

      mine = @user.maker_suppliers.create!(name: "Mine")
      @user.maker_inventory_items.create!(name: "My bolt", supplier: mine)
      mine.destroy!

      assert_equal their_sup.id, their_item.reload.supplier_id
    end
  end
end
