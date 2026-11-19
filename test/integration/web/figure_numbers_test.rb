require "test_helper"

module Web
  # FIGURE NUMBERS ON THE PAGE (the Shop manual spec §9 and §11.3), on catan's 60 files: every callout
  # the page draws, the BOM's citations, a build-log photo's, the Recently changed row's and the index
  # of files read ONE numbering, and that numbering is the page's own order. Which numbers the walk
  # gives is test/services/maker/figure_numbers_test.rb's; this reads them off the rendered page, so a
  # partial that draws its files in a different order from the walk (Maker::ProjectFigures) goes red
  # here — the walk and the partials are two descriptions of one page, and this is what holds them to
  # one.
  #
  # CATALOG ROWS, NEVER THE PORT (the project-folder-fixtures pitfall), version_stacks_pages_test.rb's
  # seed: the demo seed's own file list as `nodes` rows, on a fresh share library.
  class FigureNumbersTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SEED = Rails.root.join("db/seeds/demo/Projects/catan")

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "fig-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "catan", status: "active", autofile: false)
      @catan = project_folder_rows!(@user, @project)
      @dirs = { "" => @catan }
      @files = {}
      paths = Dir.glob("**/*", base: SEED).select { |p| SEED.join(p).file? }.sort
      assert_equal 60, paths.size, "the demo seed changed; these counts are catan's"
      paths.each_with_index do |path, i|
        dir = File.dirname(path)
        dir = "" if dir == "."
        @dirs[dir] ||= @user.nodes.create!(node_id: "d-#{dir}", name: dir, kind: "dir",
                                           parent_node_id: @catan.node_id, mtime: 1, size: 0)
        @files[path] = @user.nodes.create!(node_id: "f-#{i}", name: File.basename(path), kind: "file",
                                           parent_node_id: @dirs[dir].node_id, size: 10 + i,
                                           mtime: 1_700_000_000_000_000_000 + i)
      end
      # The cover, as the screens draw it: tile.svg, Fig. 1.
      @project.update!(cover_node_id: file("design/tile.svg").node_id)
      # The Parts list: three file lines — a file, a stack's older member, a 3D print — and a part.
      bom = @project.boms.create!(user: @user)
      [ "laser/hex tiles.lbrn2", "laser/game box v1.lbrn2", "models/robber.3mf" ].each_with_index do |path, i|
        bom.lines.create!(user: @user, node_id: file(path).node_id, quantity: 1, position: i)
      end
      bom.lines.create!(user: @user, part_name: "Wood glue", quantity: 1, position: 3)
      # A build-log entry with a photo: Photos draws it as a figure, the entry cites it.
      entry = @project.build_log_entries.create!(user: @user, body: "First edge test.", logged_at: 1.day.ago)
      @photo = @files.keys.find { |p| p.start_with?("images/") }
      entry.file_attachments.create!(user: @user, node_id: file(@photo).node_id, role: "image")
    end

    def file(path) = @files.fetch(path)

    # THE NODE AN ELEMENT DRAWS: its own `data-node-id` (a poll cell), else the first descendant's,
    # else the file page it links to.
    def node_of(element)
      element["data-node-id"] || element.at_css("[data-node-id]")&.[]("data-node-id") ||
        element.at_css("a[href^='/files/']")["href"].delete_prefix("/files/")
    end

    def figures = css_select("[data-fig]:not([data-fig-repeat])")
    def index = css_select(".files-index-entry").to_h { |li| [ li.at_css("a.files-index-name")["href"].delete_prefix("/files/"), li["data-entry-fig"]&.to_i ] }

    test "every figure is numbered where it first appears, in the page's order, with no gap" do
      get project_path(@project)
      assert_response :success

      first_seen = figures.map { |el| el["data-fig"].to_i }.uniq
      assert_operator first_seen.size, :>, 30, "catan must draw its figures for this to mean anything"
      assert_equal (1..first_seen.size).to_a, first_seen,
                   "numbers must first appear 1, 2, 3 down the page: a partial draws in an order the walk does not"
      # Each figure's callout reads its own number: the disc on a tile, a stack, a photo, the cover.
      figures.each do |el|
        disc = el.at_css(".fig-num")
        assert disc, "#{el.name}.#{el['class']} carries data-fig but no disc"
        assert_equal "Fig. #{el['data-fig']}", disc.text.strip
      end
      # The cover is Fig. 1, and keeps 1 where the design panel draws it again.
      cover = file("design/tile.svg").node_id
      assert_equal %w[1 1], figures.select { |el| node_of(el) == cover }.map { |el| el["data-fig"] }
      assert_select "figcaption .project-hero-fig", text: "Fig. 1"
      # A file is one figure: no node is drawn under two numbers.
      by_node = figures.group_by { |el| node_of(el) }.transform_values { |els| els.map { |el| el["data-fig"] }.uniq }
      assert(by_node.values.all? { |nums| nums.size == 1 }, "a file carries two numbers: #{by_node.select { |_, n| n.size > 1 }}")
    end

    test "the parts list, a build-log photo, Recently changed and the index cite the numbers the figures carry" do
      get project_path(@project)
      numbers = figures.to_h { |el| [ node_of(el), el["data-fig"].to_i ] }
      entries = index

      # THE INDEX: all 60 files, A to Z, each with the number its figure carries — a stack's members
      # the stack's — and every number on the page is in it.
      assert_equal 60, entries.size
      names = css_select(".files-index-entry a.files-index-name").map { |a| a.children.first.text.downcase }
      assert_equal names.sort, names, "the index reads A to Z"
      numbers.each { |node, n| assert_equal n, entries.fetch(node), "the index disagrees with the figure for #{node}" }
      assert_equal numbers.values.uniq.sort, entries.values.compact.uniq.sort, "a number on the page is missing from the index, or the reverse"
      %w[laser/game\ box.lbrn2 laser/game\ box\ v1.lbrn2].map { |p| entries.fetch(file(p).node_id) }.then do |a, b|
        assert a, "the game box stack has a number"
        assert_equal a, b, "a stack's members share its number in the index"
      end
      assert_not_equal entries.fetch(file("laser/game box.lbrn2").node_id), entries.fetch(file("laser/game box 2.lbrn2").node_id),
                       "game box 2 is a different part, so a different figure"

      # THE PARTS LIST: each file line cites its file's figure; the part with no file cites nothing.
      cites = css_select(".bom-lines td.col-fig[data-fig-cite]")
      assert_equal 3, cites.size
      [ "laser/hex tiles.lbrn2", "laser/game box v1.lbrn2", "models/robber.3mf" ].zip(cites).each do |path, td|
        assert_equal entries.fetch(file(path).node_id), td["data-fig-cite"].to_i, "the BOM's citation of #{path}"
        assert_equal "Fig. #{td['data-fig-cite']}", td.at_css(".fig-num").text.strip
        assert_equal "/files/#{file(path).node_id}", td.parent.at_css(".col-target a")["href"]
      end

      # A BUILD-LOG PHOTO: the ring, citing the number Photos drew it with; never where the find box lands.
      photo = css_select(".entry-photo[data-fig-repeat]").sole
      assert_equal numbers.fetch(file(@photo).node_id), photo["data-fig"].to_i
      assert photo.at_css(".fig-num--ring")

      # RECENTLY CHANGED: a second look, numbering nothing; each tile shows its file's number.
      recent = css_select(".recent-files .attachment-tile")
      assert_operator recent.size, :>, 0
      recent.each do |tile|
        assert tile["data-fig-repeat"], "a Recently changed tile is a repeat"
        assert_equal entries.fetch(node_of(tile)), tile["data-fig"].to_i
      end
    end

    test "the index is the last section, in the contents column, with its find box" do
      get project_path(@project)
      slot = css_select(".files-index-grid > .panel-slot[data-section]").sole
      sections = css_select(".panel-slot[data-section]").map { |s| s["data-section"].to_i }
      assert_equal sections.max, slot["data-section"].to_i, "the index of files is the page's last section"
      row = css_select("#column .project-contents a.column-row--section").last
      assert_equal "#project-index", row["href"]
      assert_equal slot["data-section"], row.at_css(".column-row-num").text.strip
      assert_equal "Index of files", row.at_css(".column-row-name").text.strip
      assert_equal "60", row.at_css(".column-row-note").text.strip
      assert_select "#column .figure-find[data-figure-find-files-index-outlet='#project-index'] input[type=search][placeholder='Find a file or figure']"
      # A name two files share says which folder each is in, as the screen's
      # "harbor-number-v4.svg (project folder)" does; a name nobody shares does not.
      twins = css_select(".files-index-entry .files-index-folder").map { |s| s.parent.text.squish }
      assert_includes twins, "harbor-number-v4.svg (project folder)"
      assert_includes twins, "harbor-number-v4.svg (design)"
      assert_select ".files-index-entry a.files-index-name", text: "tile.svg"
    end

    # THE VISITOR'S PAGE NUMBERS ITS OWN FIGURES (Maker::PublicProject#figure_numbers): the published
    # panels only, in their order, so a folder the maker hid takes its files' numbers with it and
    # leaves no gap, and the BOM cites only a figure this page draws.
    test "the visitor's page numbers its own published figures, with no gap where a hidden folder was" do
      @user.update!(handle: "fig#{SecureRandom.hex(3)}")
      laser = Maker::ProjectKind.folder_key(@dirs.fetch("laser").node_id)
      @project.update!(visibility: "public", panels: { "hidden" => [ laser ] })
      get public_project_path(@user.handle, @project.slug)
      assert_response :success

      first_seen = figures.map { |el| el["data-fig"].to_i }.uniq
      assert_operator first_seen.size, :>, 20
      assert_equal (1..first_seen.size).to_a, first_seen, "the visitor's page numbers down the page with no gap"
      assert_select ".public-top .project-hero[data-fig='1'] .fig-num--hero", text: "Fig. 1"
      assert_select "[data-fig] a[href*=?], a[data-fig][href*=?]", file("laser/hex tiles.lbrn2").node_id,
                    file("laser/hex tiles.lbrn2").node_id, count: 0
      robber = css_select("a.grid-card[data-fig][title='robber.3mf']").sole
      cites = css_select(".public-bom td.col-fig[data-fig-cite]").map { |td| td["data-fig-cite"] }
      assert_equal [ robber["data-fig"] ], cites, "the hidden laser files are cited by nothing; robber.3mf by its figure"
    end

    # A TAB PUTS PANELS BELOW THE BAR, and the page reads top group first: projects/_panel_groups
    # renders the top grid before the panes, so the sections and the figures are numbered down the
    # page in one order. It captured the panes first until 2026-11-19, and tabbed panels took the
    # lower section numbers while sitting below the panels that carried the higher ones.
    test "with a tab, sections and figures are numbered down the page, the top group first" do
      folder = ->(name) { Maker::ProjectKind.folder_key(@dirs.fetch(name).node_id) }
      tab = "tab:#{'a' * 12}"
      @project.update!(panels: { "order" => [ "attachments", folder.call("design"), tab, folder.call("laser"), folder.call("cnc") ],
                                 "titles" => { tab => "Cutting" } })
      get project_path(@project)
      assert_response :success
      assert_select ".tab-pane", 1

      sections = css_select(".panel-slot[data-section]").map { |s| s["data-section"].to_i }
      assert_equal (1..sections.size).to_a, sections, "section numbers must run down the page"
      first_seen = figures.map { |el| el["data-fig"].to_i }.uniq
      assert_equal (1..first_seen.size).to_a, first_seen, "figure numbers must run down the page"
      laser = css_select("section[id='#{folder.call('laser')}'] [data-fig]").map { |el| el["data-fig"].to_i }
      design = css_select("section[id='#{folder.call('design')}'] [data-fig]:not([data-fig='1'])").map { |el| el["data-fig"].to_i }
      assert_operator laser.min, :>, design.max, "a tabbed panel's figures come after the top group's"
    end

    test "the editor numbers nothing, as it numbers no section" do
      get edit_layout_project_path(@project)
      assert_response :success
      assert_select "[data-fig]", 0
      assert_select ".fig-num", 0
      assert_select "#project-index", 0
      assert_select ".figure-find", 0
    end
  end
end
