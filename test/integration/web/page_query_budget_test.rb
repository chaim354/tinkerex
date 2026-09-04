require "test_helper"
require_relative "../../support/fake_addon_source"
require "support/git_repo_fixture"

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
    include GitRepoFixture

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
      # THE FOLDER, NOT JUST THE RELATION, HAS TO GROW TOO. Since stage 2's S2-2 the panel's file
      # list is Maker::ProjectFolderListing (one dirs pluck, one capped files query, one count),
      # and it is a genuinely separate code path from @attachments -- an eager load missing on
      # either side is invisible unless BOTH grow, which is the exact shape this file's own header
      # names for build-log rich text (flat, then +1 query per entry, whole suite green).
      folder = project_folder_rows!(@user, project)
      # STAGE 2, S2-4: the BOM panel grows too -- one line per iteration, CYCLING through the
      # three kinds (not all three every time) so the total stays UNDER Projects::BomLinesController
      # ::PANEL_CAP at the small size. The panel caps its table at PANEL_CAP rows, so a seed that
      # already exceeds the cap at BOTH sizes would saturate `shown` at the same row count either
      # way and make a per-row N+1 invisible to this measurement -- probed, not assumed: with all
      # three kinds added every iteration (9 lines at SMALL=3, already past PANEL_CAP=8), a
      # deliberately reintroduced per-row node lookup in the view stayed GREEN here.
      bom = project.boms.create!(user: @user)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          # A SUBFOLDER PER ITERATION exercises the dir WALK (collect_dirs), not merely the row
          # count a flat folder would grow.
          sub = @user.nodes.create!(node_id: "#{id}-dir", name: id, kind: "dir",
                                    parent_node_id: folder.node_id, size: 0,
                                    mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-file", name: "#{id}.stl", kind: "file",
                              parent_node_id: sub.node_id, size: 1,
                              mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          # THE LINKED CASE: an attachment to a node OUTSIDE the folder, growing @linked_rows.
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          project.tasks.create!(user: @user, title: "task #{id}")
          project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                           logged_at: Time.current)
          case i % 3
          when 0
            bom_item = @user.maker_inventory_items.create!(name: "bom-item-#{id}", unit: "each")
            bom.lines.create!(user: @user, inventory_item: bom_item, quantity: 1, unit: "each")
          when 1
            node!("bf-#{id}", "bom-#{id}.stl")
            bom.lines.create!(user: @user, node_id: "bf-#{id}", quantity: 1, unit: "each")
          else
            bom.lines.create!(user: @user, part_name: "bom-text-#{id}", quantity: 1, unit: "each")
          end
        end
      end

      assert_constant_queries(project_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#show")
    end

    # STAGE 2, S2-4: the full BOM page renders every line, unlike the project page's capped panel
    # above -- its own budget, over the same three-kinds-per-iteration growth.
    test "boms#show does not grow with lines" do
      project = @user.maker_projects.create!(name: "Budgeted BOM", status: "active")
      bom = project.boms.create!(user: @user)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          item = @user.maker_inventory_items.create!(name: "item-#{id}", unit: "each")
          node!("bf-#{id}", "bom-#{id}.stl")
          bom.lines.create!(user: @user, inventory_item: item, quantity: 1, unit: "each")
          bom.lines.create!(user: @user, node_id: "bf-#{id}", quantity: 1, unit: "each")
          bom.lines.create!(user: @user, part_name: "text-#{id}", quantity: 1, unit: "each")
        end
      end

      assert_constant_queries(project_bom_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "boms#show")
    end

    # EVERY PROJECT GETS A COVER, and without one this test could not see the page's cover map at
    # all: `cover_node_id` falls back to the first attachment, so a project with none contributes
    # no node id, `ThumbnailMap.for` is handed an empty list and returns before it queries. N covers
    # resolved in one query is the property this page most needs held — it is the one index whose
    # thumbnail count grows with the row count.
    test "projects#index does not grow with the number of projects" do
      add = lambda do |prefix, count|
        count.times do |i|
          # A tag per project too (stage 2, S2-5, review 2026-09-04), so the filter-chip query
          # (@project_tags) is under measurement -- the same reasoning inventory#index's own
          # category-per-item seed states below.
          project = @user.maker_projects.create!(name: "#{prefix}#{i}", status: "active",
                                                  tag_list: "#{prefix}tag#{i}")
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

    # THIS PAGE GROWS ON TWO AXES AT ONCE -- one row per shelf, and each row's live/missing
    # indicator scanned against every DIRECTORY in the library -- so it is seeded on both. The scan
    # is Ruby over ONE pluck that ShelvesController#decorate memoizes across the whole map; drop
    # that memo and the page costs a pluck per shelf, which is precisely the linear-in-rows shape
    # this file exists for and which no assertion about the rendered markup can see.
    test "shelves#index does not grow with shelves or directories" do
      # Stamped, so seeding is not a write inside the measured requests. It would be absorbed by the
      # warm-up render either way; this makes what is being counted unambiguous.
      @user.update_column(:shelves_seeded_at, Time.current)
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_shelves.create!(path: "#{prefix}#{i}")
          @user.nodes.create!(node_id: "sd-#{prefix}#{i}", name: "#{prefix}#{i}", kind: "dir",
                              size: 0, mtime: 1_700_000_000_000_000_000)
        end
      end
      assert_constant_queries(shelves_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "shelves#index")
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

    # THE HERO IS SEEDED TOO, NOT JUST THE RECENT LISTS — a current project is what makes
    # HomeController#index actually enter the hero's branch (tasks, stats, the latest entry, the
    # folder-ensure), so a page seeded with no current project would budget only the anonymous
    # empty-hero path and miss an N+1 in the branch every signed-in visit with a project actually
    # takes. The hero project itself gains one task, one attachment and one log entry per seed step for the same reason: its task
    # list is loaded with `.to_a` (one query regardless of row count), so growing EVERY collection the hero
    # reads is what would catch a per-row query if one crept in — with only the tasks growing, a
    # per-attachment probe in the stats line stayed green (found in review, 2026-09-04).
    test "home#index does not grow with projects, files, runs or tasks" do
      hero = @user.maker_projects.create!(name: "Hero", status: "active")
      patch current_project_path, params: { project_id: hero.id }
      # THE HERO'S FOLDER GROWS TOO — a subfolder with a file per step — because the hero now counts
      # the folder through Maker::ProjectFolderListing, and a listing budgeted over an EMPTY folder
      # cannot see a per-dir query: the review's per-dir mutation reddened projects#show and left this
      # test green until the folder was seeded (2026-09-04).
      hero_folder = project_folder_rows!(@user, hero)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          sub = @user.nodes.create!(node_id: "#{id}-dir", name: "sub-#{id}", kind: "dir",
                                    parent_node_id: hero_folder.node_id, mtime: 1, size: 0)
          @user.nodes.create!(node_id: "#{id}-in", name: "#{id}.pdf", kind: "file",
                              parent_node_id: sub.node_id, mtime: 1, size: 1)
          project = @user.maker_projects.create!(name: "P #{id}", status: "active")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          model = @user.maker_models.create!(title: "M #{id}", slug: "m-#{id}")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "failed")
          hero.tasks.create!(user: @user, title: "task #{id}")
          hero.file_attachments.create!(user: @user, node_id: id, role: "model")
          hero.build_log_entries.create!(user: @user, body: "entry #{id}", logged_at: Time.current)
          # STAGE 2, S2-3: the attention list's second source. Each item is seeded already below
          # its own minimum, so the `low_stock` scope's row count grows past ATTENTION_STOCK (5)
          # between SMALL (3) and LARGE (15) — the same over-the-cap crossing RECENT_PROJECTS etc.
          # already rely on to catch a per-row query the LIMIT alone would hide.
          inv = @user.maker_inventory_items.create!(name: "Inv #{id}", unit: "each", min_quantity: 10)
          Maker::InventoryTransaction.apply!(item: inv, user: @user, delta: 1, reason: "initial")
        end
      end
      assert_constant_queries(root_path,
                              -> { add.call("hs", SMALL) },
                              -> { add.call("hl", LARGE - SMALL) },
                              "home#index")
    end

    # Stage 2, S2-3. Each item gets its OWN location and supplier so `.includes(:location,
    # :supplier)` is what is actually under test — without it this would cost 2 extra queries per
    # row (one per association) instead of the constant 2 the preload issues regardless of N.
    test "inventory#index does not grow with the number of items" do
      add = lambda do |prefix, count|
        count.times do |i|
          location = @user.maker_locations.create!(name: "#{prefix}loc#{i}")
          supplier = @user.maker_suppliers.create!(name: "#{prefix}sup#{i}")
          # A category per item too, so the chip loop is under measurement (review, 2026-09-04).
          # A tag per item too (stage 2, S2-5), for the identical reason on @item_tags.
          @user.maker_inventory_items.create!(name: "#{prefix}item#{i}", unit: "each", location:, supplier:,
                                              category: "#{prefix}cat#{i}", tag_list: "#{prefix}tag#{i}")
        end
      end
      assert_constant_queries(inventory_items_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "inventory#index")
    end

    # Stage 2, S2-5. Each iteration tags one project, one model and one inventory item with the
    # SAME tag ("laser"), so all three of TagsController#show's group queries grow with N while
    # staying well under GROUP_CAP -- crossing that cap would add a count query to only the
    # "large" measurement and fail constancy for a reason that has nothing to do with an N+1, so
    # SMALL/LARGE (3/15) are chosen to stay far under it.
    test "tags#show does not grow with the number of things wearing the tag" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_projects.create!(name: "#{prefix}p#{i}", tag_list: "laser")
          @user.maker_models.create!(title: "#{prefix}m#{i}", tag_list: "laser")
          @user.maker_inventory_items.create!(name: "#{prefix}i#{i}", unit: "each", tag_list: "laser")
        end
      end
      assert_constant_queries(tag_path("laser"),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "tags#show")
    end

    # Each transaction gets its OWN project, for the identical reason: `.includes(:project)` on
    # the ledger scope is the thing under test (mutation c in the plan), and a shared project would
    # let a per-row `t.project` lookup hide behind AR's identity map instead of actually costing a
    # query per row.
    test "inventory#show does not grow with the number of ledger entries" do
      item = @user.maker_inventory_items.create!(name: "Bulk part", unit: "each")
      add = lambda do |prefix, count|
        count.times do |i|
          project = @user.maker_projects.create!(name: "#{prefix}proj#{i}")
          Maker::InventoryTransaction.apply!(item:, user: @user, delta: 1, reason: "restocked", project_id: project.id)
        end
      end
      assert_constant_queries(inventory_item_path(item),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "inventory#show")
    end

    # THE FILE PAGE INSIDE A GIT REPOSITORY, AND THE SUBJECT IS `Library::WorkingTree`. Every other
    # case here grows the page's OWN rows; this one grows the repository AROUND one unchanged file.
    # The walk that decides whether that file is editable is an ANCESTOR walk — a couple of queries
    # per LEVEL, memoised on the parent — and the cheapest way to get it wrong is to answer the same
    # question by looking through a folder's CHILDREN for `.git`. That reads identically on a
    # three-file fixture and costs a query per sibling on a repository the maker actually brought.
    #
    # A REAL SHARE LIBRARY AND A REAL REPOSITORY, via GitRepoFixture#library_root: `.git` has to be
    # a node the scan really indexed (Library::RepoMetadata keeps the marker) before the walk has
    # anything to find, and rows minted by hand would not have one. The pin also makes this case
    # measure the SAME thing on all three backend legs, which is what keeps their run counts equal
    # (§15): nothing in this case varies with the ambient LIBRARY_BACKEND.
    #
    # CONSTANCY, NEVER A LITERAL, for this class's own reason: a literal pins whatever the page
    # costs today and goes red on any unrelated query it gains, while the defect worth catching is
    # growth with N.
    #
    # NOT WRITTEN THROUGH `assert_constant_queries`, and the deviation is small but deliberate: that
    # helper takes the path BEFORE seeding, and here the path IS the seed's result. Its two warm-up
    # renders are kept, because they are what stop a first-render backfill from landing inside a
    # measurement; its failure message is not, because "add the missing eager load" is the wrong
    # remedy for a walk that has started going sideways.
    test "files#show inside a repository does not grow with the repository" do
      file = seed_repo_file!("a.txt", "x\n")
      path = file_path(file.node_id)
      # KEYWORD ARGUMENT: Library::ScanJob#perform is `perform(user_id:, root: nil)`.
      grow = lambda do |prefix, count|
        count.times { |i| File.write(File.join(library_root, "demo", "#{prefix}#{i}.txt"), "y\n") }
        Library::ScanJob.new.perform(user_id: @user.id)
      end

      grow.call("sib", 3)
      get path
      assert_response :success, "files#show must render before it can be budgeted"
      few = count_queries { get path }

      grow.call("more", 30)
      get path
      many = count_queries { get path }

      assert_equal few, many,
                   "files#show issued #{few} queries in a small repository and #{many} in a " \
                   "larger one — it grows with the repository. Library::WorkingTree walks " \
                   "ANCESTORS and memoises on the parent; if this grows it is walking siblings, " \
                   "or the memo is gone."
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
    # THE TWO SETTINGS LISTS (S2-3). Each row shows a count of the items that reference it; the
    # count comes from ONE grouped query, not one per row -- the shape settings_reference_test.rb
    # pins locally and this pins against the seed growing.
    test "suppliers#index does not grow with the number of suppliers" do
      add = lambda do |prefix, count|
        count.times do |i|
          supplier = @user.maker_suppliers.create!(name: "S #{prefix}#{i}", url: "https://example.com/#{prefix}#{i}")
          @user.maker_inventory_items.create!(name: "I #{prefix}#{i}", supplier:)
        end
      end
      assert_constant_queries(suppliers_path,
                              -> { add.call("ss", SMALL) },
                              -> { add.call("sl", LARGE - SMALL) },
                              "suppliers#index")
    end

    test "locations#index does not grow with the number of locations" do
      add = lambda do |prefix, count|
        count.times do |i|
          parent = @user.maker_locations.create!(name: "P #{prefix}#{i}")
          child = @user.maker_locations.create!(name: "C #{prefix}#{i}", parent:)
          @user.maker_inventory_items.create!(name: "I #{prefix}#{i}", location: child)
        end
      end
      assert_constant_queries(locations_path,
                              -> { add.call("ls", SMALL) },
                              -> { add.call("ll", LARGE - SMALL) },
                              "locations#index")
    end
  end
end
