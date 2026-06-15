require "test_helper"

module Web
  # Exercises the server-rendered web UI end to end through the SAME presign + Sync::Commit
  # machinery the desktop client uses, with the memory chunk store backed by the dev blob
  # endpoint (so bytes actually round-trip without S3, while never going through v1/Rails).
  class FilesFlowTest < ActionDispatch::IntegrationTest
    setup { Storage::ChunkStore.reset! }

    # Sign in via the placeholder dev login.
    def sign_in(email = "web@example.com")
      post login_path, params: { email: }
      User.find_by(email:)
    end

    # Mirror the browser uploader: hash -> begin_upload -> PUT bytes -> finalize_upload.
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
      get files_path
      assert_redirected_to login_path
    end

    test "placeholder login signs in and lists files" do
      sign_in
      get files_path
      assert_response :success
      assert_select "h1", "Files"
    end

    test "upload -> list -> download byte-for-byte" do
      sign_in
      bytes = "hello tinkerex \x00\x01\x02 binary".b
      node_id = upload("notes.txt", bytes)

      # Appears in the list.
      get files_path
      assert_response :success
      assert_select "a", text: "notes.txt"

      # A version + content-addressed chunk were recorded through Sync::Commit.
      user = User.find_by(email: "web@example.com")
      assert_equal 1, user.nodes.present.where(kind: "file").count
      assert user.versions.where(node_id:).exists?
      assert user.chunks.where(chunk_hash: Digest::SHA256.hexdigest(bytes)).exists?

      # Download returns the exact bytes.
      get blob_file_path(node_id, download: 1)
      assert_response :success
      assert_equal bytes, response.body.b
    end

    test "dedup: re-uploading identical content uploads no new chunk" do
      sign_in
      bytes = "duplicate me".b
      upload("a.txt", bytes)

      # Second begin for the same content should report nothing missing (chunk exists).
      hash = Digest::SHA256.hexdigest(bytes)
      manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
      post begin_upload_files_path, params: { name: "b.txt", size: bytes.bytesize, manifest: }, as: :json
      assert_response :success
      assert_empty JSON.parse(response.body)["put_urls"]
    end

    test "image preview renders an <img> to the blob endpoint" do
      sign_in
      png = "\x89PNG\r\n\x1a\nfake-image-bytes".b
      node_id = upload("pic.png", png)

      get file_path(node_id)
      assert_response :success
      assert_select "img.preview-image"
    end

    test "text preview page renders the text container" do
      sign_in
      node_id = upload("readme.md", "# Hello\nworld".b)
      get file_path(node_id)
      assert_response :success
      assert_select "pre.preview-text"
    end

    test "unknown type falls back to a download link" do
      sign_in
      node_id = upload("model.stl", "solid cube".b)
      get file_path(node_id)
      assert_response :success
      assert_select ".preview-fallback"
    end

    test "delete tombstones the node and removes it from the list" do
      sign_in
      node_id = upload("trash.txt", "bye".b)
      delete file_path(node_id)
      assert_redirected_to files_path

      user = User.find_by(email: "web@example.com")
      assert user.nodes.find_by(node_id:).deleted?, "node should be tombstoned"
      assert_equal 0, user.nodes.present.count
      # Version is retained (keep-versions rule).
      assert user.versions.where(node_id:).exists?
    end

    test "isolation: a user cannot see or fetch another user's file" do
      sign_in("alice@example.com")
      alice_node = upload("secret.txt", "alice only".b)

      # Sign in as bob.
      delete logout_path
      sign_in("bob@example.com")

      # Bob's library has no such node -> not found (never alice's bytes).
      get blob_file_path(alice_node)
      assert_redirected_to files_path
      assert_equal 0, User.find_by(email: "bob@example.com").nodes.present.count

      get file_path(alice_node)
      assert_redirected_to files_path
    end
  end
end
