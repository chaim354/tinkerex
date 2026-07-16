require "test_helper"

module V1
  module Maker
    class PreviewsTest < ActionDispatch::IntegrationTest
      setup do
        Storage::ChunkStore.reset!
      end

      def register(email: "p@example.com")
        bootstrap_token(email: email, device_name: "laptop")
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
        # The ONLY test in this file that stages chunk-shaped bytes, so it is the only one that
        # gets pinned. The other five (auth, tenant isolation, param validation, index filtering)
        # are genuinely backend-agnostic — pinning them too would shield them from the exact
        # ambient-dependence signal the ci.yml `test-share-backend` leg exists to produce.
        pin_file_layer_backend("chunk")
        token = register
        user  = User.find_by(email: "p@example.com")
        store = Storage::ChunkStore.current
        svg   = File.binread(Rails.root.join("test/fixtures/files/square.svg"))
        store.write_blob(user.id, "svgh", svg)
        ::ManifestChunk.create!(user_id: user.id, manifest_id: "m", chunk_hash: "svgh",
                                seq: 0, offset: 0, length: svg.bytesize)
        ::Version.create!(user_id: user.id, version_id: "vr", node_id: "ready.svg", manifest_id: "m")
        # A preview always belongs to a real, live node in production — FileLayer#read enforces
        # that (tombstoned = gone), so the fixture has to reflect reality.
        user.nodes.create!(node_id: "ready.svg", name: "ready.svg", kind: "file",
                           deleted: false, current_version_id: "vr")
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
