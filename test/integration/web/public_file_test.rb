require "test_helper"
require "support/public_fixture"
require_relative "../../support/fake_s3"

module Web
  # STAGE 3, S3-4: /u/:handle/:slug/files/:id — the bytes of a file a published project shows.
  #
  # TWO THINGS ARE ON TRIAL HERE AND THEY ARE DIFFERENT. The DELIVERY is FileDelivery's, shared
  # verbatim with FilesController#blob, so what is new about it is only that a sessionless route
  # reaches it — asserted through a helper that branches on `FileLayer.current.capabilities`, never
  # on an adapter class (§14a), with both arms genuinely taken: the bulk of the suite runs on a
  # pinned share library and the redirect test pins S3 with FakeS3, mirroring s3_delivery_test.rb.
  # The PERMISSION is Maker::PublicProject's, and it is the whole reason this route can exist at
  # all — nine of the tests below are one refusal each.
  #
  # WHY THE SHARE PIN RATHER THAN THE AMBIENT BACKEND: these tests fetch REAL BYTES, and a
  # create_node! fixture has an object behind it only on share (test/support/public_fixture.rb's
  # header). Pinning also keeps the run counts identical across the three legs, which §15 requires.
  class PublicFileTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
    end

    teardown { FileLayer.reset! }

    def file_path_for(node_id, **opts) = public_file_path("ada", @project.slug, node_id, **opts)

    def disposition_of(url) = CGI.parse(URI(url).query)["response-content-disposition"].first.to_s

    # TWO ARMS, ASKED OF THE CAPABILITIES AND NEVER OF A CLASS. `presignable?` is the redirect
    # backend (s3, pinned below with FakeS3); everything else answers in-band with headers. Each
    # arm asserts the thing only that mechanism can get wrong: a redirect carries its policy
    # SIGNED INTO THE URL (there are no headers on a 302), the in-band answer carries it in the
    # headers. HONESTLY: the in-band arm is exercised by SHARE only. chunk_remote's `Stream`
    # mechanism is not reachable from a fixture here (`create_node!` has bytes only on share),
    # so on this ROUTE no leg runs it; the same `FileDelivery#deliver_file` is what
    # `FilesController#blob` runs, and the chunk_remote leg covers the Stream arm there.
    def assert_delivered(disposition, filename)
      caps = FileLayer.current.capabilities
      if caps.presignable?
        assert_response :redirect
        assert_includes response.headers["Location"], "X-Amz-Signature",
                        "§15: the browser must fetch from the store, via a SIGNED url"
        assert_match(/\A#{disposition}/, disposition_of(response.headers["Location"]))
        assert_match(/#{Regexp.escape(filename)}/, disposition_of(response.headers["Location"]))
      else
        assert_response :success
        assert_match(/\A#{disposition}/, response.headers["Content-Disposition"].to_s)
        assert_includes response.headers["Content-Disposition"].to_s, filename
        assert_equal "nosniff", response.headers["X-Content-Type-Options"]
      end
    end

    # --- 1/2. the delivery ---------------------------------------------------------

    test "a file in the folder is delivered as an attachment" do
      get file_path_for(@f[:base].node_id)
      assert_delivered "attachment", "base.stl"
    end

    test "a PNG is inline, and ?download=1 forces an attachment" do
      get file_path_for(@f[:pic].node_id)
      assert_delivered "inline", "pic.png"

      get file_path_for(@f[:pic].node_id, download: 1)
      assert_delivered "attachment", "pic.png"
    end

    # THE REDIRECT ARM, PINNED — the same shape s3_delivery_test.rb uses for /files/:id/blob, moved
    # onto the public route. It is the only mechanism whose policy is unobservable in the response
    # headers, so a test that merely asserted `:redirect` would pass with the policy dropped.
    test "on a presigning backend the public route redirects with the policy signed into the URL" do
      fake = FakeS3.new
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: "library", client: fake.client)
      fake.seed!("library/#{@f[:base].storage_path}", "solid base", last_modified: Time.now)

      get file_path_for(@f[:base].node_id)

      assert_predicate FileLayer.current.capabilities, :presignable?
      assert_delivered "attachment", "base.stl"
      assert_equal 0, fake.calls[:get_object], "the bytes must never pass through Rails"
    end

    # --- 3/4. what the permission REACHES ------------------------------------------

    test "a file two folders deep is delivered — ancestry, not the capped listing" do
      get file_path_for(@f[:deep_file].node_id)
      assert_delivered "attachment", "x.stl"
    end

    test "a build-log photo living outside the folder is delivered — attachment, not ancestry" do
      assert_nil @f[:entry_photo].parent_node_id
      get file_path_for(@f[:entry_photo].node_id)
      assert_delivered "inline", "shot.png"
    end

    # --- 5-9. what it REFUSES --------------------------------------------------------

    test "an unattached sibling of the folder is 404" do
      get file_path_for(@f[:outsider].node_id)
      assert_response :not_found
    end

    test "another maker's node id is 404" do
      other = make_owner!(handle: "bob")
      theirs = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.stl", kind: "file",
                                   mtime: 1, size: 1)
      get file_path_for(theirs.node_id)
      assert_response :not_found
    end

    test "a directory node is 404" do
      get file_path_for(@f[:models].node_id)
      assert_response :not_found
    end

    test "a tombstoned file is 404" do
      @f[:base].update!(deleted: true)
      get file_path_for(@f[:base].node_id)
      assert_response :not_found
    end

    test "a dot-file inside the folder is 404" do
      get file_path_for(@f[:dotfile].node_id)
      assert_response :not_found
    end

    # --- 10. visibility gates the bytes, not just the page -----------------------------

    test "a private project's file is 404, and an unlisted one's needs the token" do
      @project.update!(visibility: "private")
      get file_path_for(@f[:base].node_id)
      assert_response :not_found

      @project.update!(visibility: "unlisted")
      get file_path_for(@f[:base].node_id)
      assert_response :not_found, "without the token there is no page and no bytes either"

      get file_path_for(@f[:base].node_id, k: @project.reload.unlisted_token)
      assert_delivered "attachment", "base.stl"
    end

    # --- 11. the named form ------------------------------------------------------------

    test "the named form delivers the same node, extension and all" do
      get file_path_for(@f[:kicad].node_id, filename: "driver.kicad_sch")

      assert_delivered "attachment", "driver.kicad_sch"
      assert_includes response.body, "kicad_sch", "the real bytes, not a placeholder"
    end

    test "a filename that is not the node's own still delivers the node's own name" do
      # The glob is decoration for KiCanvas's benefit; the id is the identity. A mismatched name
      # must not become the Content-Disposition, or a link could rename someone's download.
      get file_path_for(@f[:base].node_id, filename: "anything.txt")
      assert_delivered "attachment", "base.stl"
    end
  end
end
