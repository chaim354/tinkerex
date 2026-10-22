require "test_helper"

module V1
  module Maker
    class TagsTest < ActionDispatch::IntegrationTest
      def register
        bootstrap_token(email: "tg@example.com", device_name: "d")
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

      test "item json exposes tagging ids so a tag can be removed" do
        post "/v1/maker/items/#{@vase}/taggings", params: { name: "printed" }, as: :json, headers: auth(@token)
        get "/v1/maker/items/#{@vase}", headers: auth(@token)
        taggings = JSON.parse(response.body)["taggings"]
        assert_equal 1, taggings.size
        tg = taggings.first
        assert_equal "printed", tg["name"]
        assert tg["id"].present?, "tagging id must be exposed for removal"
        # remove via the tagging id
        delete "/v1/maker/taggings/#{tg['id']}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/items/#{@vase}", headers: auth(@token)
        assert_equal [], JSON.parse(response.body)["tags"]
        assert_equal [], JSON.parse(response.body)["taggings"]
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

      # A LITERAL MUST BE FOUND, NOT MERELY NOT-OVERMATCH. This once asserted `q: "%"` returns
      # `[]`, which passes with or without `ESCAPE '\'` on SQLite: lacking it, the sanitized
      # pattern `%\%%` hunts for a backslash nobody stored and finds nothing — the same answer the
      # test wanted. Both rows below share "100", so each half carries weight: drop ESCAPE and the
      # search finds nothing; drop sanitize_sql_like and `%` matches "100 percent" too.
      test "search treats % as a literal, not a wildcard" do
        post "/v1/maker/items", params: { item: { title: "100% infill" } }, as: :json, headers: auth(@token)
        post "/v1/maker/items", params: { item: { title: "100 percent" } }, as: :json, headers: auth(@token)
        get "/v1/maker/items", params: { q: "100%" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "100% infill" ], titles
      end

      test "search treats _ as a literal, not a single-character wildcard" do
        post "/v1/maker/items", params: { item: { title: "M3_8 bolt" } }, as: :json, headers: auth(@token)
        post "/v1/maker/items", params: { item: { title: "M3-8 bolt" } }, as: :json, headers: auth(@token)
        get "/v1/maker/items", params: { q: "M3_8" }, headers: auth(@token)
        titles = JSON.parse(response.body)["items"].map { |i| i["title"] }
        assert_equal [ "M3_8 bolt" ], titles
      end
    end
  end
end
