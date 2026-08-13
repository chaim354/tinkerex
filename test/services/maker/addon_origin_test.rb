require "test_helper"

module Maker
  class AddonOriginTest < ActiveSupport::TestCase
    # Counts calls into the addon source, which is what Maker::Addons::Registry fetches through.
    # A raising double would prove nothing here: Registry.manifests rescues StandardError and
    # answers [], so an accidental fetch would be swallowed and the test would still pass.
    class CountingAddonSource
      attr_reader :calls

      def initialize = @calls = 0
      def manifests = (@calls += 1) && []
      def cacheable? = false
    end

    setup do
      @user = User.create!(email: "origin@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @state = @user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box",
                                                data: {}, revision: 3)
      @state.files.create!(node_id: "node-a", role: "output", position: 0)
      @state.files.create!(node_id: "node-b", role: "output", position: 1)
    end

    teardown { Maker::Addons::Source.reset! }

    test "resolves a node to the state that produced it" do
      origins = Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz])
      assert_equal @state.id, origins["node-a"].state.id
      assert_equal "boxes", origins["node-a"].addon_key
      assert_equal "shelf box", origins["node-a"].state.name
    end

    # AN ABSENT KEY, NOT A RAISE AND NOT A NIL VALUE — the caller holds a page of node ids and most
    # of them will not be addon output. Same contract as the port's own stat_all (CLAUDE.md §14a).
    #
    # `assert_nil origins["node-zzz"]` ALONE WOULD NOT SEE THE DIFFERENCE: a hash carrying an
    # explicit nil answers it identically. The key set is what tells the two apart, so it is what
    # is asserted, alongside a real hit so an implementation that answered {} unconditionally could
    # not pass.
    test "a node no addon produced is simply absent" do
      origins = Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz])
      assert_equal %w[node-a], origins.keys
      assert_not origins.key?("node-zzz")
      assert_nil origins["node-zzz"]

      assert_empty Maker::AddonOrigin.for(user: @user, node_ids: %w[node-zzz])
    end

    test "another user's addon output is never resolved" do
      other = User.create!(email: "origin2@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      theirs = other.maker_addon_states.create!(addon_key: "boxes", name: "theirs", data: {})
      theirs.files.create!(node_id: "node-theirs", role: "output", position: 0)

      assert_empty Maker::AddonOrigin.for(user: @user, node_ids: %w[node-theirs])
    end

    # PINS THE CONTRACT, NOT THE LINE THAT LOOKS LIKE ITS GUARD, and that is worth saying because
    # the resemblance is misleading. `for`'s `return {} if ids.empty?` can be deleted and this test
    # still passes: `where(node_id: [])` compiles to `WHERE 1=0` and Rails short-circuits `pluck`
    # on it without issuing a statement. Verified by removing that line and watching the whole file
    # stay green. Kept because a caller handing over an empty page must cost nothing whatever
    # ActiveRecord does about empty IN lists in some later version.
    test "an empty node_ids list makes no query at all" do
      assert_equal 0, count_queries { Maker::AddonOrigin.for(user: @user, node_ids: []) }
      assert_equal 0, count_queries { Maker::AddonOrigin.for(user: @user, node_ids: nil) }
    end

    # CONSTANT IN N, NOT A LITERAL. A per-node lookup here is an N+1 on a 2000-node library page,
    # and page_query_budget_test.rb asserts constancy for exactly that reason. A literal would also
    # pin one LIBRARY_BACKEND leg and fail the other two.
    #
    # THE BULK NODES ARE REAL HITS, not misses: a lookup written per node would be constant at 1
    # against ten node ids that resolve to nothing, so the growth this exists to catch would be
    # invisible.
    test "the query count does not grow with the number of nodes" do
      10.times { |i| @state.files.create!(node_id: "bulk-#{i}", role: "output", position: 10 + i) }
      one = count_queries { Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a]) }
      many = count_queries do
        Maker::AddonOrigin.for(user: @user, node_ids: (0...10).map { "bulk-#{it}" } + %w[node-a])
      end
      assert_equal one, many
    end

    # THE REGISTRY IS NEVER CONSULTED HERE, AND THAT IS THE REASON THIS CLASS HAS TWO METHODS.
    # `Maker::Addons::Registry.all` fetches manifests over HTTP behind a 5-minute cache; making that
    # call from the lookup would turn an addon-source outage into a slow Files page for a user who
    # has never opened /tools. Asserted with a real counting double rather than by reading the code,
    # and asserted on the HIT path too — the no-hit path is the easy half.
    test "resolving addon output makes no call to the addon source" do
      source = CountingAddonSource.new
      Maker::Addons::Source.stub = source

      Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz])
      Maker::AddonOrigin.for(user: @user, node_ids: %w[node-zzz])
      assert_equal 0, source.calls

      # And the double really does count, so a zero above means "not called" rather than "not
      # wired". Without this line the assertion could not fail.
      Maker::Addons::Registry.all
      assert_equal 1, source.calls
    end

    # SCHEMA/TRANSACTION/PRAGMA are excluded for the reason page_query_budget_test.rb gives: they
    # are this call's cost only by accident of being first in the process.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end
  end
end
