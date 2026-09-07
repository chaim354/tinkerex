require "test_helper"

module Web
  # The .lbrn2 Measure view's coordinate endpoint. Chunk-shaped (it uploads through
  # Sync::Commit's two-phase flow), so it pins the backend and says so — see
  # test_helper#pin_file_layer_backend.
  class LbrnGeometryTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    setup do
      # A fresh library root per test, for the reason test_helper's own comment gives: the ambient
      # LIBRARY_PATH outlives the per-test database rollback, so Share's clobber refusal rejects
      # the second test to upload a given name.
      @root = use_fresh_share_library!
      @user = sign_in
      @node_id = upload("measure.lbrn2", file_fixture_bytes("real-export.lbrn2"))
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "web@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    def file_fixture_bytes(name) = File.binread(Rails.root.join("test/fixtures/files", name))

    def upload(name, bytes) = port_upload(name, bytes)

    # THE REAL ROW #geometry WOULD LOOK UP — same node_id, same version_id (content_token) the
    # action resolves via FileLayer.current.stat. find_or_create_by!, not create!: the row may
    # already exist (e.g. a prior GET in the same test), and a plain create! would then hit the
    # (user, node, kind) uniqueness index instead of handing back the row a test wants to mutate.
    #
    # STAMPED WITH THE CURRENT RENDERER REVISION, like a row the app itself would have written.
    # Leave it null and the row reads as STALE, so the controller correctly routes past it into
    # Enqueue and every terminal-status test below sees "pending" instead of what it set.
    def preview_for(node_id, revision: current_revision)
      token = FileLayer.current.stat(@user, node_id:).content_token
      row = Maker::Preview.find_or_create_by!(user: @user, node_id:, version_id: token, kind: "geometry")
      row.update!(renderer_revision: revision)
      row
    end

    def current_revision = Maker::Previews::Enqueue.revision_for_name("measure.lbrn2", "geometry")

    # The same shape for the THUMBNAIL kind. find_or_create_by!, not create!: uploading in setup
    # already minted one through the real door, and (user, node, kind) is unique.
    def thumbnail_at(revision, status: "ready")
      token = FileLayer.current.stat(@user, node_id: @node_id).content_token
      row = Maker::Preview.find_or_create_by!(user: @user, node_id: @node_id, version_id: token,
                                              kind: "thumbnail")
      row.update!(renderer_revision: revision, status:, version_id: token)
      row
    end

    def current_thumbnail_revision
      Maker::Previews::Enqueue.revision_for_name("measure.lbrn2", "thumbnail")
    end

    test "requires authentication" do
      delete destroy_user_session_path
      get geometry_file_path(@node_id)
      assert_redirected_to new_user_session_path
    end

    test "answers pending while the preview is being generated" do
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "pending", response.parsed_body["status"]
    end

    test "answers ready with a blob url once the preview is generated" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      get geometry_file_path(@node_id)

      assert_response :success
      body = response.parsed_body
      assert_equal "ready", body["status"]
      assert body["url"].present?, "a ready geometry preview must expose its blob url"
    end

    test "the ready payload is the geometry, not an image" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }
      preview = @user.maker_previews.find_by!(node_id: @node_id, kind: "geometry")

      assert_equal "application/json", preview.asset.content_type
      assert_equal 4, JSON.parse(preview.asset.download)["shapes"].length
    end

    test "generating geometry does not disturb the thumbnail preview" do
      perform_enqueued_jobs { get geometry_file_path(@node_id) }

      assert @user.maker_previews.find_by(node_id: @node_id, kind: "geometry"),
             "the geometry row exists"
      # Two rows for one node, one per kind — Preview.rb: "ONE ROW PER (user, node, kind)".
      # If this ever finds the thumbnail row REPOINTED at JSON, the kind seam is broken.
      thumb = @user.maker_previews.find_by(node_id: @node_id, kind: "thumbnail")
      assert thumb.nil? || thumb.asset.content_type != "application/json"
    end

    test "surfaces a failed preview rather than 500ing" do
      preview_for(@node_id).update!(status: "failed", error: "boom")
      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "failed", response.parsed_body["status"]
      assert_equal "boom", response.parsed_body["error"]
    end

    test "surfaces unsupported with the job's own message" do
      preview_for(@node_id).update!(status: "unsupported",
                                    error: "lbrn2 is 40 MB, over the 32 MB preview ceiling")
      get geometry_file_path(@node_id)

      assert_equal "unsupported", response.parsed_body["status"]
      assert_match(/over the 32 MB preview ceiling/, response.parsed_body["error"])
    end

    # THE BUG THIS WHOLE MECHANISM EXISTS FOR, at the door where it was actually observed. A row
    # left by an OLDER BUILD is ready, and its file's content has not changed — so before the
    # revision check, this endpoint found it and served its payload back forever. On the live
    # share backend that meant four already-measured files kept rendering mangled curves after
    # the fix deployed, until they were destroyed by hand.
    test "does not serve a payload rendered by an older build" do
      stale = preview_for(@node_id, revision: current_revision - 1)
      stale.update!(status: "ready")

      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "pending", response.parsed_body["status"],
                   "a stale-revision row must be re-rendered, not served"
      assert_equal current_revision, stale.reload.renderer_revision
    end

    # THE OTHER STALENESS AXIS AT THE SAME DOOR, AND IT WAS COMPLETELY UNGUARDED. `version_id`
    # asks "was this payload made from the file's CURRENT CONTENT?" and `renderer_revision` asks
    # "was it made by the CURRENT CODE?" — two independent questions (Enqueue says so in those
    # words), but only the second had a test. Deleting `version_id:` from this action's `find_by`
    # was measured at 2444 runs, 0 failures before this test existed, so the content axis was
    # protected by nothing but the fact that nobody had edited the line.
    #
    # A row at a SUPERSEDED token is the case: the file was re-saved, the payload describes the
    # bytes that used to be there, and serving it hands the Measure view coordinates for a shape
    # the user is no longer looking at.
    test "does not serve a payload rendered from superseded content" do
      stale = preview_for(@node_id)
      stale.update!(status: "ready", version_id: "some-older-content")

      get geometry_file_path(@node_id)

      assert_response :success
      assert_equal "pending", response.parsed_body["status"],
                   "a payload of DIFFERENT content must be re-rendered, not served"
      assert_equal FileLayer.current.stat(@user, node_id: @node_id).content_token,
                   stale.reload.version_id, "the row must be repointed at the current content"
    end

    # THE PANEL LABELS A LAYER BY COLOUR, BUT ONLY WHEN LIGHTBURN NAMED IT AFTER ITS INDEX.
    # "C01" tells a reader nothing the swatch beside it does not already show; a name its owner
    # chose tells them everything, and substituting a colour over it would destroy information.
    # Both directions asserted, because a rule that only ever fires one way is half a rule.
    test "an unnamed layer is labelled by colour, not by its index" do
      # nested-plate.lbrn2 supplies no <color>, so its layers take LightBurn's palette — which is
      # the ordinary case and the only one with a name to show. real-export.lbrn2 (this file's
      # main fixture) OVERRIDES its colours, so it deliberately has no palette name at all.
      node = upload("plate.lbrn2", file_fixture_bytes("nested-plate.lbrn2"))
      # The panel renders from the THUMBNAIL row's metadata, and #show enqueues nothing — so the
      # artifact has to be built explicitly. Through the real pipeline, not a hand-written hash:
      # the labels asserted below have to come from LbrnMetadata actually parsing the fixture.
      token = FileLayer.current.stat(@user, node_id: node).content_token
      thumb = Maker::Previews::Enqueue.call(user: @user, node_id: node, name: "plate.lbrn2",
                                            version_id: token, kind: "thumbnail")
      Maker::GeneratePreviewJob.perform_now(thumb.id, filename: "plate.lbrn2")
      assert_equal "ready", thumb.reload.status

      get file_path(node)

      assert_response :success
      labels = css_select(".lbrn-layers tbody td:first-child").map { |td| td.text.strip }
      assert_includes labels, "Black", "C00 should read as its colour"
      assert_includes labels, "Red",   "C02 should read as its colour"
      assert_empty labels.grep(/\AC\d+\z/), "no layer should still be labelled by its index"
    end

    # THE PATH THAT MADE renderer_revision UNREACHABLE FOR THUMBNAILS, driven as a real request.
    #
    # Every earlier test of the mechanism called Enqueue directly, so all of them passed while the
    # thing a USER does — open a file page — never consulted a revision at all. Two deploys bumped
    # THUMBNAIL_REVISION and 172 of 174 LightBurn thumbnails stayed on revision 1, which is why
    # layer colours were invisible: the Laser Settings panel draws from that stored metadata.
    test "opening a file page re-enqueues a thumbnail left by an older build" do
      current = current_thumbnail_revision
      stale = thumbnail_at(current - 1)

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get file_path(@node_id) }

      assert_response :success
      stale.reload
      assert_equal current, stale.renderer_revision, "the row must be repointed, not served"
      # AND THE OLD PICTURE STAYS UP. A renderer bump does not make the stored artifact a lie —
      # it depicts this exact file, just built by older code — so blanking it to "pending" would
      # replace a correct image with a spinner for the whole render (the page polls a pending row
      # and reloads since S4-3, but a spinner over a correct picture is still the wrong trade). Only a CONTENT change
      # earns the spinner. Shipping it the other way read as "generating preview is broken".
      assert_equal "ready", stale.status,
                   "a renderer rebuild must not blank an artifact that is still of this file"
    end

    test "a CONTENT change still blanks the artifact rather than showing the wrong picture" do
      thumbnail_at(current_thumbnail_revision)
      row = Maker::Preview.find_by!(user: @user, node_id: @node_id, kind: "thumbnail")
      row.update!(version_id: "some-older-content")

      Maker::Previews::Enqueue.call(user: @user, node_id: @node_id, name: "measure.lbrn2",
                                    version_id: FileLayer.current.stat(@user, node_id: @node_id).content_token,
                                    kind: "thumbnail")

      assert_equal "pending", row.reload.status,
                   "an artifact of DIFFERENT content must not be shown as current"
    end

    # THE SAME CONTENT AXIS AT THE DETAIL PAGE'S DOOR, WHICH THE TEST ABOVE CANNOT SEE. That one
    # calls `Enqueue.call` directly, so it proves Enqueue repoints a superseded row and proves
    # nothing about whether `#current_thumbnail` ever declines to serve one — the door reads the
    # row itself, and a `find_by` that stopped comparing `version_id` would simply hand the old
    # artifact back and never reach Enqueue at all. Measured at 2444 runs, 0 failures with
    # `version_id:` deleted from that lookup before this test existed.
    #
    # Driven as a real request for exactly the reason §14h records one door over: a test that
    # calls the service proves the service works and nothing about whether anything calls it.
    test "opening a file page does not serve a thumbnail of superseded content" do
      stale = thumbnail_at(current_thumbnail_revision)
      stale.update!(version_id: "some-older-content")

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get file_path(@node_id) }

      assert_response :success
      stale.reload
      assert_equal FileLayer.current.stat(@user, node_id: @node_id).content_token,
                   stale.version_id, "the row must be repointed at the current content"
      # AND THE OLD PICTURE COMES DOWN. Unlike a renderer bump, a CONTENT change makes the stored
      # artifact a lie about this file, so the spinner is the honest replacement (Enqueue's rule).
      assert_equal "pending", stale.status,
                   "an artifact of DIFFERENT content must not stay up as this file's thumbnail"
    end

    test "a thumbnail at the current revision is served without re-enqueueing" do
      thumbnail_at(current_thumbnail_revision)

      assert_no_enqueued_jobs { get file_path(@node_id) }
      assert_response :success
    end

    # The grid's own read path, which decides whether backfill enqueues anything. A stale row
    # counting as "existing" here is what silenced the detail page's sibling above.
    test "the file list does not count an older build's thumbnail as present" do
      thumbnail_at(current_thumbnail_revision - 1)

      assert_enqueued_with(job: Maker::GeneratePreviewJob) { get files_path }
      assert_response :success
    end

    test "404s for a node this user does not own" do
      other = User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)
      stranger = other.nodes.create!(node_id: SecureRandom.uuid, name: "theirs.lbrn2", kind: "file")

      get geometry_file_path(stranger.node_id)
      assert_response :not_found
    end

    test "an lbrn2 file page offers the Measure surface" do
      get file_path(@node_id)

      assert_response :success
      assert_select "[data-controller='measure']", 1
      # VALUE, not just presence — an attribute pointing at the wrong URL is exactly the bug a
      # presence check misses.
      assert_select "[data-measure-url-value='#{geometry_file_path(@node_id)}']", 1
      assert_select "button[data-action='measure#load']", 1
    end

    # EVERY MEASURABLE FORMAT OFFERS IT, not just the one it was built for. Driven through the
    # real page for each extension rather than asserted against MEASURABLE_EXTS, which would only
    # prove the list equals itself.
    test "the other measurable formats offer it too" do
      { "part.mage" => "sample.mage", "drawing.dxf" => "sample.dxf",
        "logo.svg" => "square.svg" }.each do |name, fixture|
        node = upload(name, file_fixture_bytes(fixture))
        get file_path(node)

        assert_response :success
        assert_select "[data-controller='measure']", 1, "#{name} should offer the Measure surface"
        assert_select "[data-measure-url-value='#{geometry_file_path(node)}']", 1,
                      "#{name}: the Measure surface must point at its OWN geometry endpoint"
      end
    end

    # THE OTHER DIRECTION, and it is the assertion that carries the weight here: without it,
    # "offers Measure" passes trivially if the partial were rendered for every file type. A .stl
    # has its own 3D viewer and a .step only a thumbnail; neither is measurable, and neither may
    # sprout the surface just because the branch moved.
    test "a file we cannot build geometry for does not" do
      %w[model.stl notes.txt].each do |name|
        node = upload(name, "not really #{name}")
        get file_path(node)

        assert_response :success
        assert_select "[data-controller='measure']", 0, "#{name} must not offer Measure"
      end
    end

    # AN SVG POSTS ITSELF rather than a server-rendered thumbnail — it is the one measurable
    # format the browser can display raw. Asserted on the SRC, because "an <img> is present" is
    # equally true of the thumbnail branch this must NOT be taking.
    test "an svg page posters the file itself, not a rendered thumbnail" do
      node = upload("logo.svg", file_fixture_bytes("square.svg"))
      get file_path(node)

      assert_response :success
      assert_select ".measure-fallback img[src=?]", blob_file_path(node), 1
    end

    # The :lbrn branch REPLACES the :thumbnail branch for these files, so everything that branch
    # handled has to still work. A ready thumbnail is the resting state — Measure is a button,
    # not a replacement.
    #
    # DIRECT ROW MANIPULATION, NOT `perform_enqueued_jobs { get file_path(@node_id) }` — the
    # latter was tried first and does NOT work: #show never enqueues anything (it only reads the
    # existing Preview row), so wrapping its GET in perform_enqueued_jobs has nothing to catch —
    # the block only inlines jobs ENQUEUED DURING it, and the thumbnail job from setup's upload was
    # already sitting in the queue before the block started (verified against activejob 8.1.3.1's
    # TestAdapter: only a NEW #enqueue call checks the perform-inline flag). Confirmed empirically:
    # that version left @thumbnail stuck at "pending" and failed this test for the wrong reason —
    # same idiom as files_flow_test.rb's "the detail page shows a ready thumbnail for a CAD file".
    test "the lbrn page still shows its thumbnail poster when one is ready" do
      token = FileLayer.current.stat(@user, node_id: @node_id).content_token
      preview = @user.maker_previews.find_by!(node_id: @node_id, version_id: token, kind: "thumbnail")
      preview.update!(status: "ready")
      preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png", content_type: "image/png")

      get file_path(@node_id)

      assert_response :success
      assert_select ".measure-fallback img", 1
    end

    test "the lbrn page says so while the thumbnail is still generating" do
      get file_path(@node_id)

      assert_response :success
      assert_select ".measure-fallback", text: /Generating preview/
    end
  end
end
