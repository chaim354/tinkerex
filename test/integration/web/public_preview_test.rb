require "test_helper"
require "support/public_fixture"

module Web
  # A PUBLIC FILE'S DERIVED ASSET DIES WITH THE PROJECT'S PUBLICATION (hardening, 2026-09-08;
  # tinkerex#278). Every public surface used to render `url_for(preview.asset)` — an Active Storage
  # blob URL, which is UNAUTHENTICATED and has NO EXPIRY (`ActiveStorage.urls_expire_in` is nil) —
  # so a cover thumbnail saved off a public page kept answering after the project went private, and
  # kept answering forever. `GET /u/:handle/:slug/files/:id/preview/:kind` asks the SAME permission
  # the byte route asks (`Maker::PublicProject#deliverable!`) and then redirects to a service URL
  # that expires in five minutes.
  #
  # IT PINS SHARE for PublicFixture's reason (that module's header): these tests read real bytes
  # through the port, and a `create_node!` fixture has an object behind it only on share.
  class PublicPreviewTest < ActionDispatch::IntegrationTest
    include PublicFixture

    GEOMETRY_JSON = '{"shapes":[]}'.freeze

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
      # A CAD file, whose page takes files/viewers/_static's `:thumbnail` branch — the one viewer
      # that has nothing but the poster, so a missing `thumbnail_url` there shows as a blank page
      # rather than as a fallback. `.stl` is the `:model3d` branch beside it (the poster BEHIND an
      # interactive viewer), and `.lbrn2` is `:measure`, whose payload is the second `kind` this
      # route serves.
      @cad   = make_file!(@user, "bracket.ai", @f[:folder], body: "%!PS-Adobe\n")
      @laser = make_file!(@user, "sign.lbrn2", @f[:folder], body: "<LightBurnProject/>")
      # A CONTENT TOKEN IS WHAT PUTS A VIEWER ON THE PAGE AT ALL (public_file_view_test.rb's own
      # setup says why, at more length): the page opens with `if @info.content_token.nil?` →
      # "No content yet.", so without these two columns every file-page test below would assert
      # about the empty branch and pass for nothing. BOTH columns, because the port's content token
      # is `content_hash` on share/s3 and `current_version_id` on chunk_remote (§14a).
      [ @f[:base], @f[:pic], @f[:entry_photo], @cad, @laser ].each do |node|
        node.update!(content_hash: "h-#{node.node_id}", current_version_id: "v-#{node.node_id}")
      end
    end

    teardown { FileLayer.reset! }

    # `ready_preview!` is PublicFixture's (shared with public_file_view_test.rb since review).

    def preview_path_for(node_id, kind: "thumbnail", **opts)
      public_file_preview_path("ada", @project.slug, node_id, kind, **opts)
    end

    # --- 1. every public surface emits the route, and no blob URL --------------------------------

    # THE MAKER'S PAGE. `_project_card` builds this URL itself rather than taking a local: it is a
    # public template, so a public route helper is what it is allowed to name (the seam guard's
    # arms are about the SHARED partials), and `thumb` is a Maker::Preview carrying the node_id.
    test "a maker's page renders each cover through the public preview route" do
      ready_preview!(@user, @f[:pic])
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card .card-cover img[src=?]", preview_path_for(@f[:pic].node_id)
      assert_no_private_urls
    end

    # THE HERO, FROM A NON-IMAGE COVER. An image-role cover is the picture itself through the byte
    # route and never reaches a preview row at all, so the thumbnail arm needs a cover that is not
    # one — which is also the arm that carried the page's LARGEST never-expiring picture.
    # BOTH FILE SURFACES SINCE FOLDER PANELS (2026-09-08): the Files panel's table is the folder
    # ROOT alone, and a subfolder's files render as TILES in that folder's own panel — two
    # `files/_thumb` callers where there was one, and the tile is the new one, so a `url_for` left
    # in it would reach a visitor with the table assertion still green.
    test "the project page's hero, photos and both file surfaces name the preview route" do
      ready_preview!(@user, @f[:base])
      ready_preview!(@user, @f[:pic])
      # `@cad` SITS AT THE FOLDER ROOT, which is what the Files panel is now — and it is one of the
      # nodes this suite's setup stamps a content token onto, without which no preview row of it
      # could ever be current (that setup's own comment).
      ready_preview!(@user, @cad)
      @project.update_column(:cover_node_id, @f[:base].node_id)

      get public_project_path("ada", @project.slug)

      assert_response :success
      assert_select ".project-hero img[src=?]", preview_path_for(@f[:base].node_id)
      assert_select ".public-photos .thumb img[src=?]", preview_path_for(@f[:pic].node_id)
      assert_select "table.public-files .col-thumb img[src=?]", preview_path_for(@cad.node_id)
      assert_select ".public-tiles .thumb img[src=?]", preview_path_for(@f[:base].node_id)
      assert_no_private_urls
    end

    # A BUILD-LOG PHOTO IS THE THIRD PUBLIC `files/_thumb` CALLER, and its node lives OUTSIDE the
    # folder (PublicFixture seeds it at the library root on purpose), so it is permitted by the
    # ATTACHMENT arm rather than by ancestry — the arm most likely to be dropped by a "simplifying"
    # rewrite of the door below.
    test "a build-log photo's thumbnail names the preview route" do
      ready_preview!(@user, @f[:entry_photo])

      get public_project_path("ada", @project.slug)

      assert_response :success
      assert_select ".entry-photos .thumb img[src=?]", preview_path_for(@f[:entry_photo].node_id)
      assert_no_private_urls
    end

    test "a visitor's file page posters the :thumbnail and :model3d viewers through the route" do
      ready_preview!(@user, @cad)
      ready_preview!(@user, @f[:base])

      get public_file_view_path("ada", @project.slug, @cad.node_id)
      assert_response :success
      assert_select "img.preview-image[src=?]", preview_path_for(@cad.node_id)
      assert_no_private_urls

      get public_file_view_path("ada", @project.slug, @f[:base].node_id)
      assert_response :success
      assert_select ".model-viewer-fallback img.preview-image[src=?]",
                    preview_path_for(@f[:base].node_id)
      assert_no_private_urls
    end

    # THE GEOMETRY POLLER'S URL OUTLIVES THE RESPONSE, which is why it is the same problem as an
    # <img> and not a smaller one: measure_controller.js fetches it later, and a blob URL there is
    # the whole Measure payload behind a link that never expires.
    test "the geometry poll answers the public preview route, never a blob URL" do
      ready_preview!(@user, @laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")

      get public_file_geometry_path("ada", @project.slug, @laser.node_id)

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal "ready", body["status"]
      assert_equal preview_path_for(@laser.node_id, kind: "geometry"), body["url"]
      assert_no_match(%r{/rails/active_storage/}, response.body)
    end

    # --- 2. the door itself ----------------------------------------------------------------------

    # A SERVICE URL, NOT A BLOB URL, AND THE DIFFERENCE IS THE WHOLE POINT: the disk service's URL
    # carries a token minted with `ActiveStorage.service_urls_expire_in` (5 minutes), where
    # `/rails/active_storage/blobs/redirect/<signed_id>` carries a signed id with no expiry at all.
    test "the route redirects to an EXPIRING service URL that serves the asset's bytes" do
      ready_preview!(@user, @f[:base])

      get preview_path_for(@f[:base].node_id)

      assert_response :redirect
      assert_match(%r{/rails/active_storage/disk/}, response.location)
      # THE REDIRECT MAY BE KEPT FOR A MINUTE, AND A MINUTE IS SHORTER THAN ITS TARGET LIVES
      # (tinkerex#291): the second assertion is what makes the first safe — a cached 302 that
      # outlived the service URL it names would hand a browser a dead picture, and a project that
      # goes private is stale for at most the cache's minute.
      assert_match(/max-age=60/, response.headers["Cache-Control"].to_s, "the 302 carries a one-minute cache")
      assert_match(/private/, response.headers["Cache-Control"].to_s, "the cache is the browser's, not a shared one")
      assert_operator 1.minute, :<, ActiveStorage.service_urls_expire_in,
                      "the cached redirect must expire before the URL it points at"

      follow_redirect!
      assert_response :success
      assert_equal PublicFixture::PNG_BYTES, response.body.b
    end

    test "the Measure payload comes through the same door" do
      ready_preview!(@user, @laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")

      get preview_path_for(@laser.node_id, kind: "geometry")

      assert_response :redirect
      follow_redirect!
      assert_equal GEOMETRY_JSON, response.body
    end

    # THE MEASURE PAYLOAD'S REDIRECT IS NEVER KEPT (F-S08-2, folding the audit's §4 note). Its URL is
    # the same for every build of the file, so the minute of private cache a thumbnail's 302 carries
    # (tinkerex#291, the test above) let a visitor's browser answer the next Measure open after a
    # rebuild with the OLDER payload, for up to a minute after `current_build?` began refusing it on
    # the server. Driven through a real rebuild: neither 302 may be reusable — the one a browser
    # holds when the rebuild lands, nor the one after it — and the second names the rebuilt payload.
    test "the Measure payload's redirect is never cached, so a rebuild cannot be answered from an older one" do
      row = ready_preview!(@user, @laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")

      get preview_path_for(@laser.node_id, kind: "geometry")
      assert_response :redirect
      assert_match(/\bno-store\b/, response.headers["Cache-Control"].to_s,
                   "a browser may keep this 302 and replay the older payload after a rebuild")

      # THE REBUILD: the row was built by an older renderer, and the visitor's render queues the job.
      row.update!(renderer_revision: row.renderer_revision - 1)
      get public_file_view_path("ada", @project.slug, @laser.node_id)
      get preview_path_for(@laser.node_id, kind: "geometry")
      assert_response :not_found, "mid-rebuild the older payload must not be served at all"

      Maker::GeneratePreviewJob.perform_now(row.id)
      get preview_path_for(@laser.node_id, kind: "geometry")
      assert_response :redirect
      assert_match(/\bno-store\b/, response.headers["Cache-Control"].to_s)
      follow_redirect!
      assert_not_equal GEOMETRY_JSON, response.body, "the redirect still named the older build's payload"
    end

    # THE HEADLINE. The picture is what a visitor keeps a copy of, so the URL outliving the
    # publication is the failure the whole slice exists to close.
    test "the same URL stops answering the moment the project goes private" do
      ready_preview!(@user, @f[:base])
      url = preview_path_for(@f[:base].node_id)

      get url
      assert_response :redirect

      @project.update!(visibility: "private")

      get url
      assert_response :not_found
    end

    # AN UNLISTED PROJECT'S TOKEN IS THE CREDENTIAL, on this route as on its two siblings —
    # `preview_url_for` carries `link_params` for exactly this reason, so the page's own <img> tags
    # keep working while a token-less guess does not.
    test "an unlisted project's preview needs its k token" do
      ready_preview!(@user, @f[:base])
      @project.update!(visibility: "unlisted")

      get preview_path_for(@f[:base].node_id)
      assert_response :not_found

      get preview_path_for(@f[:base].node_id, k: @project.reload.unlisted_token)
      assert_response :redirect
    end

    # THE PERMISSION IS `deliverable!`'S, NOT "a node this user owns". `outsider` is a real node of
    # the same owner, with a real ready preview row, sitting OUTSIDE the project folder and attached
    # to nothing — the exact shape a bare `owner.nodes.find_by(node_id:)` would serve.
    #
    # THE `content_hash` STAMP IS WHAT MAKES THIS TEST ABLE TO FAIL, and it was missing at first:
    # without it the port answers `content_token: nil`, `current_preview` refuses a blank version_id
    # and the 404 arrives for a reason that has nothing to do with permission — so substituting
    # `owner.nodes.find_by!` for `deliverable!` stayed GREEN (measured, then fixed; §15's rule about
    # a guard that has never failed).
    test "a node the project does not permit is a 404, ready row and all" do
      @f[:outsider].update!(content_hash: "h-#{@f[:outsider].node_id}",
                            current_version_id: "v-#{@f[:outsider].node_id}")
      row = ready_preview!(@user, @f[:outsider])
      assert_predicate row.version_id, :present?,
                       "the row must be CURRENT, or the 404 below proves nothing about permission"

      get preview_path_for(@f[:outsider].node_id)

      assert_response :not_found
    end

    # A ROW THAT IS NOT READY IS THE SAME 404 AS A NODE THAT IS NOT PERMITTED, because an <img>
    # cannot use a status — and because the two must be indistinguishable to a stranger.
    test "a permitted node with no current ready row is a 404" do
      get preview_path_for(@f[:base].node_id)
      assert_response :not_found

      pending = @user.maker_previews.create!(
        node_id: @f[:base].node_id, kind: "thumbnail", status: "pending",
        version_id: FileLayer.current.stat(@user, node_id: @f[:base].node_id).content_token,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(@f[:base].name, "thumbnail")
      )
      get preview_path_for(@f[:base].node_id)
      assert_response :not_found

      # READY BUT UNATTACHED is its own case: `status` is a column, the asset is a separate record,
      # and the row can hold one without the other (files-preview.md's own "ready with no attached
      # asset" state). `redirect_to nil` would be a 500.
      pending.update!(status: "ready")
      get preview_path_for(@f[:base].node_id)
      assert_response :not_found
    end

    # A RENDERER REBUILD SPLITS THE TWO KINDS THIS ROUTE SERVES (F-S08-2), and that split is the
    # point: the thumbnail is a PICTURE of this same content and stays served while its rebuild is
    # queued, the Measure payload is DATA and an older build's is wrong. The visitor's page render
    # queues both rebuilds; until the jobs run, the geometry poll and the payload route must refuse
    # the older payload — `Enqueue` left the geometry row `ready`, so both served it as current.
    # MUTATION: drop Enqueue's `rebuilding` write.
    test "a renderer rebuild keeps serving the picture but never an older build's Measure payload" do
      thumb = ready_preview!(@user, @laser)
      geometry = ready_preview!(@user, @laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")
      [ thumb, geometry ].each { |row| row.update!(renderer_revision: row.renderer_revision - 1) }

      get public_file_view_path("ada", @project.slug, @laser.node_id)
      assert_response :success

      get public_file_geometry_path("ada", @project.slug, @laser.node_id)
      assert_equal "pending", JSON.parse(response.body)["status"],
                   "the visitor's poll served an older build's payload as current"
      get preview_path_for(@laser.node_id, kind: "geometry")
      assert_response :not_found
      get preview_path_for(@laser.node_id)
      assert_response :redirect, "the picture of this same content stopped answering mid-rebuild"
    end

    # A STALE ROW IS NOT THE FILE'S PICTURE. `current_preview` is the same "current content, current
    # renderer build" rule the page rendered from, so this route cannot serve a picture of content
    # the file no longer holds.
    test "a row for superseded content is a 404" do
      ready_preview!(@user, @f[:base])
      @f[:base].update!(content_hash: "h-moved-on")
      @root.join(@f[:base].storage_path).binwrite("solid different")

      get preview_path_for(@f[:base].node_id)

      assert_response :not_found
    end

    # AN UNKNOWN KIND IS A 404, AND THE BYTE ROUTE'S `filename` CONSTRAINT IS WHAT MAKES IT ONE
    # (found in Task A, measured: without it, `files/:id(/*filename)` one line below the preview route
    # matched `/preview/other` as `filename: "preview/other"` and served the file's own bytes with a
    # 200 — behind the same `deliverable!`, so a surprise rather than a leak, but a URL that says
    # "preview" and answers with the file is the trap config/routes.rb's `view`/`geometry` ordering
    # comment exists to prevent, one segment deeper). A filename is a leaf name and never holds a
    # slash, so the constraint costs nothing a real URL needs. Both nodes, so the 404 is the route's
    # and not `deliverable!`'s.
    test "an unknown kind is a 404, not the file's bytes" do
      ready_preview!(@user, @f[:base])

      get "/u/ada/#{@project.slug}/files/#{@f[:base].node_id}/preview/other"
      assert_response :not_found

      get "/u/ada/#{@project.slug}/files/#{@f[:outsider].node_id}/preview/other"
      assert_response :not_found
    end

    # --- 3. the private page is deliberately UNCHANGED -------------------------------------------

    # THE MAKER'S OWN PAGE STILL SERVES A BLOB URL, and that is the decision, not an oversight: it
    # is session-authed, so the URL is already behind a login for as long as the row exists, and
    # `preview_src` is the one private spelling. This test is what makes the swap above a SPLIT
    # rather than a global replacement — and it is what would go red if someone "tidied" the two
    # spellings into one.
    test "the maker's own file page still renders its thumbnail as a blob URL" do
      ready_preview!(@user, @cad)
      sign_in_as(@user)

      get file_path(@cad.node_id)

      assert_response :success
      assert_select "img.preview-image[src^=?]", "/rails/active_storage/"
    end
  end
end
