require "test_helper"

module Web
  # THE MAKER PAGES SELF-HEAL A MISSING OR STALE THUMBNAIL, THE WAY THE FILES PAGE ALWAYS DID.
  #
  # These drive real requests, and that is the whole point of the file. Every test of the mechanism
  # underneath — `enqueue_test.rb`, `thumbnail_map_test.rb` — can pass while nothing on a page calls
  # it, which is exactly what happened twice already: §14h records 172 of 174 LightBurn thumbnails
  # sitting at revision 1 through two deploys with `Enqueue`'s revision comparison working perfectly
  # the entire time, because the only thing that CALLED it skipped them. A unit test proves the
  # class works; only a request proves the page asks.
  #
  # Backend-neutral: the fixtures carry BOTH `current_version_id` (chunk's content_token) and
  # `content_hash` (share's and S3's), and `stat_all` reads the shared `nodes` catalog on all three
  # adapters, so these run identically on every leg.
  class MakerPageThumbnailsTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "mpt-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    # A file shaped like one in a real library — a content token, so `stat_all` reports content and
    # the thumbnail paths actually run. A bare `nodes` row has none, and a fixture without one is
    # how the first version of files#index's own query-count guard passed while measuring nothing.
    def file!(node_id, name)
      @user.nodes.create!(node_id:, name:, kind: "file", mtime: 1_000_000_000, size: 5,
                          content_hash: "h-#{node_id}", current_version_id: "v-#{node_id}")
      node_id
    end

    def token_for(node_id) = FileLayer.current.stat(@user, node_id:).content_token

    def preview!(node_id, name, revision:, status: "ready")
      p = @user.maker_previews.create!(node_id:, version_id: token_for(node_id), kind: "thumbnail",
                                       status:, renderer_revision: revision)
      p.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png",
                     content_type: "image/png")
      p
    end

    def current_revision(name) = Maker::Previews::Enqueue.revision_for_name(name, "thumbnail")

    # ----------------------------------------------------------------------------------
    # GAP 1 — a node with no preview row. Nothing in this path ever created one: the cell
    # rendered a spinner, `thumbs_controller.js` polled `/files/thumbnails`, which omits a
    # node with no row from its JSON entirely, so `if (!entry) continue` ran 40 times and
    # gave up. The spinner then sat there for good.
    # ----------------------------------------------------------------------------------

    test "the 3D models view enqueues a missing cover thumbnail" do
      node = file!("m-cover", "case.stl")
      model = @user.maker_models.create!(title: "Case", slug: "case", cover_node_id: node)
      assert_nil @user.maker_previews.find_by(node_id: node), "fixture: no row yet"

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get files_models_path }
      assert_response :success
      assert @user.maker_previews.exists?(node_id: node, kind: "thumbnail")
      assert model.reload
    end

    test "models#show enqueues a missing cover thumbnail" do
      node = file!("ms-cover", "hero.stl")
      model = @user.maker_models.create!(title: "Shown", slug: "shown", cover_node_id: node)

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get model_path(model) }
      assert_response :success
      assert @user.maker_previews.exists?(node_id: node, kind: "thumbnail")
    end

    test "projects#index enqueues a missing cover thumbnail" do
      node = file!("p-cover", "lamp.stl")
      @user.maker_projects.create!(name: "Lamp", cover_node_id: node)

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get projects_path }
      assert_response :success
      assert @user.maker_previews.exists?(node_id: node, kind: "thumbnail")
    end

    # BOTH SURFACES ON THIS PAGE, in one request: the attachment tiles and the build-log photos.
    # They were two separate `ThumbnailMap.for` calls until PageNodes merged them into `@page_thumbs`
    # over the page's whole union — so this now proves the merged call still reaches BOTH sets of
    # ids, where before it proved a fix had been applied to the class rather than to one call site.
    # Either way the failure it catches is the same: a surface whose thumbnails never enqueue.
    test "projects#show enqueues missing thumbnails for attachments AND build-log photos" do
      project = @user.maker_projects.create!(name: "Bench")
      att = file!("ps-att", "jig.stl")
      photo = file!("ps-photo", "progress.png")
      project.file_attachments.create!(user: @user, node_id: att, role: "model")
      entry = project.build_log_entries.create!(user: @user, body: "day one", logged_at: Time.current)
      entry.file_attachments.create!(user: @user, node_id: photo, role: "image")

      assert_enqueued_jobs 2, only: Maker::GeneratePreviewJob do
        get project_path(project)
      end
      assert_response :success
      assert @user.maker_previews.exists?(node_id: att), "the attachment tile never enqueued"
      assert @user.maker_previews.exists?(node_id: photo), "the build-log photo never enqueued"
    end

    # ----------------------------------------------------------------------------------
    # GAP 2 — a row from an OLDER RENDERER BUILD. It satisfied the has-a-row check, so nothing
    # re-enqueued, and unlike the Files page this one then SERVED it: an out-of-date picture
    # presented as the file's current thumbnail. `.stl` is the live example — every model
    # rendered before the Z-up fix is framed lying on its side.
    # ----------------------------------------------------------------------------------

    test "a stale-revision cover is neither shown nor left alone" do
      name = "case.stl"
      node = file!("stale-cover", name)
      assert_operator current_revision(name), :>, Maker::Previews::Enqueue::BASE_REVISION,
                      "fixture: this needs a renderer that has been bumped at least once"
      preview!(node, name, revision: current_revision(name) - 1)
      model = @user.maker_models.create!(title: "Stale", slug: "stale", cover_node_id: node)

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get model_path(model) }
      assert_response :success

      # THE USER-VISIBLE HALF. `files/_thumb.html.erb` paints an <img> only for a row it was
      # handed; a spinner is what an unresolved cell looks like, and it is the honest answer
      # while the rebuild runs. Asserting the absence of the <img> is what makes this test
      # about the page rather than about the row.
      assert_select ".thumb img", false,
                    "an older build's artifact was painted as this file's current thumbnail"
      assert_select ".thumb .thumb-spinner"
      assert_equal current_revision(name),
                   @user.maker_previews.find_by!(node_id: node).renderer_revision
    end

    # A CURRENT ROW IS SERVED AND NOTHING IS ENQUEUED — the other direction, or "re-enqueue
    # everything" would pass every test above while rebuilding the whole library on every page
    # view. It is also what proves the revision filter compares rather than merely rejects.
    test "a current-revision cover is shown and not re-enqueued" do
      name = "case.stl"
      node = file!("fresh-cover", name)
      preview!(node, name, revision: current_revision(name))
      model = @user.maker_models.create!(title: "Fresh", slug: "fresh", cover_node_id: node)

      assert_no_enqueued_jobs(only: Maker::GeneratePreviewJob) { get model_path(model) }
      assert_response :success
      assert_select ".thumb img"
    end

    # THE DEGRADE PATH SURVIVES THE ENQUEUE. `ThumbnailMap` swallows a FetchError so a backend
    # blip degrades a thumbnail rather than 503-ing a page of maker data that does not depend on
    # the file backend — and the backfill must not reintroduce the raise by writing rows for
    # nodes the port could not answer for.
    test "a backend blip still degrades to a spinner instead of taking the page down" do
      node = file!("blip-cover", "case.stl")
      model = @user.maker_models.create!(title: "Blip", slug: "blip", cover_node_id: node)
      # DELEGATES EVERYTHING ELSE, as page_nodes_test.rb's double does: the top bar's Upload asks
      # the port for its capabilities on every signed-in page (redesign slice 4), and a bare double
      # answers NoMethodError there — red for a reason that has nothing to do with the blip.
      FileLayer.current = Class.new(SimpleDelegator) do
        def stat_all(*, **) = raise(FileLayer::FetchError, "nas down")
      end.new(FileLayer.current)

      assert_no_enqueued_jobs(only: Maker::GeneratePreviewJob) { get model_path(model) }
      assert_response :success
      assert_empty @user.maker_previews
    ensure
      FileLayer.reset!
    end
  end
end
