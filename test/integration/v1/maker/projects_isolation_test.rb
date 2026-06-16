require "test_helper"

module V1
  module Maker
    # Belt-and-suspenders: every project resource must 404 (never leak) across users.
    class ProjectsIsolationTest < ActionDispatch::IntegrationTest
      def register(email)
        post "/v1/auth/register", params: { email:, device_name: "d" }, as: :json
        JSON.parse(response.body)["device_token"]
      end
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-piso@example.com")
        @b = register("b-piso@example.com")
        post "/v1/maker/projects", params: { project: { name: "A's project" } }, as: :json, headers: auth(@a)
        @project = JSON.parse(response.body)["id"]
        post "/v1/maker/projects/#{@project}/build_log_entries",
             params: { build_log_entry: { body: "A's log" } }, as: :json, headers: auth(@a)
        @entry = JSON.parse(response.body)["id"]
      end

      test "B cannot read, update, or delete A's project or its children" do
        get    "/v1/maker/projects/#{@project}", headers: auth(@b);                          assert_response :not_found
        patch  "/v1/maker/projects/#{@project}", params: { project: { name: "hax" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        delete "/v1/maker/projects/#{@project}", headers: auth(@b);                          assert_response :not_found
        get    "/v1/maker/projects/#{@project}/build_log_entries", headers: auth(@b);        assert_response :not_found
        delete "/v1/maker/build_log_entries/#{@entry}", headers: auth(@b);                   assert_response :not_found
        post   "/v1/maker/projects/#{@project}/file_attachments",
               params: { file_attachment: { node_id: "n" } }, as: :json, headers: auth(@b)
        assert_response :not_found
      end

      test "B's project index is empty" do
        get "/v1/maker/projects", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["projects"]
      end
    end
  end
end
