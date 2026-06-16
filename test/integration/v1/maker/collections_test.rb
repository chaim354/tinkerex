require "test_helper"

module V1
  module Maker
    class CollectionsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "cl@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Knob" } }, as: :json, headers: auth(@token)
        @item = JSON.parse(response.body)["id"]
      end

      test "create a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Lamp parts" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "Lamp parts", JSON.parse(response.body)["name"]
      end

      test "add and list items in a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Box" } }, as: :json, headers: auth(@token)
        cid = JSON.parse(response.body)["id"]
        post "/v1/maker/collections/#{cid}/items", params: { item_id: @item }, as: :json, headers: auth(@token)
        assert_response :created
        get "/v1/maker/collections/#{cid}/items", headers: auth(@token)
        assert_equal [ "Knob" ], JSON.parse(response.body)["items"].map { |i| i["title"] }
      end

      test "remove an item from a collection" do
        post "/v1/maker/collections", params: { collection: { name: "Box" } }, as: :json, headers: auth(@token)
        cid = JSON.parse(response.body)["id"]
        post "/v1/maker/collections/#{cid}/items", params: { item_id: @item }, as: :json, headers: auth(@token)
        delete "/v1/maker/collections/#{cid}/items/#{@item}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/collections/#{cid}/items", headers: auth(@token)
        assert_equal [], JSON.parse(response.body)["items"]
      end
    end
  end
end
