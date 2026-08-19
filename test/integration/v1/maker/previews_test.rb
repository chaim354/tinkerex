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

      # THE COST OF ONE ROW PER (node, kind): "which version" stopped being the client's to choose.
      # Honouring a POST for an old version would throw away the current render and repoint the
      # live row at content the library has moved past — and on share/s3, where there is no
      # history, at bytes that do not exist, so the render would then fail and leave the node with
      # NO preview. 422 naming the current version is the honest answer.
      test "POSTing a superseded version is refused rather than clobbering the current render" do
        pin_file_layer_backend("chunk")
        token = register(email: "stale@example.com")
        user  = User.find_by(email: "stale@example.com")
        user.nodes.create!(node_id: "moved.svg", name: "moved.svg", kind: "file",
                           deleted: false, current_version_id: "v2")

        assert_no_enqueued_jobs(only: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews", params: { preview: { node_id: "moved.svg", version_id: "v1" } },
               as: :json, headers: auth(token)
        end
        assert_response :unprocessable_entity
        assert_equal "v2", JSON.parse(response.body)["current_version_id"]
        assert_not ::Maker::Preview.exists?(node_id: "moved.svg")
      end

      test "POSTing the CURRENT version is accepted" do
        pin_file_layer_backend("chunk")
        token = register(email: "current@example.com")
        user  = User.find_by(email: "current@example.com")
        user.nodes.create!(node_id: "here.svg", name: "here.svg", kind: "file",
                           deleted: false, current_version_id: "v2")

        post "/v1/maker/previews", params: { preview: { node_id: "here.svg", version_id: "v2" } },
             as: :json, headers: auth(token)
        assert_response :created
        assert_equal "v2", JSON.parse(response.body)["version_id"]
      end

      # The gate can only refuse what the port can adjudicate. A node the backend cannot resolve —
      # never synced, already deleted, an unmounted share — gives no basis to reject, and rejecting
      # anyway would break a client rendering a node it is about to create. Every other test in
      # this file relies on that fall-through.
      test "a node the port cannot resolve falls through rather than 422-ing" do
        pin_file_layer_backend("chunk")
        token = register(email: "unknown@example.com")

        post "/v1/maker/previews", params: { preview: { node_id: "never-synced.svg", version_id: "v9" } },
             as: :json, headers: auth(token)
        assert_response :created
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

      # AN EXPLICIT `"kind": null` IS A CLIENT ERROR, AND THIS PINS THAT IT STAYS ONE.
      #
      # `attrs.fetch(:kind, "thumbnail")` defaults on an ABSENT key only, so a null reaches the
      # model and the `kind` inclusion validation refuses it — 422 via `V1::BaseController`'s
      # `rescue_from RecordInvalid`, zero rows. That is the right answer and is NOT a bug to be
      # tidied into a default: coercing an explicit null is normalization, and this repo rejects
      # rather than normalizes at every comparable seam (CLAUDE.md §14a's `key_for`, §14c's
      # `validate_asset_path!`, the addon SDK's path-segment rule).
      #
      # The client that was sending nulls was `sync-client`'s `enqueue_preview`, whose inline
      # `serde_json::json!` body had nowhere to hang `skip_serializing_if`; that was fixed on the
      # SENDING end. This test exists so the next reader who finds the 422 does not "fix" it here
      # instead — into a silent default, or into the 500 it would be without the rescue.
      #
      # NO ROWS, asserted separately from the status: a 422 rendered AFTER a save would look
      # identical from the status line alone.
      test "an explicit null kind is refused rather than defaulted" do
        token = register
        assert_no_difference -> { ::Maker::Preview.count } do
          post "/v1/maker/previews",
               params: { preview: { node_id: "n.svg", kind: nil } },
               as: :json, headers: auth(token)
        end
        assert_response :unprocessable_entity
        assert_match(/Kind/, JSON.parse(response.body)["error"])
      end

      # The absent-key half of the same line: omitting `kind` DOES get the documented default.
      # Both arms are needed — a fix that defaulted the null would keep this one green.
      test "an absent kind gets the thumbnail default" do
        token = register
        post "/v1/maker/previews", params: { preview: { node_id: "n.svg" } },
             as: :json, headers: auth(token)
        assert_response :created
        assert_equal "thumbnail", JSON.parse(response.body)["kind"]
      end
    end
  end
end
