require "test_helper"
require "support/public_fixture"
require "support/gerber_fixture"
require "support/mesh_fixture"
require "support/three_mf_fixture"

module Web
  # A VISITOR'S FILE PAGE (stage 4, S4-5; spec §2 D5 and §5's S4-5 row; stories 5.5, 5.7). The same
  # eight viewer partials the maker's own page renders (app/views/files/viewers/), pointed at public
  # URLs and permitted by the SAME object the page and the byte route ask, Maker::PublicProject.
  #
  # ITS OWN NODES, NOT `seed_public_project!`'S. Four suites assert about that fixture's contents —
  # public_bundle_test.rb pins the bundle's whole file list — so a .lbrn2, a .gtl and a .pdf added
  # there would be a change to four other suites for this one's convenience.
  class PublicFileViewTest < ActionDispatch::IntegrationTest
    include PublicFixture
    # REAL BYTES the server opens on a visitor's page: a zipped Gerber export (Maker::GerberArchive)
    # and a slicer's 3MF (Maker::ThreeMfManifest). Only the BYTES come from these two; every node is
    # still PublicFixture#make_file!'s, so it lands where the port reads it on this pinned share.
    include GerberFixture
    include ThreeMfFixture
    # `assert_no_enqueued_jobs` needs this EXPLICITLY — it is not on ActiveSupport::TestCase here
    # (test/integration/web/maker_page_thumbnails_test.rb and s3_write_test.rb both include it).
    include ActiveJob::TestHelper

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
      @laser = make_file!(@user, "sign.lbrn2", @f[:folder], body: "<LightBurnProject/>")
      @gtl   = make_file!(@user, "driver.gtl", @f[:models], body: "%FSLAX46Y46*%\nM02*\n")
      @doc   = make_file!(@user, "manual.pdf", @f[:folder], body: "%PDF-1.4\n")
      # A CONTENT TOKEN IS WHAT PUTS A VIEWER ON THE PAGE AT ALL, and neither `create_node!` nor
      # PublicFixture#make_file! stamps one — the four S3-4 suites never needed it, because a
      # download reads `storage_path` and a README is read through the port. This page opens with
      # `if @info.content_token.nil?` → "No content yet.", so without these two columns every test
      # below would assert about the empty branch and pass for nothing. BOTH columns, because
      # `content_token` is `content_hash` on share/s3 and `current_version_id` on chunk_remote
      # (§14a; template_hygiene_test.rb's own `file!` says the same). Stamped HERE rather than in
      # the shared fixture: four other suites assert about that fixture's contents.
      [ @f[:base], @f[:pic], @f[:kicad], @f[:readme], @laser, @gtl, @doc ].each do |node|
        node.update!(content_hash: "h-#{node.node_id}", current_version_id: "v-#{node.node_id}")
      end
      # ONE READY THUMBNAIL, so the 3D viewer's poster takes its READY branch on the page this suite
      # sweeps and `assert_no_private_urls`'s blob arm has something to catch (hardening, 2026-09-08;
      # found in review: without it, `url_for(thumbnail.asset)` restored in two viewers left every
      # test here green).
      ready_preview!(@user, @f[:base])
    end

    teardown { FileLayer.reset! }

    def view_path_for(node_id, **opts) = public_file_view_path("ada", @project.slug, node_id, **opts)

    # What gerber_controller.js will fetch, as the page handed it over (gerber_preview_test.rb's own).
    def layers_of(selector) = JSON.parse(css_select(selector).first["data-gerber-layers-value"])

    # EVERY Maker::PublicProject IN THE BLOCK REFUSES EVERY LAYER URL — the public side's refusal,
    # reaching all three Gerber arms at once. `deliverable!` asks `permits?`, not this method, so the
    # page itself still renders and the refusal reaches the URL builder alone, which is what the rule
    # under test is about. Replaced on the CLASS because the controller builds its own instance per
    # request, and restored to the original UnboundMethod (project_adoptions_test.rb's shape;
    # Minitest 6 has no Object#stub).
    def refusing_layer_urls
      real = Maker::PublicProject.instance_method(:layer_url_for)
      Maker::PublicProject.define_method(:layer_url_for) { |_node| nil }
      yield
    ensure
      Maker::PublicProject.define_method(:layer_url_for, real)
    end

    # `assert_no_private_urls` IS PublicFixture's, NOT A LOCAL COPY. This file carried its own
    # until 2026-09-08; when the fixture's version gained the `/rails/active_storage/` arm
    # (hardening, tinkerex#278) the local one SHADOWED it, so this suite alone kept the weaker
    # fence with nothing anywhere going red. One definition, in the module every public suite
    # includes — the argument for it (why the match is anchored on the attribute's opening quote)
    # lives there now.

    test "a permitted model file gets the 3D viewer, pointed at the PUBLIC named byte route" do
      get view_path_for(@f[:base].node_id)

      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      assert_select "[data-modelviewer-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:base].node_id, filename: "base.stl")
      assert_select "[data-modelviewer-lazy-value=?]", "true"
      assert_no_private_urls
    end

    # A 3MF's COLOURS AND ITS UNIT REACH A VISITOR'S VIEWER AS DATA — the server half files_flow_test.rb
    # pins on the maker's page, unpinned on this one until F-S10-2. three's 3MFLoader reads neither,
    # so without them a Bambu plate renders grey and a part in metres measures 1000x short.
    # `unit: "meter"` is what makes the factor an assertion: at 1.0 the template's own default would
    # pass it with no manifest read at all.
    test "a published 3MF carries its slicer colours and its unit factor to the visitor's viewer" do
      plate = make_file!(@user, "plate.3mf", @f[:models],
                         body: bambu_3mf(filaments: %w[#161616 #F98C36 #FFFFFF], unit: "meter"))
      plate.update!(content_hash: "h-#{plate.node_id}", current_version_id: "v-#{plate.node_id}")

      get view_path_for(plate.node_id)

      assert_response :success
      assert_select ".model-viewer[data-modelviewer-colors-value=?]", '["#161616","#F98C36"]'
      assert_select ".model-viewer[data-modelviewer-unit-factor-value=?]", "1000.0"
    end

    # THE ROUTE'S ORDER IS THE GUARD, NOT A PREFERENCE (Amendment 6). `files/:id(/*filename)` matches
    # this very path with `filename: "view"`, and `:filename` is decorative to the server — so
    # declared the other way round the visitor is handed THE BYTES with a 200 and nothing anywhere
    # to say so. This is what makes that silent trap loud.
    test "the view path recognizes as the page, never as the byte route with a decorative filename" do
      assert_recognizes({ controller: "public/files", action: "view", handle: "ada",
                          slug: @project.slug, id: @f[:base].node_id },
                        "/u/ada/#{@project.slug}/files/#{@f[:base].node_id}/view")
    end

    test "an image renders inline, a PDF is framed, a KiCad file mounts KiCanvas on the named URL" do
      get view_path_for(@f[:pic].node_id)
      assert_select "img.preview-image[src=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)

      get view_path_for(@doc.node_id)
      assert_select "iframe.preview-pdf[src=?]", public_file_path("ada", @project.slug, @doc.node_id)

      get view_path_for(@f[:kicad].node_id)
      assert_select "[data-kicanvas-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:kicad].node_id, filename: "driver.kicad_sch")
    end

    # A JOB FILE'S BOARD IS FILTERED BY `permits?`, ONE SIBLING AT A TIME. The sibling walk is
    # FilePreview's, shared verbatim with the maker's page, and it hands each node to a URL builder
    # the CALLER supplies — `Maker::PublicProject#layer_url_for`, which answers nil for a sibling
    # this project does not publish. Without that arm the board would render a layer whose URL the
    # BYTE route refuses (asserted directly below), which is the page and the route disagreeing —
    # the one thing Maker::PublicProject exists to prevent.
    #
    # THE FIXTURE IS THE ONLY SHAPE THAT REACHES IT: siblings share a parent, so a sibling of a file
    # permitted by ANCESTRY is permitted too. The job file therefore sits OUTSIDE the folder (in
    # `Projects/`, beside @f[:outsider]) and is published by ATTACHMENT, while its layer sibling is
    # attached to nothing.
    test "a .gbrjob drops a layer sibling the project does not publish, rather than linking it" do
      projects_dir = @user.nodes.find_by!(node_id: @f[:folder].parent_node_id)
      job = make_file!(@user, "board.gbrjob", projects_dir,
                       body: '{"FilesAttributes":[{"Path":"root.gtl"}]}')
      stray = make_file!(@user, "root.gtl", projects_dir, body: "%FSLAX46Y46*%\nM02*\n")
      [ job, stray ].each { |n| n.update!(content_hash: "h-#{n.node_id}", current_version_id: "v-#{n.node_id}") }
      @project.file_attachments.create!(user: @user, node_id: job.node_id, role: "pcb", position: 9)

      get view_path_for(stray.node_id)
      assert_response :not_found, "the layer itself is not published — which is what makes this case real"

      get view_path_for(job.node_id)
      assert_response :success
      assert_select ".gerber-viewer", 0, "a board built entirely of unpublished layers is no board"
      assert_select "p.muted", text: /No Gerber layers/
      assert_no_match(Regexp.escape(public_file_path("ada", @project.slug, stray.node_id, filename: "root.gtl")),
                      response.body,
                      "a layer URL the byte route would refuse must never reach a visitor's page")
    end

    test "a Gerber layer renders the board viewer and a text file is READ-ONLY codeview" do
      get view_path_for(@gtl.node_id)
      assert_select ".gerber-viewer[data-controller=?]", "gerber"
      assert_select "[data-gerber-single-value=?]", "true"

      get view_path_for(@f[:readme].node_id)
      assert_select "[data-controller=?]", "codeview"
      assert_select "[data-controller=?]", "editor", 0, "a visitor must never get the editor mount"
      assert_select "form", 0, "a visitor's file page carries no form at all"
    end

    # A ZIPPED EXPORT IS A BOARD ON A VISITOR'S PAGE TOO, AND THE SAME BOARD (F-S10-2). Which viewer a
    # file gets, the layer list and the single-or-stackup choice are ONE answer, FilePreview#viewer_for,
    # asked by both file pages; while each controller spelled it out, this page's copy of the zip
    # branch had no test, so a change landing in one controller could not be noticed in the other.
    # gerber_preview_test.rb pins the maker's half; this is the visitor's, on the PUBLIC named route.
    test "a published Gerber zip is a stackup of ONE archive entry on the public named route" do
      zip = make_file!(@user, "board.zip", @f[:models], body: fusion_zip)
      zip.update!(content_hash: "h-#{zip.node_id}", current_version_id: "v-#{zip.node_id}")

      get view_path_for(zip.node_id)

      assert_response :success
      assert_select ".model-viewer.gerber-viewer[data-controller=?]", "gerber"
      assert_select ".gerber-viewer[data-gerber-single-value=?]", "false"
      assert_equal [ { "name" => "board.zip",
                       "url" => public_file_path("ada", @project.slug, zip.node_id, filename: "board.zip"),
                       "archive" => true,
                       "members" => fusion_zip_members } ],
                   layers_of(".gerber-viewer")
      assert_no_private_urls
    end

    # A REFUSED LAYER URL IS ABSENT ON EVERY ARM OR ON NONE (files-preview.md, "A .gbrjob's SIBLING
    # WALK IS ONE ANSWER"). The single-layer arm `.compact`s and the job arm `filter_map`s; the ZIP
    # arm used to skip the page's URL builder entirely and so could not drop anything. A refusal of
    # the zip's own URL is unreachable after `deliverable!`, but the rule is about the SHAPE: a
    # viewer handed `url: null` draws board chrome around a layer that does not exist. Both halves
    # are asserted, because "absent on none" is the half a builder refusing everything would break.
    test "a layer URL the page refuses is absent on all three Gerber arms, and one it permits present on all three" do
      job = make_file!(@user, "board.gbrjob", @f[:models], body: gerber_job("driver.gtl"))
      zip = make_file!(@user, "board.zip", @f[:models], body: fusion_zip)
      [ job, zip ].each { |n| n.update!(content_hash: "h-#{n.node_id}", current_version_id: "v-#{n.node_id}") }
      arms = { "a layer" => @gtl, "a job file" => job, "a zipped export" => zip }

      arms.each do |arm, node|
        get view_path_for(node.node_id)
        assert_response :success
        assert_select ".gerber-viewer", 1, "#{arm}: a layer URL the page permits must reach the viewer"
      end

      refusing_layer_urls do
        arms.each do |arm, node|
          get view_path_for(node.node_id)
          assert_response :success, "#{arm}: the refusal is the URL builder's alone; the page still renders"
          assert_select ".gerber-viewer", 0,
                        "#{arm}: a refused URL must reach the viewer as an ABSENT layer, never as a null one"
          assert_select "p.muted", text: /No Gerber layers/
        end
      end
    end

    test "the Measure view ships whole: the launch, the paper picker, Print and Download SVG" do
      get view_path_for(@laser.node_id)

      assert_select ".measure-view[data-measure-url-value=?]",
                    public_file_geometry_path("ada", @project.slug, @laser.node_id)
      assert_select "[data-action=?]", "measure#load"
      assert_select "[data-action=?]", "measure#print"
      assert_select "[data-action=?]", "measure#downloadSvg"
    end

    # THE TWO SAVE CONTROLS ARE THE ONE THING MEASURE DROPS, and it is not squeamishness: stage 4
    # S4-3 put "Save sheet" and "Save SVG" on that bar, and they write an EXPORT into the maker's
    # own library through the two upload doors. A visitor has nowhere to put one, so rendering them
    # would be two dead buttons and four public URLs into a private write path — which is why
    # `files/viewers/_measure.html.erb` takes a `save:` local and this page passes false. Print and
    # Download SVG stay: both are client-side work over a payload the visitor already fetched, and
    # withholding them costs story 5.5 the one thing it asks for.
    test "a visitor's Measure bar carries no Save control and no write URL at all" do
      get view_path_for(@laser.node_id)

      assert_response :success
      assert_select "[data-action=?]", "measure#savePrint", 0, "Save sheet writes into a library a visitor has not got"
      assert_select "[data-action=?]", "measure#saveSvg", 0, "Save SVG writes into a library a visitor has not got"
      assert_select "[data-measure-target=?]", "savePrintButton", 0
      assert_select "[data-measure-target=?]", "saveSvgButton", 0
      assert_select "[data-measure-create-url-value]", 0, "no upload door on a page with no session"
      assert_select "[data-measure-begin-url-value]", 0
      assert_select "[data-measure-finalize-url-value]", 0
      # STAGE 4, S4-8: the two lineage values the Save path reads. An EMPTY attribute is not absence
      # to Stimulus — `hasLinkUrlValue` is true for `""` — so if these ever left the partial's
      # `if save` block, `recordSources` would POST to "" (the page's own URL, with no CSRF token)
      # on a visitor's save path. Pinned like the three write URLs above; found missing in review by
      # hoisting them out of that block, which left every test green.
      assert_select "[data-measure-source-node-id-value]", 0, "no lineage source on a page with no session"
      assert_select "[data-measure-link-url-value]", 0, "no link door on a page with no session"
      assert_no_private_urls
    end

    test "the page carries the project breadcrumb, the author and a Download, and no notes panel" do
      get view_path_for(@f[:base].node_id)

      assert_select "nav.breadcrumb a[href=?]", public_project_path("ada", @project.slug)
      assert_select "nav.breadcrumb a[href=?]", public_user_path("ada")
      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id, download: 1)
      assert_select "section.notes-panel", count: 0
      assert_select "section.history-panel", count: 0
    end

    # AN UNMOUNTED LIBRARY IS A 503, NOT A 500 — the same mapping FilesController makes once for
    # the maker's page (§14a: FetchError is the retryable answer), made once here for every public
    # page by Public::BaseController (found in review: the public byte route and this page both
    # answered 500). `use_fresh_share_library!` hands this test its own Share instance, so a
    # singleton stub on it outlives nothing.
    test "a library that cannot answer makes the public file page a 503, not a 500" do
      FileLayer.current.define_singleton_method(:stat) { |*_a, **_k| raise FileLayer::FetchError, "unmounted" }

      get view_path_for(@f[:base].node_id)

      assert_response :service_unavailable
    end

    # THE PERMISSION IS `permits?`'S, NOT A SECOND ONE. Same matrix public_file_test.rb pins for the
    # bytes: if the view page could reach a node the byte route refuses, the page and the route
    # would disagree — which is the one thing Maker::PublicProject exists to prevent.
    test "a sibling of the folder, a dot-file, a directory and another maker's file are all 404" do
      # ANOTHER MAKER'S FILE, DRIVEN AND NOT ONLY NAMED (found in review): `deliverable!` resolves in
      # the OWNER's library, so a foreign node id is unfindable there before `permits?` is even asked.
      theirs = make_owner!(handle: "bob").nodes.create!(node_id: SecureRandom.uuid, name: "theirs.stl",
                                                         kind: "file", mtime: 1, size: 1)
      [ @f[:outsider].node_id, @f[:dotfile].node_id, @f[:models].node_id, theirs.node_id, "no-such-node" ].each do |id|
        get view_path_for(id)
        assert_response :not_found, "#{id} must not have a public page"
      end
    end

    test "a private project's file page is a 404 and an unlisted one needs its token" do
      @project.update!(visibility: "private")
      get view_path_for(@f[:base].node_id)
      assert_response :not_found

      @project.update!(visibility: "unlisted")
      get view_path_for(@f[:base].node_id)
      assert_response :not_found

      get view_path_for(@f[:base].node_id, k: @project.reload.unlisted_token)
      assert_response :success
      # EVERY LINK CARRIES THE TOKEN, or the page links to its own 404s.
      assert_select "a[href*=?]", "k=#{@project.unlisted_token}"
    end

    # THE POLL IS ASKED BEFORE ANY PAGE HAS RENDERED, AND THAT ORDER IS THE WHOLE GUARD. Polled
    # AFTER a render — which is how this test was first written — `current_preview` finds the row
    # that render created, so the "nothing current exists" branch is never entered and an
    # `Enqueue.call` planted in it is INVISIBLE: measured, the mutation stayed green over all
    # thirteen tests. A stranger's very first poll is exactly the state that branch exists for, and
    # `Enqueue.call` there would re-enqueue a doomed render on every poll of a `failed` row (§14h).
    test "the page render enqueues geometry once; the poll endpoint never writes" do
      assert_no_difference -> { @user.maker_previews.where(kind: "geometry").count } do
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          get public_file_geometry_path("ada", @project.slug, @laser.node_id)
        end
      end
      assert_response :success
      assert_equal "pending", response.parsed_body["status"],
                   "no row yet is `pending`, truthfully — and it must stay a REPORT"

      assert_difference -> { @user.maker_previews.where(kind: "geometry").count }, 1 do
        get view_path_for(@laser.node_id)
      end
      # IDEMPOTENT: the row it just created is what makes the second render a no-op.
      assert_no_difference -> { @user.maker_previews.where(kind: "geometry").count } do
        get view_path_for(@laser.node_id)
      end

      # AND STILL A REPORT once a row exists — the other arm of the same rule.
      assert_no_difference -> { @user.maker_previews.where(kind: "geometry").count } do
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          get public_file_geometry_path("ada", @project.slug, @laser.node_id)
        end
      end
      assert_response :success
      assert_includes %w[pending processing ready failed unsupported], response.parsed_body["status"]
    end

    # A FAILED RENDER IS WHAT THE `current_preview` GUARD ON THE RENDER ENQUEUE IS ACTUALLY FOR, and
    # nothing else reaches it. `Enqueue.call` is idempotent by its OWN staleness test for a `pending`
    # row — measured: dropping the guard entirely left all thirteen tests green — but it resets a
    # `failed` row to pending and re-enqueues WHENEVER it is called (§14h). Unguarded, one visitor
    # reloading the page of a file whose render is broken would enqueue a doomed render per reload,
    # which is the retry storm Amendment 5 named. The guard makes the work one job per (node, content
    # token, renderer build) instead of one per page view.
    test "a visitor reloading a file whose render FAILED does not re-enqueue it" do
      get view_path_for(@laser.node_id)
      preview = @user.maker_previews.find_by!(node_id: @laser.node_id, kind: "geometry")
      preview.update!(status: "failed", error: "boom")

      assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
        get view_path_for(@laser.node_id)
      end

      assert_equal "failed", preview.reload.status,
                   "a stranger's reload reset a failed render to pending — that is a doomed job per view"
      assert_equal "boom", preview.error
    end

    # A ROW WHOSE JOB WAS LOST IS HEALED BY THE PAGE RENDER, ONCE PER WINDOW, AND STILL NEVER BY THE
    # POLL. The render's guard returned on ANY current row, so a `processing` row from a lost job sat
    # there for good and a visitor's Measure view spun with nothing coming. It asks
    # `Enqueue.needs_job?` now with `retry_failed: false` — the test above is what keeps a FAILED row
    # terminal — and the heal's restamp is what keeps a reloading stranger to one job per window.
    test "a visitor's render re-enqueues a geometry row whose job was lost; the poll still does not" do
      get view_path_for(@laser.node_id)
      preview = @user.maker_previews.find_by!(node_id: @laser.node_id, kind: "geometry")
      preview.update_columns(status: "processing", updated_at: 3.days.ago)
      clear_enqueued_jobs

      assert_no_enqueued_jobs(only: Maker::GeneratePreviewJob) do
        get public_file_geometry_path("ada", @project.slug, @laser.node_id)
      end
      assert_enqueued_jobs(1, only: Maker::GeneratePreviewJob) { get view_path_for(@laser.node_id) }
      assert_no_enqueued_jobs(only: Maker::GeneratePreviewJob) { get view_path_for(@laser.node_id) }
    end

    # A RENDERER REBUILD KEEPS A VISITOR'S POSTER, AND THE URL THE POSTER NAMES (F-S08-2). The page
    # and `#preview` ask the same question of the row — is there a picture of this content? — so a
    # rebuild cannot leave the page naming an image that 404s. Looked at from INSIDE the job: its
    # start used to write `processing` over the row, and both the poster and its route went dark
    # for as long as the render took.
    CUBE_3MF = File.binread(Rails.root.join("test/fixtures/files/cube.3mf")).freeze

    # maker_page_thumbnails_test.rb's helper, for the same reasons: `look` runs at the job's byte
    # read, after its start and before its render, and the read answers a real 3MF.
    def during_its_job(row, look)
      original = Maker::FileBytes.method(:read)
      Maker::FileBytes.define_singleton_method(:read) { |*, **| look.call; CUBE_3MF }
      Maker::GeneratePreviewJob.perform_now(row.id)
    ensure
      Maker::FileBytes.define_singleton_method(:read, original)
    end

    test "a renderer rebuild keeps a visitor's poster up, and the poster's URL keeps answering" do
      model = make_file!(@user, "case.3mf", @f[:models], body: CUBE_3MF)
      model.update!(content_hash: "h-#{model.node_id}", current_version_id: "v-#{model.node_id}")
      row = ready_preview!(@user, model)
      row.update!(renderer_revision: row.renderer_revision - 1)
      poster = public_file_preview_path("ada", @project.slug, model.node_id, "thumbnail")

      get view_path_for(model.node_id) # the render after the bump: its backfill queues the rebuild
      assert_response :success

      seen = nil
      during_its_job(row, lambda {
        seen = row.reload.then { |r| [ r.showable?, r.in_flight? ] }

        get view_path_for(model.node_id)
        assert_select ".model-viewer-fallback img.preview-image[src=?]", poster
        get poster
        assert_response :redirect, "the page named a poster whose route 404'd mid-rebuild"
      })

      assert_equal [ true, true ], seen, "mid-render the row must show its picture and be in flight"
      assert row.reload.current_build?
    end

    test "the geometry endpoint refuses a node the project does not permit, as JSON not a redirect" do
      get public_file_geometry_path("ada", @project.slug, @f[:outsider].node_id)
      assert_response :not_found
      assert_no_match(/<html/i, response.body, "a JSON poller must never be handed a page")
    end

    # ON s3 THE VIEWERS' FETCH LEAVES THE ORIGIN AND ONLY connect-src LETS THE BROWSER READ IT
    # (files-preview.md:410-422). No system test on the share leg can see this, and the existing CSP
    # suite only ever drives a SIGNED-IN page — so a public page losing the policy would be silent
    # on every leg. Branches on the CAPABILITY, exactly as content_security_policy_test.rb does.
    test "a public file page carries the same connect-src the private one does" do
      get view_path_for(@f[:base].node_id)
      sources = response.headers["Content-Security-Policy-Report-Only"][/connect-src ([^;]+)/, 1]
      port = FileLayer.current

      if port.capabilities.presignable?
        assert_equal "'self' #{port.presigned_origin}", sources
      else
        assert_equal "'self'", sources
      end
    end
  end
end
