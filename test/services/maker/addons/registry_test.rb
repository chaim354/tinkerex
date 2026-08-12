require "test_helper"
require_relative "../../../support/fake_addon_source"

module Maker
  module Addons
    class RegistryTest < ActiveSupport::TestCase
      MANIFEST = {
        "key" => "generators", "title" => "Generators", "icon" => "✏️",
        "description" => "Parametric 2D drawings", "api_version" => "1",
        "entry" => "generators.js", "pins" => { "makerjs" => "makerjs.js" }
      }.freeze

      # THE GLOBAL TEST CACHE IS :null_store (config/environments/test.rb), whose #fetch always calls
      # the block and stores nothing — so "a failed fetch is NOT cached" is unobservable under it and
      # the guard passes whether or not it works. That is the §14e rate-limiting bug's exact shape.
      # A per-test MemoryStore makes the caching real HERE without changing the global default.
      setup do
        @prior_cache = Rails.cache
        Rails.cache = ActiveSupport::Cache::MemoryStore.new
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
      end

      teardown do
        Rails.cache = @prior_cache
        Source.reset!
      end

      test "builds addons from the source's manifests" do
        addon = Registry.find("generators")
        assert_equal "Generators", addon.title
        assert_equal "generators.js", addon.entry
        assert_equal({ "makerjs" => "makerjs.js" }, addon.pins)
        assert_equal [], addon.services
        assert addon.available?
      end

      test "services defaults to [] when the manifest omits it, exactly as pins does" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("pins") ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_equal [], addon.services
      end

      test "a manifest's declared services are carried onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("services" => [ "boxes" ]) ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_equal [ "boxes" ], addon.services
      end

      test "layout defaults to nil when the manifest omits it, exactly as pins/services do" do
        addon = Registry.find("generators")
        assert_nil addon.layout
      end

      test "a manifest declaring layout: wide carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("layout" => "wide") ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_equal "wide", addon.layout
      end

      # Only "wide" is meaningful today. A manifest is fetched from a source this process does not
      # control, so a value it doesn't recognize — a typo, or a value a newer addon invents for a
      # host version we haven't shipped yet — must degrade to the same default as "absent", never
      # raise. (The rendered consequence — the container class this does or doesn't produce — is
      # covered by test/controllers/tools/addons_controller_test.rb.)
      test "an unrecognized layout value degrades to the default rather than erroring" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("layout" => "extra-wide") ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_nil addon.layout
      end

      test "states_key defaults to the addon's own key when the manifest omits it" do
        addon = Registry.find("generators")
        assert_equal "generators", addon.states_key
      end

      # Predates the mutual-declaration constraint below (states_key was added in d000c76, the
      # constraint in the audit-§2.1 fix), so the claimed addon must now reciprocate — otherwise
      # this is exactly the unreciprocated claim the constraint refuses, and `Registry.find` would
      # return nil instead of the addon this test means to inspect.
      test "a manifest's declared states_key carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("states_key" => "legacy-generators"),
          MANIFEST.merge("key" => "legacy-generators", "title" => "Legacy Generators",
                         "shares_states_with" => [ "generators" ])
        ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_equal "legacy-generators", addon.states_key
      end

      # A blank string is not "absent" at the JSON layer the way a missing key is, so this has to be
      # checked separately from the omitted-key case above — `.presence` is what makes both collapse
      # to the same default.
      test "a blank states_key in the manifest falls back to the addon's own key" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("states_key" => "") ])
        Rails.cache.clear
        addon = Registry.find("generators")
        assert_equal "generators", addon.states_key
      end

      test "all is ordered by [title, key], not source order" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "z", "title" => "Zebra"),
          MANIFEST.merge("key" => "a", "title" => "Aardvark")
        ])
        Rails.cache.clear
        assert_equal %w[Aardvark Zebra], Registry.all.map(&:title)
      end

      test "an addon declaring an unsupported api_version is skipped, not raised on" do
        # One bad addon must not take the gallery down. Greying out is the whole point of the
        # `available?` design; refusing to boot would be strictly worse.
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("api_version" => "99") ])
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "a manifest missing a required key is skipped, not raised on" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.except("entry") ])
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "an unreachable source degrades to no addons rather than raising" do
        # THE FAILURE THAT MATTERS. /tools must render an empty gallery, never a 500, when the
        # addon host is down.
        failing = Object.new
        def failing.manifests = raise(Source::Error, "boom")
        Source.stub = failing
        Rails.cache.clear
        assert_empty Registry.all
      end

      test "a failed fetch is NOT cached, so recovery does not wait out the TTL" do
        failing = Object.new
        def failing.manifests = raise(Source::Error, "boom")
        Source.stub = failing
        assert_empty Registry.all

        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST ])
        assert_equal 1, Registry.all.size, "a transient outage must not grey addons out for the TTL"
      end

      # The metadata keys are all OPTIONAL and all degrade. A manifest is fetched from a source this
      # process does not control, so a malformed value must never take /tools down — the same rule
      # `layout` already follows.
      test "the metadata keys carry onto the Addon when the manifest declares them" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "version" => "2.1.0", "author" => "Chaim", "license" => "MIT",
          "homepage" => "https://example.com/gen"
        ) ])
        addon = Registry.find("generators")
        assert_equal "2.1.0", addon.version
        assert_equal "Chaim", addon.author
        assert_equal "MIT", addon.license
        assert_equal "https://example.com/gen", addon.homepage
      end

      test "the metadata keys default to nil when the manifest omits them" do
        addon = Registry.find("generators")
        assert_nil addon.version
        assert_nil addon.author
        assert_nil addon.license
        assert_nil addon.homepage
      end

      test "permissions carry onto the Addon as name/reasoning pairs" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "permissions" => [
            { "name" => "library:write", "reasoning" => "to save your drawing" },
            { "name" => "service:boxes" }
          ]
        ) ])
        addon = Registry.find("generators")
        assert_equal 2, addon.permissions.size
        assert_equal "library:write", addon.permissions.first["name"]
        assert_equal "to save your drawing", addon.permissions.first["reasoning"]
        assert_nil addon.permissions.second["reasoning"]
      end

      # A MALFORMED ENTRY IS DROPPED, NOT RAISED ON, AND NOT RENDERED AS A BLANK ROW. A bare string
      # is the likeliest authoring mistake (the key reads like a list of names), so it is worth
      # naming: it is dropped rather than coerced, because coercing invents a `reasoning` the author
      # never wrote and the card would then vouch for it.
      test "permission entries that are not name-bearing hashes are dropped" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "permissions" => [ { "name" => "state" }, "library:write", { "reasoning" => "no name" }, nil ]
        ) ])
        assert_equal [ "state" ], Registry.find("generators").permissions.map { |p| p["name"] }
      end

      test "permissions defaults to [] when the manifest omits it" do
        assert_equal [], Registry.find("generators").permissions
      end

      test "shares_states_with defaults to [] when the manifest omits it" do
        assert_equal [], Registry.find("generators").shares_states_with
      end

      test "a manifest's declared shares_states_with carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge(
          "shares_states_with" => [ "boxes-next" ]
        ) ])
        assert_equal [ "boxes-next" ], Registry.find("generators").shares_states_with
      end

      # AUDIT §2.1, CLOSED. `states_key` let a manifest declare itself the reader AND WRITER of
      # another addon's saved states — for every user, unconditionally, with nothing checking that
      # the other addon agreed or even existed. It was safe only because every manifest was
      # first-party. The constraint is MUTUAL: the claimant names the target, and the target must
      # name the claimant back.
      test "an addon claiming another's states_key is skipped unless that addon shares back" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST,
          MANIFEST.merge("key" => "thief", "title" => "Thief", "states_key" => "generators")
        ])
        assert_nil Registry.find("thief"), "an unreciprocated states_key claim must not be registered"
        assert_not_nil Registry.find("generators"), "the target addon is unaffected"
      end

      test "a mutual declaration is honoured" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("shares_states_with" => [ "boxes-next" ]),
          MANIFEST.merge("key" => "boxes-next", "title" => "Boxes Next", "states_key" => "generators")
        ])
        assert_equal "generators", Registry.find("boxes-next").states_key
      end

      # A CLAIM ON AN ADDON THAT IS NOT THERE IS STILL REFUSED. The target might appear later, or
      # might be a typo; either way nothing has agreed to the sharing, so the permissive reading
      # ("no target, no harm") would let a typo silently grant itself a private namespace and then
      # start colliding the day the real addon shipped.
      test "a states_key naming an addon that does not exist is refused" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "orphan", "title" => "Orphan", "states_key" => "nobody")
        ])
        assert_nil Registry.find("orphan")
      end

      test "the ordinary case — states_key equal to the addon's own key — is untouched" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("states_key" => "generators") ])
        assert_equal "generators", Registry.find("generators").states_key
      end

      # THE TARGET MUST ITSELF BUILD, NOT MERELY APPEAR IN THE RAW INDEX. "broken" is present in the
      # index and even declares shares_states_with back — but its api_version is one `build` refuses,
      # so it never appears in `Registry.all`. Honouring its claim anyway would grant "claimant"
      # access on behalf of an addon no operator can see in the gallery to audit that grant against.
      test "a states_key naming an addon present in the index but rejected by build is refused" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("key" => "claimant", "title" => "Claimant", "states_key" => "broken"),
          MANIFEST.merge("key" => "broken", "title" => "Broken", "api_version" => "99",
                         "shares_states_with" => [ "claimant" ])
        ])
        assert_nil Registry.find("claimant")
      end

      test "min_host defaults to 0 when the manifest omits it" do
        assert_equal 0, Registry.find("generators").min_host
      end

      # NON-INTEGER min_host DEGRADES TO NO FLOOR, WHICH IS THE SAFER DIRECTION. A typo that made an
      # addon vanish from the gallery would read as "the deploy broke"; a typo that leaves it
      # available reads as "the floor did not apply", which is what actually happened. `"2".to_i` is
      # 2, so coercion would silently honour a value a JSON manifest should not contain.
      test "a non-integer min_host is ignored rather than coerced" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("min_host" => "2") ])
        assert_equal 0, Registry.find("generators").min_host
      end

      test "an integer min_host carries onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("min_host" => 2) ])
        assert_equal 2, Registry.find("generators").min_host
      end

      # THE ADDON IS STILL BUILT AND STILL LISTED. Skipping it would be the easy implementation and
      # the wrong one: an operator who published an addon needs to see WHY it is not usable, and an
      # addon that silently never appears reads as a broken deploy.
      test "an addon asking for a newer host is listed but unavailable, with a reason naming both levels" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL + 1)
        ])
        addon = Registry.find("generators")
        assert_not_nil addon, "the addon must still be listed"
        assert_not addon.available?
        assert_match(/level #{Maker::Addons::Host::LEVEL + 1}/, addon.unavailable_reason)
        assert_match(/level #{Maker::Addons::Host::LEVEL}/, addon.unavailable_reason)
      end

      test "an addon asking for exactly this host level is available" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("min_host" => Maker::Addons::Host::LEVEL)
        ])
        assert Registry.find("generators").available?
      end

      # ---- service_timeouts ------------------------------------------------------------------

      test "service_timeouts defaults to {} when the manifest omits it, exactly as pins does" do
        assert_equal({}, Registry.find("generators").service_timeouts)
      end

      test "a manifest's declared service_timeouts carry onto the Addon" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("service_timeouts" => { "openscad" => 90, "boxes" => 15 })
        ])
        assert_equal({ "openscad" => 90, "boxes" => 15 },
                     Registry.find("generators").service_timeouts)
      end

      test "a non-hash service_timeouts degrades to {} rather than erroring" do
        [ 90, "90", [ "openscad", 90 ], nil ].each do |bad|
          Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("service_timeouts" => bad) ])
          assert_equal({}, Registry.find("generators").service_timeouts,
                       "#{bad.inspect} must degrade, not carry")
        end
      end

      # THE REFUSED VALUES, AND WHY EACH IS REFUSED RATHER THAN COERCED. `"90".to_i` is 90, so
      # coercion would honour a value a JSON manifest should not contain — min_host's argument. 0
      # and negatives are worse than a typo: Net::HTTP reads `read_timeout: 0` as "give up
      # immediately", so honouring one would take a working sidecar down completely instead of
      # leaving today's 30 s in place.
      test "a service_timeouts value that is not a positive integer is dropped, not coerced" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("service_timeouts" => {
            "str" => "90", "zero" => 0, "neg" => -5, "float" => 12.5, "nil" => nil, "ok" => 90
          })
        ])
        assert_equal({ "ok" => 90 }, Registry.find("generators").service_timeouts)
      end

      # PER ENTRY, NOT PER HASH — an addon with two sidecars must not lose the good timeout to the
      # bad one. The assertion above already proves this for a mixed hash; this states it as the
      # rule so a "reject the whole hash if any entry is malformed" simplification fails here.
      test "one malformed service_timeouts entry does not discard its valid siblings" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("service_timeouts" => { "good" => 45, "bad" => "45" })
        ])
        assert_equal({ "good" => 45 }, Registry.find("generators").service_timeouts)
      end

      # THE CAP IS NOT THE REGISTRY'S JOB. It records what the manifest ASKED FOR; the host's
      # ceiling is applied at the point of use (ServiceProxy.read_timeout_for), so lowering
      # ADDON_SERVICE_MAX_TIMEOUT takes effect without waiting out the 5-minute manifest cache.
      test "a service_timeouts value above the host cap is carried unclamped, not refused here" do
        Source.stub = FakeAddonSource.new(manifests: [
          MANIFEST.merge("service_timeouts" => { "slow" => 9_999 })
        ])
        assert_equal({ "slow" => 9_999 }, Registry.find("generators").service_timeouts)
        assert_equal Maker::Addons::ServiceProxy::MAX_TIMEOUT_DEFAULT,
                     Maker::Addons::ServiceProxy.read_timeout_for(9_999),
                     "the clamp belongs to the proxy, and must actually happen there"
      end
    end
  end
end
