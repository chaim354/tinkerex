require "test_helper"
require "support/public_fixture"

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
    end

    teardown { FileLayer.reset! }

    def view_path_for(node_id, **opts) = public_file_view_path("ada", @project.slug, node_id, **opts)

    # NOT A PRIVATE ROUTE ANYWHERE IN THE DOCUMENT, and this is a stronger fence than the seam
    # guard's. That guard greps the shared partials for `current_user` and friends; it cannot see a
    # `blob_file_path` that a CALLER passed in as a local, because the local is what the partial
    # renders. The public byte route contains "/files/" too (/u/ada/desk-lamp/files/:id), so the
    # match is anchored on the quote that opens the attribute — only a root-relative private URL
    # starts that way.
    def assert_no_private_urls
      assert_select "[href^='/files/']", count: 0
      assert_select "[src^='/files/']", count: 0
      assert_no_match(%r{["']/files/}, response.body,
                      "a public page built a private /files/ URL — the seam a public template " \
                      "must never cross (CLAUDE.md §14d)")
    end

    test "a permitted model file gets the 3D viewer, pointed at the PUBLIC named byte route" do
      get view_path_for(@f[:base].node_id)

      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      assert_select "[data-modelviewer-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:base].node_id, filename: "base.stl")
      assert_select "[data-modelviewer-lazy-value=?]", "true"
      assert_no_private_urls
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
