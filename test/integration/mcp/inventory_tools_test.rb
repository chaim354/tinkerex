require "test_helper"
require "support/mcp_client"

module Mcp
  class InventoryToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-inventory@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-inventory@example.com")
      @bench = @user.maker_locations.create!(name: "Bench")
      @shop = @user.maker_suppliers.create!(name: "Shop")
    end

    def item!(name, qty: 0, **attrs)
      item = @user.maker_inventory_items.create!({ name: name }.merge(attrs))
      Maker::InventoryTransaction.apply!(item: item, user: @user, delta: qty, reason: "initial") if qty != 0
      item.reload
    end

    test "list_inventory answers by name with location, supplier and low_stock, and filters" do
      bolts = item!("M3 bolt", qty: 100, part_number: "B-M3", location: @bench, supplier: @shop, min_quantity: 10)
      ply = item!("Ply 3mm", qty: 2, min_quantity: 5, unit: "sheet")

      out = mcp_structured(@token, "list_inventory")
      assert_equal [ bolts.id, ply.id ], out["items"].map { |i| i["id"] }
      row = out["items"].first
      assert_equal({ "quantity" => 100.0, "unit" => "each", "location" => "Bench", "supplier" => "Shop", "low_stock" => false },
                   row.slice("quantity", "unit", "location", "supplier", "low_stock"))
      assert_equal true, out["items"].last["low_stock"]

      assert_equal [ ply.id ], mcp_structured(@token, "list_inventory", { low_stock: true })["items"].map { |i| i["id"] }
      assert_equal [ bolts.id ], mcp_structured(@token, "list_inventory", { location_id: @bench.id })["items"].map { |i| i["id"] }
      assert_equal [ bolts.id ], mcp_structured(@token, "list_inventory", { q: "b-m3" })["items"].map { |i| i["id"] }
    end

    test "get_inventory_item answers the full row and its ledger newest first" do
      bolts = item!("M3 bolt", qty: 100, unit_cost: 0.05, notes: "zinc")
      Maker::InventoryTransaction.apply!(item: bolts, user: @user, delta: -4, reason: "consumed")
      out = mcp_structured(@token, "get_inventory_item", { id: bolts.id })
      assert_equal 96.0, out.dig("item", "quantity")
      assert_equal 0.05, out.dig("item", "unit_cost")
      assert_equal "zinc", out.dig("item", "notes")
      assert_equal [ -4.0, 100.0 ], out["transactions"].map { |t| t["delta"] }
      assert_equal "No inventory item with id 0.", mcp_refusal(@token, "get_inventory_item", { id: 0 })
    end

    test "create_inventory_item posts the opening quantity to the ledger as initial stock" do
      out = mcp_structured(@token, "create_inventory_item",
                           { name: "Nuts", quantity: 50, unit: "pack", min_quantity: 5, location_id: @bench.id })
      item = @user.maker_inventory_items.find(out.dig("item", "id"))
      assert_equal 50, item.quantity_cached
      assert_equal [ [ "initial", 50 ] ], item.transactions.map { |t| [ t.reason, t.delta.to_i ] }
      assert_equal "Bench", out.dig("item", "location")

      out = mcp_structured(@token, "create_inventory_item", { name: "Empty" })
      assert_empty @user.maker_inventory_items.find(out.dig("item", "id")).transactions
    end

    test "create_inventory_item refuses a foreign location in the model's words" do
      other = User.create!(email: "other-inv@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_locations.create!(name: "Theirs")
      message = mcp_refusal(@token, "create_inventory_item", { name: "X", location_id: theirs.id })
      assert_match(/Location/i, message)
      assert_nil @user.maker_inventory_items.find_by(name: "X")
    end

    test "update_inventory_item changes the given fields and never the balance" do
      bolts = item!("M3 bolt", qty: 100)
      out = mcp_structured(@token, "update_inventory_item", { id: bolts.id, name: "M3 x 10 bolt", min_quantity: 20, supplier_id: @shop.id })
      assert_equal "M3 x 10 bolt", bolts.reload.name
      assert_equal 20, bolts.min_quantity
      assert_equal @shop, bolts.supplier
      assert_equal 100.0, out.dig("item", "quantity")
    end

    test "adjust_inventory posts a signed ledger row naming the project" do
      bolts = item!("M3 bolt", qty: 100)
      lamp = @user.maker_projects.create!(name: "Lamp")
      out = mcp_structured(@token, "adjust_inventory", { id: bolts.id, delta: -4, reason: "consumed", project: "lamp", note: "base" })
      assert_equal 96.0, out.dig("item", "quantity")
      txn = bolts.transactions.last
      assert_equal [ -4, "consumed", lamp.id, "base" ], [ txn.delta.to_i, txn.reason, txn.project_id, txn.note ]
      assert_equal txn.id, out.dig("transaction", "id")
      assert_equal "delta must not be zero.", mcp_refusal(@token, "adjust_inventory", { id: bolts.id, delta: 0 })
      assert_equal "No project \"nope\".", mcp_refusal(@token, "adjust_inventory", { id: bolts.id, delta: 1, project: "nope" })
    end
  end
end
