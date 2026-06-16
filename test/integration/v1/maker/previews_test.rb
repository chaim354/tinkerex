require "test_helper"

module V1
  module Maker
    class PreviewsTest < ActionDispatch::IntegrationTest
      setup { Storage::ChunkStore.reset! }

      def register(email: "p@example.com")
        post "/v1/auth/register", params: { email:, device_name: "laptop" }, as: :json
        assert_response :created
        JSON.parse(response.body)["device_token"]
      end

      def auth(t) = { "Authorization" => "Bearer #{t}" }

      test "create enqueues a preview (pending) and is idempotent per node/version/kind" do
        token = register
        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews",
               params: { preview: { node_id: "n1.svg", version_id: "v1" } },
               as: :json, headers: auth(token)
        end
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal "pending", body["status"]
        assert_equal "thumbnail", body["kind"]
        assert_equal "n1.svg", body["node_id"]

        # second call returns the same record, doesn't duplicate
        post "/v1/maker/previews",
             params: { preview: { node_id: "n1.svg", version_id: "v1" } },
             as: :json, headers: auth(token)
        assert_response :success
        assert_equal 1, ::Maker::Preview.where(node_id: "n1.svg").count
      end

      test "index filters by node_id and version_id, scoped to the user" do
        token = register
        post "/v1/maker/previews", params: { preview: { node_id: "a", version_id: "v" } },
             as: :json, headers: auth(token)
        get "/v1/maker/previews?node_id=a&version_id=v", headers: auth(token)
        assert_response :success
        items = JSON.parse(response.body)["previews"]
        assert_equal 1, items.size
        assert_equal "a", items.first["node_id"]
      end

      test "index returns an asset url once the preview is ready" do
        token = register
        user  = User.find_by(email: "p@example.com")
        store = Storage::ChunkStore.current
        svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
        store.write_blob(user.id, "svgh", svg)
        ::ManifestChunk.create!(user_id: user.id, manifest_id: "m", chunk_hash: "svgh",
                                seq: 0, offset: 0, length: svg.bytesize)
        ::Version.create!(user_id: user.id, version_id: "vr", node_id: "ready.svg", manifest_id: "m")
        preview = user.maker_previews.create!(node_id: "ready.svg", version_id: "vr")
        ::Maker::GeneratePreviewJob.perform_now(preview.id, filename: "ready.svg")
        assert_equal "ready", preview.reload.status

        get "/v1/maker/previews?node_id=ready.svg", headers: auth(token)
        assert_response :success
        item = JSON.parse(response.body)["previews"].first
        assert_equal "ready", item["status"]
        assert item["url"].present?, "ready preview should expose a blob url"
      end

      test "requires auth" do
        get "/v1/maker/previews?node_id=a"
        assert_response :unauthorized
      end

      test "users cannot see each other's previews (tenant isolation)" do
        token_a = register(email: "a@example.com")
        token_b = register(email: "b@example.com")

        post "/v1/maker/previews", params: { preview: { node_id: "secret", version_id: "v" } },
             as: :json, headers: auth(token_a)
        assert_response :created

        # B lists the same node → sees nothing
        get "/v1/maker/previews?node_id=secret", headers: auth(token_b)
        assert_response :success
        assert_empty JSON.parse(response.body)["previews"]

        # B creating against the same node gets B's OWN distinct record
        post "/v1/maker/previews", params: { preview: { node_id: "secret", version_id: "v" } },
             as: :json, headers: auth(token_b)
        assert_response :created
        assert_equal 2, ::Maker::Preview.where(node_id: "secret").count
      end

      test "create requires the preview param" do
        token = register
        post "/v1/maker/previews", params: {}, as: :json, headers: auth(token)
        assert_response :bad_request
      end
    end
  end
end
