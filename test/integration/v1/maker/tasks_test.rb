require "test_helper"

module V1
  module Maker
    class TasksTest < ActionDispatch::IntegrationTest
      def register
        post "/v1/auth/register", params: { email: "tk@example.com", device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }
      setup { @token = register }

      test "create a standalone task" do
        post "/v1/maker/tasks", params: { task: { title: "Buy filament" } }, as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Buy filament", body["title"]
        assert_equal "todo", body["status"]
      end

      test "create a task owned by an item" do
        post "/v1/maker/items", params: { item: { title: "Bracket" } }, as: :json, headers: auth(@token)
        item_id = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks",
             params: { task: { title: "Print it", taskable_type: "Maker::Item", taskable_id: item_id } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal item_id, JSON.parse(response.body)["taskable_id"]
      end

      test "index lists tasks; open scope excludes done" do
        post "/v1/maker/tasks", params: { task: { title: "A" } }, as: :json, headers: auth(@token)
        post "/v1/maker/tasks", params: { task: { title: "B" } }, as: :json, headers: auth(@token)
        id_b = JSON.parse(response.body)["id"]
        patch "/v1/maker/tasks/#{id_b}", params: { task: { status: "done" } }, as: :json, headers: auth(@token)
        get "/v1/maker/tasks", params: { open: true }, headers: auth(@token)
        titles = JSON.parse(response.body)["tasks"].map { |t| t["title"] }
        assert_equal [ "A" ], titles
      end

      test "update can complete a task" do
        post "/v1/maker/tasks", params: { task: { title: "X" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/tasks/#{id}", params: { task: { status: "done" } }, as: :json, headers: auth(@token)
        assert_response :success
        assert_equal "done", JSON.parse(response.body)["status"]
        assert_not_nil JSON.parse(response.body)["completed_at"]
      end

      test "destroy removes a task" do
        post "/v1/maker/tasks", params: { task: { title: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/tasks/#{id}", headers: auth(@token)
        assert_response :no_content
      end
    end
  end
end
