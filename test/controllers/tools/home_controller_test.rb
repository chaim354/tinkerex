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
      sign_in_web!(@user, password: PASSWORD)
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
    end

    # EVERY CARD COMES FROM A MANIFEST — asserted as a COUNT, which is the only form that can see a
    # card the @addons loop did not produce. Until openscad migrated, this view ended with a
    # hand-written block rendering an OpenSCAD card whether or not the Registry had anything in it,
    # and the assertion guarding it (`assert_select ".addon-card", text: /OpenSCAD/`) matched BOTH
    # branches of that block — so it could not tell "this addon is registered" from "somebody
    # hardcoded a card". One manifest is stubbed above, so one card; a reintroduced hardcoded card
    # makes this 2 and fails here.
    test "the gallery renders no card the registry did not produce" do
      get tools_path
      assert_response :success
      assert_select ".addon-card", count: 1
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

    # The house stub helper (help_page_test.rb carries the same body). Replaces a SINGLETON method
    # for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    # WHY A TOOL NEVER APPEARED, SHOWN WHERE THE AUTHOR IS LOOKING — but only in a local
    # environment. In production the cards are read by the maker, who can do nothing with
    # "missing icon" (the onboarding rule that moved sidecar env-var names off the cards).
    test "a skipped manifest is named, with its reason, in a local environment" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        MANIFEST, MANIFEST.merge("key" => "broken", "title" => "Broken").except("icon")
      ])
      get tools_path
      assert_response :success
      assert_select ".addon-problems li", count: 1, text: /broken.*missing icon/
      assert_select ".addon-card", count: 1, message: "the notice must not add or remove a card"
    end

    test "a clean index renders no notice" do
      get tools_path
      assert_response :success
      assert_select ".addon-problems", count: 0
    end

    test "production never renders the notice, whatever the index holds" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("icon") ])
      replacing(Rails, :env, -> { ActiveSupport::EnvironmentInquirer.new("production") }) do
        get tools_path
      end
      assert_response :success
      assert_select ".addon-problems", count: 0
    end
  end
end
