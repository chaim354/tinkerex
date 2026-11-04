require "test_helper"
require "support/mcp_client"

module Mcp
  class ReferenceToolsTest < ActionDispatch::IntegrationTest
    include McpClient

    setup do
      @token = bootstrap_token(email: "mcp-reference@example.com", device_name: "assistant")
      @user = User.find_by!(email: "mcp-reference@example.com")
    end

    test "list_suppliers and create_supplier" do
      @user.maker_suppliers.create!(name: "Zed parts", url: "https://zed.example")
      @user.maker_suppliers.create!(name: "Acme")
      out = mcp_structured(@token, "list_suppliers")
      assert_equal [ "Acme", "Zed parts" ], out["suppliers"].map { |s| s["name"] }
      assert_equal "https://zed.example", out["suppliers"].last["url"]

      out = mcp_structured(@token, "create_supplier", { name: "Bolt barn", notes: "cheap" })
      assert_equal "cheap", @user.maker_suppliers.find(out.dig("supplier", "id")).notes
      assert_match(/Name can't be blank/, mcp_refusal(@token, "create_supplier", { name: " " }))
    end

    test "list_locations names the parent, and create_location nests" do
      shop = @user.maker_locations.create!(name: "Shop")
      @user.maker_locations.create!(name: "Bench", parent: shop)
      out = mcp_structured(@token, "list_locations")
      assert_equal [ [ "Bench", "Shop" ], [ "Shop", nil ] ], out["locations"].map { |l| [ l["name"], l["parent"] ] }

      out = mcp_structured(@token, "create_location", { name: "Drawer 3", parent_id: shop.id, description: "screws" })
      drawer = @user.maker_locations.find(out.dig("location", "id"))
      assert_equal shop, drawer.parent
      assert_equal "Shop", out.dig("location", "parent")

      other = User.create!(email: "other-loc@example.com", confirmed_at: Time.current, omniauth_signup: true)
      theirs = other.maker_locations.create!(name: "Theirs")
      assert_match(/Parent/i, mcp_refusal(@token, "create_location", { name: "X", parent_id: theirs.id }))
    end
  end
end
