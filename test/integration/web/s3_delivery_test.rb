require "test_helper"
require_relative "../../support/fake_s3"

module Web
  # S3-mode byte delivery through the real controller. Like share mode, blob 404d here before
  # Task 3 -- an S3 node has no current_version either.
  #
  # WHY THIS EXISTS ALONGSIDE s3_test.rb's download tests, which already assert the signed wire
  # thoroughly: they pin that the ADAPTER honors the disposition it is GIVEN. They cannot pin
  # that the CONTROLLER gives it the right one -- #blob could pass disposition: "inline" for an
  # SVG, or drop ?download=1 on the floor, and every one of those tests would stay green.
  #
  # That gap is precisely Landmine 3's claim ("the same UI button behaves differently depending
  # on the deployment's backend"), so it has to be asserted at the layer where the button is. The
  # redirect branch sets NO response headers by design, which means the URL is the only place the
  # policy can be checked -- and a test that only asserted `assert_response :redirect` here would
  # pass with the policy dropped entirely.
  class S3DeliveryTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    PREFIX = "library".freeze

    setup do
      @fake = FakeS3.new
      @user = User.create!(email: "s3d-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk", prefix: PREFIX,
                                            client: @fake.client)
      sign_in_web!(@user, password: PASSWORD)
    end
    # Load-bearing, not decoration: a direct `FileLayer.current =` does not set
    # @file_layer_backend_pinned, so test_helper's teardown will not clean up after it.
    teardown { FileLayer.reset! }

    # Seeded as another tool would have, then indexed with THE REAL OBSERVER -- the same call
    # Library::ScanJob makes in production, over the adapter this deployment is configured with.
    # The backend's premise is that the bucket already has the user's files in it.
    #
    # max_delete_pct: 100 for s3_test.rb's reason: a fixture is not about the mass-deletion guard,
    # and a helper that could refuse depending on the test's history fails somewhere unrelated.
    def index!(name, bytes)
      @fake.seed!("#{PREFIX}/#{name}", bytes, last_modified: Time.now)
      Library::S3Observer.call(@user, adapter: FileLayer.current, max_delete_pct: 100)
      @user.nodes.find_by!(storage_path: name).node_id
    end

    def disposition_of(url) = CGI.parse(URI(url).query)["response-content-disposition"].first.to_s

    test "an S3-backed file redirects to a signed URL -- it used to 404" do
      id = index!("bracket.stl", "solid bracket")
      get blob_file_path(id)

      assert_response :redirect
      assert_includes response.headers["Location"], "X-Amz-Signature",
                      "§15: the browser must fetch from the store, via a SIGNED url"
      assert_equal 0, @fake.calls[:get_object], "the bytes must never pass through Rails"
    end

    # LANDMINE 3 AT THE CONTROLLER. The stored-XSS policy is #blob's and must reach the store,
    # or an SVG is served from the bucket with whatever Content-Type the object carries.
    test "the SVG attachment policy survives the redirect" do
      id = index!("evil.svg", "<svg onload=alert(1)></svg>")
      get blob_file_path(id)

      assert_match(/attachment/, disposition_of(response.headers["Location"]),
                   "the controller's SAFE_INLINE_TYPES verdict must be signed into the URL")
      assert_match(/evil\.svg/, disposition_of(response.headers["Location"]))
    end

    # The same button, the same answer as chunk mode (files_flow_test) and share mode.
    test "a PNG is inline here too" do
      id = index!("ok.png", "\x89PNG\r\n\x1a\n".b)
      get blob_file_path(id)
      assert_match(/inline/, disposition_of(response.headers["Location"]))
    end

    # ?download=1 is the UI's OWN control. A redirect ignores it unless the controller passes it
    # through, and then it is silently a no-op on exactly one backend.
    test "?download=1 forces an attachment even for an inline-safe type" do
      id = index!("ok2.png", "\x89PNG".b)
      get blob_file_path(id, download: 1)
      assert_match(/attachment/, disposition_of(response.headers["Location"]),
                   "?download=1 must not be silently dropped on the redirect path")
    end

    test "another user's node is 404, never a signed URL to their bytes" do
      id = index!("mine.stl", "secret")
      other = User.create!(email: "o2-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      delete destroy_user_session_path
      sign_in_web!(other, password: PASSWORD)

      get blob_file_path(id)
      # Both answers are a 302, so the status alone proves nothing here -- assert WHERE to.
      assert_redirected_to files_path
      assert_not_includes response.headers["Location"], "X-Amz-Signature",
                          "a cross-user blob must never mint a signed URL to the owner's bytes"
    end
  end
end
