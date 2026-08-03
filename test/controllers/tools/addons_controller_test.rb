require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  class AddonsControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # KEY IS DELIBERATELY NOT "generators", EVEN THOUGH title/entry mirror the real Generators
    # addon Task 6 will register under that name. `/tools/generators` is still claimed by the OLD
    # Tools::GeneratorsController (kept live on purpose — see the routes.rb comment on the generic
    # addon routes, and test/controllers/tools/generators_controller_test.rb, which still drives
    # that exact URL). Rails route recognition is first-match-wins by DECLARATION ORDER, not by
    # which named helper built the request string, and `resources :generators` is declared above
    # the generic `tools/:key` routes — so a request to "/tools/generators" resolves to
    # `tools/generators#index` regardless of what `tools_addon_path("generators")` looks like.
    # Verified: `Rails.application.routes.recognize_path("/tools/generators", method: :get)` =>
    # {controller: "tools/generators", action: "index"}. Using a key none of the three legacy
    # addons (boxes/openscad/generators) claim lets this suite actually exercise
    # Tools::AddonsController rather than silently re-testing the old one. The real "generators"
    # key only routes here once Task 7 removes the legacy routes.
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
        assets: { "widgetkit/generators.js" => "export default { mount() {} }" }
      )
      @user = User.create!(email: "addons@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      Maker::Addons::Source.reset!
      Rails.cache = @prior_cache
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

    test "a traversing asset path is refused" do
      # Belt and braces: Source#asset_path! refuses it too, but the controller is the door an
      # attacker actually knocks on, and a 404 here must not depend on the layer below.
      get "/tools/widgetkit/asset/../../secret"
      assert_response :not_found
    end
  end
end
