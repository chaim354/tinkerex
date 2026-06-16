require "test_helper"

module V1
  module Maker
    class SuppliersTest < ActionDispatch::IntegrationTest
      def register(email = "sp@example.com")
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create a supplier" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Digikey", url: "https://digikey.com" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Digikey", body["name"]
        assert_equal "https://digikey.com", body["url"]
      end

      test "index lists only my suppliers" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Mine" } }, as: :json, headers: auth(@token)
        other = register("o@example.com")
        post "/v1/maker/suppliers", params: { supplier: { name: "Theirs" } }, as: :json, headers: auth(other)
        get "/v1/maker/suppliers", headers: auth(@token)
        assert_equal [ "Mine" ], JSON.parse(response.body)["suppliers"].map { |s| s["name"] }
      end

      test "update and destroy" do
        post "/v1/maker/suppliers", params: { supplier: { name: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/suppliers/#{id}", params: { supplier: { name: "New" } }, as: :json, headers: auth(@token)
        assert_equal "New", JSON.parse(response.body)["name"]
        delete "/v1/maker/suppliers/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
