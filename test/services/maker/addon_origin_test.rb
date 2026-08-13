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

    # THE VALUE IS THE Maker::AddonState ROW ITSELF. It was a one-member `Origin` Data wrapper until
    # the caller (AddonOrigins#addon_origins_for) was written and turned out to read the state and
    # nothing else — see the note on #for.
    test "resolves a node to the state that produced it" do
      origins = Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz])
      assert_equal @state.id, origins["node-a"].id
      assert_equal "boxes", origins["node-a"].addon_key
      assert_equal "shelf box", origins["node-a"].name
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
    # THE BULK NODES ARE REAL HITS, not misses. The lookup returns early on `claims.empty?`, so ten
    # node ids that resolve to nothing cost one query however the body below is written — the growth
    # this exists to catch would be invisible.
    test "the query count does not grow with the number of nodes" do
      10.times { |i| @state.files.create!(node_id: "bulk-#{i}", role: "output", position: 10 + i) }
      one = count_queries { Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a]) }
      many = count_queries do
        Maker::AddonOrigin.for(user: @user, node_ids: (0...10).map { "bulk-#{it}" } + %w[node-a])
      end
      assert_equal one, many
    end

    # THE SECOND AXIS, AND THE TEST ABOVE IS BLIND TO IT. Every node there belongs to ONE state, so
    # `claims.map(&:last).uniq` is a single id and a per-STATE lookup — resolving each claim with its
    # own `find_by` instead of one batched `where` — stays constant however many NODES are added.
    # Found by mutating exactly that and watching the file stay green. It is also the realistic
    # shape: a Files page shows output from many saved boxes, one state each, so growth in DISTINCT
    # STATES is the N that actually moves in production.
    test "the query count does not grow with the number of distinct states" do
      10.times do |i|
        other = @user.maker_addon_states.create!(addon_key: "boxes", name: "box #{i}", data: {})
        other.files.create!(node_id: "multi-#{i}", role: "output", position: 0)
      end
      one = count_queries { Maker::AddonOrigin.for(user: @user, node_ids: %w[multi-0]) }
      many = count_queries do
        Maker::AddonOrigin.for(user: @user, node_ids: (0...10).map { "multi-#{it}" })
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

    # THE QUERY PLAN, NOT THE QUERY COUNT — and it takes TWO assertions, because neither of them
    # catches both reverts and the obvious single assertion catches the wrong one.
    #
    # A COUNT ASSERTION WOULD BE USELESS HERE. The join spelling this method rejects
    # (`joins(<string>) + includes`) issues TWO statements of its own whenever it matches a row, so
    # `assert_equal 2, count_queries` stays green through the exact revert it appears to guard.
    #
    # THE SHAPE IS ASSERTED STRUCTURALLY AND THE PLAN IS ASSERTED SEPARATELY, because they fail for
    # different reasons and only one of them is content-independent.
    #
    # THE NO-JOIN ASSERTION IS THE DURABLE ONE. It pins the two-statement shape the argument in
    # Maker::AddonOrigin#for rests on, and nothing about the data can change its answer.
    #
    # THE INDEX ASSERTION IS THE ONE THAT NOTICES A DROPPED MIGRATION, and it is deliberately NOT
    # trusted to catch a join revert, even though it happens to today: SQLite's plan for the join
    # depends on table CONTENT as well as on stats, and it was probed choosing at least three
    # different shapes — the composite probe (what this test DB produces, and what makes the join
    # revert fail here), a bare `SCAN maker_addon_files` at fixture scale once ANALYZE has run, and
    # `index_maker_addon_files_on_node_id` itself both at production scale after ANALYZE and at a
    # degenerate one-row scale. That last shape is the point: an index assertion alone would PASS a
    # join revert on some databases. Do not delete the no-join assertion on the grounds that this
    # one already covers it.
    #
    # A COUNT ASSERTION WOULD COVER NEITHER. The join spelling this method rejects
    # (`joins(<string>) + includes`) issues TWO statements of its own whenever it matches a row, so
    # `assert_equal 2, count_queries` stays green through the exact revert it appears to guard.
    #
    # Couples to SQLite's EXPLAIN wording, which is worth it here. The skip cannot fire in bin/ci:
    # LIBRARY_BACKEND selects a FileLayer adapter, not a database, and all three legs plus the test
    # env report adapter_name "SQLite" (verified on each).
    test "the lookup reaches the index the migration added, and never joins the two tables" do
      skip "EXPLAIN wording is SQLite's" unless ActiveRecord::Base.connection.adapter_name == "SQLite"

      statements = capture_sql { Maker::AddonOrigin.for(user: @user, node_ids: %w[node-a node-zzz]) }

      joined = statements.select { |s| s.match?(/\bJOIN\b/i) }
      assert_empty joined,
                   "resolving an origin must not put maker_addon_files and maker_addon_states in " \
                   "one statement — see Maker::AddonOrigin#for for the measurements. Got:\n#{joined.join("\n")}"

      files = statements.select { |s| s.include?("maker_addon_files") }
      assert_equal 1, files.size, "exactly one statement should touch maker_addon_files"
      plan = explain_plan(files.sole)
      assert_includes plan, "index_maker_addon_files_on_node_id",
                      "the node_id lookup no longer reaches its index — plan was:\n#{plan}"
      assert_not_includes plan, "SCAN maker_addon_files", "the node_id lookup degraded to a scan"
    end

    # --- link_for: the states_key -> route mapping -------------------------------
    #
    # REAL Addon VALUES, BUILT BY `Registry.build`, NOT A THREE-MEMBER Struct. The double a Struct
    # would give is exactly the shape §14e warns about: it would agree with this code about which
    # readers exist and could not notice `states_key` defaulting differently, being renamed, or
    # `build` refusing a manifest. Building costs one hash.
    def addon(key, states_key: nil, title: "Box Generator")
      manifest = { "key" => key, "title" => title, "icon" => "box", "description" => "d",
                   "api_version" => Maker::Addons::Registry::API_VERSION, "entry" => "index.js" }
      manifest["states_key"] = states_key if states_key
      Maker::Addons::Registry.build(manifest).tap { |a| assert_not_nil a, "manifest did not build" }
    end

    # THE NORMAL CASE IS AN EXACT `key` MATCH, because Registry defaults states_key to key. Asserted
    # against a rival that declares the same states_key and is listed FIRST, so a `find` on
    # states_key alone (the one-line spelling) picks the wrong addon and fails here.
    test "link_for prefers the addon whose own key matches" do
      addons = [ addon("boxes-next", states_key: "boxes", title: "Boxes Next"), addon("boxes") ]
      assert_equal({ url: "/tools/boxes?state=#{@state.id}", title: "Box Generator" },
                   Maker::AddonOrigin.link_for(@state, addons:))
    end

    # THE FALLBACK, for a successor addon that deliberately took over a predecessor's namespace
    # (Registry's states_key/shares_states_with pair). Without it, every file the old addon made
    # would lose its "Edit in" entry the day the old manifest was withdrawn.
    test "link_for falls back to an addon that declares the states_key" do
      addons = [ addon("boxes-next", states_key: "boxes", title: "Boxes Next") ]
      assert_equal({ url: "/tools/boxes-next?state=#{@state.id}", title: "Boxes Next" },
                   Maker::AddonOrigin.link_for(@state, addons:))
    end

    # nil, NOT A GUESSED PATH. An addon whose manifest has been withdrawn (or a source outage, which
    # answers []) leaves saved output with nowhere to go, and a link to /tools/boxes that 404s is
    # worse than no link: the caller drops the key entirely, so no attribute is rendered and the menu
    # entry is simply absent.
    test "link_for is nil when no registered addon claims the key" do
      assert_nil Maker::AddonOrigin.link_for(@state, addons: [])
      assert_nil Maker::AddonOrigin.link_for(@state, addons: [ addon("generators") ])
    end

    # THE URL IS BUILT FROM THE ROUTE HELPER, NOT INTERPOLATED — asserted here as a path RECOGNISED
    # by the router rather than only as a string, so a future change to the /tools/:key shape cannot
    # leave this method emitting a path that merely looks right.
    test "link_for's url is the real addon route carrying ?state=" do
      link = Maker::AddonOrigin.link_for(@state, addons: [ addon("boxes") ])
      recognized = Rails.application.routes.recognize_path(link[:url])
      assert_equal({ controller: "tools/addons", action: "show", key: "boxes" }, recognized)
      assert_equal @state.id.to_s, Rack::Utils.parse_query(URI.parse(link[:url]).query)["state"]
    end

    def capture_sql
      out = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          out << payload[:sql]
        end
      end
      yield
      out
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    def explain_plan(sql)
      ActiveRecord::Base.connection
                        .select_all("EXPLAIN QUERY PLAN #{sql}").rows.map(&:last).join("\n")
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
