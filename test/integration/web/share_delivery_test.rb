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

    # LANDMINE 2, at the layer it actually moved to. Task 2 pins that Share#download refuses a
    # poisoned path. This pins the OTHER half: that the controller does not resolve one itself.
    # The guard lives in exactly one place -- Share#absolute_path -- and a controller that
    # builds or re-validates a path either bypasses it or becomes a second copy that drifts.
    #
    # update_column bypasses validation on purpose: this is a row a future bug could produce, not
    # one a caller can make today. storage_path is written by our own observer (a walk under the
    # root) or by Share#write (already guarded) -- but it is a plain DB column, and 2b's #write
    # takes a `name` from the UI. "No caller passes anything bad today" is the assumption that
    # ages badly, and Delivery::SendFile is a Data object anyone can construct with anything, so
    # the type carries no guarantee whatsoever.
    # THE `..` COUNT IS COMPUTED, NOT WRITTEN DOWN, and that is the whole test. A literal
    # "../../../etc/passwd" -- this test's first draft -- lands on /var/folders/24/etc/passwd from
    # a macOS tmpdir six levels deep. That path does not exist, so the request 404s on ENOENT and
    # the test passes IDENTICALLY with the escape guard deleted: verified by mutation, it was the
    # only one of these two that stayed green. It asserted nothing about traversal at all.
    #
    # The depth of Dir.mktmpdir is environment-specific (a Linux CI runner's /tmp is two levels,
    # this box's is six), so no hardcoded count is right everywhere -- which means a literal is
    # not merely wrong here, it is untrustworthy anywhere. relative_path_from computes the exact
    # payload that reaches /etc/passwd from wherever the root actually is.
    test "a poisoned storage_path cannot be downloaded through the controller" do
      id = index!("innocent.stl", "b")
      File.binwrite(@root.join("decoy.stl"), "so the library does not look unmounted")
      traversal = Pathname.new("/etc/passwd").relative_path_from(@root).to_s
      assert_equal "/etc/passwd", @root.join(traversal).expand_path.to_s,
                   "the payload must actually reach /etc/passwd, or this test proves nothing"
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, traversal)

      get blob_file_path(id)

      assert_not_equal File.read("/etc/passwd"), response.body, "traversal must not serve"
      assert_not_includes response.body.to_s, "root:", "and must not leak /etc/passwd's contents"
    end

    # An absolute storage_path is the same attack with a different spelling: root.join("/etc/x")
    # in Pathname yields "/etc/x", NOT root + "/etc/x". A guard testing only for ".." misses it.
    test "an ABSOLUTE storage_path cannot be downloaded either" do
      id = index!("innocent2.stl", "b")
      File.binwrite(@root.join("decoy2.stl"), "so the library does not look unmounted")
      @user.nodes.find_by!(node_id: id).update_column(:storage_path, "/etc/passwd")

      get blob_file_path(id)
      assert_not_includes response.body.to_s, "root:"
    end
  end
end
