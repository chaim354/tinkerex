require "test_helper"

module V1
  module Maker
    class ProjectsTest < ActionDispatch::IntegrationTest
      def register(email = "p@example.com")
        post "/v1/auth/register", params: { email:, device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup { @token = register }

      test "create returns the project json with a derived slug" do
        post "/v1/maker/projects",
             params: { project: { name: "Smart Lamp", status: "active", description: "RGB lamp" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Smart Lamp", body["name"]
        assert_equal "smart-lamp", body["slug"]
        assert_equal "active", body["status"]
        assert body["id"].present?
      end

      test "index lists only the current user's projects, filterable by status" do
        post "/v1/maker/projects", params: { project: { name: "Active one", status: "active" } },
             as: :json, headers: auth(@token)
        post "/v1/maker/projects", params: { project: { name: "Done one", status: "done" } },
             as: :json, headers: auth(@token)
        other = register("two@example.com")
        post "/v1/maker/projects", params: { project: { name: "Theirs" } }, as: :json, headers: auth(other)

        get "/v1/maker/projects", headers: auth(@token)
        assert_response :success
        assert_equal %w[Active\ one Done\ one].sort,
                     JSON.parse(response.body)["projects"].map { |p| p["name"] }.sort

        get "/v1/maker/projects", params: { status: "active" }, headers: auth(@token)
        assert_equal [ "Active one" ], JSON.parse(response.body)["projects"].map { |p| p["name"] }
      end

      test "show returns a project with empty build log and attachments" do
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        get "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "Lamp", body["name"]
        assert_equal [], body["build_log_entries"]
        assert_equal [], body["file_attachments"]
      end

      test "update changes fields" do
        post "/v1/maker/projects", params: { project: { name: "Old" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        patch "/v1/maker/projects/#{id}", params: { project: { name: "New", status: "paused" } },
              as: :json, headers: auth(@token)
        assert_response :success
        body = JSON.parse(response.body)
        assert_equal "New", body["name"]
        assert_equal "paused", body["status"]
      end

      test "rejects an invalid status with 422" do
        post "/v1/maker/projects", params: { project: { name: "X", status: "bogus" } },
             as: :json, headers: auth(@token)
        assert_response :unprocessable_entity
      end

      test "destroy removes the project" do
        post "/v1/maker/projects", params: { project: { name: "Doomed" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        delete "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/projects/#{id}", headers: auth(@token)
        assert_response :not_found
      end

      test "another user cannot show my project" do
        post "/v1/maker/projects", params: { project: { name: "Private" } }, as: :json, headers: auth(@token)
        id = JSON.parse(response.body)["id"]
        other = register("x@example.com")
        get "/v1/maker/projects/#{id}", headers: auth(other)
        assert_response :not_found
      end

      test "auth is required" do
        get "/v1/maker/projects"
        assert_response :unauthorized
      end
    end
  end
end
