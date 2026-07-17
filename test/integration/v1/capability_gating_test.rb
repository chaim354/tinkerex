require "test_helper"

module V1
  # Spec §6: "The API returns 501 Not Implemented (not 500) -- an honest 'this deployment can't
  # do that'." The gate is a capability check BEFORE the call, never a rescue: NotImplementedError
  # is not a StandardError (a bare rescue does not catch it), and a 501 for a chunk-mode
  # Chunk#write would be a lie anyway, since chunk mode accepts uploads via Sync::Commit.
  #
  # EVERY 501 ASSERTION HERE ALSO ASSERTS THE BODY, and that is not belt-and-braces. A route that
  # does not exist, a before_action halting for another reason, and an auth failure all produce a
  # plausible status; only the message proves it was THIS gate. The `chunk mode is completely
  # ungated` tests are the other half: they run the same request, with the same auth, against a
  # backend that HAS the capability, so a green 501 above cannot be a broken request.
  class CapabilityGatingTest < ActionDispatch::IntegrationTest
    setup do
      @root = Pathname.new(Dir.mktmpdir("gate"))
      # bootstrap_account is test_helper.rb's real device-auth idiom (Device.register! + the
      # plaintext token). Matched rather than reinvented: the v1 suites all use it.
      @account = bootstrap_account(email: "gate-#{SecureRandom.hex(4)}@example.com")
      @user = User.find(@account["user_id"])
      FileLayer.current = FileLayer::Share.new(root: @root.to_s)
    end
    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def auth = { "Authorization" => "Bearer #{@account['device_token']}" }
    def error = JSON.parse(response.body)["error"].to_s

    # THE headline 501. Before the gate this returned {versions: []} -- "this file has no history"
    # -- which is a lie: it has none because this DEPLOYMENT has none. An empty list tells a client
    # the file is fine and unversioned; 501 tells it the truth.
    test "versions answers 501 in share mode, not an empty list that lies" do
      node = @user.nodes.create!(node_id: "n1", name: "a.stl", kind: "file", storage_path: "a.stl")
      get "/v1/nodes/#{node.node_id}/versions", headers: auth
      assert_response :not_implemented
      assert_no_match(/"versions":\s*\[\]/, response.body, "an empty list is the lie, not the answer")
      assert_match(/versioned_unavailable/, error, "the 501 must be THIS gate, not a stray halt")
    end

    test "restore answers 501 in share mode" do
      post "/v1/nodes/n1/restore", params: { version_id: "v1" }, headers: auth
      assert_response :not_implemented
      assert_match(/versioned_unavailable/, error)
    end

    # The whole sync surface, each with the body asserted -- several of these paths would answer a
    # plausible status for an entirely different reason if the gate were missing (a bad param, an
    # absent node, an empty list).
    test "the sync surface answers 501 in share mode" do
      {
        [ :get,  "/v1/changes" ]                     => :syncable,
        [ :get,  "/v1/tree" ]                        => :syncable,
        [ :get,  "/v1/conflicts" ]                   => :syncable,
        [ :get,  "/v1/locks" ]                       => :syncable,
        [ :get,  "/v1/trash" ]                       => :syncable,
        [ :post, "/v1/trash/n1/restore" ]            => :syncable,
        [ :post, "/v1/commit" ]                      => :syncable,
        [ :post, "/v1/commit/c1/finalize" ]          => :syncable,
        [ :post, "/v1/chunks/download" ]             => :syncable,
        [ :post, "/v1/nodes" ]                       => :syncable,
        [ :post, "/v1/nodes/symlink" ]               => :syncable,
        [ :delete, "/v1/nodes/n1" ]                  => :syncable,
        [ :post, "/v1/nodes/n1/move" ]               => :syncable,
        [ :post, "/v1/nodes/n1/lock" ]               => :syncable,
        [ :post, "/v1/nodes/n1/unlock" ]             => :syncable,
        [ :post, "/v1/nodes/n1/resolve_conflict" ]   => :syncable,
        [ :get,  "/v1/nodes/n1/versions" ]           => :versioned,
        [ :post, "/v1/nodes/n1/restore" ]            => :versioned,
        [ :post, "/v1/share_links" ]                 => :versioned
      }.each do |(verb, path), capability|
        send(verb, path, headers: auth)
        assert_response :not_implemented, "#{verb.upcase} #{path} must not pretend to be a sync endpoint"
        assert_match(/#{capability}_unavailable/, error,
                     "#{verb.upcase} #{path} must 501 for the RIGHT missing capability")
      end
    end

    # 501, not 500, and it must SAY something. A bare status with no body leaves an operator
    # guessing whether the deployment is broken or merely different.
    test "a 501 explains itself" do
      get "/v1/changes", headers: auth
      assert_response :not_implemented
      body = JSON.parse(response.body)
      assert body["error"].present?, "a 501 must name the capability that is absent"
      assert_match(/syncable/, body["error"], "and name WHICH capability")
    end

    # The counterpart, and the one that catches an over-firing gate: chunk mode keeps ALL of it.
    # Same auth, same paths -- so a 501 above is the gate and not a broken request.
    test "chunk mode is completely ungated" do
      FileLayer.current = FileLayer::Chunk.new
      node = @user.nodes.create!(node_id: "n2", name: "b.stl", kind: "file")

      get "/v1/nodes/#{node.node_id}/versions", headers: auth
      assert_response :success

      get "/v1/changes", headers: auth
      assert_response :success

      get "/v1/tree", headers: auth
      assert_response :success

      get "/v1/conflicts", headers: auth
      assert_response :success

      get "/v1/locks", headers: auth
      assert_response :success

      get "/v1/trash", headers: auth
      assert_response :success
    end

    # THE GATE IS NOT AUTH, PROVEN RATHER THAN ASSERTED. Auth is included before the gate, so an
    # unauthenticated caller gets 401 -- which also means no stranger learns this deployment's
    # backend by poking a gated endpoint.
    test "an unauthenticated request is 401, not 501 -- the gate never runs" do
      get "/v1/changes"
      assert_response :unauthorized
      assert_no_match(/unavailable/, response.body)
    end

    # The maker layer is the WHOLE PRODUCT in share mode. A gate that caught it would defeat the
    # phase this arc exists for.
    test "the maker layer is NOT gated in share mode" do
      get "/v1/maker/projects", headers: auth
      assert_response :success
      get "/v1/maker/items", headers: auth
      assert_response :success
      get "/v1/search?q=a", headers: auth
      assert_response :success
    end

    # AND THE MAKER LAYER MUST BE REACHABLE, WHICH IS A STRICTLY STRONGER CLAIM THAN THE TEST
    # ABOVE. Every /v1 endpoint authenticates by device token, so gating enrollment on `syncable`
    # -- as "a share deployment has no devices" invites -- would make a share deployment's entire
    # API unauthenticatable, maker included, while the test above kept passing: it holds a token
    # that bootstrap_account minted directly, in Ruby, without ever calling the endpoint a real
    # client must call.
    test "a share deployment can still enroll a device -- the maker API's only credential" do
      user = User.create!(email: "enroll-#{SecureRandom.hex(4)}@example.com",
                          password: "correct horse battery staple", confirmed_at: Time.current)
      post "/v1/devices/login", params: { email: user.email, password: "correct horse battery staple" }
      assert_response :created
      token = JSON.parse(response.body)["device_token"]

      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{token}" }
      assert_response :success, "a token minted in share mode must open the maker layer"
    end

    # The anonymous redeem side is deliberately ungated: a 501 would tell any stranger holding any
    # string which backend this deployment runs, and 404 is already both honest and terminal (no
    # link can exist -- that is the gate on the owner side).
    test "the anonymous share-link redeem side is 404, not 501 -- it leaks no backend" do
      get "/v1/share/nonexistent-token"
      assert_response :not_found
      assert_no_match(/unavailable/, response.body)
    end

    # EVERY TEST ABOVE PASSES WITHOUT A CHUNK STORE ONLY BECAUSE THE TEST ENV HAS ONE, and that
    # made all nine of them unable to fail for the reason they exist. They set FileLayer.current
    # and never touch STORAGE_BACKEND, which Storage::ChunkStore defaults to `memory` IN TEST and
    # `s3` EVERYWHERE ELSE -- so a real share deployment, configured exactly as docs/STATUS.md
    # documents it (LIBRARY_* set, CHUNK_* unset), built S3ChunkStore.from_env on every v1 request
    # and answered `KeyError: CHUNK_BUCKET` -> 500. Login, /v1/maker/*, and every endpoint gated
    # above: 500 rather than the 501 this phase exists to give. The gate was unreachable and the
    # suite was green.
    #
    # So this test sets STORAGE_BACKEND to what PRODUCTION defaults to and leaves CHUNK_* unset --
    # a share operator's real environment, not a simulation of one -- and asserts the four answers
    # a stranger, a client, and the API itself must get. Without the before_actions' capability
    # gate all four are 500.
    #
    # It asserts the WHOLE surface rather than just login: `stash_request_base_url` runs before
    # every action in two controllers, so one endpoint proves one endpoint.
    class NoChunkStoreTest < ActionDispatch::IntegrationTest
      setup do
        @root = Pathname.new(Dir.mktmpdir("gate"))
        FileLayer.current = FileLayer::Share.new(root: @root.to_s)
        @storage_backend = ENV["STORAGE_BACKEND"]
        ENV["STORAGE_BACKEND"] = "s3" # production's default; CHUNK_* deliberately absent
        Storage::ChunkStore.reset!
      end
      teardown do
        ENV["STORAGE_BACKEND"] = @storage_backend
        ENV.delete("STORAGE_BACKEND") if @storage_backend.nil?
        Storage::ChunkStore.reset!
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root&.exist?
      end

      test "a share deployment with no chunk store configured can still enroll a device" do
        user = User.create!(email: "nochunk-#{SecureRandom.hex(4)}@example.com",
                            password: "correct horse battery staple", confirmed_at: Time.current)
        post "/v1/devices/login",
             params: { email: user.email, password: "correct horse battery staple" }
        assert_response :created, "the API's only credential must be mintable without a chunk store"

        token = JSON.parse(response.body)["device_token"]
        get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{token}" }
        assert_response :success, "the maker layer IS the product in share mode"
      end

      test "a gated endpoint still answers 501, not the 500 the chunk store used to raise" do
        account = bootstrap_account(email: "nochunk-gate-#{SecureRandom.hex(4)}@example.com")
        get "/v1/tree", headers: { "Authorization" => "Bearer #{account['device_token']}" }
        assert_response :not_implemented
        assert_match(/syncable_unavailable/, JSON.parse(response.body)["error"].to_s,
                     "the 501 must be the capability gate, not a stray halt")
      end

      test "the anonymous redeem side 404s without a chunk store -- a stranger gets no 500 page" do
        get "/v1/share/nonexistent-token"
        assert_response :not_found
      end
    end
  end
end
