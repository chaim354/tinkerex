require "test_helper"

module V1
  module Maker
    class FileAttachmentsTest < ActionDispatch::IntegrationTest
      def register
        bootstrap_token(email: "fa@example.com", device_name: "d")
      end

      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @token = register
        post "/v1/maker/items", params: { item: { title: "Lamp" } }, as: :json, headers: auth(@token)
        @item_id = JSON.parse(response.body)["id"]
      end

      test "attach a file to an item by node_id" do
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "node-abc", role: "model", label: "body.step" } },
             as: :json, headers: auth(@token)
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "node-abc", body["node_id"]
        assert_equal "model", body["role"]

        get "/v1/maker/items/#{@item_id}", headers: auth(@token)
        assert_equal 1, JSON.parse(response.body)["file_attachments"].size
      end

      test "detach a file" do
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "n1" } }, as: :json, headers: auth(@token)
        att_id = JSON.parse(response.body)["id"]
        delete "/v1/maker/file_attachments/#{att_id}", headers: auth(@token)
        assert_response :no_content
        get "/v1/maker/items/#{@item_id}", headers: auth(@token)
        assert_equal 0, JSON.parse(response.body)["file_attachments"].size
      end

      test "cannot attach to another user's item" do
        other = register_other
        post "/v1/maker/items/#{@item_id}/file_attachments",
             params: { file_attachment: { node_id: "n" } }, as: :json, headers: auth(other)
        assert_response :not_found
      end

      def register_other
        bootstrap_token(email: "other-fa@example.com", device_name: "d")
      end
    end
  end
end
