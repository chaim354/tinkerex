require "test_helper"

module Maker
  module Addons
    # The capability map is the ONE definition of what this host can do; it is serialized into the
    # addon shell's ctx and read by the SDK's `capabilities()`. The assertions here are about SHAPE,
    # because shape is what silently breaks the client: a nil value reads as `false` in JS with no
    # error anywhere, so an unimplemented capability and a typo'd key become indistinguishable.
    class HostTest < ActiveSupport::TestCase
      test "LEVEL is an integer that a manifest's min_host can be compared against" do
        assert_kind_of Integer, Maker::Addons::Host::LEVEL
        assert_operator Maker::Addons::Host::LEVEL, :>=, 1
      end

      test "every capability value is a real boolean, never nil" do
        Maker::Addons::Host.capabilities.each do |name, value|
          assert_kind_of String, name
          assert_includes [ true, false ], value, "capability #{name.inspect} is #{value.inspect}"
        end
      end

      test "the map is frozen, so a request cannot mutate the host's answer" do
        assert Maker::Addons::Host.capabilities.frozen?
      end

      test "the capabilities this PR implements are true and the rest are declared false" do
        caps = Maker::Addons::Host.capabilities
        assert caps.fetch("library:write")
        assert caps.fetch("state:list")
        assert caps.fetch("service")
        assert caps.fetch("pick:folder")
        # Named in the contract, answered false until their own PR. Present-and-false is the
        # point: an addon can be written against a capability before the host has it.
        assert_not caps.fetch("library:read")
        assert_not caps.fetch("state:crud")
        assert_not caps.fetch("data")
        assert_not caps.fetch("maker:read")
        assert_not caps.fetch("pick:file")
        assert_not caps.fetch("project:current")
      end
    end
  end
end
