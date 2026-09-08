require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 3, S3-4: /u/:handle/:slug — one published project, read-only, for anyone.
  #
  # NO SESSION IS ESTABLISHED unless a test says so. The two tests that DO sign in are the point of
  # the suite as much as the anonymous ones: a private project must be a 404 to its own owner in
  # another tab (the page cannot consult the session, so it cannot know), and a signed-in owner
  # looking at their own PUBLIC page must see the visitor's shell rather than the rail.
  #
  # A FRESH SHARE LIBRARY PER TEST — see test/support/public_fixture.rb's header for why these
  # suites cannot ride the ambient backend.
  class PublicProjectTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
    end

    def path(**opts) = public_project_path("ada", @project.slug, **opts)

    # --- 1. private is a 404 to everyone -----------------------------------------

    test "a private project is 404 to a visitor and to its own signed-in owner" do
      @project.update!(visibility: "private")

      get path
      assert_response :not_found

      sign_in_as(@user)
      get path
      assert_response :not_found, "the page does not read the session, so it cannot make an exception"
    end

    # --- 2. unlisted needs its token ---------------------------------------------

    test "an unlisted project needs its token: none and wrong are 404, right is the page" do
      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token

      get path
      assert_response :not_found

      get path(k: "#{token}x")
      assert_response :not_found, "a wrong token must not open the page"

      get path(k: token)
      assert_response :success
    end

    # A ROW WHOSE VISIBILITY WAS FLIPPED BELOW THE VALIDATIONS HAS NO TOKEN, AND MUST FAIL CLOSED.
    # `secure_compare("", "")` is TRUE, so comparing a NULL token against a missing `k` would open
    # the page to everyone — driven here rather than reasoned about, because the two spellings look
    # identical and only one of them is safe.
    test "an unlisted project whose token column is NULL is readable by nobody" do
      @project.update_columns(visibility: "unlisted", unlisted_token: nil)

      get path
      assert_response :not_found
      get path(k: "")
      assert_response :not_found
    end

    test "every link an unlisted page renders carries the token" do
      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token
      get path(k: token)

      hrefs = css_select("a[href*='/files/']").map { |a| a["href"] }
      assert_operator hrefs.size, :>, 3, "the scan matched #{hrefs.size} file links — vacuous (§14e)"
      hrefs.each { |h| assert_includes h, "k=#{token}", "#{h} drops the token and leads to a 404" }

      stage = css_select(".kicanvas-stage").first
      assert_includes stage["data-kicanvas-url-value"], "k=#{token}",
                      "the KiCanvas fetch is a request like any other and needs the credential"
    end

    # --- 3. the public page, and what it must NOT contain ------------------------

    test "a public project renders its name, byline and tag chips linking into explore" do
      get path

      assert_response :success
      assert_select "h1", text: "Desk Lamp"
      assert_select ".public-byline a[href=?]", public_user_path("ada"), text: "@ada"
      assert_select ".public-byline .badge.license", text: "CERN OHL v2 Permissive"
      assert_select ".tag-chips a[href=?]", public_explore_path(tag: "lamp"), text: "lamp"
    end

    test "the page is read-only: no private links, no form and no button anywhere in main" do
      get path

      assert_select "main a[href^='/files/']", false, "a visitor cannot open the owner's file page"
      assert_select "main a[href^='/projects/']", false
      assert_select "main a[href^='/tags/']", false, "tag chips must link into /explore, not the private tag page"
      assert_select "main a[href^='/repos/']", false
      assert_select "main form", false
      # STAGE 3, S3-6: THE ONE BUTTON A PUBLIC PAGE MAY CARRY, AND THE RULE BEHIND IT IS UNCHANGED.
      # "No button" was always shorthand for "a visitor is not the person who would change
      # something". The bundle button submits nothing, sits in no form, and its whole effect is to
      # fetch the files this page already links and zip them in the visitor's OWN browser. Kept as
      # an exact inventory rather than relaxed to nothing, so a real write control still fails here.
      assert_select "main button", 1
      assert_select "main .bundle button[type=button][data-action=?]", "bundle#build"
    end

    test "a visitor gets the visitor shell, with no rail and no tab bar" do
      get path

      assert_select "aside.rail", false
      assert_select "nav.tabbar", false
      assert_select "main.public-main", 1, "a public page must not render inside the 440px auth column"
    end

    test "an unlisted page asks not to be indexed; a public one does not" do
      get path
      assert_select "head meta[name=robots]", false

      @project.update!(visibility: "unlisted")
      get path(k: @project.reload.unlisted_token)
      assert_select "head meta[name=robots][content=?]", "noindex"
    end

    # --- 4. the README ------------------------------------------------------------

    test "the README renders with its relative links resolved to public file URLs" do
      get path

      assert_select ".readme-panel .markdown a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id)
      assert_select ".readme-panel .markdown img[src=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".readme-panel .markdown img[src^='http']", false,
                    "an absolute image would be a request to another origin from this page"
    end

    # --- 5. files ------------------------------------------------------------------

    test "the files panel groups by section and offers a download link per row" do
      get path

      sections = css_select("h3.public-section").map(&:text)
      assert_includes sections, "Desk Lamp"
      assert_includes sections, "models" # folder-relative, never the library path

      row = css_select("table.public-files tr").find { |tr| tr.text.include?("base.stl") }
      assert row, "base.stl must be listed"
      dl = row.css("td.col-dl a").first
      assert_match(/download=1\z/, dl["href"])
      assert_match(/\d/, row.css("td.col-size").text, "the size cell shows a size")
    end

    test "a dot-file in the folder is not listed" do
      get path
      assert_select "table.public-files", text: /\.env/, count: 0
    end

    # --- 6. photos -----------------------------------------------------------------

    test "the photos panel shows the folder's image and the entry photo living outside it" do
      get path

      assert_select ".photos-panel a[href=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".photos-panel a[href=?]", public_file_path("ada", @project.slug, @f[:entry_photo].node_id)
    end

    # --- 7. the BOM: three columns, and what is absent ------------------------------

    test "the public BOM has exactly Ref, Part and Qty" do
      get path
      assert_equal %w[Ref Part Qty], css_select("table.public-bom thead th").map(&:text)
    end

    test "the public BOM names the item but never its stock level or its supplier" do
      get path
      body = response.body

      assert_select "table.public-bom", text: /M3 bolt/
      assert_not_includes body, "7 on hand", "the owner's inventory level is not this project's description"
      assert_not_includes body, "Acme Supply", "who they buy from is a private business relationship"
      assert_select "table.public-bom .col-stock", false
      assert_select "table.public-bom .col-supplier", false
    end

    test "a BOM file line links to the public file URL" do
      get path
      assert_select "table.public-bom a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id)
    end

    # A LINE POINTING OUTSIDE THE PROJECT NAMES NOTHING. The route refuses the bytes, and the cell
    # must not publish the private file's NAME in their place — the one spot the page would state
    # a fact about a non-permitted node (S3-4's review). A dash, since the line has no free text.
    test "a BOM line pointing at a file outside the project shows neither its name nor a link" do
      @f[:bom].lines.create!(user: @user, node_id: @f[:outsider].node_id, quantity: 1, unit: "each")

      get path
      assert_not_includes response.body, "elsewhere.stl"
      assert_select "table.public-bom td.col-part", text: "—"
      assert_select "table.public-bom a[href*=?]", @f[:outsider].node_id, count: 0
    end

    # --- 8. wiring ------------------------------------------------------------------

    test "the wiring table renders read-only" do
      get path

      assert_select "table.wiring tbody tr", 2
      assert_select "table.wiring input", false, "editable: false is what makes this a public table"
      assert_select "table.wiring th.col-actions", false
    end

    # --- 9. schematics ---------------------------------------------------------------

    test "the KiCanvas stage fetches the public NAMED url, extension last" do
      get path

      assert_select ".kicanvas-stage[data-kicanvas-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:kicad].node_id, filename: "driver.kicad_sch")
    end

    # --- 10. the repository card -------------------------------------------------------

    test "the repo card shows its facts and links nowhere private" do
      get path

      assert_select ".repo-card .repo-facts", 1
      assert_select ".repo-card a[href^='/repos/']", false, "Commits and History need a signed-in maker"
    end

    # --- 11/12. the owner, and handles --------------------------------------------------

    test "the owner signed in on their own public page still sees the visitor's shell" do
      sign_in_as(@user)
      get path

      assert_response :success
      assert_select "aside.rail", false
      assert_select "nav.tabbar", false
      assert_select "a", text: "Edit", count: 0
      assert_select "body.app-shell", false,
                    "the shell grid reserves a rail-wide column; without a rail it shifts the page"
    end

    test "the handle is matched case-insensitively, and a wrong one is a 404" do
      # The route's constraint accepts either case; `owner!` downcases before the lookup, because a
      # handle is stored lowercase and a link pasted from a capitalised context must still open.
      get public_project_path("ADA", @project.slug)
      assert_response :success

      get public_project_path("nobody", @project.slug)
      assert_response :not_found
    end

    test "another maker's project is a 404 under this handle" do
      other = make_owner!(handle: "bob")
      theirs = other.maker_projects.create!(name: "Their Lamp", visibility: "public")

      get public_project_path("ada", theirs.slug)
      assert_response :not_found
    end

    # --- 13. Stage 4, S4-5: the cover, on the card and as the page's hero ----------------

    # THE READY COVER, ON THE MAKER'S OWN PAGE. /u/:handle is SINGLE-OWNER, which is the whole
    # reason it gets covers and /explore does not: Maker::Previews::ThumbnailMap is per-user (a
    # preview row belongs to its owner, and the port is asked in the owner's name — §14a), so one
    # map serves this page and a cross-user list would need one per maker. This suite can assert the
    # READY branch because it pins share and has real bytes; public_explore_test.rb, which is
    # deliberately port-free, asserts the placeholder branch instead.
    #
    # `renderer_revision` IS ASKED, NEVER HARD-CODED. A row that is silently not current renders the
    # placeholder, and this test would then fail for a reason that has nothing to do with the cover.
    test "a maker's page shows each project's cover as a ready thumbnail" do
      ready_cover!(@f[:pic])
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card .card-cover img"
      assert_select "[data-controller=?]", "thumbs", 0
    end

    test "the public project page leads with its cover, linking to the file's own page" do
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get path

      assert_select ".project-hero img[src=?]",
                    public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".project-hero a[href=?]",
                    public_file_view_path("ada", @project.slug, @f[:pic].node_id)
    end

    test "a cover the project does not permit renders no hero at all" do
      @project.update_column(:cover_node_id, @f[:outsider].node_id)

      get path

      assert_select ".project-hero", 0, "an unpermitted cover must not become a public picture"
    end

    # A READY, CURRENT THUMBNAIL FOR ONE NODE. Both halves are asked of the code that owns them
    # rather than written as literals: `renderer_revision` from Enqueue (a row at the wrong build is
    # not current, renders the placeholder, and would fail this test for the wrong reason) and
    # `version_id` from the PORT.
    #
    # THE `content_hash` STAMP IS LOAD-BEARING. On share the port's content token IS that column
    # (FileLayer::Share#file_info) and `create_node!` leaves it NULL, so without this line the token
    # is nil, `Enqueue.current_preview?` refuses a blank version_id — deliberately, since `nil ==
    # nil` would serve a coincidence of representation as an answer about content — and the map
    # answers nil for a row that looks perfectly good in the database.
    def ready_cover!(node)
      node.update!(content_hash: "h-#{node.node_id}")
      preview = @user.maker_previews.create!(
        node_id: node.node_id, kind: "thumbnail", status: "ready",
        version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
        renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail")
      )
      preview.asset.attach(io: StringIO.new(PublicFixture::PNG_BYTES), filename: node.name,
                           content_type: "image/png")
      preview
    end
  end
end
