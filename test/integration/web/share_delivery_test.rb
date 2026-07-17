require "test_helper"

module Web
  # Share-mode byte delivery through the real controller. Verified before this task: blob 404s
  # in share mode -- node.current_version is nil, so it raises RecordNotFound. That was correct
  # by scope in 2a/2b; this is where it is paid off.
  #
  # These use `FileLayer.current =` rather than test_helper's `pin_file_layer_backend`, because
  # a Share adapter needs a tmpdir ROOT and pin_file_layer_backend rebuilds from ENV -- it would
  # additionally need ENV["LIBRARY_PATH"], which its teardown does not restore. The trade is that
  # a direct assignment does not set @file_layer_backend_pinned either, so test_helper's teardown
  # will NOT clean up after it: the FileLayer.reset! below is load-bearing, not decoration.
  # Without it the adapter leaks into the next test in this forked worker.
  class ShareDeliveryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = Pathname.new(Dir.mktmpdir("share-delivery"))
      @user = User.create!(email: "sd-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end
    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def index!(rel, bytes)
      path = @root.join(rel)
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, bytes)
      Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
      @user.nodes.find_by!(storage_path: rel).node_id
    end

    test "a share-backed file downloads -- it used to 404" do
      id = index!("bracket.stl", "solid bracket")
      get blob_file_path(id)
      assert_response :success
      assert_equal "solid bracket", response.body
    end

    test "the filename reaches the browser" do
      id = index!("bracket.stl", "solid")
      get blob_file_path(id, download: 1)
      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_match(/bracket\.stl/, response.headers["Content-Disposition"])
    end

    # The stored-XSS policy is the CONTROLLER's and must not vary by backend. These mirror
    # files_flow_test.rb's chunk-mode cases exactly -- the same button, the same answer.
    test "an SVG is served as an attachment on the share backend too" do
      id = index!("evil.svg", "<svg onload=alert(1)></svg>")
      get blob_file_path(id)
      assert_match(/attachment/, response.headers["Content-Disposition"])
      assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    end

    test "an HTML file is served as an attachment on the share backend too" do
      id = index!("evil.html", "<script>alert(1)</script>")
      get blob_file_path(id)
      assert_match(/attachment/, response.headers["Content-Disposition"])
    end

    test "a PNG is served inline, as it is in chunk mode" do
      id = index!("ok.png", "\x89PNG\r\n\x1a\n".b)
      get blob_file_path(id)
      assert_match(/inline/, response.headers["Content-Disposition"])
    end

    test "another user's node is 404, never their bytes" do
      id = index!("mine.stl", "secret")
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other.email, password: PASSWORD } }

      get blob_file_path(id)
      assert_not_equal "secret", response.body, "a node lookup must be scoped to current_user"
    end

    # A node whose bytes vanished from the NAS: the row is there, the file is not. It must be a
    # clean 404, not a 500 -- and it must not leak the absolute path of the library root.
    #
    # The decoy is not decoration: Share#download's ENOENT branch answers FetchError, not
    # NotFound, when the root looks UNMOUNTED (an unmounted NAS must never read as "your file is
    # permanently gone" -- spec §6). An empty root looks unmounted, so without a second file this
    # would take the FetchError path and pass, or fail, for a reason it does not name.
    #
    # `assert_redirected_to` + the flash, NOT a bare assert_response :redirect: before this task
    # blob 404d here ALREADY, for the wrong reason (node.current_version was nil), and it produced
    # this same 302 to this same path. A status-only assertion passes identically on the bug and
    # on the fix. What actually distinguishes them is upstream -- the "it used to 404" test above,
    # which fails against the old code -- so what this one is for is the OTHER regression: that a
    # vanished file is not a 500. It fails without Share#download's stat (verified by mutation:
    # ActionController::MissingFile, which maps to :internal_server_error).
    test "a node whose file vanished is a clean 404, and leaks no path" do
      id = index!("vanishing.stl", "b")
      File.unlink(@root.join("vanishing.stl"))
      File.binwrite(@root.join("other.stl"), "so the library does not look unmounted")

      get blob_file_path(id)

      assert_redirected_to files_path
      assert_equal "File not found.", flash[:alert]
      assert_not_includes response.body.to_s, @root.to_s, "never leak the library root"
    end
  end
end
