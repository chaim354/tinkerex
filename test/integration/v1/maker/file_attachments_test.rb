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
        @user = User.find_by!(email: "fa@example.com")
        %w[node-abc n1].each { |id| @user.nodes.create!(node_id: id, name: "#{id}.step", kind: "file") }
      end

      # PENTEST I2c (tinkerex#467): the API wrote whatever node_id it was posted. It now answers 422
      # for an id this user's library does not hold, whether it names nothing or another tenant's
      # file (Maker::FileAttachment#node_belongs_to_user).
      test "attaching a node outside the user's own library is refused" do
        register_other
        User.find_by!(email: "other-fa@example.com").nodes.create!(node_id: "theirs", name: "theirs.step", kind: "file")

        %w[theirs no-such-node].each do |node_id|
          assert_no_difference -> { ::Maker::FileAttachment.count } do
            post "/v1/maker/items/#{@item_id}/file_attachments",
                 params: { file_attachment: { node_id:, role: "model" } }, as: :json, headers: auth(@token)
            assert_response :unprocessable_entity
          end
          assert_match(/must be a file in your own library/, JSON.parse(response.body)["error"])
        end
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
