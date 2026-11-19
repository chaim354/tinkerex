require "test_helper"

module Web
  # VERSION STACKS ON THE PAGES (Shop manual spec §9 and §10's stack-grouping guard, drawn): the
  # Library's rows and tiles, a project's panels and Search draw catan's stacks by NAME, keep
  # `game box 2` apart from `game box`, open a stack in place, and let one file be pulled out and
  # put back. Which files group is Maker::VersionStacks' and test/services/maker/version_stacks_test.rb
  # pins it on the same names; this pins that the pages draw what the service found.
  #
  # CATALOG ROWS, NEVER THE PORT (the project-folder-fixtures pitfall): the folders and files are
  # `nodes` rows built from the demo seed's own file list, so the three backend legs run the same
  # tests. Pinned to a fresh share library, files_row_actions_test.rb's reason: the Library
  # backfills thumbnails for renderable rows, and on the ambient s3 or chunk_remote leg a bare row
  # would reach a stub bucket or a live sync server.
  class VersionStacksPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SEED = Rails.root.join("db/seeds/demo/Projects/catan")

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "vs-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "catan", status: "active", autofile: false)
      @catan = project_folder_rows!(@user, @project)
      @dirs = { "" => @catan }
      @files = {}
      paths = Dir.glob("**/*", base: SEED).select { |p| SEED.join(p).file? }.sort
      assert_operator paths.size, :>=, 50, "the demo seed is missing, so these tests would draw nothing"
      paths.each_with_index do |path, i|
        dir = File.dirname(path)
        dir = "" if dir == "."
        @dirs[dir] ||= @user.nodes.create!(node_id: "d-#{dir}", name: dir, kind: "dir",
                                           parent_node_id: @catan.node_id, mtime: 1, size: 0)
        @files[path] = @user.nodes.create!(node_id: "f-#{i}", name: File.basename(path), kind: "file",
                                           parent_node_id: @dirs[dir].node_id, size: 10 + i,
                                           mtime: 1_700_000_000_000_000_000 + i)
      end
    end

    def laser = @dirs.fetch("laser")
    def file(path) = @files.fetch(path)

    # The names of the stacks a page draws, in order.
    def stack_names(scope) = css_select("#{scope} .stack-name").map { |el| el.text.strip }

    # --- the Library ----------------------------------------------------------------------------

    test "the Library's rows draw laser's stacks by name and keep game box 2 apart" do
      get files_path(folder: laser.node_id, view: "list")
      assert_response :success
      assert_equal [ "edge test", "game box", "hex tiles", "stacking card" ], stack_names("tr.stack-row")
      assert_select "tr.stack-row", text: /game box\s+2 versions/
      assert_select "tr.stack-row", text: /hex tiles\s+1 backup/
      assert_select "tr.stack-row", text: /edge test\s+3 versions/
      # game box 2 is a different part: its own row, a link to its file, never a member.
      two = file("laser/game box 2.lbrn2")
      assert_select "tbody > tr:not(.stack-member) td.col-name a[href=?]", file_path(two.node_id), 1
      assert_select "tr.stack-member a[href=?]", file_path(two.node_id), 0
      # Every member is a row of its own beneath its stack, hidden until the stack opens.
      %w[game\ box.lbrn2 game\ box\ v1.lbrn2].each do |name|
        assert_select "tr.stack-member[hidden] a[href=?]", file_path(file("laser/#{name}").node_id), 1
      end
      # 22 files make 17 entries: four stacks hold nine files, so five fold away.
      assert_select ".toolbar-count", text: "22 items in 17 entries"
    end

    test "a stack row opens its own members and names them latest and older" do
      get files_path(folder: laser.node_id, view: "list")
      toggle = css_select("tr.stack-row .stack-toggle").find { |b| b.text.include?("hex tiles") }
      assert toggle, "no hex tiles stack row"
      assert_equal "false", toggle["aria-expanded"]
      assert_equal "stack#toggle", toggle["data-action"]
      ids = toggle["aria-controls"].split
      assert_equal 2, ids.size, "the toggle names both members"
      rows = ids.map { |id| css_select("tr##{id}").sole }
      assert_equal [ "latest", "older" ], rows.map { |r| r.at_css(".stack-role").text }
      assert_includes rows.first.text, "hex tiles.lbrn2"
      assert_includes rows.last.text, "hex tiles_backup.lbrn2"
      assert(rows.all? { |r| r["hidden"] }, "members are hidden until the stack opens")
      # A member keeps a file row's doors, and has its own way out of the stack.
      backup = file("laser/hex tiles_backup.lbrn2")
      assert_select "tr##{ids.last} [data-selection-id=?]", backup.node_id
      assert_select "tr##{ids.last} form[action=?] button[aria-label=?]",
                    file_stack_exclusion_path(backup.node_id), "Pull hex tiles_backup.lbrn2 out of its stack"
    end

    test "the Library's tiles draw a stack as one figure that opens in place" do
      get files_path(folder: @dirs.fetch("design").node_id, view: "grid")
      assert_response :success
      # Each named in its latest member's own spelling, standing where its first member stood.
      assert_equal [ "box", "gamebox-plan", "gamebox", "harbor-number" ],
                   css_select(".files-grid > .stack-item .stack-name").map { |el| el.text.strip }
      figure = css_select(".files-grid > .stack-item button.stack").find { |b| b.text.include?("harbor-number") }
      assert_includes figure.text, "4 versions"
      assert_includes figure.text, "harbor-number-v5.svg", "the figure names its latest member"
      panel = css_select("##{figure['aria-controls']}").sole
      assert panel["hidden"], "the opened panel waits for the figure"
      assert_equal 4, panel.css(".stack-member").size
      # The harbor numbers outside design/ are another folder's file and never join this stack.
      assert_select "a[href=?]", file_path(file("harbor-number-v4.svg").node_id), 0
    end

    test "the switch turns stacks off, and the choice holds across folders" do
      get files_path(folder: laser.node_id, view: "list", stacks: "0")
      assert_select "tr.stack-row", 0
      assert_select "tbody tr", 22
      assert_select ".stack-switch input[type=checkbox][name=stacks]:not([checked])"
      assert_select ".toolbar-count", text: "22 items"

      get files_path(folder: @dirs.fetch("design").node_id)
      assert_select "tr.stack-row", 0, "the cookie carries the choice into another folder"

      get files_path(folder: laser.node_id, stacks: "1")
      assert_select "tr.stack-row", 4
      assert_select ".stack-switch input[type=checkbox][name=stacks][checked]"
    end

    test "a flat search stacks each folder's own files" do
      get files_path(q: "edge test", view: "list")
      assert_response :success
      # The cnc pair and the laser three are two stacks: a stack never crosses a folder.
      assert_equal [ "edge test", "edge test" ], stack_names("tr.stack-row")
      assert_select ".toolbar-count", text: "5 matches in 2 entries"
    end

    # A PAGED FOLDER PAGES FIGURES (FilesController#index): every member but the one the name order
    # puts first leaves the paged query, so page one holds a full page of FIGURES, the count and the
    # pager say figures, and no stack is cut in two by a page edge.
    test "a paged folder pages figures, and a stack is never split across a page edge" do
      per = FilesController::FOLDER_PAGE
      big = @user.nodes.create!(node_id: "d-big", name: "big", kind: "dir", mtime: 1, size: 0)
      (per - 5).times { |i| @user.nodes.create!(node_id: "b-#{i}", name: format("a%04d.stl", i), kind: "file", parent_node_id: big.node_id, mtime: 1, size: 1) }
      # Ten stacks of three whose names sort across page one's end: m00 v1, m00 v2, m00 v3, m01 ...
      10.times do |i|
        3.times { |v| @user.nodes.create!(node_id: "m-#{i}-#{v}", name: format("m%02d v%d.stl", i, v + 1), kind: "file", parent_node_id: big.node_id, mtime: v, size: 1) }
      end
      get files_path(folder: big.node_id, view: "list", sort: "name", dir: "asc")
      figures = css_select("table.files tbody > tr:not(.stack-member)")
      assert_equal per, figures.size, "page one draws a full page of figures"
      assert_equal 5, css_select("tr.stack-row").size, "the first five stacks fill page one"
      assert_select ".toolbar-count", text: "#{per + 25} items in #{per + 5} entries"
      assert_select ".pager-status", text: /Page 1 of 2\s+\(#{per + 5} entries\)/
      # Every stack on the page holds its three members, whichever of them the query kept.
      assert_equal 15, css_select("tr.stack-member").size

      get files_path(folder: big.node_id, view: "list", page: 2)
      assert_equal 5, css_select("tr.stack-row").size, "page two holds the other five stacks, whole"
      assert_equal 15, css_select("tr.stack-member").size
    end

    # --- pull out and put back --------------------------------------------------------------------

    test "a file pulled out of its stack stands alone with a quiet Put back, and goes back" do
      backup = file("laser/hex tiles_backup.lbrn2")
      listing = files_path(folder: laser.node_id, view: "list")
      post file_stack_exclusion_path(backup.node_id), headers: { "HTTP_REFERER" => "http://www.example.com#{listing}" }
      assert_redirected_to listing
      assert_equal "Pulled hex tiles_backup.lbrn2 out of its stack.", flash[:notice]

      get listing
      assert_equal [ "edge test", "game box", "stacking card" ], stack_names("tr.stack-row")
      assert_select "tbody > tr:not(.stack-member)", text: /hex tiles_backup\.lbrn2/ do
        assert_select "form[action=?] button[aria-label=?]", file_stack_exclusion_path(backup.node_id),
                      "Put hex tiles_backup.lbrn2 back in its stack", text: "Put back"
      end

      delete file_stack_exclusion_path(backup.node_id), headers: { "HTTP_REFERER" => "http://www.example.com#{listing}" }
      assert_equal "Put hex tiles_backup.lbrn2 back in its stack.", flash[:notice]
      get listing
      assert_includes stack_names("tr.stack-row"), "hex tiles"
      assert_select "button", text: "Put back", count: 0
    end

    test "only a live file of this user can be pulled out" do
      other = User.create!(email: "vs-other-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "theirs", name: "x v1.svg", kind: "file")
      [ theirs.node_id, laser.node_id, "no-such-node" ].each do |id|
        post file_stack_exclusion_path(id)
        assert_equal "That file isn't in your library.", flash[:alert]
      end
      assert_equal 0, Maker::StackExclusion.count
    end

    # --- a project panel ------------------------------------------------------------------------

    test "a project's folder panel draws its stacks, and its own switch turns them off" do
      key = Maker::ProjectKind.folder_key(laser.node_id)
      get project_path(@project)
      assert_response :success
      panel = css_select("section[id='#{key}']").sole
      assert_equal [ "edge test", "game box", "hex tiles", "stacking card" ],
                   panel.css(".attachments-grid > .stack-item .stack-name").map { |el| el.text.strip }
      assert_select "section[id=?]", key do
        assert_select ".stack-item", text: /1 backup\s+hex tiles/
        assert_select "a[href=?]", file_path(file("laser/game box 2.lbrn2").node_id)
        assert_select ".stack-panel-switch input[type=checkbox][checked]"
      end
      # The backup the stack holds is not ALSO in the Files panel's Backups group.
      assert_select "#attachments .attachment-group", text: /Backups/, count: 0

      patch project_panels_path(@project), params: { stack: { key => "0" } }
      assert_redirected_to project_path(@project, anchor: key)
      get project_path(@project)
      assert_select "section[id=?]", key do
        assert_select ".stack-item", 0
        assert_select ".stack-panel-switch input[type=checkbox]:not([checked])"
      end
      # With the laser panel unstacked, its backup is back in Backups; design still stacks.
      assert_select "#attachments .attachment-group summary", text: /Backups/
      assert_select "section[id=?] .stack-item", Maker::ProjectKind.folder_key(@dirs.fetch("design").node_id), 4
    end

    test "a panel's switch is answered in place, and the editor's Save keeps it" do
      key = Maker::ProjectKind.folder_key(laser.node_id)
      patch project_panels_path(@project), params: { stack: { key => "0" }, in_place: "1" }
      assert_redirected_to project_path(@project, panel: key, files: "1", pressed: "stack", anchor: key)
      # Turbo follows with the stream type: the panel and the Files panel (its Backups changed).
      get project_path(@project, panel: key, files: "1", pressed: "stack"), headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
      assert_equal [ key, "attachments" ], css_select("turbo-stream[action=replace]").map { |t| t["target"] }
      assert_select "turbo-stream[target=?] .stack-panel-switch input[autofocus]", key

      draft = { layout: 1, panels: [ { key: "tasks", hidden: true, width: "full" } ] }
      patch project_panels_path(@project), params: { layout: draft.to_json }
      assert_equal "Saved the page layout.", flash[:notice]
      assert_equal [ key ], @project.reload.panels["unstacked"], "a layout Save turned the panel's stacks back on"
    end

    test "a panel's stack switch is refused for a key the page cannot stack" do
      patch project_panels_path(@project), params: { stack: { "tasks" => "0" } }
      assert_redirected_to project_path(@project)
      assert_nil @project.reload.panels
    end

    # --- Search ---------------------------------------------------------------------------------

    test "Search draws one row per stack inside the Files group" do
      get search_path(q: "harbor")
      assert_response :success
      assert_select ".result-group--file" do
        assert_select ".result-row.stack-result", 1
        assert_select ".result-row.stack-result", text: /harbor-number\s+4 versions/
        assert_select ".result-row.stack-result a[href=?]", file_path(file("design/harbor-number-v5.svg").node_id)
        assert_select "h2 .muted", text: "5 · 8 files"
      end
    end
  end
end
