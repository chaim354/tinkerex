require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every inventory resource must 404 (never leak) across users.
    class InventoryIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-iiso@example.com")
        @b = register("b-iiso@example.com")
        post "/v1/maker/locations", params: { location: { name: "A's shelf" } }, as: :json, headers: auth(@a)
        @loc = JSON.parse(response.body)["id"]
        post "/v1/maker/suppliers", params: { supplier: { name: "A's vendor" } }, as: :json, headers: auth(@a)
        @sup = JSON.parse(response.body)["id"]
        post "/v1/maker/inventory_items", params: { inventory_item: { name: "A's bolt" } },
             as: :json, headers: auth(@a)
        @item = JSON.parse(response.body)["id"]
      end

      test "B cannot read, mutate, or adjust A's inventory resources" do
        get    "/v1/maker/locations/#{@loc}", headers: auth(@b);                       assert_response :not_found
        delete "/v1/maker/suppliers/#{@sup}", headers: auth(@b);                       assert_response :not_found
        get    "/v1/maker/inventory_items/#{@item}", headers: auth(@b);                assert_response :not_found
        patch  "/v1/maker/inventory_items/#{@item}", params: { inventory_item: { name: "hax" } },
               as: :json, headers: auth(@b)
        assert_response :not_found
        post   "/v1/maker/inventory_items/#{@item}/adjust", params: { delta: 1, reason: "restocked" },
               as: :json, headers: auth(@b)
        assert_response :not_found
        get    "/v1/maker/inventory_items/#{@item}/transactions", headers: auth(@b);   assert_response :not_found
      end

      test "B's inventory index is empty" do
        get "/v1/maker/inventory_items", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["inventory_items"]
      end
    end
  end
end
