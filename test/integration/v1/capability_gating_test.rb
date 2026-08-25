require "test_helper"

module V1
  # WHAT IS LEFT OF CAPABILITY GATING AFTER ARC D PART 2, AND WHY MOST OF THIS FILE LEFT WITH THE
  # ENGINE.
  #
  # This suite used to assert that a share deployment answers 501 -- rather than a lie or a 500 --
  # on every syncable v1 endpoint: /v1/changes, /v1/tree, /v1/commit, /v1/locks, /v1/conflicts,
  # /v1/trash, /v1/chunks/download, /v1/share_links. Those endpoints are drawn by the sync engine,
  # and this app no longer loads it, so they are not gated here any more -- they are not ROUTED
  # here at all. Their gating moved with them: Sync::V1::CapabilityGate plus the
  # Sync.capability_check seam (§14j), asserted in chaim354/tinkerex-sync's own suite.
  #
  # TWO GATES ARE STILL THIS APP'S, and both are in FilesController on the WEB surface rather than
  # the v1 API -- which is why deleting the v1 half must not be read as deleting the concept:
  #   * `syncable`      on begin_upload/finalize_upload -- the presigned two-phase flow
  #   * `port_writable` on create                       -- POST /files, the direct byte door
  # They are exact opposites by construction (§14a: port_writable is NOT "accepts uploads", it
  # answers WHICH door), so a deployment always has exactly one of them, and asserting both here is
  # what proves the pair cannot both be closed.
  #
  # EVERY 501 ASSERTION ALSO ASSERTS THE BODY, and that is not belt-and-braces. A missing route, a
  # before_action halting for an unrelated reason, and an auth failure all produce a plausible
  # status; only the message proves it was THIS gate.
  class CapabilityGatingTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = Pathname.new(Dir.mktmpdir("gate"))
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

    def sign_in_web(user)
      post user_session_path, params: { user: { email: user.email, password: PASSWORD } }
      assert_redirected_to files_path
    end

    def web_user
      User.create!(email: "cap-#{SecureRandom.hex(4)}@example.com",
                   password: PASSWORD, confirmed_at: Time.current)
    end

    # --- the two gates this app still owns -------------------------------------------------

    # A share deployment has no changelog and no chunks, so the presigned flow cannot mean
    # anything here. The refusal must NAME the door that does work -- a bare 501 reads as
    # "uploads are off", which is exactly wrong (§14a).
    test "begin_upload answers 501 on a share backend, naming the door that does work" do
      sign_in_web(web_user)
      post begin_upload_files_path,
           params: { name: "a.stl", size: 3, manifest: [ { hash: "0" * 64, offset: 0, length: 3 } ] },
           as: :json
      assert_response :not_implemented
      assert_match(/syncable_unavailable/, error, "must be the capability gate, not a routing accident")
      assert_match(%r{POST /files}, error, "a refusal must name the path the caller SHOULD use")
    end

    # AND THE MIRROR IMAGE, which is the half that makes the pair meaningful. chunk_remote is
    # `port_writable: false` -- its bytes go through begin_upload/finalize_upload, never through a
    # server-side write, because a byte write here would push bytes through Rails (§15). So the
    # SAME app refuses the OTHER door depending on the deployment, and neither refusal means
    # "uploads are off".
    #
    # NO SYNC SERVER IS NEEDED FOR THIS, deliberately: `require_capability!` is a before_action
    # that runs BEFORE any port call, and FileLayer::ChunkRemote#capabilities is a constant. The
    # adapter is constructed with no transport at all, so if this test ever starts needing a live
    # server that is itself the regression -- the gate would have stopped being a check before the
    # call, which is the one thing §14a says it must always be.
    test "POST /files answers 501 on chunk_remote, naming the two-phase flow" do
      user = web_user
      sign_in_web(user)
      FileLayer.current = FileLayer::ChunkRemote.new
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_response :not_implemented
      assert_match(/port_writable_unavailable/, error)
      assert_match(/begin_upload/, error, "the refusal must name the flow that does work")
    end

    # THE GATE IS NOT AUTH AND NOT A MISSING ROUTE, proven: the same POST, unauthenticated,
    # redirects to login. If POST /files were unrouted this would 404 instead, and the 501 above
    # would have proved nothing.
    test "the same request unauthenticated redirects to login -- so the 501 was the gate" do
      FileLayer.current = FileLayer::ChunkRemote.new
      post files_path, params: {
        file: Rack::Test::UploadedFile.new(StringIO.new("bytes"), "application/octet-stream",
                                           original_filename: "direct.stl")
      }
      assert_redirected_to new_user_session_path
    end

    # --- ungated on purpose (§14a) -----------------------------------------------------------

    test "the maker layer is NOT gated" do
      get "/v1/maker/projects", headers: auth
      assert_response :success
      get "/v1/maker/items", headers: auth
      assert_response :success
      # `/v1/search` was asserted here too and is GONE, not broken: it is Sync::Search, drawn by
      # the engine, so it left this app with everything else the engine served. Its own suite in
      # chaim354/tinkerex-sync covers it now.
    end

    # A STRICTLY STRONGER CLAIM THAN THE TEST ABOVE. Every /v1 endpoint authenticates by device
    # token, so gating enrollment -- as "a share deployment has no devices" invites -- would make
    # the entire API unauthenticatable, maker included, while the test above kept passing: it holds
    # a token bootstrap_account minted directly, in Ruby, without ever calling the endpoint a real
    # client must call.
    test "a share deployment can still enroll a device -- the API's only credential" do
      user = web_user
      post "/v1/devices/login", params: { email: user.email, password: PASSWORD }
      assert_response :created
      token = JSON.parse(response.body)["device_token"]

      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{token}" }
      assert_response :success, "a token minted on a share backend must open the maker layer"
    end
  end
end
