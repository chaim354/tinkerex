require "test_helper"

module V1
  module Maker
    class TagsTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "tg@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Vase", item_type: "model_3d" } },
             as: :json, headers: auth(@token)
        @vase = JSON.parse(response.body)["id"]
        post "/v1/maker/items", params: { item: { title: "Plate", item_type: "cad" } },
             as: :json, headers: auth(@token)
        @plate = JSON.parse(response.body)["id"]
      end

      test "tag an item by name (creating the tag on the fly)" do
        post "/v1/maker/items/#{@vase}/taggings",
             params: { name: "printed" }, as: :json, headers: auth(@token)
        assert_response :created
        get "/v1/maker/items/#{@vase}", headers: auth(@token)
        assert_equal [ "printed" ], JSON.parse(response.body)["tags"]
      end

      test "tags index lists the user's tags" do
        post "/v1/maker/items/#{@vase}/taggings", params: { name: "useful" }, as: :json, headers: auth(@token)
        get "/v1/maker/tags", headers: auth(@token)
        assert_response :success
        assert_equal [ "useful" ], JSON.parse(response.body)["tags"].map { |t| t["name"] }
      end

      test "filter items by tag" do
        post "/v1/maker/items/#{@vase}/taggings", params: { name: "printed" }, as: :json, headers: auth(@token)
        get "/v1/maker/items", params: { tag: "printed" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Vase" ], titles
      end

      test "filter items by type" do
        get "/v1/maker/items", params: { type: "cad" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Plate" ], titles
      end

      test "search items by title text" do
        get "/v1/maker/items", params: { q: "vas" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Vase" ], titles
      end

      test "text search is case-insensitive (portable across sqlite/postgres)" do
        get "/v1/maker/items", params: { q: "VASE" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "Vase" ], titles, "uppercase query must still match a lowercase-stored title via LOWER()"
      end
    end
  end
end
