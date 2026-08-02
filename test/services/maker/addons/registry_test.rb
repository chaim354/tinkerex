require "test_helper"

module Maker
  module Addons
    class RegistryTest < ActiveSupport::TestCase
      # The registry is process-global and populated at to_prepare. Snapshot and restore it so these
      # tests can register throwaway addons without leaking into the rest of the suite.
      setup { @snapshot = Registry.entries.values.map(&:to_h) }

      teardown do
        Registry.reset!
        @snapshot.each { |attrs| Registry.register(**attrs) }
      end

      test "every registered addon's path resolves with no arguments" do
        # REGRESSION GUARD, GENERALIZED. The gallery renders link_to addon.path_for(self) for every
        # available addon, so a path proc needing an id 500s /tools for every user. This was guarded
        # for OpenSCAD alone, as a naming-convention accident; it now covers ANY addon — including
        # ones living in gems this repo has never seen.
        helpers = Rails.application.routes.url_helpers
        assert Registry.all.any?, "no addons registered — this guard would assert nothing"
        Registry.all.each do |addon|
          path = addon.path_for(helpers)
          assert path.to_s.start_with?("/"), "#{addon.key}: path_for returned #{path.inspect}"
        end
      end

      test "the three host addons are registered at boot" do
        assert_equal %w[boxes generators openscad], Registry.all.map(&:key).sort
      end

      test "register overwrites by key, so a dev reload does not duplicate" do
        2.times do
          Registry.register(key: "dup", title: "Dup", icon: "x", description: "d",
                            available: -> { true }, path: ->(_r) { "/dup" })
        end
        assert_equal 1, Registry.all.count { |a| a.key == "dup" }
      end

      test "all is ordered by title, not by registration order" do
        Registry.reset!
        Registry.register(key: "z", title: "Zebra", icon: "z", description: "",
                          available: -> { true }, path: ->(_r) { "/z" })
        Registry.register(key: "a", title: "Aardvark", icon: "a", description: "",
                          available: -> { true }, path: ->(_r) { "/a" })
        assert_equal %w[Aardvark Zebra], Registry.all.map(&:title)
      end

      test "find accepts a string or a symbol" do
        assert_equal "boxes", Registry.find(:boxes).key
        assert_equal "boxes", Registry.find("boxes").key
      end

      test "available? is evaluated lazily, not at registration" do
        calls = 0
        Registry.register(key: "lazy", title: "Lazy", icon: "l", description: "",
                          available: -> { calls += 1; true }, path: ->(_r) { "/lazy" })
        assert_equal 0, calls, "registration must not evaluate availability"
        Registry.find("lazy").available?
        assert_equal 1, calls
      end
    end
  end
end
