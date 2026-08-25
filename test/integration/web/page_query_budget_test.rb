require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  # Every page here is rendered at two data sizes and must issue the SAME number of queries.
  #
  # WHY CONSTANCY AND NOT A LITERAL: a literal pins whatever a page happens to cost today, so any
  # unrelated change that adds or removes a single query turns it red with nothing wrong. The
  # property that actually matters is a different one, and it is the one asserted — a page that costs
  # 12 queries is fine forever; a page that costs one query per row is a page that dies on real data.
  #
  # NOT "THE COUNTS DIFFER PER LIBRARY_BACKEND", WHICH IS WHAT THIS COMMENT SAID FROM PR #108 UNTIL
  # 2026-08-13 AND IS FALSE IN THIS FILE. `setup` calls `pin_file_layer_backend("chunk")`, so every
  # test in this class resolves the Chunk adapter on all three legs and measures the same thing three
  # times. Measured with an N+1 deliberately introduced into Maker::AddonOrigin: 11 small / 23 large
  # on the default leg, on share and on s3 — identical, because all three ran chunk. The per-backend
  # argument is real where the adapter is the subject (test/services/file_layer/adapter_contract.rb
  # makes it at length); it is inert in a class that pins one.
  #
  # THIS FILE EXISTS BECAUSE projects#show REGRESSED TO LINEAR AND NOTHING NOTICED. Rich text
  # bodies arrived with the project-page overhaul and the eager load was never extended, so the
  # page went from flat to +1 query per build-log entry with the whole suite still green. Nothing
  # in the suite measured query counts on any web page, which is exactly why that was possible.
  class PageQueryBudgetTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SMALL = 3
    LARGE = 15

    setup do
      @user = User.create!(email: "budget@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # Only the addon-origins test below stubs the source; a reset is harmless for every other test
    # here and keeps the stub from leaking into the next test in this worker.
    teardown { Maker::Addons::Source.reset! }

    # SCHEMA/TRANSACTION and PRAGMA are excluded: they are this page's cost only by accident of
    # being first in the process. The warm-up request in assert_constant_queries is what really
    # keeps them out of the measurement.
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

    # Render once to warm every lazy load (schema, routes, view compilation), then measure twice.
    def assert_constant_queries(path, seed_small, seed_large, label)
      seed_small.call
      get path
      assert_response :success, "#{label} must render before it can be budgeted"
      small = count_queries { get path }

      seed_large.call
      get path
      large = count_queries { get path }

      assert_equal small, large,
                   "#{label} issued #{small} queries at the small size and #{large} at the " \
                   "large one — it grows with the data. Add the missing eager load."
    end

    # A FILE SHAPED LIKE ONE IN A REAL LIBRARY, AND THE CONTENT TOKEN IS THE LOAD-BEARING PART.
    # Without `current_version_id` the port reports no content, so `ThumbnailMap` short-circuits
    # before its preview query ever runs — every page here was budgeting a thumbnail path that was
    # not executing, and an N+1 in it would have been invisible. `files_type_filter_test.rb` learned
    # this the same way: its first version seeded token-less rows and measured a page that was
    # doing 6008 queries.
    #
    # THE BACKFILL IS ABSORBED BY THE WARM-UP RENDER, not disabled. `assert_constant_queries`
    # renders once before each measurement, and SMALL/LARGE are both far under BACKFILL_LIMIT, so
    # every row already has its preview by the time the counted request runs — the measurement is
    # of the steady state, which is the state a page is in for all but its first view.
    def node!(id, name)
      @user.nodes.create!(node_id: id, name: name, kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000,
                          content_hash: "h-#{id}", current_version_id: "v-#{id}")
    end

    test "projects#show does not grow with attachments, tasks or build-log entries" do
      project = @user.maker_projects.create!(name: "Budgeted", status: "active")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          project.tasks.create!(user: @user, title: "task #{id}")
          project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                           logged_at: Time.current)
        end
      end

      assert_constant_queries(project_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#show")
    end

    # EVERY PROJECT GETS A COVER, and without one this test could not see the page's cover map at
    # all: `cover_node_id` falls back to the first attachment, so a project with none contributes
    # no node id, `ThumbnailMap.for` is handed an empty list and returns before it queries. N covers
    # resolved in one query is the property this page most needs held — it is the one index whose
    # thumbnail count grows with the row count.
    test "projects#index does not grow with the number of projects" do
      add = lambda do |prefix, count|
        count.times do |i|
          project = @user.maker_projects.create!(name: "#{prefix}#{i}", status: "active")
          node!("pc-#{prefix}#{i}", "pc-#{prefix}#{i}.stl")
          project.file_attachments.create!(user: @user, node_id: "pc-#{prefix}#{i}", role: "image")
        end
      end
      assert_constant_queries(projects_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#index")
    end

    # Same reasoning as projects#index above: a model with no attachment has no derived cover, so
    # the grid's `@covers` map was being budgeted while resolving nothing.
    test "models#index does not grow with the number of models" do
      add = lambda do |prefix, count|
        count.times do |i|
          model = @user.maker_models.create!(title: "#{prefix}#{i}", slug: "#{prefix}#{i}")
          node!("mc-#{prefix}#{i}", "mc-#{prefix}#{i}.stl")
          model.file_attachments.create!(user: @user, node_id: "mc-#{prefix}#{i}", role: "image")
        end
      end
      assert_constant_queries(models_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "models#index")
    end

    test "models#show does not grow with attachments or print runs" do
      model = @user.maker_models.create!(title: "Shown", slug: "shown")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          model.file_attachments.create!(user: @user, node_id: id, role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success")
        end
      end
      assert_constant_queries(model_path(model),
                              -> { add.call("ms", SMALL) },
                              -> { add.call("ml", LARGE - SMALL) },
                              "models#show")
    end

    test "files#index folder view does not grow with the number of nodes" do
      add = lambda do |prefix, count|
        count.times { |i| node!("#{prefix}#{i}", "#{prefix}#{i}.stl") }
      end
      assert_constant_queries(files_path,
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "files#index (folder)")
    end

    # THE REVERSE LOOKUP MUST NOT BE PER ROW. `Maker::AddonOrigin.for` resolves a whole page at a
    # fixed cost; written as a per-node (or per-state) lookup it is invisible on a three-file fixture
    # and fatal on a real library, which has never had pagination in flat mode and was measured at
    # 2000 nodes. Constancy, never a literal, for the reason in this class's header: growth with row
    # count is the defect, and a literal would additionally go red on any unrelated query this page
    # gains or loses.
    #
    # ONE STATE PER FILE, NOT ONE STATE WITH MANY FILES, because those are two different Ns and only
    # this shape moves both. Ten files on one saved box leave `claims.map(&:last).uniq` a single id,
    # so a per-STATE lookup stays flat however many files are added — the exact mutation that stayed
    # green in Maker::AddonOriginTest until a second axis was added there. It is also the realistic
    # library: many saved boxes, an output file or two each.
    #
    # THE SOURCE IS STUBBED so `Registry.all` returns a real addon and the page renders the whole
    # feature. Unstubbed it degrades to [] (no ADDON_SOURCE_* in the test env), which still exercises
    # `AddonOrigin.for` but stops short of `link_for` finding anything — a weaker measurement of the
    # same page for no saving.
    test "files#index does not grow with the number of addon-produced files" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        { "key" => "boxes", "title" => "Box Generator", "icon" => "📦", "description" => "d",
          "api_version" => "1", "entry" => "boxes.js" }
      ])
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.svg")
          state = @user.maker_addon_states.create!(addon_key: "boxes", name: "box #{id}", data: {})
          state.files.create!(node_id: id, role: "output", position: 0)
        end
      end
      assert_constant_queries(files_path,
                              -> { add.call("as", SMALL) },
                              -> { add.call("al", LARGE - SMALL) },
                              "files#index (addon origins)")
    end

    test "trash#index does not grow with the number of tombstones" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.nodes.create!(node_id: "#{prefix}#{i}", name: "#{prefix}#{i}.stl", kind: "file",
                              size: 1, mtime: 1_700_000_000_000_000_000, deleted: true)
        end
      end
      assert_constant_queries(trash_index_path,
                              -> { add.call("ts", SMALL) },
                              -> { add.call("tl", LARGE - SMALL) },
                              "trash#index")
    end
  end
end
