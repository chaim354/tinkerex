require "test_helper"

module V1
  # Controller-level mutation checks for Stage 3a Task 4 (Sync::Hooks, app/services/sync/hooks.rb):
  # the JSON V1::CommitsController#finalize sends the client must be byte-identical to today's
  # whether or not a hook subscriber raises, and byte-identical whether or not ANY subscriber is
  # registered at all. Both are asserted against the REAL endpoint rather than against Sync::Hooks
  # in isolation (test/services/sync/hooks_test.rb) -- "the response is unchanged" is a claim about
  # the controller's rendered JSON, not about the hook module's own return value.
  class CommitFinalizeHookTest < ActionDispatch::IntegrationTest
    setup do
      pin_file_layer_backend("chunk")
      Sync::Storage::ChunkStore.reset!
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    # begin -> PUT bytes -> finalize a one-chunk file. Returns the parsed finalize response body.
    def commit_file(token, name:, node_id: SecureRandom.uuid, hash: SecureRandom.hex(32))
      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: nil, name:, base_version_id: nil,
                     size: 5, manifest: [ { hash:, offset: 0, length: 5 } ] },
           as: :json, headers: auth(token)
      assert_response :success
      (JSON.parse(response.body)["put_urls"] || {}).each_value do |url|
        put url, params: "x", headers: { "CONTENT_TYPE" => "application/octet-stream" }
      end
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      JSON.parse(response.body)
    end

    test "a raising hook subscriber does not fail the commit, and the response body is unchanged" do
      token = bootstrap_token(email: "hook-raise@example.com")

      pin_sync_hooks_subscribers do
        Sync::Hooks.on_commit_finalized { |**| raise "boom from a fault-injected subscriber" }

        body = commit_file(token, name: "a.stl")

        # THE EXACT SHAPE #finalize RENDERS ON SUCCESS -- `render json: { version_id:, seq: }` --
        # asserted as a key SET, not merely "no error key present". A response carrying an extra
        # key (e.g. an accidentally-leaked error alongside a 200) would satisfy a weaker check and
        # still be a changed body.
        assert_equal %w[seq version_id], body.keys.sort
        assert body["version_id"].present?
        assert_equal 1, body["seq"]
      end
    end

    test "a raising hook subscriber does not block a later, working subscriber" do
      token = bootstrap_token(email: "hook-raise-then-work@example.com")

      pin_sync_hooks_subscribers do
        nudged = false
        Sync::Hooks.on_commit_finalized { |**| raise "boom" }
        Sync::Hooks.on_commit_finalized { |**| nudged = true }

        commit_file(token, name: "a.stl")

        assert nudged, "a subscriber registered after a raising one must still run"
      end
    end

    test "with no hook subscribers registered, a commit still succeeds with the same response shape" do
      token = bootstrap_token(email: "hook-none@example.com")

      pin_sync_hooks_subscribers do
        assert_empty Sync::Hooks.subscribers # the property under test: a bare host, nothing registered

        body = commit_file(token, name: "b.stl")

        assert_equal %w[seq version_id], body.keys.sort
        assert body["version_id"].present?
      end
    end
  end
end
