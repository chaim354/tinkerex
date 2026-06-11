require "test_helper"

module V1
  class SyncFlowTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def register(email: "maker@example.com", name: "laptop")
      post "/v1/auth/register", params: { email:, device_name: name }, as: :json
      assert_response :created
      JSON.parse(response.body)
    end

    def auth(token) = { "Authorization" => "Bearer #{token}" }

    def manifest(*pairs)
      pairs.map { |h, len, off| { hash: h, offset: off || 0, length: len } }
    end

    def commit_file(token, name:, chunks:, node_id: SecureRandom.uuid, parent: nil, base: nil)
      cid = SecureRandom.uuid
      size = chunks.sum { |c| c[:length] }
      post "/v1/commit",
           params: { commit_id: cid, node_id:, parent_node_id: parent, name:,
                     base_version_id: base, size:, manifest: chunks },
           as: :json, headers: auth(token)
      assert_response :success
      began = JSON.parse(response.body)
      post "/v1/commit/#{cid}/finalize", params: {}, as: :json, headers: auth(token)
      assert_response :success
      [began, JSON.parse(response.body), node_id]
    end

    test "register -> commit -> finalize -> changes -> tree" do
      token = register["device_token"]
      chunks = [{ hash: "a" * 64, offset: 0, length: 100 }, { hash: "b" * 64, offset: 100, length: 50 }]

      began, fin, node_id = commit_file(token, name: "part.stl", chunks:)
      assert_equal 2, began["missing"].size
      assert began["put_urls"].key?("a" * 64)
      assert fin["version_id"].present?
      assert_equal 1, fin["seq"]

      get "/v1/changes", params: { since: 0 }, headers: auth(token)
      assert_response :success
      ch = JSON.parse(response.body)
      assert_equal 1, ch["head_seq"]
      assert_equal 1, ch["changes"].size
      entry = ch["changes"].first
      assert_equal "put", entry["op"]
      assert_equal "part.stl", entry["node"]["name"]
      assert_equal 2, entry["manifest"].size

      get "/v1/tree", headers: auth(token)
      assert_response :success
      tree = JSON.parse(response.body)
      assert_equal 1, tree["nodes"].size
      assert_equal "part.stl", tree["nodes"].first["name"]
      assert_equal 2, tree["nodes"].first["manifest"].size
    end

    test "dedup: shared chunk reported as not-missing on the second file" do
      token = register["device_token"]
      x, y, z = "x" * 64, "y" * 64, "z" * 64
      commit_file(token, name: "a.bin", chunks: [{ hash: x, offset: 0, length: 10 }, { hash: y, offset: 10, length: 10 }])

      cid = SecureRandom.uuid
      post "/v1/commit",
           params: { commit_id: cid, node_id: SecureRandom.uuid, name: "b.bin", size: 20,
                     manifest: [{ hash: y, offset: 0, length: 10 }, { hash: z, offset: 10, length: 10 }] },
           as: :json, headers: auth(token)
      assert_response :success
      began = JSON.parse(response.body)
      assert_equal [z], began["missing"], "only the new chunk z is missing; y is deduped"
    end

    test "mkdir, move, delete, versions, and restore" do
      token = register["device_token"]
      user = User.find_by(email: "maker@example.com")

      # mkdir
      dir_id = SecureRandom.uuid
      post "/v1/nodes", params: { node_id: dir_id, name: "Projects" }, as: :json, headers: auth(token)
      assert_response :created

      # commit two versions of the same file
      node_id = SecureRandom.uuid
      _, fin1, _ = commit_file(token, name: "box.lbrn2", node_id:, parent: dir_id,
                               chunks: [{ hash: "1" * 64, offset: 0, length: 5 }])
      _, _fin2, _ = commit_file(token, name: "box.lbrn2", node_id:, parent: dir_id, base: fin1["version_id"],
                                chunks: [{ hash: "2" * 64, offset: 0, length: 7 }])

      get "/v1/nodes/#{node_id}/versions", headers: auth(token)
      assert_response :success
      versions = JSON.parse(response.body)["versions"]
      assert_equal 2, versions.size

      # restore to the first version
      first_version_id = fin1["version_id"]
      post "/v1/nodes/#{node_id}/restore", params: { version_id: first_version_id }, as: :json, headers: auth(token)
      assert_response :success

      node = user.nodes.find_by(node_id:)
      assert_equal "1" * 64, node.current_version.manifest_chunks.first.chunk_hash,
                   "restore points current version at the old manifest's chunks"

      # move + delete
      post "/v1/nodes/#{node_id}/move", params: { new_name: "renamed.lbrn2" }, as: :json, headers: auth(token)
      assert_response :success
      assert_equal "renamed.lbrn2", user.nodes.find_by(node_id:).name

      delete "/v1/nodes/#{node_id}", headers: auth(token)
      assert_response :success
      assert user.nodes.find_by(node_id:).deleted
    end

    test "auth is required" do
      get "/v1/tree"
      assert_response :unauthorized
    end
  end
end
