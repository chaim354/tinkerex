require "test_helper"

module V1
  module Maker
    # Pins the wire contract the Action Text move must not break: client/sync-client's
    # BuildLogEntry declares `pub body: String` with NO serde(default), so a body that serializes
    # as anything but a plain string is a hard deserialize error for a shipped desktop client.
    class BuildLogPlainTextTest < ActionDispatch::IntegrationTest
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = bootstrap_token(email: "bl-plain@example.com", device_name: "d")
        post "/v1/maker/projects", params: { project: { name: "Lamp" } }, as: :json,
             headers: auth(@token)
        @project = JSON.parse(response.body)["id"]
      end

      test "a rich body serializes as plain text on the entries index" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "<p>Cut the <strong>panels</strong></p>" } },
             as: :json, headers: auth(@token)
        assert_response :created

        get "/v1/maker/projects/#{@project}/build_log_entries", headers: auth(@token)
        assert_response :success

        body = JSON.parse(response.body)["build_log_entries"].first["body"]
        assert_kind_of String, body
        assert_includes body, "Cut the panels"
        assert_not_includes body, "<strong>"
      end

      test "the full project view serializes entry bodies as plain text too" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "<p>Sanded the <em>edges</em></p>" } },
             as: :json, headers: auth(@token)

        get "/v1/maker/projects/#{@project}", headers: auth(@token)
        assert_response :success

        body = JSON.parse(response.body)["build_log_entries"].first["body"]
        assert_kind_of String, body
        assert_includes body, "Sanded the edges"
        assert_not_includes body, "<em>"
      end

      test "a plain string on write is still accepted" do
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "Cut the panels" } },
             as: :json, headers: auth(@token)
        assert_response :created
        assert_equal "Cut the panels", JSON.parse(response.body)["body"]
      end
    end
  end
end
