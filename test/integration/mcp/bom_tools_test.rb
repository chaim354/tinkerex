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

    # "THE BOM" IS Maker::Project#current_bom, THE LATEST REVISION, FOR AN ASSISTANT AS FOR EVERY
    # PAGE. These tools used to take the oldest by id instead, so on a project with two BOMs an
    # assistant read the shortages and the cost of a BOM no page treats as current. The older one
    # is created first here so that "first by id" and "latest revision" are different rows.
    test "get_bom answers the project's BOMs, the current one's lines, what is short and the cost" do
      old = @lamp.boms.create!(user: @user)
      bom = @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)
      stock = bom.lines.create!(user: @user, inventory_item: @bolts, quantity: 4, reference: "R1")
      text = bom.lines.create!(user: @user, part_name: "Lens", quantity: 1, notes: "acrylic")
      assert_equal bom, @lamp.current_bom

      out = mcp_structured(@token, "get_bom", { project: "lamp" })
      assert_equal [ [ old.id, 0 ], [ bom.id, 2 ] ], out["boms"].map { |b| [ b["id"], b["lines"] ] }
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

    # ...AND A LINE ADDED WITH NO bom_id LANDS WHERE THE MAKER WILL SEE IT. It used to go into the
    # oldest BOM while the project page, the BOM page, a release and the README's table all showed
    # the latest, so the assistant said "added" and the line appeared nowhere.
    test "add_bom_line with no bom_id adds to the BOM the project page shows" do
      old = @lamp.boms.create!(user: @user)
      current = @lamp.boms.create!(user: @user, name: "Rev B", revision: 2)

      out = mcp_structured(@token, "add_bom_line", { project: "lamp", part_name: "Lens" })

      assert_equal current.id, out["bom_id"]
      assert_equal [ "Lens" ], @lamp.current_bom.lines.map(&:part_name)
      assert_empty old.lines
    end

    test "add_bom_line refuses a line with no target or two targets in the model's words" do
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp" }))
      assert_match(/exactly one of/, mcp_refusal(@token, "add_bom_line", { project: "lamp", inventory_item_id: @bolts.id, part_name: "Lens" }))
      assert_empty @lamp.boms, "a refused first line leaves no empty BOM behind"
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
