require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  class AddonsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # KEY IS DELIBERATELY NOT "generators", even though title/entry mirror the real Generators
    # addon. `/tools/generators` now DOES resolve to this generic controller (the legacy
    # `resources :generators` route and Tools::GeneratorsController are gone — the real bundle
    # lives at public/addons/generators, exercised end-to-end by
    # test/system/addon_bundle_test.rb, not here). A synthetic key keeps THIS suite — which stubs
    # Maker::Addons::Source with fakes — decoupled from that real bundle's fixtures, so a change to
    # one cannot silently paper over a break in the other.
    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1",
      "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" }
    }.freeze

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
      Rails.cache = @prior_cache
      FileLayer.reset!
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
  end
end
