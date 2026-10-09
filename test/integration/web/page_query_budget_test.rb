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
  # AND THE COUNTS DO DIFFER PER LIBRARY_BACKEND, WHICH IS WHAT MAKES CONSTANCY LOAD-BEARING RATHER
  # THAN MERELY PRUDENT. This paragraph has been wrong in both directions: from PR #108 to
  # 2026-08-13 it said the counts differ while `setup` pinned `pin_file_layer_backend("chunk")` and
  # all three legs measured the same adapter (11 small / 23 large with an N+1 deliberately
  # introduced into Maker::AddonOrigin, identical on every leg); then embedded chunk was retired
  # (2026-08-25, §14a: `chunk` is REFUSED), the pin went with it, and until 2026-09-07 this text
  # still described it. `setup` now only creates and signs in a user, so each leg measures ITS OWN
  # adapter — chunk_remote's `stat_all` is two queries where share and s3's is one (§14a) — and a
  # literal here would pin one leg and fail the other two. Noticed stale in S4-8's Task E.
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
      # STAGE 3, S3-2: ONE repo (a `.git` marker child, plus a README.md file) so the CARD is
      # under measurement — added ONCE here, at this fixture's first step, NOT inside `add`
      # below, whose own per-iteration `.git` marker (line ~127) already grows the NUMBER of
      # repo? dirs with N, for an unrelated reason (S3-1's nesting-depth coverage). That
      # pre-existing growth is why Maker::RepoCard's root-node lookup MUST be one batched
      # `WHERE node_id IN (...)` in ProjectsController#show rather than one query per repo — an
      # O(repos) query would already fail this guard today, before this line ever ran, the moment
      # a real project holds more than one repository. The README read itself is a PORT call
      # (`FileLayer.current.read`, i.e. `File.binread`), never `sql.active_record`, so it cannot
      # show up in this guard either way — it fails closed to "README unavailable" here because
      # this row, like every other one this fixture creates, has no real storage_path behind it,
      # and that failure path is exactly what this seed exercises for the card's git facts too.
      firmware = @user.nodes.create!(node_id: "firmware-dir", name: "firmware", kind: "dir",
                                     parent_node_id: folder.node_id, size: 0,
                                     mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "firmware-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                          parent_node_id: firmware.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
      @user.nodes.create!(node_id: "firmware-readme", name: "README.md", kind: "file",
                          parent_node_id: firmware.node_id, size: 12, mtime: 1_700_000_000_000_000_000,
                          content_hash: "h-firmware-readme", current_version_id: "v-firmware-readme")
      # STAGE 4, S4-4: A README AT THE FOLDER'S OWN ROOT, WHICH IS THE READ-THE-README BRANCH.
      # `projects/_readme_editor` renders on every project page, but with NO root README both it and
      # the README card take their empty branches and touch nothing — so a page seeded without this
      # row measures the feature's cheapest shape and says nothing about its real one.
      #
      # MEASURED: adding it moves this page 34 -> 36 queries, and the two are named rather than
      # absorbed. Both are single-node lookups and both are CONSTANT — one for the page, not one per
      # row, which is the only property this file asserts:
      #   * `Maker::Readme.for` reads the README through the port for the card, and on share a read
      #     resolves the node first (FileLayer::Share#live_node!).
      #   * `projects/_readme_editor` stats the same node for the form's `base_token`, likewise one
      #     `nodes` query on share (FileLayer::Share#stat).
      # The row is created HERE, once, never inside `add` below — an editor that started stating per
      # listed row instead of per page would show up as growth, which is the whole point of putting
      # it under measurement.
      #
      # No bytes behind it, like every other node this fixture creates, so Maker::Readme.for fails
      # closed to its note exactly as the repo card's README does — the same failure path, and the
      # port read still happens, which is what is being budgeted.
      @user.nodes.create!(node_id: "root-readme", name: "README.md", kind: "file",
                          parent_node_id: folder.node_id, size: 12, mtime: 1_700_000_000_000_000_000,
                          content_hash: "h-root-readme", current_version_id: "v-root-readme")
      # STAGE 4, S4-1: A COVER, so the HERO is under measurement. It joins the page's one PageNodes
      # union and its thumbnail joins the one ThumbnailMap, both of which are exactly the places a
      # per-cover lookup would hide. `update_column` rather than `update!`, because the derived
      # fallback (Maker::Project#cover_node_id) would otherwise answer from the attachments this
      # fixture grows and the cover would change size with N.
      @user.nodes.create!(node_id: "cover-img", name: "cover.png", kind: "file", parent_node_id: folder.node_id,
                          size: 1, mtime: 1_700_000_000_000_000_000)
      project.update_column(:cover_node_id, "cover-img")
      # STAGE 2, S2-4: the BOM panel grows too -- one line per iteration, CYCLING through the
      # three kinds (not all three every time) so the total stays UNDER Projects::BomLinesController
      # ::PANEL_CAP at the small size. The panel caps its table at PANEL_CAP rows, so a seed that
      # already exceeds the cap at BOTH sizes would saturate `shown` at the same row count either
      # way and make a per-row N+1 invisible to this measurement -- probed, not assumed: with all
      # three kinds added every iteration (9 lines at SMALL=3, already past PANEL_CAP=8), a
      # deliberately reintroduced per-row node lookup in the view stayed GREEN here.
      bom = project.boms.create!(user: @user)
      # STAGE 5, THE FOLDER PANELS (2026-09-08): ONE FOLDER HELD AT THE `list` VIEW, whose ROWS grow
      # with N below. The three views are three different bodies — `browser` is one empty div,
      # `tiles` is a cell per file, `list` is projects/_file_rows — and only a stored override
      # reaches the third, because a plain folder defaults to tiles and a repository to the browser
      # (Maker::ProjectKind.default_view). Without this panel `_file_rows` renders on this page in
      # no view at all and a per-row lookup inside it would be invisible here. ONE folder growing in
      # FILES rather than one per iteration: what a row partial can cost is per ROW, and the number
      # of list PANELS is already covered by the tiles ones below.
      #
      # `views` HIDES NOTHING, so the hidden-panel budget below is untouched by it: layout_for reads
      # `order` and `hidden` off the overrides and this sets neither.
      listed = @user.nodes.create!(node_id: "listed-dir", name: "listed", kind: "dir",
                                   parent_node_id: folder.node_id, size: 0,
                                   mtime: 1_700_000_000_000_000_000)
      project.update!(panels: { "views" => { "folder:listed-dir" => "list" } })
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
          # TWO LEVELS DEEP, A REPO MARKER AND A GENERATED FILE (S3-1): the tree nests, a working
          # tree is a section, and the Generated group reads one origin hash — each a path a
          # per-row read could hide in if the seed never reached it (found in review).
          deep = @user.nodes.create!(node_id: "#{id}-deep", name: "deep", kind: "dir",
                                     parent_node_id: sub.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-deep-file", name: "#{id}-deep.pdf", kind: "file",
                              parent_node_id: deep.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
          # A GERBER PER SUBFOLDER: pcb-role rows are ordinary file rows on this page (the
          # Fabrication panel that once grouped them went on 2026-09-06), kept so the seed still
          # holds a subfolder of them — a shape the tree section renders and must not query per row.
          @user.nodes.create!(node_id: "#{id}-gtl", name: "#{id}.gtl", kind: "file",
                              parent_node_id: sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                              parent_node_id: sub.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
          state = @user.maker_addon_states.create!(addon_key: "fixture", name: "gen #{id}", data: {}, revision: 1)
          state.files.create!(node_id: "#{id}-file", role: "output", position: 0)
          # STAGE 4, S4-4: A LOOSE FILE AT THE FOLDER'S OWN ROOT, so `@listing.loose` GROWS. Every
          # other file this lambda creates lands in a SUBFOLDER, which left the root holding two
          # rows at both sizes — and `@readme_row` is resolved by scanning exactly that list, so a
          # per-row lookup in place of `Maker::Readme.row_in`'s in-memory `find` was CONSTANT here
          # and this guard could not see it (measured: 36 -> 38 at both sizes, green). With this row
          # the same mutation costs one query per loose file and goes red, which is what makes the
          # "in memory over the listing" claim an assertion rather than a comment. It grows the
          # loose-files section of the panel too, an axis nothing else here moved.
          @user.nodes.create!(node_id: "#{id}-loose", name: "#{id}-loose.txt", kind: "file",
                              parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}-loose", current_version_id: "v-#{id}-loose")
          # STAGE 5, THE FOLDER PANELS (2026-09-08): A PLAIN DEPTH-ONE FOLDER PER ITERATION, AND IT
          # IS WHAT MAKES N THE NUMBER OF PANELS ON THIS PAGE. `sub` above carries a `.git` marker,
          # so every panel IT grows opens in the BROWSER — one empty div, no tiles, no rows, no
          # nested section — and a per-folder query in projects/_folder_panel would grow with it
          # while every branch below the panel head stayed unmeasured. This folder is plain: it
          # opens in TILES, draws a cell per file through projects/_file_tile, and recurses into its
          # own nested subfolder through projects/_file_tree_section. TWO FILES rather than one, so
          # a per-tile lookup is a cost that differs from a per-panel one.
          plain = @user.nodes.create!(node_id: "#{id}-plain", name: "plain-#{id}", kind: "dir",
                                      parent_node_id: folder.node_id, size: 0,
                                      mtime: 1_700_000_000_000_000_000)
          2.times do |j|
            @user.nodes.create!(node_id: "#{id}-plain-#{j}", name: "#{id}-plain-#{j}.stl", kind: "file",
                                parent_node_id: plain.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                                content_hash: "h-#{id}-plain-#{j}", current_version_id: "v-#{id}-plain-#{j}")
          end
          plain_sub = @user.nodes.create!(node_id: "#{id}-plain-sub", name: "rev", kind: "dir",
                                          parent_node_id: plain.node_id, size: 0,
                                          mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-plain-nested", name: "#{id}-nested.stl", kind: "file",
                              parent_node_id: plain_sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}-nested", current_version_id: "v-#{id}-nested")
          # ONE MORE ROW IN THE `list` PANEL created before this lambda — see its comment.
          @user.nodes.create!(node_id: "#{id}-listed", name: "#{id}-listed.stl", kind: "file",
                              parent_node_id: listed.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}-listed", current_version_id: "v-#{id}-listed")
          # THE LINKED CASE: an attachment to a node OUTSIDE the folder, growing @linked_rows.
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          project.tasks.create!(user: @user, title: "task #{id}")
          # STAGE 4, S4-1: THE ENTRY CARRIES A PHOTO AND THE FOLDER GAINS AN IMAGE, so the Photos
          # panel (Maker::ProjectPhotos) grows on BOTH of its inputs. The entry photo sits at the
          # library ROOT — where the upload door really puts one — so it is read out of @page_nodes
          # rather than the listing, which is precisely the lookup a per-photo `find_by` would
          # replace; the folder image grows the listing's own half.
          entry = project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                                    logged_at: Time.current)
          node!("#{id}-photo", "#{id}.png")
          entry.file_attachments.create!(user: @user, node_id: "#{id}-photo", role: "image")
          @user.nodes.create!(node_id: "#{id}-img", name: "#{id}.jpg", kind: "file", parent_node_id: sub.node_id,
                              size: 1, mtime: 1_700_000_000_000_000_000)
          # STAGE 3, S3-3: the wiring panel grows too -- one connection per iteration, the same
          # constant-in-N argument as tasks and build-log entries two lines up.
          project.connections.create!(user: @user, from_label: "from-#{id}", to_label: "to-#{id}")
          # STAGE 3, S3-5: A RELEASE PER ITERATION, EACH WITH A FILE, and BOTH halves grow for a
          # reason. The panel has no cap, so the number of releases is what a missing
          # `includes(:rich_text_notes)` costs one query each of; the number of FILES is what a
          # per-row `stat` instead of the page's ONE `stat_all` costs. A seed growing only one of
          # them leaves the other mutation green.
          release = project.releases.create!(user: @user, version: "v#{id}", published_at: Time.current,
                                             notes: "<div>cut #{id}</div>")
          release.files.create!(user: @user, node_id: "#{id}-file", name: "#{id}.stl",
                                path: "#{id}/#{id}.stl", content_token: "h-#{id}", size: 1)
          release.files.create!(user: @user, node_id: id, name: "#{id}.stl", path: "#{id}.stl",
                                content_token: "h-#{id}", size: 1)
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

      # The generated files need an addon the source knows, or the origins are dropped and the
      # Generated group never renders under measurement.
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [
        { "key" => "fixture", "title" => "Fixture", "icon" => "🧪", "description" => "A fixture addon",
          "api_version" => "1", "entry" => "fixture.js" }
      ])
      assert_constant_queries(project_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#show")
      # THE RECENT ROW (slice 6) WAS UNDER MEASUREMENT: one query whatever N is, and its tiles are
      # projects/_file_tile, whose per-tile cost the groups above already grow. It is full (8) at
      # BOTH sizes, so this proves the row rendered, not that a per-tile read inside it would show.
      assert_select ".attachments-panel .recent-files .attachment-tile", 8
    ensure
      Maker::Addons::Source.reset!
    end

    # STAGE 4, S4-7: A HIDDEN PANEL COSTS NO QUERIES. `assert_constant_queries` cannot see this —
    # it compares one page against itself at two sizes, and both sizes would pay the same skipped
    # loads — so the guard is a comparison between two LAYOUTS of one page at one size. A strict
    # inequality rather than a literal for the same reason every other budget here avoids one: the
    # counts differ per LIBRARY_BACKEND (§14e), and what is asserted is that the skip HAPPENS.
    #
    # THREE PANELS AND NO MORE. @tasks and @sheets are counted by the page's stats line and
    # @entries is read by Maker::ProjectPhotos, so skipping any of those three would change a
    # surface other than its own panel — ProjectsController#show says so at each site.
    test "hiding bom, wiring and releases skips their controller loads" do
      project = @user.maker_projects.create!(name: "Skippable", status: "active")
      project_folder_rows!(@user, project)
      bom = project.boms.create!(user: @user)
      3.times do |i|
        bom.lines.create!(user: @user, part_name: "part #{i}", quantity: 1, unit: "each")
        project.connections.create!(user: @user, from_label: "a#{i}", to_label: "b#{i}")
        release = project.releases.create!(user: @user, version: "v#{i}", published_at: Time.current)
        node!("rel-#{i}", "rel-#{i}.stl")
        release.files.create!(user: @user, node_id: "rel-#{i}", name: "rel-#{i}.stl",
                              path: "rel-#{i}.stl", content_token: "h-rel-#{i}", size: 1)
      end

      get project_path(project)
      shown = count_queries { get project_path(project) }

      project.update!(panels: { "hidden" => %w[bom wiring releases] })
      get project_path(project)
      hidden = count_queries { get project_path(project) }

      assert_operator hidden, :<, shown,
                      "a hidden panel still paid for its loads: #{hidden} queries hidden against " \
                      "#{shown} shown. ProjectsController#show gates @bom/@bom_lines/@items/" \
                      "@suppliers, @releases/@release_repos and @connections on @panel_layout."

      # ONE PANEL AT A TIME, BECAUSE THE ASSERTION ABOVE IS AN AGGREGATE AND AN AGGREGATE CANNOT
      # SEE ONE GATE GO. Measured rather than reasoned: with `bom_shown = true` restored in
      # ProjectsController#show — the single mutation this guard was written against — the three
      # hidden panels still saved the wiring and releases loads, so `hidden < shown` held and the
      # guard stayed GREEN over a gate that had stopped working. Each key below is compared against
      # the same `shown`, so each of the three gates carries weight on its own; a strict inequality
      # for the same reason as above, never a literal (§14e).
      %w[bom wiring releases].each do |key|
        project.update!(panels: { "hidden" => [ key ] })
        get project_path(project)
        alone = count_queries { get project_path(project) }

        assert_operator alone, :<, shown,
                        "hiding #{key} alone changed nothing: #{alone} queries with it hidden " \
                        "against #{shown} with every panel shown. Its load in " \
                        "ProjectsController#show is no longer gated on @panel_layout."
      end
    end

    # THE EDIT PAGE COSTS WHAT THE PAGE COSTS (2026-09-09, the page editor): the same action, one
    # flag, and a strip that reads only what the page already loaded. Measured as a difference with
    # the page rather than as a literal, so the three legs' differing baselines cannot pin one.
    test "projects#show in edit mode costs no more queries than the page, and stays constant in folders" do
      project = @user.maker_projects.create!(name: "Edit budget")
      folder = project_folder_rows!(@user, project)
      seed = lambda do |n|
        n.times do |i|
          dir = @user.nodes.create!(node_id: SecureRandom.uuid, name: "part-#{i}", kind: "dir", parent_node_id: folder.node_id, mtime: 1, size: 0)
          @user.nodes.create!(node_id: SecureRandom.uuid, name: "f-#{i}.stl", kind: "file", parent_node_id: dir.node_id, mtime: 1, size: 3)
        end
      end

      seed.call(1)
      get edit_layout_project_path(project) # warm-up
      # KEPT, like the file's other warm-ups: with show_exceptions :rescuable a 404 renders instead
      # of raising, so a broken edit route would otherwise count queries on a page that never drew.
      assert_response :success
      get project_path(project)
      page = count_queries { get project_path(project) }
      small = count_queries { get edit_layout_project_path(project) }
      seed.call(3)
      get edit_layout_project_path(project)
      large = count_queries { get edit_layout_project_path(project) }

      assert_operator small, :<=, page + 1, "edit mode: #{small} vs page: #{page}"
      assert_equal small, large, "the edit page must not grow with folders (#{small} → #{large})"
    end

    # CONTENT BLOCKS ARE ONE QUERY PER RENDER, WHATEVER THEIR NUMBER (2026-09-09; spec §8), on all
    # THREE renders that draw them — and the three are budgeted in one test because they are three
    # different readers of the same rows: ProjectsController#show's ivars, the same action with the
    # editors and the pickers on, and Maker::PublicProject, which shares no eager load with either.
    #
    # WHAT COULD GROW: the blocks themselves; an image block's picture, which must join the page's
    # ONE PageNodes union and its ONE ThumbnailMap rather than being looked up per block; the
    # PICKERS, which render the folder's images once per image BLOCK in edit mode; and, on the
    # visitor's page, `permits?`, which answers per node and costs a query of its own for anything
    # `page_nodes` does not hold — the exact per-line shape the BOM's own comment records above.
    #
    # ONE PROJECT, MEASURED SIGNED OUT AND SIGNED IN AT BOTH SIZES: a visitor's request must never
    # touch Warden, so the public leg is measured with no session, and the two private legs need one.
    test "blocks do not grow the project page, the edit page or the visitor's page" do
      @user.update!(handle: "blockbudget")
      project = @user.maker_projects.create!(name: "Blocked", visibility: "public")
      folder = project_folder_rows!(@user, project)
      photos = @user.nodes.create!(node_id: "blk-photos", name: "photos", kind: "dir",
                                   parent_node_id: folder.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}-#{i}"
          @user.nodes.create!(node_id: "#{id}-img", name: "#{id}.png", kind: "file",
                              parent_node_id: photos.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          project.blocks.create!(user: @user, kind: "text", heading: "Heading #{id}", body: "A **#{id}** shade.")
          project.blocks.create!(user: @user, kind: "link", heading: "Link #{id}", url: "https://e.example/#{id}")
          project.blocks.create!(user: @user, kind: "image", node_id: "#{id}-img", caption: "Caption #{id}")
        end
      end
      sign_out = -> { delete destroy_user_session_path }
      sign_in = -> { post user_session_path, params: { user: { email: @user.email, password: PASSWORD } } }
      public_path = public_project_path("blockbudget", project.slug)

      measure = lambda do
        sign_out.call
        get public_path
        assert_response :success, "the visitor's page must render before it can be budgeted"
        pub = count_queries { get public_path }
        sign_in.call
        get project_path(project)
        assert_response :success
        page = count_queries { get project_path(project) }
        get edit_layout_project_path(project)
        [ pub, page, count_queries { get edit_layout_project_path(project) } ]
      end

      add.call("s", 1)
      pub_small, page_small, edit_small = measure.call
      add.call("l", 5)
      pub_large, page_large, edit_large = measure.call

      assert_equal page_small, page_large, "projects#show grew with blocks (#{page_small} → #{page_large})"
      assert_equal edit_small, edit_large, "the edit page grew with blocks (#{edit_small} → #{edit_large})"
      assert_equal pub_small, pub_large, "the visitor's page grew with blocks (#{pub_small} → #{pub_large})"
    end

    # TABS ARE A SHAPE, NOT DATA (2026-09-09; spec §6), AND THIS IS WHAT SAYS SO. Both pages render
    # from `layout.groups`, which yields each key exactly once whichever group it lands in — so a
    # page cut into six tabs must cost what the same panels cost in one grid. What would break it:
    # a per-pane read (asking the layout, the listing or the blocks again inside each pane), or a
    # pane that re-renders a panel it already captured. Every panel is in the order either way —
    # `layout_for` is total — so the two sizes render the SAME panels, and only the separators differ.
    test "tabs do not grow the project page or the visitor's page" do
      @user.update!(handle: "tabbudget")
      project = @user.maker_projects.create!(name: "Tabbed", visibility: "public")
      project_folder_rows!(@user, project)
      public_path = public_project_path("tabbudget", project.slug)
      sign_out = -> { delete destroy_user_session_path }
      sign_in = -> { post user_session_path, params: { user: { email: @user.email, password: PASSWORD } } }

      measure = lambda do |n|
        keys = (1..n).map { |i| Maker::ProjectKind.tab_key(format("%012x", i)) }
        order = [ "attachments", "photos" ] +
                keys.flat_map.with_index { |k, i| [ k, Maker::Project::PANELS[2 + i] ].compact } + %w[publish]
        project.update!(panels: { "order" => order.uniq, "titles" => keys.to_h { |k| [ k, "T#{k.last(2)}" ] } })

        sign_out.call
        get public_path
        assert_response :success, "the visitor's page must render before it can be budgeted"
        pub = count_queries { get public_path }
        sign_in.call
        get project_path(project)
        assert_response :success, "the project page must render before it can be budgeted"
        [ pub, count_queries { get project_path(project) } ]
      end

      pub_small, page_small = measure.call(1)
      pub_large, page_large = measure.call(6)

      assert_equal page_small, page_large, "projects#show grew with tabs (#{page_small} → #{page_large})"
      assert_equal pub_small, pub_large, "the visitor's page grew with tabs (#{pub_small} → #{pub_large})"
    end

    # STAGE 3, S3-4: THE SAME PROJECT, READ BY A STRANGER. Not a duplicate of the budget above: the
    # public page is a DIFFERENT reader over the same rows (Maker::PublicProject, not
    # ProjectsController#show's ivars), and the two share no eager load — every panel it renders is
    # its own query. It is also the page most exposed to an N+1, being the one a link on the
    # internet points at.
    #
    # NOBODY IS SIGNED IN, AND THAT IS THE MEASUREMENT. `setup` signs @user in, so this test signs
    # out first: a visitor's request must never touch Warden (Public::BaseController stands on
    # ActionController::Base and `shell_signed_in?` asks `public_surface?` FIRST), and measuring as
    # the owner would budget a session lookup no real visitor pays.
    #
    # THE SEED IS `public_page_seed!` BELOW, SHARED WITH projects#preview (stage 4, S4-4). The two
    # pages render the SAME partials over the SAME Maker::PublicProject, so they must be budgeted
    # against the same shape or the second one drifts away from the first.
    test "public projects#show does not grow with files, entries, BOM lines or connections" do
      delete destroy_user_session_path
      project, add = public_page_seed!(handle: "budgeted", name: "Published")
      assert_constant_queries(public_project_path(@user.handle, project.slug),
                              -> { add.call("ps", SMALL) },
                              -> { add.call("pl", LARGE - SMALL) },
                              "public projects#show")
    end

    # A VISITOR'S FILE PAGE COSTS THE SAME ON A BIG PROJECT AS ON A SMALL ONE (stage 4, S4-5). What
    # could grow it: `Maker::PublicProject` builds a LibraryTree and a ProjectFolderListing in its
    # constructor, so a folder with more files must not cost more queries; a .gbrjob's sibling walk
    # is ONE bounded query; and `page_nodes` — the build log, the BOM, every release — must never be
    # loaded at all, which is exactly what a `permits?` answered by ancestry avoids (its own comment
    # says the file route never reaches `visible_page_ids`; this page must not either).
    test "public files#view does not grow with the project's files, entries or releases" do
      delete destroy_user_session_path
      @user.update!(handle: "viewbudget")
      project = @user.maker_projects.create!(name: "Viewed", status: "active", visibility: "public")
      folder = project_folder_rows!(@user, project)
      subject = node!("view-subject", "hero.stl")
      subject.update!(parent_node_id: folder.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          @user.nodes.create!(node_id: id, name: "#{id}.stl", kind: "file", parent_node_id: folder.node_id,
                              size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          entry = project.build_log_entries.create!(user: @user, body: "e#{id}", logged_at: Time.current)
          entry.file_attachments.create!(user: @user, node_id: id, role: "image", position: 0)
          release = project.releases.create!(user: @user, version: "v#{id}", published_at: Time.current)
          release.files.create!(user: @user, node_id: id, name: "#{id}.stl", path: "#{id}.stl",
                                content_token: "h-#{id}", size: 1)
        end
      end
      assert_constant_queries(public_file_view_path(@user.handle, project.slug, "view-subject"),
                              -> { add.call("vs", SMALL) },
                              -> { add.call("vl", LARGE - SMALL) },
                              "public files#view")
    end

    # STAGE 4, S4-4: THE OWNER'S PREVIEW, SIGNED IN — which is the difference worth measuring. It
    # renders the same partials over the same object, plus the app shell (the rail, the top bar,
    # the flash) that a visitor never pays for. That shell cost is a
    # CONSTANT and must stay one: a preview that grew with the project would grow with it on a page
    # the maker opens to check their work, not on a page a stranger opens once.
    #
    # NOT SIGNED OUT, unlike the budget above and every other public one in this file: this route IS
    # session-authed (ProjectsController#preview, `current_user.maker_projects`), so measuring it as
    # a visitor would measure a redirect to the sign-in page.
    #
    # PRIVATE ON PURPOSE. The preview answers at any visibility — that is its whole point, seeing
    # the page before anyone else can — and an unpublished project is the state a maker previews
    # from. Its links are the visitor's and are dead, which is what the banner says and what
    # project_preview_test.rb asserts; none of that changes what this page COSTS.
    test "projects#preview does not grow with files, entries, BOM lines or connections" do
      project, add = public_page_seed!(handle: "previewed", name: "Previewed", visibility: "private")
      assert_constant_queries(preview_project_path(project),
                              -> { add.call("vs", SMALL) },
                              -> { add.call("vl", LARGE - SMALL) },
                              "projects#preview")
    end

    # THE PUBLIC PAGE'S SEED, SHARED BY TWO BUDGETS (stage 4, S4-4). A second copy of this fixture
    # is a pair that drifts, and the preview would then be budgeted against a shape the public page
    # no longer has. Returns [project, add] — the project to build a path from, and the growth
    # lambda both budgets step twice.
    #
    # THE OWNER NEEDS A HANDLE BEFORE THE PROJECT CAN LEAVE `private` — Maker::Project refuses
    # otherwise, and the handle then locks. That ordering is the fixture, not a preference, and it
    # is why the handle is an argument: two tests in one class cannot both claim one.
    def public_page_seed!(handle:, name:, visibility: "public")
      @user.update!(handle:)
      project = @user.maker_projects.create!(name:, status: "active", visibility:)
      folder = project_folder_rows!(@user, project)
      bom = project.boms.create!(user: @user)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          # A SUBFOLDER PER ITERATION, with a `.git` marker and a nested dir -- the projects#show
          # seed's shape above, and here it is what grows the number of REPO CARDS. Maker::
          # PublicProject#repo_cards resolves every card's root node in ONE `WHERE node_id IN (...)`;
          # written as a lookup per repo it would be invisible on a one-repo fixture and linear on a
          # folder that holds a few.
          sub = @user.nodes.create!(node_id: "#{id}-dir", name: id, kind: "dir",
                                    parent_node_id: folder.node_id, size: 0,
                                    mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-git", name: Library::RepoMetadata::DIR_NAME, kind: "dir",
                              parent_node_id: sub.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
          deep = @user.nodes.create!(node_id: "#{id}-deep", name: "deep", kind: "dir",
                                     parent_node_id: sub.node_id, size: 0, mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-file", name: "#{id}.stl", kind: "file",
                              parent_node_id: sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          @user.nodes.create!(node_id: "#{id}-deep-file", name: "#{id}-deep.pdf", kind: "file",
                              parent_node_id: deep.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
          # A GERBER PER SUBFOLDER: pcb-role rows are ordinary file rows on this page (the public
          # Fabrication panel that once grouped them went on 2026-09-06), kept so the seed still
          # holds a subfolder of them — a shape the tree section renders and must not query per row.
          @user.nodes.create!(node_id: "#{id}-gtl", name: "#{id}.gtl", kind: "file",
                              parent_node_id: sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000)
          # STAGE 5, THE FOLDER PANELS (2026-09-08): A PLAIN DEPTH-ONE FOLDER PER ITERATION, so N is
          # the number of PANELS on the visitor's page too, and BOTH arms of
          # public/projects/_folder_panel are under measurement. `sub` above is a repository, whose
          # view is `browser` — which a visitor reads as the LIST table (spec decision 7) — so the
          # repo folders grow the list arm and these grow the TILES arm, a `files/_thumb` cell per
          # file through `pub.thumbs`. Each cell asks that memoised ThumbnailMap and `permits?`,
          # which are exactly the two places a per-row query hides on this page.
          plain = @user.nodes.create!(node_id: "#{id}-plain", name: "plain-#{id}", kind: "dir",
                                      parent_node_id: folder.node_id, size: 0,
                                      mtime: 1_700_000_000_000_000_000)
          2.times do |j|
            @user.nodes.create!(node_id: "#{id}-plain-#{j}", name: "#{id}-plain-#{j}.stl", kind: "file",
                                parent_node_id: plain.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                                content_hash: "h-#{id}-plain-#{j}", current_version_id: "v-#{id}-plain-#{j}")
          end
          # NESTED, because a folder panel renders its subfolders as sub-headings inside itself
          # (`pub.folder_sections`' walk) rather than as panels of their own — a walk that grows
          # with N and must cost no query per level.
          plain_sub = @user.nodes.create!(node_id: "#{id}-plain-sub", name: "rev", kind: "dir",
                                          parent_node_id: plain.node_id, size: 0,
                                          mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-plain-nested", name: "#{id}-nested.stl", kind: "file",
                              parent_node_id: plain_sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}-nested", current_version_id: "v-#{id}-nested")
          # AN IMAGE IN THE FOLDER AND ANOTHER OUTSIDE IT, ATTACHED TO AN ENTRY: the photos panel
          # unions the two, and only the second reaches `page_nodes` -- the map every entry photo and
          # every BOM file target is resolved through, in one query for the page rather than one per
          # attachment.
          @user.nodes.create!(node_id: "#{id}-pic", name: "#{id}.png", kind: "file",
                              parent_node_id: folder.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "hp-#{id}", current_version_id: "vp-#{id}")
          node!("#{id}-shot", "#{id}-shot.png")
          entry = project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                                    logged_at: Time.current)
          entry.file_attachments.create!(user: @user, node_id: "#{id}-shot", role: "image", position: 0)
          project.connections.create!(user: @user, from_label: "from-#{id}", to_label: "to-#{id}")
          # THE LINKED CASE, which is also what grows `attached_ids` -- the two plucks `permits?`
          # answers the attachment arm from, and neither may become a query per attachment.
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          # STAGE 3, S3-5: a release per iteration with TWO files, for the reason the private
          # budget's own comment gives -- and here the file count carries a second load too, since
          # the public panel asks `permits?` per row. Those nodes join Maker::PublicProject#page_nodes
          # precisely so that check is answered from the page's one index rather than a query a row.
          release = project.releases.create!(user: @user, version: "v#{id}", published_at: Time.current,
                                             notes: "<div>cut #{id}</div>")
          release.files.create!(user: @user, node_id: "#{id}-file", name: "#{id}.stl",
                                path: "#{id}/#{id}.stl", content_token: "h-#{id}", size: 1)
          release.files.create!(user: @user, node_id: id, name: "#{id}.stl", path: "#{id}.stl",
                                content_token: "h-#{id}", size: 1)
          # ONE BOM LINE PER ITERATION, CYCLING THE THREE KINDS. The public table has NO cap (unlike
          # the private panel's PANEL_CAP), and the design-file kind is the expensive one: the
          # partial asks `pub.permits?` for every such line so it can decide between a link and
          # plain text, which is exactly where a per-row existence check hides.
          case i % 3
          when 0
            bom_item = @user.maker_inventory_items.create!(name: "pub-item-#{id}", unit: "each")
            bom.lines.create!(user: @user, inventory_item: bom_item, quantity: 1, unit: "each")
          when 1
            bom.lines.create!(user: @user, node_id: "#{id}-file", quantity: 1, unit: "each")
          else
            bom.lines.create!(user: @user, part_name: "pub-text-#{id}", quantity: 1, unit: "each")
          end
        end
      end
      [ project, add ]
    end

    # STAGE 3, S3-6: THE FEED AND THE MANIFEST ARE TWO MORE READERS OVER THE SAME ROWS, and neither
    # rides the page's eager loads — `Public::FeedsController` and `Public::BundlesController` each
    # build their own Maker::PublicProject and read a different slice of it. They also both answer a
    # POLLER rather than a person: a feed reader fetches on a timer and the bundle button fetches
    # the manifest before every download, so a per-row query here is paid over and over by a
    # deployment nobody is even looking at.
    #
    # THE TWO GROWTH AXES ARE DELIBERATELY DIFFERENT. The feed grows with build-log entries and
    # releases and does not care how many files the folder holds; the manifest is the reverse. One
    # test with one seed would leave whichever axis it did not grow unmeasured while reading green.
    test "public feeds#show does not grow with build-log entries or releases" do
      delete destroy_user_session_path
      @user.update!(handle: "feeder")
      project = @user.maker_projects.create!(name: "Fed", status: "active", visibility: "public")
      project_folder_rows!(@user, project)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          # THE RICH TEXT IS THE POINT ON BOTH SIDES. An entry's `body` and a release's `notes` are
          # each an Action Text association, and each is what this file's own header records
          # regressing on projects#show: flat, then +1 query per row, with the whole suite green.
          # The feed renders BOTH bodies, so it carries the hazard twice.
          project.build_log_entries.create!(user: @user, body: "entry #{id}", logged_at: Time.current)
          node!("#{id}-rel", "#{id}.stl")
          release = project.releases.create!(user: @user, version: "v#{id}", published_at: Time.current,
                                             notes: "<div>cut #{id}</div>")
          # A release's FILES are read too — the item's content line counts them — so the
          # association has to be eager-loaded or the count is a query a release.
          release.files.create!(user: @user, node_id: "#{id}-rel", name: "#{id}.stl",
                                path: "#{id}.stl", content_token: "h-#{id}", size: 1)
        end
      end
      # SMALL/LARGE (3/15) both stay under Maker::PublicProject::FEED_CAP (50) on purpose:
      # saturating the cap would hold the rendered item count still between the two measurements
      # and make a per-item query invisible.
      assert_constant_queries(public_feed_path(@user.handle, project.slug),
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "public feeds#show")
    end

    test "public bundles#show does not grow with files" do
      delete destroy_user_session_path
      @user.update!(handle: "bundler")
      project = @user.maker_projects.create!(name: "Bundled", status: "active", visibility: "public")
      folder = project_folder_rows!(@user, project)
      bom = project.boms.create!(user: @user)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          # A SUBFOLDER PER ITERATION as well as a file, because the manifest's paths come from the
          # listing's own tree walk — a folder-relative path re-derived per row by walking parents
          # would be a query per file and is exactly the shape this guard exists to refuse.
          sub = @user.nodes.create!(node_id: "#{id}-dir", name: id, kind: "dir",
                                    parent_node_id: folder.node_id, size: 0,
                                    mtime: 1_700_000_000_000_000_000)
          @user.nodes.create!(node_id: "#{id}-file", name: "#{id}.stl", kind: "file",
                              parent_node_id: sub.node_id, size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          # A BOM LINE PER ITERATION TOO: the manifest itself does not render the BOM, but the
          # readme/`bundle_files` pass shares one Maker::PublicProject with whatever else the
          # controller touches, and a line-per-query here would grow with the same seed.
          bom.lines.create!(user: @user, part_name: "part-#{id}", quantity: 1, unit: "each")
        end
      end
      # Under ProjectFolderListing::FILE_CAP (300) and DIR_CAP (500) at both sizes, for the reason
      # the feed's own comment gives about FEED_CAP.
      assert_constant_queries(public_bundle_path(@user.handle, project.slug),
                              -> { add.call("bs", SMALL) },
                              -> { add.call("bl", LARGE - SMALL) },
                              "public bundles#show")
    end

    # STAGE 3, S3-4: /explore IS THE ONE CROSS-USER PAGE IN THE APP, so its growth axis is one
    # project on one OWNER per step -- a card names its maker (`project.user.handle`) and its tags,
    # and both are `includes`d. A seed that reused one user would let `project.user` come back from
    # AR's identity map and hide a per-card lookup, the same trap inventory#show's own comment
    # records for `.includes(:project)`.
    #
    # THE TAG CHIPS ARE THE SECOND AXIS AND ARE ONE GROUPED QUERY: a distinct tag per project, so
    # the chip list grows too. SMALL/LARGE (3/15) stay under both caps -- ExploreController::PAGE
    # (60) and the chips' own limit (30) -- because saturating either would hold the rendered row
    # count still between the two measurements and make a per-row query invisible.
    test "explore#index does not grow with public projects or tags" do
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          owner = User.create!(email: "explore-#{id}@example.com", password: PASSWORD,
                               confirmed_at: Time.current, handle: "explore-#{id}")
          project = owner.maker_projects.create!(name: "Lamp #{id}", description: "A lamp.",
                                                 status: "active", visibility: "public",
                                                 tag_list: "tag-#{id}")
          # STAGE 4, S4-5: A COVER PER PROJECT, ON A SEED THAT MINTS ONE OWNER PER PROJECT — which
          # is what /explore is. This is not decoration: it is what makes this test ABLE to fail if
          # the cards ever start resolving covers here. Maker::Previews::ThumbnailMap is PER-USER
          # (the row belongs to its owner, the port is asked in the owner's name — §14a), so a cover
          # map on a cross-user list is three statements per distinct maker (measured 14/50 against 5) and this assertion goes
          # red. S4-5 gave covers to /u/:handle for exactly that reason; see that plan's Amendment 9
          # and open question 1, which prices the two ways to give /explore covers.
          #
          # THE NODE IS MINTED ON `owner` RATHER THAN THROUGH `node!`, which is @user-scoped — with
          # the same two content columns it sets, because without a content token the port reports
          # no content and the naive per-card spelling short-circuits before its second query,
          # pricing half of what this seed exists to price.
          owner.nodes.create!(node_id: "#{id}-cover", name: "#{id}.png", kind: "file", size: 1,
                              mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}-cover", current_version_id: "v-#{id}-cover")
          project.file_attachments.create!(user: owner, node_id: "#{id}-cover", role: "image",
                                          position: 0)
        end
      end
      assert_constant_queries(public_explore_path,
                              -> { add.call("es", SMALL) },
                              -> { add.call("el", LARGE - SMALL) },
                              "explore#index")
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
    test "files/models#index does not grow with the number of models" do
      add = lambda do |prefix, count|
        count.times do |i|
          model = @user.maker_models.create!(title: "#{prefix}#{i}", slug: "#{prefix}#{i}")
          node!("mc-#{prefix}#{i}", "mc-#{prefix}#{i}.stl")
          model.file_attachments.create!(user: @user, node_id: "mc-#{prefix}#{i}", role: "image")
        end
      end
      assert_constant_queries(files_models_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "files/models#index")
    end

    # THIS PAGE GROWS ON TWO AXES AT ONCE -- one row per shelf, and each row's live/missing
    # indicator scanned against every DIRECTORY in the library -- so it is seeded on both. The scan
    # is Ruby over ONE pluck that Settings::ShelvesController#decorate memoizes across the whole map; drop
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
      assert_constant_queries(settings_shelves_path,
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

    # A REAL FOLDER, NOT THE ROOT. This test has always been named for the folder view and has
    # always measured the root, where `@folder` is nil — so the folder branch's own reads (the
    # breadcrumb walk, and since S4-6 the project-claim lookup) were never under measurement at
    # all. The root's flat branch is still covered by "files#index does not grow with the number of
    # addon-produced files" below.
    test "files#index folder view does not grow with the number of nodes" do
      folder = @user.nodes.create!(node_id: "budget-dir", name: "cad", kind: "dir",
                                   mtime: 1, size: 0)
      add = lambda do |prefix, count|
        count.times do |i|
          node!("#{prefix}#{i}", "#{prefix}#{i}.stl")
          @user.nodes.find_by!(node_id: "#{prefix}#{i}").update!(parent_node_id: folder.node_id)
        end
      end
      assert_constant_queries(files_path(folder: folder.node_id),
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "files#index (folder)")
    end

    # THE MODEL STRIP (slice 5) MUST NOT GROW WITH THE MODEL: its cover is derived from ONE load of its
    # attachments and its print log is one query, so a model folder with 15 files and 15 prints costs
    # what one with 3 does. Whether Maker::ModelFolder.model_in's eager load holds as hidden rows pile
    # up in one folder is model_folder_test.rb's to say — one model's attachments load once either way.
    test "files#index on a model folder does not grow with attachments or print runs" do
      folder = @user.nodes.create!(node_id: "budget-model-dir", name: "bracket", kind: "dir", mtime: 1, size: 0)
      model = @user.maker_models.create!(title: "Budget Bracket", folder_node_id: folder.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          node!("#{prefix}#{i}", "#{prefix}#{i}.stl")
          @user.nodes.find_by!(node_id: "#{prefix}#{i}").update!(parent_node_id: folder.node_id)
          model.file_attachments.create!(user: @user, node_id: "#{prefix}#{i}", role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success", printer: "P#{i}")
        end
      end
      assert_constant_queries(files_path(folder: folder.node_id), -> { add.call("ms", SMALL) },
                              -> { add.call("ml", LARGE - SMALL) }, "files#index (model folder)")
      # The strip was ON the page measured, cover and print log included — a budget over a page that
      # quietly stopped rendering it would hold for the wrong reason.
      assert_select ".model-strip h2", text: "Budget Bracket"
      assert_select ".model-strip .model-strip-cover[data-controller='thumbs']"
      assert_select ".model-strip .print-run", count: LARGE
    end

    # EVERY BOUNDED LIST RECENT READS GROWS PER STEP — recent projects (each with an attachment, which
    # `cover_node_id` reads), recent files, failed prints and low stock — and the two sizes straddle
    # each list's LIMIT, so a per-row query the LIMIT alone would hide still shows. (The
    # current-project hero, and the seeding it needed, went with the current project in slice 4 of
    # the 2026-10-08 redesign; the prints section went in slice 6, when Home became Recent.)
    #
    # LOCAL SIZES, NOT SMALL/LARGE: RECENT_FILES is 16 since slice 6, and the file's LARGE (15) sits
    # UNDER it, so with the shared constants both sizes would render every file and the straddle this
    # test exists for would be gone for its biggest list. `small` is under every limit here (6, 16, 5,
    # 5) and `large` over all of them.
    test "home#index does not grow with projects, files, failed prints or low stock" do
      small = 3
      large = 20
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          project = @user.maker_projects.create!(name: "P #{id}", status: "active")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          model = @user.maker_models.create!(title: "M #{id}", slug: "m-#{id}")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "failed")
          # STAGE 2, S2-3: the attention list's second source. Each item is seeded already below
          # its own minimum, so the `low_stock` scope's row count grows past ATTENTION_STOCK (5)
          # between `small` and `large` — the same over-the-cap crossing RECENT_PROJECTS etc.
          # already rely on to catch a per-row query the LIMIT alone would hide.
          inv = @user.maker_inventory_items.create!(name: "Inv #{id}", unit: "each", min_quantity: 10)
          Maker::InventoryTransaction.apply!(item: inv, user: @user, delta: 1, reason: "initial")
        end
      end
      assert_constant_queries(root_path,
                              -> { add.call("hs", small) },
                              -> { add.call("hl", large - small) },
                              "home#index")
      # THE STRADDLE, MEASURED RATHER THAN ASSUMED: the large size renders the capped count, so the
      # files query really was cut by its LIMIT while the per-row work stayed flat.
      assert_select ".home-files .grid-card", count: HomeController::RECENT_FILES
      assert_operator large, :>, HomeController::RECENT_FILES
      assert_operator small, :<, HomeController::RECENT_FILES
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

    # STAGE 4, S4-8: THE CONNECTED PANEL IS A FIXED NUMBER OF QUERIES FOR ANY NUMBER OF LINKS —
    # one `touching` read of maker_file_links, one `nodes.present` lookup resolving EVERY partner
    # of every link at once, and one ThumbnailMap for the photo cells. The obvious spelling is the
    # one this guards against: a `nodes.find_by(node_id:)` inside the view's loop, or a second
    # `touching` query per direction, is invisible on a two-link fixture and is a query per photo
    # on a real one.
    #
    # BOTH SHAPES OF ROW GROW, because the four lists come off ONE query but two DIFFERENT columns:
    # a `derived_from` written FROM the subject fills @derived_from, and a `photo_of` written TO it
    # fills @photos — the only list with thumbnail cells behind it. Growing only one column would
    # leave `touching`'s OR half, and the ThumbnailMap, unmeasured.
    #
    # `node!`, not `nodes.create!`: the photo cells resolve through Maker::Previews::ThumbnailMap,
    # which short-circuits on a node the port reports no content for — see that helper's own
    # header. Without the content token this case would budget a path that never executes.
    #
    # CONSTANCY, NEVER A LITERAL (this class's header): the counts differ per LIBRARY_BACKEND leg,
    # so a number here would pin one leg and fail the other two.
    test "files#show does not grow with the number of connected files" do
      subject = node!("cn-subject", "lid.stl")
      path = file_path(subject.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          src = node!("#{prefix}s#{i}", "#{prefix}s#{i}.lbrn2")
          pic = node!("#{prefix}p#{i}", "#{prefix}p#{i}.png")
          @user.maker_file_links.create!(from_node_id: subject.node_id, to_node_id: src.node_id,
                                         kind: "derived_from")
          @user.maker_file_links.create!(from_node_id: pic.node_id, to_node_id: subject.node_id,
                                         kind: "photo_of")
        end
      end
      assert_constant_queries(path, -> { add.call("cs", SMALL) }, -> { add.call("cl", LARGE - SMALL) },
                              "files#show (connections)")
    end

    # THE INSPECTOR IS ONE NODE'S PANEL, so it must not grow with the file's notes or its projects —
    # it is fetched on every selection (structural redesign slice 3). Notes are COUNTED, never
    # loaded; the attach chips come off one eager-loaded query (FilesController#attach_choices_for).
    #
    # `node!`, not `nodes.create!`, for this class's usual reason: without a content token the
    # panel's thumbnail lookup never runs, and an N+1 in it would be invisible. Constancy, never a
    # literal (this class's header).
    test "the inspector does not grow with notes or attached projects" do
      file = node!("panel", "panel.stl")
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_notes.create!(node_id: file.node_id, body: "note #{prefix}#{i}")
          project = @user.maker_projects.create!(name: "P#{prefix}#{i}")
          project.file_attachments.create!(user: @user, node_id: file.node_id, role: "model")
        end
      end
      assert_constant_queries(inspector_file_path(file.node_id),
                              -> { add.call("is", SMALL) },
                              -> { add.call("il", LARGE - SMALL) },
                              "files#inspector")
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

    # STEP 3 OF Tools::AddonsController#tool_destination_node_id IS ONE STATEMENT, and the project
    # mapping walks the request's own LibraryTree — so the page's cost must not grow with how many
    # boxes this user has saved, nor with how deep their folders sit.
    test "tools#show's default folder does not grow with saved states" do
      Maker::Addons::Source.stub = FakeAddonSource.new(
        manifests: [ { "key" => "fixture", "title" => "Fixture", "icon" => "🧪",
                       "description" => "A fixture addon", "api_version" => "1", "entry" => "f.js" } ],
        assets: { "fixture/f.js" => "export default { mount() {} }" }
      )
      project = @user.maker_projects.create!(name: "Budget Lamp")
      folder = project_folder_rows!(@user, project)
      # EACH DIR NESTS UNDER THE LAST, so the seed grows on BOTH axes the comment names: more saved
      # states, and a newest output sitting deeper under the project folder (2 levels small, 8
      # large). Siblings alone leave the walk one level long at both sizes, so a per-level query in
      # #owning_project_folder read constant over a fixture that never deepened (measured: green on
      # siblings, 13 -> 25 queries nested).
      add = lambda do |prefix, count|
        parent = folder.node_id
        count.times do |i|
          id = "#{prefix}#{i}"
          dir = @user.nodes.create!(node_id: "#{id}-dir", name: "d-#{id}", kind: "dir",
                                    parent_node_id: parent, mtime: 1, size: 0)
          @user.nodes.create!(node_id: id, name: "#{id}.svg", kind: "file", parent_node_id: dir.node_id,
                              mtime: 1, size: 1, content_hash: "h-#{id}", current_version_id: "v-#{id}")
          state = @user.maker_addon_states.create!(addon_key: "fixture", name: "box #{id}", data: {})
          state.files.create!(node_id: id, role: "output")
          parent = dir.node_id
        end
      end
      assert_constant_queries(tools_addon_path("fixture"), -> { add.call("s", 2) }, -> { add.call("l", 8) },
                              "tools#show")
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
    # SEARCH READS SEVEN KINDS, EACH ONE CAPPED QUERY PLUS ONE COUNT (S2-5; Notes and Folders
    # added by stage 4, S4-8). The seed grows every kind under the one query the page runs, so a
    # per-row read in any group would show.
    test "search#index does not grow with matches of any kind" do
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          location = @user.maker_locations.create!(name: "Bin #{id}")
          @user.nodes.create!(node_id: "search-#{id}", name: "lamp-#{id}.stl", kind: "file")
          project = @user.maker_projects.create!(name: "Lamp #{id}", status: "active")
          @user.maker_models.create!(title: "lamp #{id}", slug: "lamp-#{id}")
          item = @user.maker_inventory_items.create!(name: "lamp brick #{id}", location:)
          tag = @user.maker_tags.create!(name: "lamp-#{id}")
          Maker::Tagging.create!(user: @user, tag:, taggable: project)
          Maker::Tagging.create!(user: @user, tag:, taggable: item)
          # STAGE 4, S4-8: a note on a LIVE file, and a folder — the two groups that slice added.
          # The Notes group is the one carrying a SECOND query after its cap (the file names for
          # the five rows it renders, over the capped ids), so growing it is what would show that
          # lookup written per row instead. The folder is `kind: "dir"` and its name matches the
          # same query, which is the whole of what the Folders group reads.
          noted = @user.nodes.create!(node_id: "search-n-#{id}", name: "lamp-noted-#{id}.stl", kind: "file")
          @user.maker_notes.create!(node_id: noted.node_id, body: "<div>lamp note #{id}</div>")
          @user.nodes.create!(node_id: "search-d-#{id}", name: "lamps #{id}", kind: "dir")
        end
      end
      assert_constant_queries(search_path(q: "lamp"),
                              -> { add.call("ss", SMALL) },
                              -> { add.call("sl", LARGE - SMALL) },
                              "search#index")
    end

    # STAGE 2, S2-6 (the Filing count added in stage 3, S3-1): five plain counts, one per
    # reference list -- each a single `SELECT COUNT(*)`, independent of how many rows it is
    # counting, so growing all five together is what proves none of them was quietly rewritten
    # into something that scans rows. Rules are created directly, not through
    # Maker::FilingRules.seed! -- #show never seeds (its own header: a bare count must not
    # side-effect 82 rows into existence), so this measures the plain count alone.
    test "settings#show does not grow with shelves, suppliers, locations, filing rules or tags" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_shelves.create!(path: "#{prefix}shelf#{i}")
          @user.maker_suppliers.create!(name: "#{prefix}sup#{i}")
          @user.maker_locations.create!(name: "#{prefix}loc#{i}")
          @user.maker_filing_rules.create!(ext: "#{prefix}e#{i}", folder: "other")
          @user.maker_tags.create!(name: "#{prefix}tag#{i}")
        end
      end
      assert_constant_queries(settings_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "settings#show")
    end

    # THE SIDEBAR IS ON EVERY PAGE, so a per-project or per-pin query here would grow every page in
    # the app. Settings is the probe because nothing else on it grows with projects or pins.
    test "the sidebar does not grow with projects or pins" do
      grow = lambda do |upto|
        (@user.maker_projects.count...upto).each { |i| @user.maker_projects.create!(name: "P#{i}") }
        (@user.maker_pins.count...[ upto, Maker::Pin::CAP ].min).each do |i|
          dir = @user.nodes.create!(node_id: "pin-#{i}", name: "place-#{i}", kind: "dir")
          @user.maker_pins.create!(node_id: dir.node_id)
        end
      end
      grow.call(SMALL)
      get settings_path
      small = count_queries { get settings_path }
      grow.call(LARGE)
      large = count_queries { get settings_path }
      assert_equal small, large, "the sidebar's queries grew with projects or pins"
    end

    # THE TAGS LIST (S2-6). Each iteration grows a tag AND tags a project with it, so the one
    # grouped count (Settings::TagsController#index's @counts) is under measurement -- a per-row
    # `tag.taggings.count` in the view would show as growth here, the same argument
    # suppliers#index's own comment makes for its @item_counts.
    test "settings/tags#index does not grow with the number of tags" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.maker_projects.create!(name: "#{prefix}p#{i}", tag_list: "#{prefix}tag#{i}")
        end
      end
      assert_constant_queries(settings_tags_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "settings/tags#index")
    end

    # STAGE 3, S3-1: THE FILING RULES LIST. Rows are created directly (not through
    # Maker::FilingRules.seed!) BEFORE the first request, so #index's own `seed!` call sees
    # `exists?` true and never runs its insert_all -- the measurement below is of the plain
    # `order(:ext)` read alone, the same steady-state argument the thumbnail-backfill comment
    # above makes for the file pages.
    test "settings/filing_rules#index does not grow with the number of rules" do
      add = lambda do |prefix, count|
        count.times { |i| @user.maker_filing_rules.create!(ext: "#{prefix}e#{i}", folder: "other") }
      end
      assert_constant_queries(settings_filing_rules_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "settings/filing_rules#index")
    end

    # STAGE 4, S4-2: THE SAME PAGE ON ITS OTHER AXIS, AND THE ONE THE CARD LAYOUT ADDED. The case
    # above grows RULES inside a single folder, which the obvious wrong implementation -- a
    # `where(folder:)` inside the card partial -- survives untouched, because the number of CARDS
    # never moves there. Eleven cards over one query is the property; a maker who invents folders
    # is the reader who pays for the other shape. Every row here names a folder of its own, so the
    # page renders 14 cards small and 26 large, and a per-card query shows as +12.
    #
    # Rows are created directly (not through Maker::FilingRules.seed!) BEFORE the first request, so
    # #index's own `seed!` sees `exists?` true and never runs its insert_all -- the same
    # steady-state argument the case above and the thumbnail-backfill comment both make.
    test "settings/filing_rules#index does not grow with the number of folders" do
      add = lambda do |prefix, count|
        count.times { |i| @user.maker_filing_rules.create!(ext: "#{prefix}e#{i}", folder: "#{prefix}f#{i}") }
      end
      assert_constant_queries(settings_filing_rules_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "settings/filing_rules#index (folders)")
    end

    # STAGE 4, S4-5: /u/:handle GREW PER-CARD WORK (a cover thumbnail and the maker's handle), so it
    # earns a budget of its own — it had none. `includes(:user, :file_attachments)` is what makes it
    # constant: the card renders `project.user.handle` twice, and Maker::Project#cover_node_id falls
    # back to #derived_cover_node_id, which reads the attachments. Dropping either is a query per
    # card, and each is mutation-checked on its own — a single combined mutation cannot show that
    # both halves carry weight.
    #
    # ONE OWNER, WHICH IS THE WHOLE REASON THIS PAGE HAS COVERS AT ALL. Maker::Previews::ThumbnailMap
    # is per-user, so this page resolves them in ONE map however many cards it renders; the
    # explore#index case above seeds a cover per project across DIFFERENT owners precisely so that
    # the cross-user version of this cost is measured rather than assumed.
    test "public users#show does not grow with the number of projects" do
      delete destroy_user_session_path
      # A project cannot leave `private` without a handle (Maker::Project's own validation), so the
      # handle is set before the first one is created rather than beside the request.
      @user.update!(handle: "cardbudget")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          project = @user.maker_projects.create!(name: "P#{id}", visibility: "public", status: "active")
          node!("#{id}-cover", "#{id}.png")
          project.file_attachments.create!(user: @user, node_id: "#{id}-cover", role: "image",
                                           position: 0)
        end
      end
      assert_constant_queries(public_user_path("cardbudget"),
                              -> { add.call("us", SMALL) },
                              -> { add.call("ul", LARGE - SMALL) },
                              "public users#show")
    end
  end
end
