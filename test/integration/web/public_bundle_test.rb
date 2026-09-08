require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 3, S3-6: /u/:handle/:slug/bundle.json and /u/:handle/:slug/bom.csv — the manifest a
  # visitor's browser zips from, and the parts list that goes into the zip beside the files.
  #
  # WHAT IS ON TRIAL IS THE MANIFEST, NOT THE ZIP. The archive is assembled in the browser
  # (bundle_controller.js, test/system/public_bundle_test.rb drives it for real); what Rails owns is
  # the LIST — which files, at which paths, behind which URLs — and whether every one of those URLs
  # actually delivers. A manifest naming a file the public route refuses would fail silently in the
  # visitor's tab, halfway through a download they had already waited for.
  #
  # THE SHARE PIN AND THE DELIVERY BRANCH ARE public_file_test.rb's, for its reasons: the fixture's
  # bytes exist only on share, and the arm is chosen by `FileLayer.current.capabilities`, never by
  # an adapter class (§14a).
  class PublicBundleTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
    end

    teardown { FileLayer.reset! }

    def bundle_path_for(**opts) = public_bundle_path("ada", @project.slug, **opts)
    def bom_path_for(**opts) = public_bom_path("ada", @project.slug, **opts)

    def manifest(**opts)
      get bundle_path_for(**opts)
      assert_response :success
      JSON.parse(response.body)
    end

    def csv_rows(**opts)
      get bom_path_for(**opts)
      assert_response :success
      CSV.parse(response.body)
    end

    # public_file_test.rb's own helper, narrowed to the one question this suite asks: did the URL
    # the manifest published actually hand over the file?
    def assert_url_delivers(url)
      get url
      if FileLayer.current.capabilities.presignable?
        assert_response :redirect
      else
        assert_response :success
        assert_match(/\Aattachment/, response.headers["Content-Disposition"].to_s)
      end
    end

    # --- 1. the manifest -----------------------------------------------------------

    # THE WHOLE FOLDER, AT FOLDER-RELATIVE PATHS — the paths inside the zip. The fixture's tree is
    # three levels deep and includes a working tree (`firmware`), which is entered like any other
    # subfolder, so this list also pins that a repo's own files are bundled and its `.git` is not.
    test "the manifest lists every file in the folder at its path inside the zip" do
      json = manifest

      assert_equal "Desk Lamp", json["name"]
      assert_equal "ada", json["handle"]
      assert_equal @project.slug, json["slug"]
      assert_equal "README.md", json["readme_path"]
      assert_equal false, json["truncated"]
      assert_equal public_bom_path("ada", @project.slug), json["bom_csv_url"]
      assert_equal %w[README.md driver.kicad_sch firmware/README.md models/base.stl
                      models/deep/x.stl photos/pic.png],
                   json["files"].map { |f| f["path"] }
      assert_equal 10, json["files"].find { |f| f["path"] == "models/base.stl" }["size"],
                   "\"solid base\" is 10 bytes; the button budgets the download from these"
    end

    test "every URL the manifest publishes delivers its file" do
      urls = manifest["files"].map { |f| f["url"] }
      assert_equal 6, urls.size, "a vacuous loop would pass over an empty list (§14e)"
      urls.each { |url| assert_url_delivers(url) }
    end

    # --- 2. what it leaves out --------------------------------------------------------

    # A BACKUP AND A DOT-FILE ARE OUT FOR DIFFERENT REASONS AND BOTH MUST STAY OUT. The rescue copy
    # is noise the page already drops (`Maker::PublicProject#sections`); the dot-file is a `.env`
    # sitting beside the models, which the file route refuses too (public_file_test.rb) — a bundle
    # that carried it would be a way around that refusal.
    test "a backup and a dot-file are not in the bundle" do
      make_file!(@user, "sign_backup.lbrn2", @f[:folder], body: "backup")

      paths = manifest["files"].map { |f| f["path"] }

      refute_includes paths, "sign_backup.lbrn2"
      refute_includes paths, ".env"
      assert_includes paths, "README.md", "the sweep still saw the folder"
    end

    # THE FILE OUTSIDE THE FOLDER IS NOT IN THE BUNDLE EITHER, and it is a different rule again:
    # `elsewhere.stl` is a sibling of the project folder that nothing attaches, so it is not the
    # project's at all — the same node public_file_test.rb asserts is a 404.
    test "a file outside the folder is not in the bundle" do
      paths = manifest["files"].map { |f| f["path"] }
      refute_includes paths, "elsewhere.stl"
      refute_includes paths, "shot.png"
    end

    # THE CAP IS REPORTED, NOT HIDDEN, ON BOTH SURFACES. Seeded past FILE_CAP for real rather than
    # stubbed: `truncated?` is set inside ProjectFolderListing's constructor from the row count it
    # actually fetched, and a stub would assert about a value nothing in the app computes. Plain
    # rows with no bytes behind them — this test reads the manifest and the label, never a file.
    test "a folder past FILE_CAP says so in the manifest and on the button" do
      cap = Maker::ProjectFolderListing::FILE_CAP
      cap.times do |i|
        @user.nodes.create!(node_id: "cap-#{i}", name: format("cap-%03d.stl", i), kind: "file",
                            parent_node_id: @f[:folder].node_id, size: 1, mtime: 1)
      end

      json = manifest
      assert_equal true, json["truncated"]
      assert_equal cap, json["files"].size, "the manifest carries the listing's own capped set"

      get public_project_path("ada", @project.slug)
      assert_select ".bundle button", text: /first #{cap} files/
    end

    # --- 3. visibility -----------------------------------------------------------------

    test "a private project answers 404 on the manifest, the CSV and the feed alike" do
      @project.update!(visibility: "private")

      [ bundle_path_for, bom_path_for, public_feed_path("ada", @project.slug) ].each do |path|
        get path
        assert_response :not_found, "#{path} answered #{response.status} for a private project"
      end
    end

    test "an unlisted manifest needs the token and every URL in it carries the token" do
      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token

      get bundle_path_for
      assert_response :not_found

      json = manifest(k: token)
      urls = json["files"].map { |f| f["url"] } << json["bom_csv_url"]
      assert_equal 7, urls.size
      urls.each { |url| assert_includes url, "k=#{token}", "#{url} drops the token" }
      # DRIVEN, not merely inspected: a token in the string that the route does not accept would
      # read identically above.
      assert_url_delivers(json["files"].first["url"])
    end

    # --- 4. the CSV ---------------------------------------------------------------------

    # THE PART RULE IS public/projects/_bom's, AND THE THREE KINDS ARE THE FIXTURE'S THREE LINES.
    # The `file` column names the path the same file has inside the zip, so a row points at
    # something sitting beside the CSV.
    test "the BOM CSV is the public table's three columns plus the file, and nothing else" do
      rows = csv_rows

      assert_equal %w[reference part quantity unit file], rows.first
      assert_equal 4, rows.size
      assert_equal [ "B1", "M3 bolt", "2.0", "each", nil ], rows[1]
      assert_equal [ "F1", "base.stl", "1.0", "each", "models/base.stl" ], rows[2]
      assert_equal [ "T1", "22 AWG wire", "3.0", "m", nil ], rows[3]
      assert_equal "text/csv", response.media_type
      assert_match(/\Aattachment/, response.headers["Content-Disposition"].to_s)
      assert_includes response.headers["Content-Disposition"].to_s, "#{@project.slug}-bom.csv"
    end

    # THE OWNER'S INVENTORY IS NOT PUBLISHED — the fixture's item carries 7 on hand and a supplier
    # precisely so both can be asserted absent, exactly as public_project_test.rb does for the page.
    test "the CSV carries no stock, no supplier and no notes" do
      get bom_path_for

      refute_includes response.body, "Acme Supply"
      refute_includes response.body, "7"
      %w[stock on_hand supplier note].each do |word|
        refute_includes response.body.downcase, word, "#{word} is the maker's business, not the project's"
      end
    end

    test "a project with no BOM answers a header-only CSV" do
      @project.boms.destroy_all

      rows = csv_rows

      assert_equal [ %w[reference part quantity unit file] ], rows,
                   "a spreadsheet that opens on named columns says \"no parts\"; zero bytes says \"broken\""
    end

    # A LINE POINTING OUTSIDE THE PROJECT NAMES ITS OWN TEXT OR NOTHING — NEVER THE FILE. This is
    # the partial's privacy rule in the CSV, and it is the one thing here that is not cosmetic: the
    # node is real and named `elsewhere.stl`, and the public route 404s it.
    test "a BOM line pointing at a non-permitted file never names it" do
      @project.current_bom.lines.create!(user: @user, node_id: @f[:outsider].node_id,
                                         quantity: 1, unit: "each", reference: "X1")

      rows = csv_rows

      refute_includes response.body, "elsewhere.stl"
      assert_equal [ "X1", nil, "1.0", "each", nil ], rows.find { |r| r.first == "X1" },
                   "the line's own free text or nothing — never the node's name"
    end

    # --- 5. the panel layout reaches these documents (hardening, 2026-09-08; tinkerex#283) ------
    #
    # A HIDDEN PANEL'S DOCUMENT IS ABSENT, NOT EMPTY-BUT-PRESENT. A header-only CSV says "no parts",
    # which is a different and untrue answer from "the maker did not publish this"; and a manifest
    # that still advertised the URL would send every visitor's browser at a 404 halfway through a
    # bundle they had already waited for.

    test "hiding the BOM panel takes the CSV out of the manifest and answers 404 at the CSV itself" do
      assert_equal public_bom_path("ada", @project.slug), manifest["bom_csv_url"],
                   "the visible-panel arm, so the assertions below are a CHANGE and not the status quo"
      get bom_path_for
      assert_response :success

      @project.update!(panels: { "hidden" => %w[bom] })

      assert_nil manifest["bom_csv_url"], "the key is there and null — the script tests for it"
      get bom_path_for
      assert_response :not_found

      # THE REST OF THE MANIFEST IS UNTOUCHED. Only the BOM panel was hidden, and a gate written
      # over the whole document rather than the one key would pass a "no bom_csv_url" assertion
      # while emptying the bundle.
      assert_equal 6, manifest["files"].size
      assert_equal "README.md", manifest["readme_path"]
    end

    # THE FEED'S GATE AND THE CSV'S ARE SEPARATE, and hiding one panel must not reach the other's
    # document. Driven because the two gates read the same layout and a `hidden.any?` spelling would
    # satisfy either test alone.
    test "hiding the build log leaves the CSV and the manifest alone" do
      @project.update!(panels: { "hidden" => %w[build_log] })

      assert_equal public_bom_path("ada", @project.slug), manifest["bom_csv_url"]
      get bom_path_for
      assert_response :success
    end

    # THE BUNDLE HAS NO PANEL GATE, AND THIS IS THE TRIPWIRE ON THE REASON WHY. `attachments` is in
    # Maker::ProjectKind::ALWAYS, so `layout_for` subtracts it from `hidden` and no override can
    # hide the folder panel — which is why Maker::PublicProject#bundle_files carries a comment
    # instead of a gate the plan asked for and nothing could ever drive false. The constant is
    # asserted DIRECTLY beside the behaviour: removing `attachments` from ALWAYS makes this test red
    # at the line that names the rule, rather than silently converting the manifest into a way
    # around a panel the maker just hid.
    test "the folder panel cannot be hidden, which is why the bundle carries no gate" do
      assert_includes Maker::ProjectKind::ALWAYS, "attachments",
                      "if this is gone, gate Maker::PublicProject#bundle_files and the manifest's " \
                      "`truncated` on panel_visible?(\"attachments\") — see that method's comment"

      @project.update!(panels: { "hidden" => %w[attachments] })

      refute_includes @project.reload.panel_layout.hidden, "attachments"
      json = manifest
      assert_equal 6, json["files"].size, "the folder is the truth (spec §7) and stays in the zip"
      assert_equal false, json["truncated"]

      get public_project_path("ada", @project.slug)
      assert_select ".bundle button", 1
    end

    # --- 6. a hidden FOLDER does leave the bundle (2026-09-08, folder panels; spec decision 2) ----
    #
    # THE ONE PANEL GATE THE BUNDLE HAS, AND IT DOES NOT CONTRADICT THE TEST ABOVE: `attachments` —
    # the folder ROOT — cannot be hidden, a SUBFOLDER can, and a maker who took a folder off their
    # public page did not mean to leave it in the zip that page's own button builds.

    test "hiding a folder takes its whole subtree out of the manifest, and nothing else" do
      assert_includes manifest["files"].map { |f| f["path"] }, "models/base.stl",
                      "the visible arm, so the assertions below are a CHANGE and not the status quo"

      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      json = manifest
      assert_equal %w[README.md driver.kicad_sch firmware/README.md photos/pic.png],
                   json["files"].map { |f| f["path"] },
                   "`models/deep/x.stl` goes too — hiding a folder hides what nests inside it"
      # THE REST OF THE MANIFEST IS UNTOUCHED: the cap is the LISTING's, which still walked the
      # whole folder, and the README sits at the root where no folder key can reach it.
      assert_equal false, json["truncated"]
      assert_equal "README.md", json["readme_path"]
      assert_equal public_bom_path("ada", @project.slug), json["bom_csv_url"]
    end

    # PERMISSION IS BY FOLDER CLAIM, NEVER BY PANEL (spec decision 2) — `#deliverable!` is untouched,
    # so a URL the README or a BOM row already handed out keeps working. What a hidden folder
    # changes is only what the page and the manifest ADVERTISE.
    test "a hidden folder's file still delivers on its own link" do
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      assert_url_delivers(public_file_path("ada", @project.slug, @f[:base].node_id, download: 1))
    end

    # A BOM ROW INTO A HIDDEN FOLDER NAMES NO ZIP PATH (decision 2, found in Task C's report): the
    # bundle leaves the file out, so a `file` cell naming `models/base.stl` would point at an entry
    # the visitor's zip does not carry. It names the BARE file instead — what the CSV already writes
    # for a permitted file the listing does not hold — because hidden is not unpermitted: the file
    # still delivers on its own link and its name is not a secret.
    test "a BOM line pointing into a hidden folder names the file, not a path the zip lacks" do
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      get public_bom_path("ada", @project.slug, format: :csv)
      assert_response :success
      row = CSV.parse(response.body, headers: true).find { |r| r["part"] == "base.stl" }
      assert row, "the design-file line is still in the CSV"
      assert_equal "base.stl", row["file"], "a hidden folder's file has no path in the zip, only its name"
    end

    # THE BUTTON, THE MANIFEST AND THE ZIP AGREE BY CONSTRUCTION — all three are
    # `Maker::PublicProject#bundle_files`, so this is the one assertion that says the count a
    # visitor reads is the list they will get.
    test "the button's count follows the manifest when a folder is hidden" do
      @project.update!(panels: { "hidden" => [ Maker::ProjectKind.folder_key(@f[:models].node_id) ] })

      # THE MANIFEST FIRST: `manifest` issues its own request, so reading it after the page would
      # assert against the JSON response rather than the page that carries the button.
      assert_equal 4, manifest["files"].size

      get public_project_path("ada", @project.slug)
      assert_select ".bundle button", text: /4 files/
    end
  end
end
