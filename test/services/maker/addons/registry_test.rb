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
    end
  end
end
