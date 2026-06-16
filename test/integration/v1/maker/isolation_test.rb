require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every maker resource must 404 (never leak) across users.
    class IsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        bootstrap_token(email: email, device_name: "d")
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-iso@example.com")
        @b = register("b-iso@example.com")
        post "/v1/maker/items", params: { item: { title: "A's item" } }, as: :json, headers: auth(@a)
        @item = JSON.parse(response.body)["id"]
        post "/v1/maker/collections", params: { collection: { name: "A's coll" } }, as: :json, headers: auth(@a)
        @coll = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks", params: { task: { title: "A's task" } }, as: :json, headers: auth(@a)
        @task = JSON.parse(response.body)["id"]
      end

      test "B cannot read, update, or delete A's resources" do
        get    "/v1/maker/items/#{@item}", headers: auth(@b);                          assert_response :not_found
        patch  "/v1/maker/items/#{@item}", params: { item: { title: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/items/#{@item}", headers: auth(@b);                          assert_response :not_found
        get    "/v1/maker/collections/#{@coll}/items", headers: auth(@b);              assert_response :not_found
        delete "/v1/maker/tasks/#{@task}", headers: auth(@b);                          assert_response :not_found
      end

      test "B's index is empty" do
        get "/v1/maker/items", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["items"]
      end
    end
  end
end
