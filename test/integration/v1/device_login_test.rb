require "test_helper"

module V1
  # Device enrollment by login (the Dropbox model). Valid creds of a CONFIRMED account ->
  # a device token; wrong password / unknown email / unconfirmed -> 401. Replaces
  # the pairing-code flow. The v1 sync endpoints keep using the returned device token.
  class DeviceLoginTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    # Enrollment itself is NOT capability-gated and must never be (a device token is the only
    # credential the whole v1 API takes, maker layer included -- see V1::DevicesController). The
    # share-mode counterpart -- that enrollment still works and still opens the maker layer -- is in
    # capability_gating_test.rb.
    #
    # THIS SUITE RUNS ON THE LEG'S OWN BACKEND, AND ON chunk_remote THAT IS A REAL SYNC SERVER: a
    # login that succeeds there brokers a sync grant, provisioning a remote library for its email,
    # and that server's database does not roll back with this one. So every email that reaches a
    # SUCCESSFUL login is unique per test -- a fixed one provisions once and then answers 503 on
    # every later run (the journey helper's sign_in makes the same argument). The refusals below
    # never reach the grant and keep their fixed emails.
    setup do
      # The devices' door (lib/library_backend_check.rb). Kept when the leg sets it; otherwise a
      # placeholder, which only a syncable answer echoes.
      @prior_public_url = ENV["SYNC_PUBLIC_URL"]
      ENV["SYNC_PUBLIC_URL"] = @prior_public_url.presence || "https://sync.example.test"
      # Built from THIS leg's configuration, never an adapter an earlier test in the worker left.
      FileLayer.reset!
    end

    teardown do
      @prior_public_url.nil? ? ENV.delete("SYNC_PUBLIC_URL") : ENV["SYNC_PUBLIC_URL"] = @prior_public_url
      FileLayer.reset!
    end

    def login(email:, password:, device_name: "laptop")
      post "/v1/devices/login",
           params: { email:, password:, device_name: }, as: :json
      response
    end

    def unique_user(prefix)
      User.create!(email: "#{prefix}-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                   confirmed_at: Time.current)
    end

    test "valid credentials of a confirmed account return a device token" do
      user = unique_user("dev")
      assert_difference -> { Device.count }, 1 do
        r = login(email: user.email, password: PASSWORD)
        assert_response :created
        body = JSON.parse(r.body)
        assert body["device_token"].present?
        assert body["user_id"].present?
      end
    end

    test "the returned token works against the owner's library" do
      user = unique_user("dev2")
      token = JSON.parse(login(email: user.email, password: PASSWORD).body)["device_token"]
      # `/v1/maker/projects`, not `/v1/tree`. The claim is that a token minted here OPENS THE API,
      # and /v1/tree is the sync engine's endpoint -- gone from this app since Arc D Part 2, so it
      # would 404 for a reason that has nothing to do with the token. The maker layer is this app's
      # own and is the surface a device token actually has to reach here.
      get "/v1/maker/projects", headers: { "Authorization" => "Bearer #{token}" }
      assert_response :success
    end

    test "a wrong password is rejected with 401 and mints no device" do
      User.create!(email: "dev3@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { Device.count } do
        r = login(email: "dev3@example.com", password: "wrong")
        assert_response :unauthorized
        assert_nil JSON.parse(r.body)["device_token"]
      end
    end

    test "an unknown email is rejected with the same generic 401 (no enumeration)" do
      r = login(email: "nobody@example.com", password: PASSWORD)
      assert_response :unauthorized
      assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
    end

    test "an UNCONFIRMED account cannot enroll a device" do
      User.create!(email: "unconf@example.com", password: PASSWORD) # confirmed_at nil
      assert_no_difference -> { Device.count } do
        r = login(email: "unconf@example.com", password: PASSWORD)
        assert_response :unauthorized
        assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
      end
    end

    # NO ACCOUNT LOCKS (pentest M4b, tinkerex#466). This test used to assert the opposite -- ten
    # misses and the account was locked for an hour -- which was the finding: anyone who knew an
    # address could keep its owner's desktop app from signing in, from one IP, every hour.
    # Tinkerex::SignInThrottle bounds the stranger's source instead. Mutation-checked: with
    # `config.lock_strategy = :failed_attempts` restored, the owner's login below answers 401.
    test "wrong passwords from one source never keep the owner's device out from another" do
      user = unique_user("nolock")
      11.times do
        post "/v1/devices/login", params: { email: user.email, password: "wrong" }, as: :json,
                                  env: { "REMOTE_ADDR" => "198.51.100.66" }
      end
      assert_response :too_many_requests, "precondition: the stranger's source is throttled"

      assert_difference -> { Device.count }, 1 do
        post "/v1/devices/login", params: { email: user.email, password: PASSWORD, device_name: "laptop" },
                                  as: :json, env: { "REMOTE_ADDR" => "203.0.113.10" }
        assert_response :created
      end
      assert_not user.reload.access_locked?
    end

    # --- the library and the sync grant (D1, 2026-10-13) ----------------------------------------

    # THE ANSWER ALWAYS NAMES THE LIBRARY, AND CARRIES A SYNC GRANT ONLY WHERE THERE IS SOMETHING TO
    # SYNC. The expected values come from the LEG, never from the controller's own derivation: the
    # backend is the LIBRARY_BACKEND this leg was launched with (FileLayer.build's default when it is
    # unset), syncable is the serving adapter's capability. On share and s3 `sync` is present and
    # null; on chunk_remote it is a real grant from a real sync server, whose token the journey suite
    # (test/integration/chunk_remote_journey_test.rb) proves that server accepts.
    def assert_library_and_sync(body)
      syncable = FileLayer.current.capabilities.syncable?
      assert_equal({ "backend" => ENV.fetch("LIBRARY_BACKEND", "share"), "syncable" => syncable },
                   body["library"])
      assert body.key?("sync"), "sync is ALWAYS answered -- null is the statement that there is nothing to sync"
      if syncable
        assert_equal %w[device_id device_token head_seq url user_id], body["sync"].keys.sort
        assert_equal ENV.fetch("SYNC_PUBLIC_URL"), body["sync"]["url"],
                     "a device is handed the devices' door, never the app's own CHUNK_REMOTE_URL"
      else
        assert_nil body["sync"], "nothing to sync on #{body.dig('library', 'backend')}: the grant must be null"
      end
    end

    # THE SYNC SIBLING IS RECORDED (pentest H1b), so that once the sync server has a revoke door,
    # signing a device out here can name the sync device to revoke. NULL where no grant was brokered.
    def assert_sibling_recorded(body)
      recorded = Device.find(body["device_id"]).sync_device_id
      if (granted = body.dig("sync", "device_id"))
        assert_equal granted, recorded
      else
        assert_nil recorded
      end
    end

    test "login names the library and carries a sync grant only on a syncable deployment" do
      user = unique_user("lib")
      r = login(email: user.email, password: PASSWORD)
      assert_response :created
      body = JSON.parse(r.body)
      assert_equal %w[device_id device_token head_seq library sync user_id], body.keys.sort,
                   "the four original fields stay; library and sync are added, nothing else"
      assert_library_and_sync body
      assert_sibling_recorded body
    end

    test "a sibling enrolled through POST /v1/devices answers the same two fields" do
      user = unique_user("sib")
      token = JSON.parse(login(email: user.email, password: PASSWORD).body).fetch("device_token")

      post "/v1/devices", params: { name: "desktop" },
                          headers: { "Authorization" => "Bearer #{token}" }, as: :json
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal %w[device_id device_token library sync], body.keys.sort
      assert_library_and_sync body
      assert_sibling_recorded body
    end

    # A SYNC SERVER THAT CANNOT BE REACHED ANSWERS 503 AND MINTS NO MAKER DEVICE. The order inside
    # both actions is grant, THEN Device.register!: a device holding a maker token and no way to sync
    # would have to sign in again anyway, so a clear retry beats a half-enrolled device. Driven on
    # every leg by making the deployment syncable -- constructing a ChunkRemote dials nothing -- and
    # standing in for the grant with one that raises what Transport raises for a refused connection.
    test "a sync server that cannot be reached answers 503 and mints no maker device" do
      user = unique_user("down")
      FileLayer.current = FileLayer::ChunkRemote.new

      with_sync_server_down do
        assert_no_difference -> { Device.count } do
          r = login(email: user.email, password: PASSWORD)
          assert_response :service_unavailable
          assert_equal({ "error" => "sync_unavailable" }, JSON.parse(r.body),
                       "the body names no cause -- the message can carry the sync server's internal address")
        end
      end
    end

    test "POST /v1/devices answers the same 503 and mints no sibling" do
      token = bootstrap_token(email: "down-sib-#{SecureRandom.hex(4)}@example.com")
      FileLayer.current = FileLayer::ChunkRemote.new

      with_sync_server_down do
        assert_no_difference -> { Device.count } do
          post "/v1/devices", params: { name: "desktop" },
                              headers: { "Authorization" => "Bearer #{token}" }, as: :json
          assert_response :service_unavailable
          assert_equal({ "error" => "sync_unavailable" }, JSON.parse(response.body))
        end
      end
    end

    # THE SIBLING ID IS RECORDED AT BOTH DOORS, ON EVERY LEG. The chunk_remote leg proves it against a
    # real grant (assert_sibling_recorded above); here a stand-in grant makes share and s3 prove it
    # too, so a mutation dropping `sync_device_id:` from either door fails on every leg, not one.
    test "both doors record the sync sibling the grant names" do
      user = unique_user("sibid")
      FileLayer.current = FileLayer::ChunkRemote.new
      granted = Object.new
      granted.define_singleton_method(:call) do |*, **|
        { url: "https://sync.example.test", device_token: "t", user_id: 7, device_id: 9001, head_seq: 0 }
      end

      replacing(FileLayer::ChunkRemote::SyncGrant, :new, ->(*, **) { granted }) do
        body = JSON.parse(login(email: user.email, password: PASSWORD).body)
        assert_equal 9001, Device.find(body["device_id"]).sync_device_id

        post "/v1/devices", params: { name: "desktop" },
                            headers: { "Authorization" => "Bearer #{body.fetch("device_token")}" }, as: :json
        assert_response :created
        assert_equal 9001, Device.find(JSON.parse(response.body)["device_id"]).sync_device_id
      end
    end

    # --- the shared demo account (H, 2026-10-14) ---------------------------------------------------

    # THE DEMO ENROLS NO DEVICE, BY EITHER DOOR, AND THE REFUSAL COMES FIRST: before a grant is
    # brokered or a Device minted, and at login before the password is checked, so a stranger
    # spends nothing on it (Tinkerex::Demo; V1::DevicesController). The demo's password is known here and random in
    # production, so the 403 below is the guard's and never the generic 401 a wrong password earns;
    # every other test in this file is the control -- an ordinary account's identical login, 201. The
    # address is unique per test for the reason this file's header gives: were the guard ever gone,
    # the login would reach a real sync server on the chunk_remote leg.
    def with_demo(email)
      prior = ENV.fetch("DEMO_ACCOUNT_EMAIL", nil)
      ENV["DEMO_ACCOUNT_EMAIL"] = email
      yield
    ensure
      prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
    end

    test "the shared demo account is refused a device at login, before its password is checked" do
      demo = unique_user("demo")
      with_demo(demo.email.upcase) do
        assert_no_difference -> { Device.count } do
          r = login(email: demo.email, password: PASSWORD)
          assert_response :forbidden
          assert_equal({ "error" => "demo_account" }, JSON.parse(r.body))

          login(email: demo.email, password: "wrong")
          assert_response :forbidden, "a wrong password gets the same answer: nothing was checked"
        end
      end
    end

    test "the shared demo account is refused a sibling device through POST /v1/devices" do
      demo = unique_user("demo-sib")
      # A token the demo could only hold from before demo mode was on, or by a console: minted directly.
      token = Device.register!(user: demo, name: "before the demo").plaintext_token
      with_demo(demo.email) do
        assert_no_difference -> { Device.count } do
          post "/v1/devices", params: { name: "desktop" },
                              headers: { "Authorization" => "Bearer #{token}" }, as: :json
          assert_response :forbidden
          assert_equal({ "error" => "demo_account" }, JSON.parse(response.body))
        end
      end
    end

    # The house stub helper (web/new_menu_test.rb carries the same body; Minitest 6 has no
    # Object#stub). Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def with_sync_server_down(&)
      down = Object.new
      down.define_singleton_method(:call) do |*, **|
        raise FileLayer::FetchError, "sync server unreachable (Errno::ECONNREFUSED): http://tinkerex-sync:3000"
      end
      replacing(FileLayer::ChunkRemote::SyncGrant, :new, ->(*, **) { down }, &)
    end
  end
end
