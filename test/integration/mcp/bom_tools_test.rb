require "test_helper"
require "support/mcp_client"

module Mcp
  class BomToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-bom@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-bom@example.com")
      @lamp = @user.maker_projects.create!(name: "Lamp")
      @bolts = @user.maker_inventory_items.create!(name: "M3 bolt", unit_cost: 0.5)
      Maker::InventoryTransaction.apply!(item: @bolts, user: @user, delta: 2, reason: "initial")
      @bolts.reload
    end

    test "get_bom answers the project's BOMs, the first one's lines, what is short and the cost" do
      bom = @lamp.boms.create!(user: @user)
      stock = bom.lines.create!(user: @user, inventory_item: @bolts, quantity: 4, reference: "R1")
      text = bom.lines.create!(user: @user, part_name: "Lens", quantity: 1, notes: "acrylic")
      @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)

      out = mcp_structured(@token, "get_bom", { project: "lamp" })
      assert_equal [ [ bom.id, 2 ], [ @lamp.boms.last.id, 0 ] ], out["boms"].map { |b| [ b["id"], b["lines"] ] }
      assert_equal bom.id, out.dig("bom", "id")
      lines = out.dig("bom", "lines")
      assert_equal [ stock.id, text.id ], lines.map { |l| l["id"] }
      assert_equal({ "id" => @bolts.id, "name" => "M3 bolt", "on_hand" => 2.0 }, lines.first["item"])
      assert_equal "inventory_item", lines.first["kind"]
      assert_equal "Lens", lines.last["part_name"]
      assert_equal [ { "line_id" => stock.id, "item" => "M3 bolt", "needed" => 4.0, "on_hand" => 2.0 } ], out.dig("bom", "short")
      assert_equal 2.0, out.dig("bom", "estimated_cost")
    end

    test "get_bom takes a bom_id, answers bom: null for a project with none, and names a wrong id" do
      assert_nil mcp_structured(@token, "get_bom", { project: "lamp" })["bom"]
      rev_b = @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)
      assert_equal rev_b.id, mcp_structured(@token, "get_bom", { project: "lamp", bom_id: rev_b.id }).dig("bom", "id")
      assert_equal "No BOM with id 0 on project \"lamp\".", mcp_refusal(@token, "get_bom", { project: "lamp", bom_id: 0 })
    end

    test "add_bom_line creates the project's first BOM, then adds a stock line and a text line" do
      out = mcp_structured(@token, "add_bom_line", { project: "lamp", inventory_item_id: @bolts.id, quantity: 4 })
      bom = @lamp.boms.sole
      assert_equal bom.id, out["bom_id"]
      line = bom.lines.sole
      assert_equal @bolts, line.inventory_item
      assert_equal "each", out.dig("line", "unit")

      out = mcp_structured(@token, "add_bom_line", { project: "lamp", part_name: "Lens", unit: "sheet", notes: "acrylic" })
      assert_equal bom.id, out["bom_id"]
      assert_equal 2, bom.lines.count
      assert_equal 1.0, out.dig("line", "quantity")
    end

    test "add_bom_line refuses a line with no target or two targets in the model's words" do
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp" }))
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp", inventory_item_id: @bolts.id, part_name: "Lens" }))
      assert_empty @lamp.boms.sole.lines
    end

    test "update_bom_line changes the given fields" do
      bom = @lamp.boms.create!(user: @user)
      line = bom.lines.create!(user: @user, part_name: "Lens", quantity: 1)
      out = mcp_structured(@token, "update_bom_line", { id: line.id, quantity: 3, reference: "L1" })
      assert_equal [ 3, "L1", "Lens" ], [ line.reload.quantity.to_i, line.reference, line.part_name ]
      assert_equal 3.0, out.dig("line", "quantity")
      assert_equal "No BOM line with id 0.", mcp_refusal(@token, "update_bom_line", { id: 0, quantity: 1 })
    end
  end
end
