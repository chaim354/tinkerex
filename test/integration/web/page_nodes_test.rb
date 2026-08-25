require "test_helper"

module Web
  # ONE LIVENESS INDEX PER PAGE, AND EVERY CONSUMER READS IT (the PageNodes concern).
  #
  # A file deleted from the library leaves a PROJECT immediately — project_attachments_test.rb has
  # pinned that since the panel shipped. The MODELS page had the same attachments and no such rule:
  # ModelsController#show built a live index and then never consulted it for `@by_role` or
  # `@cover_att`, so a tombstoned attachment still rendered an <img>, an <iframe> and a hero cell.
  # None of those degrade the way they look like they would. FilesController's `rescue_from` answers
  # a plain HTML GET with a 302 to /files, so the frame did not show a 404 — it showed the user's
  # ENTIRE Files listing inside a frame headed "Instructions", with a "File not found." flash; and
  # the hero spun forever, because /files/thumbnails omits a row-less node from its JSON, so
  # thumbs_controller's `if (!entry) continue` runs 40 times and gives up (the exact permanent
  # spinner Maker::Previews::ThumbnailMap's backfill exists to prevent).
  #
  # THE OTHER HALF IS WHAT MUST NOT BE "SIMPLIFIED" INTO IT: liveness reads `user.nodes.present`,
  # never the port. `ThumbnailMap.for` rescues FetchError to {}, so a page deriving liveness from
  # `stat_all` would hide every attachment on an unmounted NAS and tell the user they were deleted.
  # The FetchError test below is the only thing that pins that, and nothing asserted it before.
  #
  # BACKEND-NEUTRAL: `nodes` rows and route helpers throughout. `pin_file_layer_backend` is for the
  # views that read `capabilities`, exactly as models_flow_test.rb does it.
  class PageNodesTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
      @user = User.create!(email: "pn-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    # A row shaped like a real library file: a content token, so `stat_all` reports content and the
    # thumbnail paths actually run. A bare `nodes` row has none, and a fixture without one is how a
    # thumbnail guard comes to measure nothing.
    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1_000_000_000, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node_id
    end

    def tombstone!(node_id) = @user.nodes.find_by!(node_id:).update!(deleted: true)

    # ------------------------------------------------------------------ models#show

    test "a tombstoned image attachment paints no gallery img" do
      model = @user.maker_models.create!(title: "Case", slug: "case")
      live  = file!("m-img-live", "front.png")
      dead  = file!("m-img-dead", "back.png")
      model.file_attachments.create!(user: @user, node_id: live, role: "image", position: 0)
      model.file_attachments.create!(user: @user, node_id: dead, role: "image", position: 1)
      tombstone!(dead)

      get model_path(model)
      assert_response :success
      srcs = css_select(".image-gallery img").map { |el| el["src"] }
      assert_not_includes srcs, blob_file_path(dead),
                          "a tombstoned image still painted an <img> on the models page"
      # AND THE GALLERY ITSELF IS GONE. It renders only `if images.size > 1`, so an unfiltered dead
      # entry summons a gallery a live-only count would never have produced — the dead file does not
      # merely appear broken, it changes the layout around the live one.
      assert_select ".image-gallery", { count: 0 },
                    "a dead attachment made the gallery appear for a single live image"
    end

    test "a tombstoned instructions attachment paints no iframe" do
      model = @user.maker_models.create!(title: "Rig", slug: "rig")
      dead = file!("m-pdf-dead", "manual.pdf")
      model.file_attachments.create!(user: @user, node_id: dead, role: "instructions")
      tombstone!(dead)

      get model_path(model)
      assert_response :success
      assert_select "iframe.preview-pdf", { count: 0 },
                    "a tombstoned PDF still rendered an <iframe> pointed at a dead blob"
      assert_select ".model-instructions", count: 0
    end

    test "a tombstoned cover falls back to the empty hero rather than a forever spinner" do
      dead = file!("m-cover-dead", "hero.stl")
      model = @user.maker_models.create!(title: "Shown", slug: "shown", cover_node_id: dead)
      model.file_attachments.create!(user: @user, node_id: dead, role: "model")
      tombstone!(dead)

      get model_path(model)
      assert_response :success
      # ELEMENTS, NOT TEXT — the three hero branches differ only by class, so only a class assertion
      # can tell "empty placeholder" from "cell polling a node that will never answer".
      assert_select ".model-hero-empty", 1
      assert_select ".model-hero-thumb", { count: 0 },
                    "a dead cover rendered a thumb cell whose poll can never resolve"
      assert_select ".model-hero-img", count: 0
    end

    test "the models page says how many attachments are gone rather than hiding them silently" do
      model = @user.maker_models.create!(title: "Bench", slug: "bench")
      model.file_attachments.create!(user: @user, node_id: file!("m-live", "jig.stl"), role: "model")
      model.file_attachments.create!(user: @user, node_id: "m-gone", role: "model", label: "ghost.stl")

      get model_path(model)
      assert_select ".attachments-missing", text: /1 attached file no longer in your library/
      assert_select ".attachments-missing a[href=?]", trash_index_path
      assert_no_match(/ghost\.stl/, response.body)
    end

    # THE COVER-ONLY RULE, PINNED AS A BUDGET. models#show renders exactly ONE thumbnail — the hero
    # cover; `_file_tree.html.erb` is plain link_to's. So it must NOT merge its ThumbnailMap call
    # over every node the page renders the way projects#show does: `ThumbnailMap.for` backfills
    # unconditionally at BACKFILL_LIMIT = 100, so the merged shape would create up to 100 preview
    # rows and enqueue 100 jobs per view for thumbnails nothing paints — and would save no query
    # here at all, because there is no second call to merge with.
    test "models#show enqueues for the cover alone, not for every attachment" do
      cover = file!("cov", "hero.stl")
      model = @user.maker_models.create!(title: "Budget", slug: "budget", cover_node_id: cover)
      model.file_attachments.create!(user: @user, node_id: cover, role: "model", position: 0)
      %w[a b c].each_with_index do |s, i|
        model.file_attachments.create!(user: @user, node_id: file!("extra-#{s}", "part-#{s}.stl"),
                                       role: "model", position: i + 1)
      end

      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        get model_path(model)
      end
      assert_response :success
    end

    # ------------------------------------------------------------------ projects#show

    test "a tombstoned build-log photo stays hidden" do
      project = @user.maker_projects.create!(name: "Bench")
      entry = project.build_log_entries.create!(user: @user, body: "day one", logged_at: Time.current)
      live = file!("e-live", "progress.png")
      dead = file!("e-dead", "oops.png")
      entry.file_attachments.create!(user: @user, node_id: live, role: "image")
      entry.file_attachments.create!(user: @user, node_id: dead, role: "image")
      tombstone!(dead)

      get project_path(project)
      assert_response :success
      assert_equal [ live ], css_select(".entry-photo").map { |el| el["data-node-id"] },
                   "a tombstoned build-log photo still rendered a cell"
    end

    # ONE MAP, NOT TWO. A node attached to the project AND to a build-log entry appears on both
    # surfaces and must resolve from the single merged ThumbnailMap — the union is deduped, so it
    # enqueues once.
    test "a node on both surfaces resolves from the one map" do
      project = @user.maker_projects.create!(name: "Shared")
      node = file!("both", "shared.stl")
      project.file_attachments.create!(user: @user, node_id: node, role: "model")
      entry = project.build_log_entries.create!(user: @user, body: "same file", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: node, role: "image")

      assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
        get project_path(project)
      end
      assert_response :success
      assert_select ".attachment-tile .grid-name", text: "shared.stl"
      assert_select ".entry-photo[data-node-id=?]", node
    end

    # THE CONSTRAINT MOST LIKELY TO BE OPTIMISED AWAY, AND NOTHING ASSERTED IT BEFORE. Liveness is
    # `user.nodes.present`; the port is asked only for thumbnails. Switch liveness to `stat_all` (or
    # to ThumbnailMap#from_info, whose answer is already in hand) and an unmounted NAS makes this
    # page hide every attachment and report "1 attached file no longer in your library" — a lie,
    # told by the one degradation path the maker layer exists to be independent of.
    test "a FetchError from the port still renders every attachment" do
      project = @user.maker_projects.create!(name: "Unmounted")
      project.file_attachments.create!(user: @user, node_id: file!("nas-1", "bracket.stl"),
                                       role: "model")
      entry = project.build_log_entries.create!(user: @user, body: "day one", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: file!("nas-2", "shot.png"), role: "image")

      # DELEGATES EVERYTHING ELSE. The panel renders `_upload_control`, which asks the port for its
      # capabilities — a bare double answers NoMethodError there and the test would go red for a
      # reason that has nothing to do with liveness.
      FileLayer.current = Class.new(SimpleDelegator) do
        def stat_all(*, **) = raise(FileLayer::FetchError, "nas down")
      end.new(FileLayer.current)

      get project_path(project)
      assert_response :success
      # THE LIE FIRST — it is the assertion that names the failure, so it must be the one that
      # reports when liveness is switched to the port.
      assert_select ".attachments-missing", { count: 0 },
                    "an unreachable backend was reported to the user as deleted files"
      assert_select ".attachment-tile .grid-name", text: "bracket.stl"
      assert_select ".entry-photo", 1
    ensure
      FileLayer.reset!
    end
  end
end
