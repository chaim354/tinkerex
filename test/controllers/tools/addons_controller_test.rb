require "test_helper"
require_relative "../../support/fake_addon_source"
require_relative "../../support/fake_service_proxy"

module Tools
  class AddonsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # KEY IS DELIBERATELY NOT "generators", even though title/entry mirror the real Generators
    # addon. `/tools/generators` now DOES resolve to this generic controller (the legacy
    # `resources :generators` route and Tools::GeneratorsController are gone — the real bundle is
    # served by the `addons` Kamal accessory from the chaim354/tinkerex-addons repo in production,
    # and by test/system/addon_bundle_test.rb's own hermetic fixture in CI, not by anything here). A
    # synthetic key keeps THIS suite — which stubs Maker::Addons::Source with fakes — decoupled from
    # either of those, so a change to one cannot silently paper over a break in the other.
    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1",
      "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" },
      "services" => [ "fixture-svc" ]
    }.freeze
    FIXTURE_KEY = MANIFEST["key"]

    setup do
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ MANIFEST ],
        assets: {
          "widgetkit/generators.js" => "export default { mount() {} }",
          # Seeded ONLY so the traversal test can fail for the right reason. If asset_path! ever stops
          # refusing, FakeAddonSource#asset would find this key and the controller would serve it —
          # so the assertion below distinguishes "refused" from the coincidental "not in the hash",
          # which is what made an earlier version of this test pass under mutation.
          "widgetkit/../../secret" => "PWNED"
        }
      )
      @user = User.create!(email: "addons@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      Storage::ChunkStore.reset!
      # Mirrors GeneratorsControllerTest/BoxesControllerTest: on the s3 CI leg, FileLayer.current
      # otherwise resolves to a REAL FileLayer::S3 pointed at CI's stub (non-existent) bucket
      # creds, so an unstubbed save 403s against actual AWS instead of exercising the save path.
      if ENV["LIBRARY_BACKEND"] == "s3"
        require_relative "../../support/fake_s3"
        @fake = FakeS3.new
        FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                              secret_access_key: "sk", prefix: "library",
                                              client: @fake.client)
      end
    end

    teardown do
      Maker::Addons::Source.reset!
      Maker::Addons::ServiceProxy.reset!
      Rails.cache = @prior_cache
      FileLayer.reset!
    end

    # Registers a canned response for one full sidecar URL (base + path), via the ServiceProxy seam
    # — never Net::HTTP itself (this repo has no `Object#stub`; see the require at the top of this
    # file for why). Reused across the service tests below.
    def stub_http_ok(full_url, body:, content_type:)
      @fake_service_proxy ||= FakeServiceProxy.new
      Maker::Addons::ServiceProxy.stub = @fake_service_proxy
      @fake_service_proxy.ok(full_url, body: body, content_type: content_type)
    end

    test "requires login" do
      reset!
      get tools_addon_path("widgetkit")
      assert_redirected_to new_user_session_path
    end

    test "renders the shell with the addon's entry URL and host context" do
      get tools_addon_path("widgetkit")
      assert_response :success
      assert_select "[data-controller=addon][data-addon-entry-value=?]",
                    tools_addon_asset_path("widgetkit", "generators.js")
      assert_select "[data-addon-save-url-value=?]", tools_addon_path("widgetkit")
    end

    test "an unknown addon key is a 404, not a 500" do
      get tools_addon_path("nope")
      assert_response :not_found
    end

    test "the addon's pins are merged into the page importmap" do
      get tools_addon_path("widgetkit")
      assert_response :success
      assert_includes response.body, tools_addon_asset_path("widgetkit", "makerjs.js")
    end

    test "serves an addon asset as JavaScript" do
      get tools_addon_asset_path("widgetkit", "generators.js")
      assert_response :success
      assert_equal "text/javascript", response.media_type
      assert_equal "export default { mount() {} }", response.body
    end

    test "a missing asset is a 404, not a 500" do
      get tools_addon_asset_path("widgetkit", "nope.js")
      assert_response :not_found
    end

    test "a traversing asset path is refused, not merely absent" do
      # Belt and braces: Source#asset_path! refuses it too, but the controller is the door an
      # attacker actually knocks on, and a 404 here must not depend on the layer below.
      get "/tools/widgetkit/asset/../../secret"
      assert_response :not_found
      assert_no_match(/PWNED/, response.body)
    end

    test "save writes the file to the library and records an AddonState" do
      assert_difference -> { @user.maker_addon_states.count } => 1 do
        post tools_addon_path("widgetkit"), params: {
          name: "3mm birch test",
          data: { generator: "material-test-grid", params: { cols: "5" } }.to_json,
          files: [ { name: "grid.svg", content_type: "image/svg+xml", body: "<svg/>" } ].to_json
        }
      end
      assert_redirected_to tools_addon_path("widgetkit")

      state = @user.maker_addon_states.last
      assert_equal "widgetkit", state.addon_key
      assert_equal "3mm birch test", state.name
      assert_equal "material-test-grid", state.data["generator"]
      assert_equal 1, state.files.count
    end

    test "save refuses a payload over the size cap" do
      post tools_addon_path("widgetkit"), params: {
        name: "huge", data: "{}",
        files: [ { name: "big.svg", content_type: "image/svg+xml",
                   body: "x" * (Tools::AddonsController::MAX_FILE_BYTES + 1) } ].to_json
      }
      assert_response :unprocessable_entity
    end

    test "save refuses a file count over the cap" do
      files = Array.new(Tools::AddonsController::MAX_FILES + 1) do |i|
        { name: "f#{i}.svg", content_type: "image/svg+xml", body: "<svg/>" }
      end
      post tools_addon_path("widgetkit"), params: { name: "many", data: "{}", files: files.to_json }
      assert_response :unprocessable_entity
    end

    test "save refuses malformed files JSON rather than 500ing" do
      post tools_addon_path("widgetkit"), params: { name: "bad", data: "{}", files: "not json" }
      assert_response :unprocessable_entity
    end

    test "service proxies to the sidecar URL the HOST configures" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      stub_http_ok("http://sidecar.test/render", body: "SIDECAR-BODY", content_type: "image/svg+xml")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render"), params: { a: "1" }

      assert_response :success
      assert_equal "SIDECAR-BODY", response.body
      assert_equal "image/svg+xml", response.media_type
    ensure
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end

    test "a service the manifest does not declare is refused" do
      # The manifest names WHICH services an addon may reach; the host says WHERE each lives. An
      # addon that could name an arbitrary service — or an arbitrary URL — would be an SSRF
      # primitive pointed at the internal network (spec §4.1).
      ENV["OTHER_SIDECAR_URL"] = "http://other.test"
      # Stubbed so a real answer is a REACHABLE outcome. Without this, a broken guard would still
      # 404 here for an unrelated reason — Net::HTTP failing to resolve "other.test" — which would
      # make the assertion below pass by coincidence rather than by the guard actually firing. The
      # mutation check in step 7 depends on this distinction (§15).
      stub_http_ok("http://other.test/render", body: "SHOULD-NOT-BE-REACHABLE", content_type: "text/plain")

      post tools_addon_service_path(FIXTURE_KEY, "other", "render")
      assert_response :not_found
    ensure
      ENV.delete("OTHER_SIDECAR_URL")
    end

    test "a declared service with no configured URL is refused, not guessed at" do
      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "render")
      assert_response :not_found
    end

    test "a traversing service path is refused" do
      ENV["FIXTURE_SVC_SIDECAR_URL"] = "http://sidecar.test"
      # Stubbed at the WOULD-BE traversal target so a bypassed guard gets a reachable answer instead
      # of a coincidental 404 from Net::HTTP failing on a malformed URL (§15 mutation-check note).
      stub_http_ok("http://sidecar.test/../../admin", body: "SHOULD-NOT-BE-REACHABLE", content_type: "text/plain")

      post tools_addon_service_path(FIXTURE_KEY, "fixture-svc", "../../admin")
      assert_response :not_found
    ensure
      ENV.delete("FIXTURE_SVC_SIDECAR_URL")
    end
  end
end
