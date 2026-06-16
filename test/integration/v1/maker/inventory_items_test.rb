require "test_helper"

module V1
  module Maker
    class InventoryItemsTest < ActionDispatch::IntegrationTest
      def register(email = "ii@example.com")
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      def create_item(attrs = {}, token: @token)
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "M3 bolt" }.merge(attrs) },
             as: :json, headers: auth(token)
        JSON.parse(response.body)["id"]
      end

      test "create returns the item with a zero balance" do
        post "/v1/maker/inventory_items",
             params: { inventory_item: { name: "M3 bolt", unit: "each", min_quantity: 50 } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "M3 bolt", body["name"]
        assert_equal "0.0", body["quantity_cached"].to_s.sub(/\.0+\z/, ".0")
        assert_equal "50.0", body["min_quantity"].to_s.sub(/\.0+\z/, ".0")
      end

      test "adjust posts a transaction and moves the cached balance" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 100, reason: "restocked" }, as: :json, headers: auth(@token)
        assert_response :created
        assert_equal 100.0, JSON.parse(response.body)["quantity_cached"].to_f

        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: -7, reason: "consumed" }, as: :json, headers: auth(@token)
        assert_equal 93.0, JSON.parse(response.body)["quantity_cached"].to_f
      end

      test "adjust rejects an invalid reason with 422" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust",
             params: { delta: 1, reason: "bogus" }, as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "transactions lists the ledger newest-first" do
        id = create_item
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 10, reason: "initial" },
             as: :json, headers: auth(@token)
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: -2, reason: "consumed" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/#{id}/transactions", headers: auth(@token)
        assert_response :success
        deltas = JSON.parse(response.body)["transactions"].map { |t| t["delta"].to_f }
        assert_equal [ -2.0, 10.0 ], deltas
      end

      test "low_stock returns items at or below min_quantity" do
        low = create_item({ name: "low", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{low}/adjust", params: { delta: 3, reason: "initial" },
             as: :json, headers: auth(@token)
        ok = create_item({ name: "ok", min_quantity: 10 })
        post "/v1/maker/inventory_items/#{ok}/adjust", params: { delta: 99, reason: "initial" },
             as: :json, headers: auth(@token)
        get "/v1/maker/inventory_items/low_stock", headers: auth(@token)
        assert_response :success
        names = JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
        assert_includes names, "low"
        assert_not_includes names, "ok"
      end

      test "index is filterable by category" do
        create_item({ name: "bolt", category: "fasteners" })
        create_item({ name: "wire", category: "electronics" })
        get "/v1/maker/inventory_items", params: { category: "fasteners" }, headers: auth(@token)
        assert_equal [ "bolt" ], JSON.parse(response.body)["inventory_items"].map { |i| i["name"] }
      end

      test "another user cannot adjust my item" do
        id = create_item
        other = register("o@example.com")
        post "/v1/maker/inventory_items/#{id}/adjust", params: { delta: 1, reason: "restocked" },
             as: :json, headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/inventory_items"
        assert_response :unauthorized
      end
    end
  end
end
