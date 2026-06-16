require "test_helper"

module V1
  module Maker
    class ItemsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "m@example.com", device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup { @token = register }

      test "create returns the item json" do
        post "/v1/maker/items",
             params: { item: { title: "Benchy", item_type: "model_3d", origin: "downloaded",
                               source_url: "https://printables.com/benchy" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Benchy", body["title"]
        assert_equal "model_3d", body["item_type"]
        assert body["id"].present?
      end

      test "index lists only the current user's items" do
        post "/v1/maker/items", params: { item: { title: "Mine" } }, as: :json, headers: auth(@token)
        post "/v1/auth/register", params: { email: "two@example.com", device_name: "d" }, as: :json
        other = JSON.parse(response.body)["device_token"]
        post "/v1/maker/items", params: { item: { title: "Theirs" } }, as: :json, headers: auth(other)

        get "/v1/maker/items", headers: auth(@token)
        assert_response :success
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Mine" ], titles
      end

      test "show returns an item with its attachments and tags" do
        post "/v1/maker/items", params: { item: { title: "Lamp" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "Lamp", body["title"]
        assert_equal [], body["file_attachments"]
        assert_equal [], body["tags"]
      end

      test "update changes fields" do
        post "/v1/maker/items", params: { item: { title: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/items/#{id}", params: { item: { title: "New", favorited: true } },
              as: :json, headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "New", body["title"]
        assert_equal true, body["favorited"]
      end

      test "destroy removes the item" do
        post "/v1/maker/items", params: { item: { title: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/items/#{id}", headers: auth(@token)
        assert_response :not_found
      end

      test "another user cannot show my item" do
        post "/v1/maker/items", params: { item: { title: "Private" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        post "/v1/auth/register", params: { email: "x@example.com", device_name: "d" }, as: :json
        other = JSON.parse(response.body)["device_token"]
        get "/v1/maker/items/#{id}", headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/items"
        assert_response :unauthorized
      end
    end
  end
end
