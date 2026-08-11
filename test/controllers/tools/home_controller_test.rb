require "test_helper"
require_relative "../../support/fake_addon_source"

module Tools
  class HomeControllerTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # Was `assert_select ".addon-card", text: /Box Generator/`, which passed against the TEMPORARY
    # hardcoded boxes card regardless of whether Registry had anything real in it — both the
    # "available" and "disabled" branches of that block rendered the title text. Boxes has since
    # migrated onto the generic manifest-driven surface (Tools::AddonsController), so "lists
    # registered addons" now has to mean what it says: stub Maker::Addons::Source, the same door
    # `boxes` itself goes through in production, and assert the @addons loop actually renders it.
    MANIFEST = {
      "key" => "widgetkit", "title" => "Generators", "icon" => "✏️",
      "description" => "Parametric 2D drawings", "api_version" => "1", "entry" => "generators.js"
    }.freeze

    setup do
      @user = User.create!(email: "tools@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @prior_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
    end

    teardown do
      Rails.cache = @prior_cache
      Maker::Addons::Source.reset!
    end

    test "requires login" do
      reset!
      get tools_path
      assert_redirected_to new_user_session_path
    end

    test "lists registered addons" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", text: /Generators/ # from the registry-driven @addons loop
      assert_select ".addon-card", text: /OpenSCAD/    # openscad's own hardcoded card, untouched
    end

    # THE GALLERY SHOWS THE REASON, NOT A FIXED SENTENCE. Before this, the disabled card's tooltip
    # said "Not configured on this deployment" for every cause there could be — which for a
    # too-new addon points an operator at env vars that are perfectly fine.
    test "a too-new addon renders its own unavailable reason" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-card.disabled" do
        # NOT `[title=?]` — rails-dom-testing only performs a REGEXP match on an attribute through
        # its `:match('attr', ?)` pseudo-class; a plain `[attr=?]` substitutes a Regexp via #to_s
        # into an exact CSS equality selector (`[title="(?-mix:...)"]`) and can never match real
        # text. Verified by reproducing both against rails-dom-testing 2.3.0 directly: `[title=?]`
        # finds 0 elements against this exact title, `:match('title', ?)` finds 1.
        assert_select ":match('title', ?)", /Needs a newer version of this host/
      end
    end

    # WHAT THE OPERATOR SEES AT PUBLISH TIME. The point of rendering these is scope drift: a
    # republished bundle that quietly starts asking for more shows up on the card, in a deployment
    # where publishing the bundle IS the deploy and Rails is never rebuilt.
    test "a card lists the permissions its manifest declares, by label" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST.merge("permissions" => [ { "name" => "library:write" }, { "name" => "service:boxes" } ])
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", text: /Write files to your library/
      assert_select ".addon-permissions", text: /Call the boxes service/
    end

    test "a card with no declared permissions renders no permission list at all" do
      get tools_path
      assert_response :success
      assert_select ".addon-permissions", count: 0
    end
  end
end
