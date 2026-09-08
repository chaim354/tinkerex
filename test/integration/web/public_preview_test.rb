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

    # A READY, CURRENT ROW WITH AN ATTACHED ASSET, for any node and either kind. Both halves of
    # "current" are asked of the code that owns them rather than written as literals
    # (public_project_test.rb's `ready_cover!` is this, thumbnail-only): `renderer_revision` from
    # Enqueue — a row at the wrong build is not current, renders the placeholder, and would fail
    # these tests for the wrong reason — and `version_id` from the PORT, which on share IS the
    # `content_hash` column stamped above.
    def ready_preview!(node, kind: "thumbnail", body: PublicFixture::PNG_BYTES,
                       content_type: "image/png")
      preview = @user.maker_previews.create!(
        node_id: node.node_id, kind:, status: "ready",
        version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, kind)
      )
      preview.asset.attach(io: StringIO.new(body), filename: node.name, content_type:)
      preview
    end

    def preview_path_for(node_id, kind: "thumbnail", **opts)
      public_file_preview_path("ada", @project.slug, node_id, kind, **opts)
    end

    # --- 1. every public surface emits the route, and no blob URL --------------------------------

    # THE MAKER'S PAGE. `_project_card` builds this URL itself rather than taking a local: it is a
    # public template, so a public route helper is what it is allowed to name (the seam guard's
    # arms are about the SHARED partials), and `thumb` is a Maker::Preview carrying the node_id.
    test "a maker's page renders each cover through the public preview route" do
      ready_preview!(@f[:pic])
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card .card-cover img[src=?]", preview_path_for(@f[:pic].node_id)
      assert_no_private_urls
    end

    # THE HERO, FROM A NON-IMAGE COVER. An image-role cover is the picture itself through the byte
    # route and never reaches a preview row at all, so the thumbnail arm needs a cover that is not
    # one — which is also the arm that carried the page's LARGEST never-expiring picture.
    test "the project page's hero, photos and file rows all name the preview route" do
      ready_preview!(@f[:base])
      ready_preview!(@f[:pic])
      @project.update_column(:cover_node_id, @f[:base].node_id)

      get public_project_path("ada", @project.slug)

      assert_response :success
      assert_select ".project-hero img[src=?]", preview_path_for(@f[:base].node_id)
      assert_select ".public-photos .thumb img[src=?]", preview_path_for(@f[:pic].node_id)
      assert_select "table.public-files .col-thumb img[src=?]", preview_path_for(@f[:base].node_id)
      assert_no_private_urls
    end

    # A BUILD-LOG PHOTO IS THE THIRD PUBLIC `files/_thumb` CALLER, and its node lives OUTSIDE the
    # folder (PublicFixture seeds it at the library root on purpose), so it is permitted by the
    # ATTACHMENT arm rather than by ancestry — the arm most likely to be dropped by a "simplifying"
    # rewrite of the door below.
    test "a build-log photo's thumbnail names the preview route" do
      ready_preview!(@f[:entry_photo])

      get public_project_path("ada", @project.slug)

      assert_response :success
      assert_select ".entry-photos .thumb img[src=?]", preview_path_for(@f[:entry_photo].node_id)
      assert_no_private_urls
    end

    test "a visitor's file page posters the :thumbnail and :model3d viewers through the route" do
      ready_preview!(@cad)
      ready_preview!(@f[:base])

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
      ready_preview!(@laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")

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
      ready_preview!(@f[:base])

      get preview_path_for(@f[:base].node_id)

      assert_response :redirect
      assert_match(%r{/rails/active_storage/disk/}, response.location)

      follow_redirect!
      assert_response :success
      assert_equal PublicFixture::PNG_BYTES, response.body.b
    end

    test "the Measure payload comes through the same door" do
      ready_preview!(@laser, kind: "geometry", body: GEOMETRY_JSON, content_type: "application/json")

      get preview_path_for(@laser.node_id, kind: "geometry")

      assert_response :redirect
      follow_redirect!
      assert_equal GEOMETRY_JSON, response.body
    end

    # THE HEADLINE. The picture is what a visitor keeps a copy of, so the URL outliving the
    # publication is the failure the whole slice exists to close.
    test "the same URL stops answering the moment the project goes private" do
      ready_preview!(@f[:base])
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
      ready_preview!(@f[:base])
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
      row = ready_preview!(@f[:outsider])
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

    # A STALE ROW IS NOT THE FILE'S PICTURE. `current_preview` is the same "current content, current
    # renderer build" rule the page rendered from, so this route cannot serve a picture of content
    # the file no longer holds.
    test "a row for superseded content is a 404" do
      ready_preview!(@f[:base])
      @f[:base].update!(content_hash: "h-moved-on")
      @root.join(@f[:base].storage_path).binwrite("solid different")

      get preview_path_for(@f[:base].node_id)

      assert_response :not_found
    end

    # AN UNKNOWN KIND FALLS THROUGH TO THE BYTE ROUTE, AND THIS IS THE ONE PLACE THAT SAYS SO
    # (measured, not assumed — the plan predicted a routing 404 and it is not one). The `kind`
    # constraint `/thumbnail|geometry/` keeps `/preview/other` off THIS action, but the byte route
    # one line below it is `files/:id(/*filename)` and `:filename` is decorative to the server, so
    # the path matches with `filename: "preview/other"` and serves the file's own bytes with a 200.
    #
    # THAT IS SURPRISING AND IT IS NOT A LEAK, which is what the second half pins: the byte route
    # asks the SAME `Maker::PublicProject#deliverable!` this action asks, so the worst an unknown
    # kind can produce is the file the URL already names — never another node's derived asset, and
    # never anything on a project that does not permit it. Tightening it belongs to the route (the
    # `view`/`geometry` ordering comment in config/routes.rb is the same trap), not here.
    test "an unknown kind falls through to the byte route, still behind the same permission" do
      ready_preview!(@f[:base])

      get "/u/ada/#{@project.slug}/files/#{@f[:base].node_id}/preview/other"
      assert_response :success
      assert_equal "solid base", response.body

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
      ready_preview!(@cad)
      sign_in_as(@user)

      get file_path(@cad.node_id)

      assert_response :success
      assert_select "img.preview-image[src^=?]", "/rails/active_storage/"
    end
  end
end
