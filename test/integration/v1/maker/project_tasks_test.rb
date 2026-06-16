require "test_helper"

module V1
  module Maker
    class ProjectTasksTest < ActionDispatch::IntegrationTest
      def register(email = "pt@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project_id = JSON.parse(response.body)["id"]
      end

      test "create a task owned by a project" do
        post "/v1/maker/tasks",
             params: { task: { title: "Wire the LEDs", taskable_type: "Maker::Project",
                               taskable_id: @project_id } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Maker::Project", body["taskable_type"]
        assert_equal @project_id, body["taskable_id"]
      end

      test "cannot own a task with another user's project" do
        other = register("other-pt@example.com")
        post "/v1/maker/projects", params: { project: { name: "Theirs" } }, as: :json, headers: auth(other)
        their_project = JSON.parse(response.body)["id"]
        post "/v1/maker/tasks",
             params: { task: { title: "Sneaky", taskable_type: "Maker::Project",
                               taskable_id: their_project } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "an unknown taskable_type is rejected" do
        post "/v1/maker/tasks",
             params: { task: { title: "x", taskable_type: "Maker::Bogus", taskable_id: 1 } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end
    end
  end
end
