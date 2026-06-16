require "test_helper"

module V1
  module Maker
    class BuildLogEntriesTest < ActionDispatch::IntegrationTest
      def register(email = "bl@example.com")
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json, headers: auth(@token)
        @project_id = JSON.parse(response.body)["id"]
      end

      test "add a build log entry to a project" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "Soldered the board", entry_type: "milestone" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "Soldered the board", body["body"]
        assert_equal "milestone", body["entry_type"]
        assert body["logged_at"].present?
      end

      test "index lists a project's build log in logged_at order" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "First", logged_at: 2.days.ago.iso8601 } },
             as: :json, headers: auth(@token)
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "Second", logged_at: 1.day.ago.iso8601 } },
             as: :json, headers: auth(@token)
        get "/v1/maker/projects/#{@project_id}/build_log_entries", headers: auth(@token)
        assert_response :success
        assert_equal %w[First Second], JSON.parse(response.body)["build_log_entries"].map { |e| e["body"] }
      end

      test "delete a build log entry" do
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "x" } }, as: :json, headers: auth(@token)
        entry_id = JSON.parse(response.body)["id"]
        delete "/v1/maker/build_log_entries/#{entry_id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/projects/#{@project_id}/build_log_entries", headers: auth(@token)
        assert_equal [], JSON.parse(response.body)["build_log_entries"]
      end

      test "cannot add to another user's project" do
        other = register("other-bl@example.com")
        post "/v1/maker/projects/#{@project_id}/build_log_entries",
             params: { build_log_entry: { body: "x" } }, as: :json, headers: auth(other)
        assert_response :not_found
      end

      test "attach a design file to a project by node_id" do
        post "/v1/maker/projects/#{@project_id}/file_attachments",
             params: { file_attachment: { node_id: "node-step", role: "model", label: "enclosure.step" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "node-step", JSON.parse(response.body)["node_id"]
        get "/v1/maker/projects/#{@project_id}", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["file_attachments"].size
      end
    end
  end
end
