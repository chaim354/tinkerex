require "test_helper"

module V1
  module Maker
    class LocationsTest < ActionDispatch::IntegrationTest
      def register(email = "lc@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create and nest a location" do
        post "/v1/maker/locations", params: { location: { name: "Shelf A" } }, as: :json, headers: auth(@token)
        assert_response :created
        shelf = JSON.parse(response.body)["id"]
        post "/v1/maker/locations", params: { location: { name: "Bin 1", parent_id: shelf } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal shelf, JSON.parse(response.body)["parent_id"]
      end

      test "index lists only my locations" do
        post "/v1/maker/locations", params: { location: { name: "Mine" } }, as: :json, headers: auth(@token)
        other = register("o@example.com")
        post "/v1/maker/locations", params: { location: { name: "Theirs" } }, as: :json, headers: auth(other)
        get "/v1/maker/locations", headers: auth(@token)
        assert_equal [ "Mine" ], JSON.parse(response.body)["locations"].map { |l| l["name"] }
      end

      test "cannot nest under another user's location (422)" do
        other = register("o2@example.com")
        post "/v1/maker/locations", params: { location: { name: "Theirs" } }, as: :json, headers: auth(other)
        foreign = JSON.parse(response.body)["id"]
        post "/v1/maker/locations", params: { location: { name: "Bin", parent_id: foreign } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "destroy removes a location" do
        post "/v1/maker/locations", params: { location: { name: "X" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/locations/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
