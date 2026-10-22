require "test_helper"

module V1
  module Maker
    # Cross-user isolation for the catalog controllers not covered elsewhere:
    # tags, taggings, file_attachments (destroy-by-id), previews.
    class CatalogIsolationTest < ActionDispatch::IntegrationTest
      def register(email) = bootstrap_token(email: email, device_name: "d")
      def auth(token) = { "Authorization" => "Bearer #{token}" }

      setup do
        @a = register("a-cat@example.com")
        @b = register("b-cat@example.com")
        @a_user = User.find_by(email: "a-cat@example.com")
        @b_user = User.find_by(email: "b-cat@example.com")
      end

      # ---- tags --------------------------------------------------------------
      test "B cannot delete A's tag and B's tag index is empty" do
        tag = @a_user.maker_tags.create!(name: "printed")
        delete "/v1/maker/tags/#{tag.id}", headers: auth(@b)
        assert_response :not_found
        assert ::Maker::Tag.exists?(tag.id)

        get "/v1/maker/tags", headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["tags"]
      end

      # ---- taggings ----------------------------------------------------------
      test "B cannot tag A's item (nested create 404s on the parent item)" do
        item = @a_user.maker_items.create!(title: "A widget")
        post "/v1/maker/items/#{item.id}/taggings", params: { name: "mine" },
             as: :json, headers: auth(@b)
        assert_response :not_found
        assert_equal 0, item.taggings.count
      end

      test "B cannot delete A's tagging by id" do
        item = @a_user.maker_items.create!(title: "A widget")
        tag  = @a_user.maker_tags.create!(name: "x")
        tagging = item.taggings.create!(user: @a_user, tag: tag)
        delete "/v1/maker/taggings/#{tagging.id}", headers: auth(@b)
        assert_response :not_found
        assert ::Maker::Tagging.exists?(tagging.id)
      end

      # ---- file_attachments --------------------------------------------------
      test "B cannot delete A's file attachment by id" do
        item = @a_user.maker_items.create!(title: "A widget")
        @a_user.nodes.create!(node_id: "node-1", name: "a.stl", kind: "file")
        att  = item.file_attachments.create!(user: @a_user, node_id: "node-1")
        delete "/v1/maker/file_attachments/#{att.id}", headers: auth(@b)
        assert_response :not_found
        assert ::Maker::FileAttachment.exists?(att.id)
      end

      test "B cannot attach a file to A's item (nested create 404s on the parent)" do
        item = @a_user.maker_items.create!(title: "A widget")
        post "/v1/maker/items/#{item.id}/file_attachments",
             params: { file_attachment: { node_id: "sneaky" } }, as: :json, headers: auth(@b)
        assert_response :not_found
        assert_equal 0, item.file_attachments.count
      end

      # ---- previews ----------------------------------------------------------
      test "B's preview index never returns A's previews" do
        @a_user.maker_previews.create!(node_id: "secret.svg", version_id: "v1", kind: "thumbnail")
        get "/v1/maker/previews", params: { node_id: "secret.svg" }, headers: auth(@b)
        assert_equal [], JSON.parse(response.body)["previews"]
      end

      test "B creating a preview for the same node_id makes a SEPARATE row (no cross-user collision)" do
        a_preview = @a_user.maker_previews.create!(node_id: "shared-name.svg", version_id: "v1",
                                                   kind: "thumbnail", status: "ready")
        post "/v1/maker/previews",
             params: { preview: { node_id: "shared-name.svg", version_id: "v1", kind: "thumbnail" } },
             as: :json, headers: auth(@b)
        assert_response :created
        b_id = JSON.parse(response.body)["id"]
        assert_not_equal a_preview.id, b_id
        assert_equal @b_user.id, ::Maker::Preview.find(b_id).user_id
        # A's preview is untouched (status not reset to pending).
        assert_equal "ready", a_preview.reload.status
      end
    end
  end
end
