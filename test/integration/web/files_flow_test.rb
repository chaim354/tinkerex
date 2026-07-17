require "test_helper"

module Web
  # Exercises the server-rendered web UI end to end through the SAME presign + Sync::Commit
  # machinery the desktop client uses, with the memory chunk store backed by the dev blob
  # endpoint (so bytes actually round-trip without S3, while never going through v1/Rails).
  class FilesFlowTest < ActionDispatch::IntegrationTest
    # This suite's FIXTURES are chunk-shaped -- it uploads through Sync::Commit's two-phase flow
    # and asserts ManifestChunk rows -- so it is a chunk test and now has to SAY so. It did not
    # need to before Phase 4 Task 3: #blob reached for Storage::ChunkStore.current directly, which
    # ignores LIBRARY_BACKEND, so it passed on the share/s3 legs by being blind to the backend
    # rather than by being right. Routing #blob through FileLayer.current is what made the
    # dependency real, and the share leg reported it immediately (ActionController::MissingFile --
    # the Share adapter looking for these chunks' bytes on a disk that has none).
    #
    # That is the honest signal test_helper documents at pin_file_layer_backend, not a regression:
    # nothing about the assertions below changed, only the declaration of which deployment they
    # are about.
    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    # Sign in via the real password auth. Creates a confirmed account if needed, then
    # logs in (sets the signed session cookie) — the web UI works behind real auth.
    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "web@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
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
      assert_redirected_to new_user_session_path
    end

    # ---- Fix 9: sniffable user content is served as a download, never inline ---

    test "an SVG blob is served as an attachment (no stored XSS on the app origin)" do
      sign_in
      node_id = upload("evil.svg", "<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/attachment/, response.headers["Content-Disposition"], "SVG must not render inline")
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "an HTML blob is served as an attachment" do
      sign_in
      node_id = upload("page.html", "<html><body><script>alert(1)</script></body></html>".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/attachment/, response.headers["Content-Disposition"])
    end

    test "a PNG blob is still served inline (safe raster image)" do
      sign_in
      node_id = upload("pic.png", "\x89PNG\r\n\x1a\nfake".b)

      get blob_file_path(node_id)
      assert_response :success
      assert_match(/inline/, response.headers["Content-Disposition"], "raster images stay inline")
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

    # THE OTHER HALF OF CAPABILITY GATING, and the half a plan forgets. A gate that hides a
    # feature in share mode is half-right; a gate that hides it in the product's MAIN deployment
    # is a straightforward bug, and it is the easy one to ship -- `port_writable` reads like
    # "accepts uploads", which chunk mode very much does (that is what Sync::Commit IS).
    #
    # So this is the counterpart to share_delivery_test.rb's "does not offer a version": the same
    # two surfaces, asserted present rather than absent. Without it, a gate that fired everywhere
    # would leave both suites green while the product lost its upload button and its versions.
    test "chunk mode keeps version history and the upload control" do
      sign_in
      node_id = upload("v.stl", "bytes")

      get file_path(node_id)
      assert_response :success
      assert_match(/Current version/i, response.body,
                   "chunk is the versioned backend -- the gate must not fire here")
      assert_match(/5 Bytes/i, response.body, "size must survive the move from Version to the port")

      get files_path
      assert_match(/upload/i, response.body,
                   "chunk mode uploads via the two-phase flow -- port_writable: false does NOT " \
                   "mean 'no uploads', and reading it that way hides this button in production")
      # WHICH upload control, not just that one exists. Both branches of the view say "Upload a
      # file", so /upload/i alone stays green with the branch INVERTED -- chunk mode would render
      # the direct form, POST /files, and take a 501. Verified by mutation: only the share side
      # caught it. This is the chunk-side half.
      assert_match(/data-controller="uploader"/, response.body,
                   "chunk mode must drive the two-phase flow, not POST the bytes to the port")
    end

    # The other direction of the upload branch. Chunk mode CAN accept uploads -- it does so all
    # day via the two-phase presigned flow -- it just cannot take the bytes through Rails (§15).
    # So the direct endpoint is an honest 501, and it must NAME the flow that does work: a bare
    # 501 here would read as "uploads are off", which is exactly wrong.
    test "the direct upload answers 501 in chunk mode, naming the two-phase flow" do
      sign_in
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_response :not_implemented
      assert_match(/port_writable_unavailable/, response.body,
                   "the 501 must be the capability gate, not a routing or auth accident")
      assert_match(/begin_upload/, response.body,
                   "a refusal must name the path the caller SHOULD use -- as Chunk#write does")
    end

    # THE GATE IS NOT AUTH AND NOT A MISSING ROUTE, proven: the same POST, unauthenticated,
    # redirects to login. If POST /files were unrouted this would 404 instead, and the 501 above
    # would have proved nothing.
    test "the direct upload route exists and is behind auth" do
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_redirected_to new_user_session_path
    end

    test "isolation: a user cannot see or fetch another user's file" do
      sign_in("alice@example.com")
      alice_node = upload("secret.txt", "alice only".b)

      # Sign in as bob.
      delete destroy_user_session_path
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
