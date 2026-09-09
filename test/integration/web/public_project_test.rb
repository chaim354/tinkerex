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

    # THE SAME BADGE RULE AS THE MAKER'S PAGE (stage 4, S4-6, found in review): `planning` is the
    # default and is not badged; a status the maker set is.
    test "the byline badges a set status and not the planning default" do
      get path
      assert_select ".public-byline .badge[class*=status-]", count: 0

      @project.update_column(:status, "active")
      get path
      assert_select ".public-byline .badge.status-active", text: "Active"
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

    # --- 5. files: the folder root, plus one panel per subfolder --------------------
    #
    # 2026-09-08, FOLDER PANELS (spec §5): the Files panel was the whole folder, section by
    # section; it is now the ROOT alone (decision 4) and each DEPTH-ONE subfolder is a panel of its
    # own, in the maker's order, with the view the maker chose. The fixture already holds all three
    # shapes this needs — `firmware` (a working tree), `models` (with `deep` nested inside it) and
    # `photos` — so nothing here has to build a second project folder.

    test "the files panel lists the folder's root files only, with a download link per row" do
      get path

      names = css_select("section.files-panel table.public-files td.col-name").map(&:text)
      assert_equal [ "README.md", "driver.kicad_sch" ], names,
                   "the root is the Files panel; a subfolder's files belong to its own panel now"
      assert_select "section.files-panel", text: /base\.stl/, count: 0

      row = css_select("section.files-panel table.public-files tr").find { |tr| tr.text.include?("README.md") }
      dl = row.css("td.col-dl a").first
      assert_match(/download=1\z/, dl["href"])
      assert_match(/\d/, row.css("td.col-size").text, "the size cell shows a size")
    end

    test "a dot-file in the folder is not listed" do
      get path
      assert_select "table.public-files", text: /\.env/, count: 0
    end

    # THE ORDER IS THE MAKER'S OWN, AND THE DEFAULT PUTS THE FOLDERS AFTER FILES IN DISK ORDER —
    # the arrangement a maker who has never touched the chooser gets (Maker::ProjectKind's
    # after-Files rule), read here off the rendered page rather than off the layout.
    test "each depth-one subfolder is its own panel, after Files and in disk order" do
      get path

      assert_equal %w[firmware models photos], css_select("section.folder-panel h2").map(&:text)

      classes = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"] }
      assert_operator classes.index { |c| c.include?("files-panel") }, :<,
                      classes.index { |c| c.include?("folder-panel") },
                      "the folder root reads first, then its subfolders"
      assert_select "section.folder-panel .panel-head .mono", { text: "2 files", count: 1 },
                    "models holds base.stl and deep/x.stl — the whole subtree, not this dir's own files"
    end

    # DEPTH ONE IS THE WHOLE RULE (spec decision 3): `models/deep` renders INSIDE the models panel
    # as a sub-heading, never as a panel of its own.
    test "a nested folder is a sub-heading inside its parent's panel, not a panel" do
      get path

      panel = css_select("section.folder-panel").find { |s| s.css("h2").text == "models" }
      assert_equal [ "deep" ], panel.css("h3.public-section").map(&:text),
                   "folder-relative, never the library path and never `models/deep`"
      assert_select "section.folder-panel h2", text: "deep", count: 0
      assert panel.css("a[href='#{public_file_view_path("ada", @project.slug, @f[:deep_file].node_id)}']").any?,
             "the nested folder's own file renders inside that panel"
    end

    # TILES ARE THE DEFAULT FOR A PLAIN FOLDER (spec decision 6), and a tile's thumbnail goes
    # through the public preview route — never a blob URL, which is what `assert_no_private_urls`
    # sweeps for (tinkerex#278).
    test "a plain folder renders tiles linking to each file's own page" do
      get path

      panel = css_select("section.folder-panel").find { |s| s.css("h2").text == "models" }
      assert panel.css("div.public-tiles .thumb").any?, "tiles is the default view for a plain folder"
      assert panel.css("a.grid-card[href='#{public_file_view_path("ada", @project.slug, @f[:base].node_id)}']").any?
      assert_empty panel.css("table.public-files"), "tiles, not the list"
      assert_no_private_urls
    end

    # SPEC DECISION 7: the Miller-columns browser reads a session-authed endpoint, so a visitor gets
    # the LIST wherever the maker chose the browser — asserted twice over, because `firmware` is a
    # working tree and defaults to `browser` with nothing stored at all.
    test "a folder the maker views in the browser reads as a list for a visitor" do
      get path
      firmware = css_select("section.folder-panel").find { |s| s.css("h2").text == "firmware" }
      assert firmware.css("table.public-files").any?, "the repo folder's default view is `browser`"
      assert_select ".repo-browser", count: 0
      assert_select "[data-controller*=filebrowser]", count: 0

      @project.update!(panels: { "views" => { Maker::ProjectKind.folder_key(@f[:models].node_id) => "browser" } })

      get path
      models = css_select("section.folder-panel").find { |s| s.css("h2").text == "models" }
      assert models.css("table.public-files").any?, "a stored `browser` reads as the list too"
      assert_select ".repo-browser", count: 0
      assert_select "[data-controller*=filebrowser]", count: 0
    end

    test "a stored view of list renders that panel as a table and leaves the others as tiles" do
      @project.update!(panels: { "views" => { Maker::ProjectKind.folder_key(@f[:models].node_id) => "list" } })

      get path

      models = css_select("section.folder-panel").find { |s| s.css("h2").text == "models" }
      photos = css_select("section.folder-panel").find { |s| s.css("h2").text == "photos" }
      assert models.css("table.public-files").any?
      assert_empty models.css("div.public-tiles")
      assert photos.css("div.public-tiles").any?, "the view is per panel, not per page"
    end

    # SPEC DECISION 2: a hidden folder leaves the visitor's page (and the bundle — public_bundle_test).
    # The FILES go with it, nested ones included; the direct link still delivers, which is that
    # suite's half.
    test "a hidden folder panel and its whole subtree are absent from the visitor's page" do
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      get path

      assert_equal %w[firmware photos], css_select("section.folder-panel h2").map(&:text)
      [ @f[:base], @f[:deep_file] ].each do |node|
        assert_select "a[href=?]", public_file_view_path("ada", @project.slug, node.node_id), count: 0
      end
    end

    test "a stored order can lift a folder panel above the build log" do
      key = Maker::ProjectKind.folder_key(@f[:firmware].node_id)
      @project.update!(panels: { "order" => [ key, "build_log", "attachments" ] })

      get path

      classes = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"] }
      assert_operator classes.index { |c| c.include?("folder-panel") }, :<,
                      classes.index { |c| c.include?("build-log-panel") }
    end

    # AN EMPTY FOLDER IS OMITTED HERE, unlike the maker's own page, where it stays as a quiet panel
    # (S3-4's rule: an empty state invites someone to add the first file, which a visitor cannot
    # do). A folder holding only a rescue copy is empty by the same measure — the public page drops
    # backups wherever they sit.
    test "a folder with nothing a visitor may see renders no panel at all" do
      make_dir!(@user, "notes", @f[:folder])
      rescued = make_dir!(@user, "rescued", @f[:folder])
      make_file!(@user, "sign_backup.lbrn2", rescued, body: "backup")

      get path

      names = css_select("section.folder-panel h2").map(&:text)
      assert_equal %w[firmware models photos], names, "an empty folder is not a heading over nothing"
      assert_not_includes response.body, "sign_backup.lbrn2"
    end

    # --- 6. photos -----------------------------------------------------------------

    test "the photos panel shows the folder's image and the entry photo living outside it" do
      get path

      # THE VIEW PAGE since stage 4, S4-5 (the file names in the Files panel link there too).
      assert_select ".photos-panel a[href=?]", public_file_view_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".photos-panel a[href=?]", public_file_view_path("ada", @project.slug, @f[:entry_photo].node_id)
    end

    # A HIDDEN FOLDER'S IMAGES LEAVE THE VISITOR'S PHOTOS PANEL TOO (folder panels, decision 2): the
    # Photos panel cannot be hidden, so a hidden `photos/` folder would otherwise keep showing its
    # pictures one panel down. The entry photo lives outside the folder and stays.
    test "a hidden folder's images are not in the visitor's Photos panel" do
      photos_dir = @user.nodes.present.find_by!(name: "photos", kind: "dir")
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(photos_dir.node_id) ] })

      get path

      assert_select ".photos-panel a[href=?]", public_file_view_path("ada", @project.slug, @f[:pic].node_id),
                    { count: 0 }, "the hidden folder's image must leave the gallery"
      assert_select ".photos-panel a[href=?]", public_file_view_path("ada", @project.slug, @f[:entry_photo].node_id)
    end

    # THE THREE DERIVED READERS REVIEW FOUND UNFILTERED (folder panels, decision 2). A hidden folder
    # must not leak through a surface that is not its panel: its repository card (the owner's
    # library path, the README and a public link into the folder), the Schematics panel (whose
    # first row is the KiCanvas embed's file) and the hero (the page's largest picture).
    test "a hidden repository folder shows no repo card to a visitor" do
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:firmware].node_id) ] })

      get path

      assert_select ".repo-card", { count: 0 }, "the hidden repository's card must leave the page with its panel"
      assert_no_match(%r{Projects/#{@project.slug}/firmware}, response.body, "the owner's library path must not print")
    end

    test "a hidden folder's board leaves the visitor's Schematics panel and its embed" do
      make_file!(@user, "board.kicad_sch", @f[:models], body: "(kicad_sch (version 1))")
      Library::Scanner.call(@user, root: @root.to_s)
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      get path

      assert_select ".schematics-panel", text: /driver\.kicad_sch/
      assert_select ".schematics-panel", { text: /board\.kicad_sch/, count: 0 }
      assert_no_match(/board\.kicad_sch/, response.body, "the hidden board must not be the embed's file either")
    end

    test "a hidden folder's image is not the visitor's hero" do
      photos_dir = @user.nodes.present.find_by!(name: "photos", kind: "dir")
      @project.update_column(:cover_node_id, @f[:pic].node_id)
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(photos_dir.node_id) ] })

      get path

      assert_select ".project-hero", { count: 0 }, "a hidden folder's image must not be the page's largest picture"
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

    # THE CARD ASKS THE SAME QUESTION THE HERO ASKS. Found in S4-5's review: it did not — a cover
    # chosen from anywhere in the library (the chooser browses the whole library on purpose),
    # outside the folder and unattached, rendered its thumbnail on /u/:handle while the project
    # page's hero refused the very same node. One rule, `Maker::PublicProject.claimed?`, on both
    # surfaces, asked ONCE for the whole page (`permitted_cover_ids`) so the page's budget stays
    # constant in the number of projects (page_query_budget_test.rb).
    test "a maker's page shows no cover the project does not permit" do
      ready_cover!(@f[:outsider])
      @project.update_column(:cover_node_id, @f[:outsider].node_id)

      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card .card-cover img", 0,
                    "an unpermitted cover must not become a public picture on the list either"
      assert_select ".project-card .card-cover", 1
    end

    test "the public project page leads with its cover, linking to the file's own page" do
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get path

      assert_select ".project-hero img[src=?]",
                    public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".project-hero a[href=?]",
                    public_file_view_path("ada", @project.slug, @f[:pic].node_id)
    end

    # THE SAME SPLIT ON THE VISITOR'S PAGE (tinkerex#285): a `.heic` cover is an image by role and
    # shows through its READY thumbnail via the public preview route, never as raw bytes the
    # browser cannot render.
    test "a HEIC cover leads with its thumbnail, not its bytes" do
      original = make_file!(@user, "IMG_0001.heic", @f[:folder], body: "x")
      original.update!(content_hash: "h-heic", current_version_id: "v-heic")
      ready_preview!(@user, original)
      @project.update_column(:cover_node_id, original.node_id)

      get path

      assert_select ".project-hero img[src=?]",
                    public_file_preview_path("ada", @project.slug, original.node_id, "thumbnail")
      assert_select ".project-hero img[src=?]", public_file_path("ada", @project.slug, original.node_id),
                    { count: 0 }, "a .heic must not be embedded as raw bytes"
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

    # --- 10. the owner's own panel layout, honoured for a visitor (stage 4, S4-7) ---

    # STAGE 4, S4-7 (story 6.5): THE VISITOR SEES THE PAGE THE MAKER ARRANGED. One layout, read off
    # the project through Maker::PublicProject, so the two pages cannot disagree about what is
    # hidden — a maker who hid Wiring did not hide it only from themselves. The fixture already
    # seeds two connections, which is what makes the panel present in the first place.
    # THE PAGE, NOT EVERY PUBLIC DOOR (found in review): the Atom feed, the bundle manifest and the
    # BOM CSV never consult the layout, so a hidden Build log or BOM is still one click away from
    # this page through them. Recorded as open work rather than widened here.
    test "a hidden panel is hidden from the visitor's page too" do
      get path
      assert_select "section.wiring-panel", 1

      @project.update!(panels: { "hidden" => %w[wiring] })
      get path
      assert_select "section.wiring-panel", count: 0
    end

    test "a stored order reorders the visitor's page as well" do
      @project.update!(panels: { "order" => %w[build_log attachments] })

      get path

      panels = css_select("div.project-panels > div.panel-slot > section.panel").map { |s| s["class"] }
      assert_operator panels.index { |c| c.include?("build-log-panel") }, :<,
                      panels.index { |c| c.include?("files-panel") }
    end

    # A PRIVATE-ONLY PANEL HAS NO PUBLIC FACE, AND THE MAP IS THE WHOLE DEFINITION OF THAT. Tasks,
    # Sheets and Publish are absent from a visitor's page today and must stay absent whatever the
    # order says — a maker who moved Tasks to the top must not publish their task list.
    test "tasks, sheets and publish never reach a visitor, whatever the order says" do
      @project.tasks.create!(user: @user, title: "cut")
      @project.sheets.create!(user: @user, name: "Cut list")
      @project.update!(panels: { "order" => %w[tasks sheets publish] })

      get path

      assert_response :success
      assert_select "section.tasks-panel", count: 0
      assert_select "section.sheets-panel", count: 0
      assert_select "section.publish-panel", count: 0
      # AND NOTHING ELSE RENDERED IN THEIR PLACE. The three assertions above ask about the classes
      # those panels WOULD wear, which cannot see a key that leaks into the map pointing at some
      # OTHER partial — mutation-checked: adding `"tasks" => "public/projects/build_log"` left all
      # three green while the visitor's page grew a second build log. Counting the one panel a
      # stray key would most plausibly duplicate is what makes the absent-key rule load-bearing
      # rather than a coincidence of which partials happen to exist.
      assert_select "section.build-log-panel", 1,
                    "a key the map does not name must render NOTHING, not something else's partial"
    end

    # AN EMPTY PANEL IS STILL OMITTED for a visitor — the public page's own rule (its header says
    # why: an empty state invites someone to add the first one, which is what a visitor cannot do).
    # The layout decides whether a panel is RENDERED; each public partial still decides whether it
    # has anything to render. Two questions here as well.
    test "a visible panel with nothing in it is still omitted" do
      get path

      assert_select "section.releases-panel", count: 0
    end

    # --- the arrangement travels (2026-09-09, the page editor; spec §2) ---------------------------
    #
    # ITS OWN PROJECT, NOT THE SHARED FIXTURE. `seed_public_project!` seeds a photo in the folder AND
    # an entry photo at the library root, so its Photos panel is never empty — and "no photos, no
    # slot" is half of what this test exists to prove. A folder holding one file, one build-log
    # entry and no image anywhere is exactly the shape that leaves Photos with nothing to render,
    # built out of the same fixture helpers so it is still a real share library with real bytes.
    test "a visitor sees the maker's titles, intros and widths, inside slots, and no slot for an empty panel" do
      project = @user.maker_projects.create!(name: "Bench Rig", visibility: "public")
      folder = make_project_folder!(@user, project)
      models = make_dir!(@user, "models", folder)
      make_file!(@user, "base.stl", models, body: "solid base")
      project.build_log_entries.create!(user: @user, body: "Cut the base tonight.",
                                        logged_at: Time.zone.local(2026, 5, 1, 12, 0, 0))
      folder_key = Maker::ProjectKind.folder_key(models.node_id)
      # BOTH WIDTHS ARE THE OPPOSITE OF THEIR DEFAULT (ProjectKind.default_width: a folder is full,
      # build_log is half), so each assertion below fails if the width class is written from the
      # default rather than from the maker's own layout.
      project.update!(panels: { "titles" => { folder_key => "Prints", "build_log" => "Diary" },
                                "intros" => { folder_key => "Sliced." },
                                "widths" => { folder_key => "half", "build_log" => "full" } })

      get public_project_path("ada", project.slug)

      assert_response :success
      assert_select "div.project-panels > div.panel-slot.panel--half > section.folder-panel h2", text: "Prints"
      assert_select "section.folder-panel p.panel-intro", text: "Sliced."
      assert_select "div.panel-slot.panel--full > section.build-log-panel h2", text: "Diary"
      assert_select "div.panel-slot > section.photos-panel", { count: 0 }, "no photos, no slot"
      # NOT `div.panel-slot:empty` (the plan's spelling): CSS `:empty` matches an element with no
      # child NODES AT ALL, and a slot wrapping a partial that rendered nothing still holds the
      # whitespace between its own tags — so that assertion passes whatever the page does. Counting
      # slots against slots that hold a panel is the assertion with weight, which is the idiom
      # project_layout_editor_test.rb already uses for the maker's page.
      slots = css_select("div.project-panels > div.panel-slot")
      assert_equal slots.size, css_select("div.project-panels > div.panel-slot > section.panel").size,
                   "a panel that renders nothing must render no slot"
      assert_operator slots.size, :>, 0, "and the count is not vacuously zero"
    end
  end
end
