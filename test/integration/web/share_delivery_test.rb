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

    # --- Acceleration: TWO tests, because either one alone proves nothing ------------------
    #
    # When Rack::Sendfile accelerates it sets Content-Length: 0 and REPLACES THE BODY WITH [].
    # So "sent the header" and "served the bytes" are MUTUALLY EXCLUSIVE outcomes: a test
    # asserting only the header passes while serving nothing, and a test asserting only the
    # bytes passes while the header silently never fires. Both, or neither means anything.
    #
    # The nastiest version of that: acceleration engages ONLY when the body responds to
    # `to_path` (rack-3.2.6/lib/rack/sendfile.rb:131). send_file's body does; send_data's never
    # does. A send_data implementation would pass every bytes test in this file forever while
    # making the whole mechanism permanently dead code, with nothing red anywhere.
    test "with no sendfile variation -- THIS deployment -- Rails serves the bytes itself" do
      id = index!("plain.stl", "real bytes")
      get blob_file_path(id)

      assert_response :success
      assert_equal "real bytes", response.body,
                   "no proxy here (Kamal + kamal-proxy, not nginx): Rack::Files must actually serve"
      assert_nil response.headers["x-sendfile"], "nothing to hand off to"
    end

    # The accelerated path.
    #
    # THE VARIATION IS SET VIA rack env, NOT VIA Rails.application.config, and that is a
    # correction to this task's plan rather than a shortcut. Rails builds the middleware stack
    # ONCE at boot -- `middleware.use ::Rack::Sendfile, config.action_dispatch.x_sendfile_header`
    # -- so Rack::Sendfile's @variation is frozen to nil here before any test runs (verified:
    # the stack's Sendfile entry has args == [nil]). Mutating the config mid-suite reaches
    # nothing. Rack::Sendfile#variation is `@variation || env["sendfile.type"]`, so env is the
    # only seam that exists after boot, and it is the SAME branch production takes.
    #
    # It is not a security hole either: `sendfile.type` is a rack env key, not an HTTP header.
    # Rack maps request headers to HTTP_* keys only, so no client can set it -- which is exactly
    # why Rack deliberately stopped reading HTTP_X_SENDFILE_TYPE (see its `variation` comment).
    #
    # x-sendfile rather than x-accel-redirect on purpose: Rack's x-accel-redirect branch ALSO
    # needs an x-accel-mapping header from nginx to translate the filesystem path into an
    # internal URI, and without one it logs "x-accel-mapping header missing" to rack.errors and
    # serves normally -- it fails safe, and silently. That asymmetry is the real X-Accel footgun,
    # and it is why the knob is DOCUMENTED for the operator instead of shipped as our own code.
    test "with a sendfile variation, the proxy gets the path and the body is empty" do
      id = index!("accel.stl", "real bytes")

      get blob_file_path(id), env: { "sendfile.type" => "x-sendfile" }

      assert_equal @root.join("accel.stl").to_s, response.headers["x-sendfile"],
                   "the proxy must be handed the real filesystem path -- which needs a body " \
                   "that responds to to_path, i.e. send_file and never send_data"
      assert_equal "0", response.headers["Content-Length"]
      assert_empty response.body, "when accelerated Rack replaces the body -- WE must not serve"
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

    # --- LANDMINE 5: the page must stop lying ----------------------------------------------
    #
    # Fixing #blob while `show` still reads Version ships a page that calls the file EMPTY next
    # to a Download button that works. The view is not wrong about Version -- there genuinely is
    # no Version here -- it is asking the wrong object. Version is a chunk-mode concept; the port
    # is the backend-neutral one, which is why routing the views through FileLayer#stat is the
    # same fix as #blob rather than scope creep.
    test "the show page reports the real size and does NOT say 'No content yet'" do
      id = index!("bracket.stl", "solid bracket")
      get file_path(id)

      assert_response :success
      assert_no_match(/No content yet/, response.body,
                      "the file has 13 bytes sitting on the user's NAS")
      assert_match(/13 Bytes/i, response.body)
    end

    # THIS IS NOT THE PLAN'S TEST, AND THE PLAN'S VERSION WAS DECORATION. It asserted
    # no_match(/Restore/i) and no_match(/Version history/i) on the show page -- but the web UI
    # has no Restore and no version-history surface on this page at all (they are the Tauri
    # app's), so both assertions pass with this task's implementation reverted, with the view
    # deleted, and indeed with Phase 4 never written. They pin nothing.
    #
    # The version-shaped thing that IS on this page is the "Current version" row, and it is the
    # one that must disappear on an unversioned backend. Unlike the plan's, this test is red
    # before the implementation -- verified.
    test "the show page does not offer a version on an unversioned backend" do
      id = index!("bracket.stl", "solid")
      get file_path(id)

      assert_response :success
      assert_no_match(/Current version/i, response.body,
                      "share keeps no history (capabilities.versioned? == false) -- do not offer it")
    end

    # The index had the same bug in a second spelling: @versions_by_node comes from
    # current_user.versions, which is empty in share mode, so every Size cell rendered an
    # em-dash. Asserting only that the filenames appear -- the plan's version -- passes today,
    # before any of this, because listing `nodes` was never the broken part.
    #
    # BOTH FILES AT ROOT, not one nested in cad/ as this test first read: the index now scopes to
    # ONE folder's children (folder navigation), so a nested cad/b.stl no longer appears on the
    # root page — it lives inside cad. The point of this test is real sizes vs the em-dash of a
    # missing Version, which two root files prove exactly as well; the nesting was incidental. See
    # folder_nav_test.rb for the child-scoping itself.
    test "the index reports real sizes, not the em-dash of a Version that does not exist" do
      index!("a.stl", "aaa")
      index!("b.stl", "bbbb")
      get files_path

      assert_response :success
      assert_match(/a\.stl/, response.body)
      assert_match(/b\.stl/, response.body)
      assert_match(/3 Bytes/, response.body)
      assert_match(/4 Bytes/, response.body)
    end

    # --- The upload branch, share side ------------------------------------------------------
    #
    # Both directions are honest 501s: share has no chunk store to presign into, and chunk mode
    # genuinely cannot take bytes through Rails (§15). See files_flow_test.rb for the other half.

    # Share mode has no chunk store, so there is nothing to presign into and no manifest to begin.
    # 501 -- "this deployment can't do that" -- rather than a 500 out of Sync::Commit or (worse) a
    # pending_commit that can never be finalized.
    test "begin_upload answers 501 in share mode" do
      post begin_upload_files_path,
           params: { name: "x.stl", size: 1, manifest: [ { hash: "a" * 64, offset: 0, length: 1 } ] },
           as: :json
      assert_response :not_implemented
      # The body, not just the status: a missing route and a halted filter both look like this
      # from the outside. And the refusal must name the door that WORKS -- a bare "no" reads as
      # "uploads are off", which is exactly wrong on a backend that uploads fine.
      assert_match(/syncable_unavailable/, JSON.parse(response.body)["error"].to_s)
      assert_match(/upload/i, JSON.parse(response.body)["error"].to_s)
    end

    test "finalize_upload answers 501 in share mode" do
      post finalize_upload_files_path, params: { commit_id: SecureRandom.uuid }, as: :json
      assert_response :not_implemented
      assert_match(/syncable_unavailable/, JSON.parse(response.body)["error"].to_s)
    end

    # The share/s3 flow: the bytes come straight up in a multipart POST and land on the port.
    test "the direct upload writes through the port in share mode" do
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("uploaded bytes"), "application/octet-stream",
                                           original_filename: "up.stl")
      }
      assert_response :redirect
      assert_equal "uploaded bytes", File.binread(@root.join("up.stl")), "the bytes must reach the NAS"
      assert @user.nodes.find_by(storage_path: "up.stl"), "and the node must be indexed"
    end

    # WHAT THE USER IS TOLD, which is the whole of this bug -- and the reason it is asserted here
    # and not only in the adapter's suite. Share#write has always refused a clobber and the bytes
    # have always survived; it raised NotFound to do it, and FilesController maps that to "File
    # not found." So the user re-uploaded a name they already had, watched the app tell them the
    # file was missing, and could see it in the list behind the alert. The adapter tests could not
    # catch that -- they assert a class, and the class was the bug.
    test "a duplicate-name upload says the name is taken, not 'File not found'" do
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("first"), "application/octet-stream",
                                           original_filename: "dupe.stl")
      }
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("second"), "application/octet-stream",
                                           original_filename: "dupe.stl")
      }

      assert_redirected_to files_path
      assert_match(/already exists/, flash[:alert])
      assert_no_match(/not found/i, flash[:alert],
                      "the file is demonstrably there -- NotFound is the one thing this is not")
      assert_equal "first", File.binread(@root.join("dupe.stl")), "the original bytes survive"
    end

    # The button has to match the flow. The JS uploader drives begin_upload, which now 501s here,
    # so rendering it in share mode would ship a button that cannot work -- Landmine 5's shape,
    # one task later: the API tells the truth while the page still lies.
    test "the index offers the direct upload form, not the two-phase uploader" do
      get files_path
      assert_response :success
      assert_match(/upload/i, response.body, "share mode uploads -- the control must be there")
      assert_no_match(/data-controller="uploader"/, response.body,
                      "the two-phase uploader drives begin_upload, which answers 501 here")
    end

    # An unmounted library is not a missing file, and keeping those two apart is the whole point
    # of FetchError. Before this task Share#download raised it and NOTHING rescued it -> a 500.
    # Task 5/6 deliberately left it: a lone rescue in one action would have been a second copy of
    # a mapping that belongs at the controller, next to the 404 it must not become.
    #
    # 503 for a machine: retryable, and distinguishable from "gone" by status alone. The HTML
    # branch redirects with an honest alert instead, matching the shipped RecordNotFound handler
    # exactly -- and what matters in both is the SAME thing: never "your file is gone", which is
    # terminal and false. The library is fine; we could not reach it this second.
    test "an unmounted library is 503 to a client -- NOT 'your file is gone'" do
      id = index!("mounted.stl", "bytes")
      # Emptiness is how Share detects an unmounted mount point (see Share#mounted?).
      FileUtils.rm_rf(Dir.glob(@root.join("*")))

      get blob_file_path(id), as: :json
      assert_response :service_unavailable
      assert_equal "fetch_error", JSON.parse(response.body)["error"]
      assert_no_match(/not_found/, response.body.to_s, "'gone' is terminal; this is not")
    end

    test "an unmounted library tells the browser to retry, and does not say the file is gone" do
      id = index!("mounted2.stl", "bytes")
      FileUtils.rm_rf(Dir.glob(@root.join("*")))

      get blob_file_path(id)
      assert_redirected_to files_path
      assert_match(/reach your library/i, flash[:alert])
      assert_no_match(/not found/i, flash[:alert].to_s)
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
