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
        # PR 5's file plane.
        assert caps.fetch("library:read")
        assert caps.fetch("pick:file")
        # Named in the contract, answered false until their own PR. Present-and-false is the
        # point: an addon can be written against a capability before the host has it.
        assert_not caps.fetch("state:crud")
        assert_not caps.fetch("data")
        assert_not caps.fetch("maker:read")
        assert_not caps.fetch("project:current")
      end

      # THE RULE §14c STATES, ASSERTED RATHER THAN REMEMBERED: bump LEVEL in the same commit that
      # flips a capability to true. Pinned as a RELATIONSHIP — the level and the set of true
      # capabilities move together — so flipping one more capability without bumping goes red here
      # rather than shipping a capability no manifest's `min_host` can require.
      #
      # The literals are the point rather than a smell: this test is the ledger of which level
      # bought which capabilities, and updating it IS the deliberate act the rule asks for.
      #
      # LEVEL 3 IS THE FIRST ENTRY THAT BOUGHT NO CAPABILITY, AND THE UNCHANGED LIST IS THE RECORD
      # OF THAT rather than an oversight. State revisions are the SAME `library:write` door growing
      # an optional `state_id`, so there is no name to flip — see Host::LEVEL's own comment. Note
      # what this test therefore does NOT claim: the implication runs one way only (a capability
      # flip requires a bump), never the reverse, so a bump on its own is legitimate and the two
      # literals are updated together whenever either moves.
      test "LEVEL records which capabilities this host has, and moves when they do" do
        assert_equal 3, Maker::Addons::Host::LEVEL
        assert_equal %w[library:read library:write pick:file pick:folder service state:list],
                     Maker::Addons::Host.capabilities.select { |_, v| v }.keys.sort
      end
    end
  end
end
