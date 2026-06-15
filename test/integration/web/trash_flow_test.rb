require "test_helper"

module Web
  # The server-rendered Trash view: deleted files show up here (name + size + when),
  # a Restore button un-tombstones them and returns them to the normal file listing,
  # and a user can never see/restore another user's trash.
  class TrashFlowTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    def sign_in(email = "web-trash@example.com")
      post login_path, params: { email: }
      User.find_by(email:)
    end

    def upload(name, bytes)
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name:, size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      begun = JSON.parse(response.body)
      (begun["put_urls"] || {}).each_value do |url|
        put url, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" }
        assert_response :ok
      end
      post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
      assert_response :success
      begun["node_id"]
    end

    test "requires login" do
      get trash_index_path
      assert_redirected_to login_path
    end

    test "deleted file appears in trash, not in the file list" do
      sign_in
      node_id = upload("doomed.txt", "bye".b)
      delete file_path(node_id)

      get files_path
      assert_response :success
      assert_select "a", text: "doomed.txt", count: 0

      get trash_index_path
      assert_response :success
      assert_select "h1", "Trash"
      assert_select "td", text: "doomed.txt"
    end

    test "empty trash shows the empty state" do
      sign_in
      get trash_index_path
      assert_response :success
      assert_select ".empty", text: /Trash is empty/
    end

    test "restore returns the file to the normal listing" do
      sign_in
      node_id = upload("restore-me.txt", "alive".b)
      delete file_path(node_id)

      post restore_trash_path(node_id)
      assert_redirected_to files_path
      follow_redirect!
      assert_select "a", text: "restore-me.txt"

      user = User.find_by(email: "web-trash@example.com")
      assert_not user.nodes.find_by(node_id:).deleted?
      # No new version/chunk was created by the restore (re-points the kept version).
      assert_equal 1, user.versions.where(node_id:).count

      # Trash is now empty.
      get trash_index_path
      assert_select ".empty", text: /Trash is empty/
    end

    test "isolation: a user cannot see or restore another user's trash" do
      sign_in("alice-web@example.com")
      alice_node = upload("alice-secret.txt", "alice".b)
      delete file_path(alice_node)

      delete logout_path
      sign_in("bob-web@example.com")

      # Bob's trash is empty.
      get trash_index_path
      assert_response :success
      assert_select "td", text: "alice-secret.txt", count: 0

      # Bob can't restore alice's node (scoped lookup -> not found -> redirect).
      post restore_trash_path(alice_node)
      assert_redirected_to trash_index_path

      # Still deleted for alice.
      assert User.find_by(email: "alice-web@example.com").nodes.find_by(node_id: alice_node).deleted?
    end
  end
end
