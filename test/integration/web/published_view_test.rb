require "test_helper"
require "support/public_fixture"

module Web
  # THE PUBLISHED VIEW (2026-11-19; the Shop manual's spec §3, §9 and §11.6): a maker chooses, on the
  # edit area's Publishing tab, which panels the public page leaves out, and their own page keeps
  # every one. The choice is `panels["unpublished"]`, read by Maker::ProjectKind.layout_for and
  # applied by Maker::PublicProject#layout (`Layout#published`), which feeds the public page, its
  # feed, its bundle and its BOM CSV — so each of those doors is driven here with a panel left out,
  # beside the same request with it in. `#permits?` is the fifth door: a folder left out stops
  # delivering its files, where a folder the maker merely HID keeps delivering (decision 2), and the
  # two are driven side by side so neither can quietly become the other.
  #
  # A FRESH SHARE LIBRARY PER TEST, for test/support/public_fixture.rb's reason: these doors read
  # real bytes.
  class PublishedViewTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
    end

    teardown { FileLayer.reset! }

    def key(node) = Maker::ProjectKind.folder_key(node.node_id)
    def page_path(**opts) = public_project_path("ada", @project.slug, **opts)
    def file_path_for(node) = public_file_path("ada", @project.slug, node.node_id)

    def keep_back!(*keys)
      @project.update!(panels: (@project.reload.panels || {}).merge("unpublished" => keys))
    end

    def unpublished = Array(@project.reload.panels&.dig("unpublished"))

    def boxes = css_select("input[type=checkbox][name='project[public_panels][]']")

    # What a browser posts from the tab: the blank entry, then every enabled box that is ticked.
    def ticked_on_tab
      get publishing_project_path(@project)
      [ "" ] + boxes.reject { |b| b["disabled"] }.select { |b| b["checked"] }.map { |b| b["value"] }
    end

    def save_publishing(shown)
      patch project_path(@project), params: { project: { visibility: @project.visibility, public_panels: shown },
                                              return_to: "publishing" }
    end

    # --- 1. the Publishing tab ----------------------------------------------------------------

    # EVERY PANEL A VISITOR'S PAGE CAN DRAW, IN THE PAGE'S ORDER, AND NOTHING ELSE. The fixture's
    # three subfolders land after Files in disk order (Maker::ProjectKind's splice rule); Tasks,
    # Sheets, Calculations and 3D models have no public face, so they get no box and one sentence.
    test "the Publishing tab offers one ticked box per panel a visitor can see, in the page's order" do
      sign_in_as(@user)
      get publishing_project_path(@project)

      assert_response :success
      assert_equal [ "readme", "attachments", key(@f[:firmware]), key(@f[:models]), key(@f[:photos]), "photos",
                     "schematics", "build_log", "bom", "wiring", "releases" ], boxes.map { |b| b["value"] }
      assert boxes.all? { |b| b["checked"] }, "a project that never chose publishes every panel it shows"
      assert_equal %w[attachments photos], boxes.select { |b| b["disabled"] }.map { |b| b["value"] },
                   "the folder root and the photos are what publishing a project is"
      assert_select ".publish-panels .publish-option", text: /Files\s+always shown/
      assert_select ".publish-panels .publish-option .mono", text: "models/"
      assert_select ".publish-panels > p", text: "Never on the public page: 3D models, Tasks, Sheets and Calculations."
      assert_select "form.publish-form input[type=hidden][name=?][value='']", "project[public_panels][]", 1
      # THE TAB'S ONE INK PRIMARY STAYS ITS ONE (design-system.md rule 13; accent_spend_test.rb's row).
      assert_select ".btn.primary", 1
      assert_select ".btn.primary[value=?]", "Save publishing"
    end

    test "unticking a folder and saving keeps it off the public page and changes nothing else" do
      sign_in_as(@user)
      shown = ticked_on_tab - [ key(@f[:models]) ]

      save_publishing(shown)

      assert_redirected_to publishing_project_path(@project)
      assert_equal "Saved Desk Lamp.", flash[:notice]
      assert_equal [ key(@f[:models]) ], unpublished
      assert_equal "public", @project.reload.visibility
      follow_redirect!
      refute boxes.find { |b| b["value"] == key(@f[:models]) }["checked"], "the tab reads back what was saved"
    end

    test "ticking a box again puts the panel back, and nothing kept back stores nothing" do
      keep_back!("bom")
      sign_in_as(@user)

      save_publishing(ticked_on_tab + [ "bom" ])

      assert_empty unpublished
      assert_nil @project.reload.panels, "a column that only ever held the choice goes back to nil"
    end

    # DETAILS POSTS TO THE SAME ACTION AND SAYS NOTHING ABOUT PANELS, so it must leave the choice as it
    # found it — an absence is not "every box unticked", which only the tab's blank entry can say.
    test "a form that carries no panel list leaves the choice alone" do
      keep_back!("bom")
      sign_in_as(@user)

      patch project_path(@project), params: { project: { name: "Desk Lamp II" } }
      patch project_path(@project), params: { project: { license: "MIT" }, return_to: "publishing" }

      assert_equal %w[bom], unpublished
    end

    # THE LIST IS INTERSECTED WITH WHAT THE TAB OFFERS, so a crafted request can keep back only a
    # panel the tab would have offered — never Files, never a key the layout does not know — and a
    # value that is not a list is no answer at all rather than a 500.
    test "a crafted list keeps back only what the tab offers, and a hash is no answer" do
      sign_in_as(@user)

      # FIRST, FROM NOTHING KEPT BACK: a hash read as "no box ticked" would keep back every panel.
      patch project_path(@project), params: { project: { public_panels: { "bom" => "1" } }, return_to: "publishing" }
      assert_response :redirect
      assert_empty unpublished, "a hash-shaped value changed the choice"

      save_publishing([ "", "../etc", "tasks" ])
      kept = unpublished
      assert_includes kept, key(@f[:models])
      assert_includes kept, "build_log"
      [ "attachments", "photos", "tasks", "sheets", "../etc" ].each { |k| refute_includes kept, k }
    end

    # B3 (2026-11-02), FOR THE BOXES TOO: a refused save re-renders the tab with what was ticked.
    test "a refused save comes back with the boxes as they were ticked, and writes nothing" do
      sign_in_as(@user)
      shown = ticked_on_tab - [ "bom" ]
      prior = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV["DEMO_ACCOUNT_EMAIL"] = @user.email

      save_publishing(shown)

      assert_response :unprocessable_entity
      refute boxes.find { |b| b["value"] == "bom" }["checked"], "the typed choice is kept"
      assert boxes.find { |b| b["value"] == "readme" }["checked"]
      assert_empty unpublished, "a refused save writes nothing"
    ensure
      prior ? ENV["DEMO_ACCOUNT_EMAIL"] = prior : ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    test "a panel the maker hid keeps its box, and says it is hidden on their page too" do
      @project.update!(panels: { "hidden" => %w[bom] })
      sign_in_as(@user)

      get publishing_project_path(@project)

      assert boxes.find { |b| b["value"] == "bom" }["checked"]
      assert_select ".publish-panels .publish-option", text: /Bill of materials\s+hidden on your page too/
      assert_select ".publish-panels .publish-option", text: /hidden on your page too/, count: 1
    end

    # --- 2. the doors: the page, the feed, the bundle, the CSV ------------------------------------

    test "the public page leaves out what is kept back while the maker's own page keeps it" do
      get page_path
      assert_select "section.folder-panel[id=?]", key(@f[:models])
      assert_select "section.bom-panel"
      assert_select "section.build-log-panel"

      keep_back!(key(@f[:models]), "bom", "build_log")

      get page_path
      assert_response :success
      assert_select "section.folder-panel[id=?]", key(@f[:models]), 0
      assert_select "section.bom-panel", 0
      assert_select "section.build-log-panel", 0
      assert_select "section.folder-panel[id=?]", key(@f[:photos]), 1, "only what was kept back leaves"

      sign_in_as(@user)
      get project_path(@project)
      assert_select "section.folder-panel[id=?]", key(@f[:models]), 1
      assert_select "section.bom-panel", 1
      assert_select "section.build-log-panel", 1
    end

    test "the owner's preview of the public page leaves it out too" do
      keep_back!(key(@f[:models]))
      sign_in_as(@user)

      get preview_project_path(@project)

      assert_response :success
      assert_select "section.folder-panel[id=?]", key(@f[:models]), 0
      assert_select "section.folder-panel[id=?]", key(@f[:photos]), 1
    end

    test "a build log kept back leaves the feed" do
      get public_feed_path("ada", @project.slug)
      assert_equal 1, Nokogiri::XML(response.body).xpath("//xmlns:entry").size

      keep_back!("build_log")

      get public_feed_path("ada", @project.slug)
      assert_response :success
      assert_equal 0, Nokogiri::XML(response.body).xpath("//xmlns:entry").size
    end

    test "a folder kept back leaves the bundle, and a BOM kept back leaves its CSV out of it" do
      get public_bundle_path("ada", @project.slug)
      paths = JSON.parse(response.body)["files"].map { |f| f["path"] }
      assert_includes paths, "models/base.stl"

      keep_back!(key(@f[:models]), "bom")

      get public_bundle_path("ada", @project.slug)
      manifest = JSON.parse(response.body)
      paths = manifest["files"].map { |f| f["path"] }
      refute_includes paths, "models/base.stl"
      refute_includes paths, "models/deep/x.stl"
      assert_includes paths, "README.md"
      assert_includes paths, "photos/pic.png"
      assert_nil manifest["bom_csv_url"]
    end

    test "a BOM kept back has no CSV, and a CSV row never names a file kept back" do
      keep_back!(key(@f[:models]))
      get public_bom_path("ada", @project.slug)
      assert_response :success
      row = CSV.parse(response.body).find { |r| r.first == "F1" }
      assert_nil row.last, "a file kept back has no path in the zip and no name in the CSV"
      refute_includes row, "base.stl"

      keep_back!("bom")
      get public_bom_path("ada", @project.slug)
      assert_response :not_found
    end

    # --- 3. the file route: kept back is unpermitted, hidden is not ------------------------------

    test "a file in a folder kept back is a 404 at every depth, attached or not, and returns when published" do
      # THE SWEEP'S SHAPE: Maker::ProjectIntake attaches every file under the folder, so the
      # attachment arm of `permits?` must not keep a kept-back folder downloadable.
      @project.file_attachments.create!(user: @user, node_id: @f[:base].node_id, role: "model", position: 0)
      keep_back!(key(@f[:models]))

      [ @f[:base], @f[:deep_file] ].each do |node|
        get file_path_for(node)
        assert_response :not_found, "#{node.name} must not deliver"
        get public_file_view_path("ada", @project.slug, node.node_id)
        assert_response :not_found, "#{node.name}'s page must not open"
      end
      get file_path_for(@f[:readme])
      assert_response :success, "the folder's root stays published"
      get file_path_for(@f[:pic])
      assert_response :success, "another folder stays published"

      keep_back!
      get file_path_for(@f[:base])
      assert_response :success
    end

    test "a folder the maker only hid still delivers its files" do
      @project.update!(panels: { "hidden" => [ key(@f[:models]) ] })

      get file_path_for(@f[:base])
      assert_response :success, "hidden arranges the page; it does not unpublish (decision 2)"
    end

    # THE ONE EXCEPTION: a build-log entry's own photo kept in such a folder, while the build log is
    # on the page — the entry is what the maker published it with. Photos still leaves it out.
    test "a build-log photo in a folder kept back shows with its entry until the build log is kept back too" do
      bench = make_file!(@user, "bench.png", @f[:models], body: PNG_BYTES)
      @f[:entry].file_attachments.create!(user: @user, node_id: bench.node_id, role: "image", position: 1)
      keep_back!(key(@f[:models]))

      get file_path_for(bench)
      assert_response :success
      get page_path
      assert_select ".build-log-panel a[href=?]", file_path_for(bench)
      assert_select ".photos-panel a[href=?]", public_file_view_path("ada", @project.slug, bench.node_id), 0

      keep_back!(key(@f[:models]), "build_log")
      get file_path_for(bench)
      assert_response :not_found
    end

    # --- 4. what links to a file kept back goes quiet --------------------------------------------

    test "a README link into a folder kept back reads as its words, and its picture goes" do
      base_url = file_path_for(@f[:base])
      get page_path
      assert_select ".readme-panel .markdown a[href=?]", base_url
      assert_select ".readme-panel .markdown img[src=?]", file_path_for(@f[:pic])

      keep_back!(key(@f[:models]), key(@f[:photos]))

      get page_path
      assert_select ".readme-panel .markdown a[href=?]", base_url, 0
      assert_select ".readme-panel .markdown", text: /See base for the printed part/
      assert_select ".readme-panel .markdown img[src=?]", file_path_for(@f[:pic]), 0
    end

    test "a text block's link into a folder kept back reads as its words" do
      @project.blocks.create!(user: @user, kind: "text", heading: "Parts", body: "Print [the base](models/base.stl) first.")
      get page_path
      assert_select ".block-panel .markdown a[href=?]", file_path_for(@f[:base])

      keep_back!(key(@f[:models]))

      get page_path
      assert_select ".block-panel .markdown a[href=?]", file_path_for(@f[:base]), 0
      assert_select ".block-panel .markdown", text: /Print the base first/
    end

    test "a cover in a folder kept back is neither the hero nor the card's picture" do
      @f[:pic].update!(content_hash: "h-#{@f[:pic].node_id}")
      ready_preview!(@user, @f[:pic])
      @project.update_column(:cover_node_id, @f[:pic].node_id)
      get page_path
      assert_select ".project-hero", 1
      get public_user_path("ada")
      assert_select ".project-card .card-cover img", 1

      keep_back!(key(@f[:photos]))

      get page_path
      assert_select ".project-hero", 0
      get public_user_path("ada")
      assert_select ".project-card .card-cover img", 0
      assert_select ".project-card .card-cover", 1
    end

    # --- 5. what keeps the choice: the editor's Save and Reset ------------------------------------

    test "the editor's Save carries the choice through untouched" do
      keep_back!(key(@f[:models]), "bom")
      sign_in_as(@user)

      patch project_panels_path(@project),
            params: { layout: { layout: 1, panels: [ { key: "tasks", hidden: true, width: "full" } ] }.to_json }

      assert_redirected_to project_path(@project)
      assert_equal %w[tasks], @project.reload.panels["hidden"]
      assert_equal [ key(@f[:models]), "bom" ], unpublished, "a layout Save that dropped it would publish them"
    end

    test "Reset keeps the choice, and goes back to nil when nothing is kept back" do
      keep_back!("bom")
      @project.update!(panels: @project.panels.merge("hidden" => %w[tasks], "widths" => { "bom" => "full" }))
      sign_in_as(@user)

      delete project_panels_path(@project)
      assert_equal({ "unpublished" => %w[bom] }, @project.reload.panels)

      keep_back!
      delete project_panels_path(@project)
      assert_nil @project.reload.panels
    end

    test "the layout editor says which panels are not on the public page" do
      keep_back!(key(@f[:models]))
      sign_in_as(@user)

      get edit_layout_project_path(@project)

      assert_select ".panel-slot[data-key=?] .panel-strip-unpublished", key(@f[:models]), text: "not on the public page"
      assert_select ".panel-strip-unpublished", 1
    end
  end
end
