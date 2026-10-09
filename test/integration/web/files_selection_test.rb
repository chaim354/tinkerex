require "test_helper"

module Web
  # SELECTION ON THE FILES PAGE (structural redesign spec §5.1, slice 3): a click on a file tile
  # selects it and opens the inspector; `?selected=` is read by the server, so a reload, Back or a
  # shared link restores it. selection_controller.js does the clicking — test/system/
  # files_selection_test.rb drives it — and this pins the markup that controller reads, and the
  # server's half: which ids it honours.
  #
  # PINNED TO A FRESH SHARE LIBRARY for the reason addon_origin_surfaces_test.rb gives: this is the
  # web layer, and on the ambient s3 or chunk_remote leg a bare row would reach real Aws calls or a
  # live sync server.
  class FilesSelectionTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "sel-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @dir = @user.nodes.create!(node_id: "dir-legs", name: "legs", kind: "dir", mtime: 1, size: 0)
      in_legs = { kind: "file", mtime: 1, size: 5, parent_node_id: @dir.node_id }
      # Both file shapes in both views: a renderable one (the `.file-cell` branch) and one nothing
      # renders (the plain-link branch).
      @file = @user.nodes.create!(node_id: "n-leg", name: "leg.lbrn2", **in_legs)
      @stl = @user.nodes.create!(node_id: "n-bracket", name: "bracket.stl", **in_legs)
      @rtf = @user.nodes.create!(node_id: "n-notes", name: "notes.rtf", **in_legs)
      # A folder INSIDE the listing. The folder case of "ignored" needs one: `legs` itself is not a
      # child of `legs`, so selecting it is the off-listing case and cannot tell whether the server
      # asks `file?` at all.
      @sub = @user.nodes.create!(node_id: "dir-feet", name: "feet", kind: "dir", mtime: 1, size: 0,
                                 parent_node_id: @dir.node_id)
      # At the root, so off the `legs` listing: a camera photo and a screenshot.
      @jpg = @user.nodes.create!(node_id: "n-side", name: "side.jpg", kind: "file", mtime: 1, size: 5)
      @root_png = @user.nodes.create!(node_id: "n-shot", name: "shot.png", kind: "file", mtime: 1, size: 5)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "every file tile is a selectable item that still links to its page; folders are not" do
      %w[grid list].each do |view|
        get files_path(folder: @dir.node_id, view:)
        items = css_select("[data-selection-target='item']")
        assert_equal [ @file, @stl, @rtf ].map(&:node_id).sort, items.map { |el| el["data-selection-id"] }.sort,
                     "#{view}: every file, and only files, is an item"
        items.each do |el|
          assert_equal file_path(el["data-selection-id"]), el["href"], "#{view}: an item stopped linking to its page"
          assert_includes el["data-action"], "click->selection#click"
          assert_includes el["data-action"], "dblclick->selection#open"
        end
        # The file menu's action shares the attribute, so selection must APPEND to it.
        assert_equal items.size, css_select("[data-selection-target='item'][data-action*='contextmenu->filemenu#open']").size,
                     "#{view}: an item lost the file menu"
        # The folder renders, and is not an item: a folder click navigates into it.
        assert_select "a.dir, a.grid-folder", minimum: 1
        assert_select "a.dir[data-selection-target], a.grid-folder[data-selection-target]", count: 0
      end
    end

    test "with nothing selected the inspector is present and empty, so the controller has a frame" do
      get files_path(folder: @dir.node_id)
      assert_select ".library[data-controller~='selection']"
      assert_select ".library.has-inspector", count: 0
      assert_select "aside.inspector turbo-frame#inspector[target='_top'][data-selection-target='frame']"
      assert_select "turbo-frame#inspector[src]", count: 0
      assert_select ".is-selected", count: 0
    end

    test "a selected file in the listing opens the inspector frame and marks its tile" do
      get files_path(folder: @dir.node_id, selected: @stl.node_id, view: "grid")
      assert_select ".library.has-inspector"
      assert_select "aside.inspector turbo-frame#inspector[src=?][target='_top']", inspector_file_path(@stl.node_id)
      assert_select ".grid-card.is-selected", count: 1
      assert_select ".grid-card.is-selected[data-selection-id=?]", @stl.node_id

      # The plain-link branch of the list marks its tile too.
      get files_path(folder: @dir.node_id, selected: @rtf.node_id, view: "list")
      assert_select "table.files a.is-selected", count: 1
      assert_select "table.files a.is-selected[data-selection-id=?]", @rtf.node_id
    end

    test "a stale, foreign, folder or off-listing selection is ignored, not an error" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com")
      theirs = other.nodes.create!(node_id: "n-theirs", name: "x.stl", kind: "file", mtime: 1, size: 1,
                                   parent_node_id: @dir.node_id)
      [ "no-such-node", theirs.node_id, @sub.node_id, @root_png.node_id ].each do |id|
        get files_path(folder: @dir.node_id, selected: id)
        assert_response :success
        assert_select ".library.has-inspector", { count: 0 }, "#{id} was honoured"
        assert_select "turbo-frame#inspector[src]", { count: 0 }, "#{id} loaded an inspector"
        assert_select ".is-selected", { count: 0 }, "#{id} marked a tile"
      end
    end

    # WITH JAVASCRIPT OFF the frame never loads, so a ?selected= page (the file page's folder crumb
    # always carries one) shows an empty panel — on a phone a full-screen sheet over the listing and
    # the top bar. Its close must work without the controller: a link to the listing minus the param.
    test "the inspector's close is a link back to the listing without the selection" do
      get files_path(folder: @dir.node_id, selected: @stl.node_id, view: "grid")
      close = css_select("aside.inspector .inspector-close").first
      assert_equal "a", close.name, "a <button type=button> does nothing without JavaScript"
      assert_includes close["href"], "folder=#{@dir.node_id}"
      refute_includes close["href"], "selected="
      assert_includes close["data-action"], "selection#close"
    end

    # OFF-PAGE, its own case: a file in the SAME folder on another page. The off-listing case above
    # cannot see it — a check against the whole folder (`scope`) instead of the rendered rows keeps
    # every assertion there green.
    test "a file on another page of a paged folder is ignored there and selected on its own page" do
      shelf = @user.nodes.create!(node_id: "dir-shelf", name: "shelf", kind: "dir", mtime: 1, size: 0)
      (FilesController::FOLDER_PAGE + 1).times do |i|
        @user.nodes.create!(node_id: format("n-p%04d", i), name: format("p%04d.stl", i), kind: "file",
                            mtime: 1, size: 1, parent_node_id: shelf.node_id)
      end
      last = format("n-p%04d", FilesController::FOLDER_PAGE)

      get files_path(folder: shelf.node_id, selected: last)
      assert_select "nav.pager"
      assert_select ".library.has-inspector", count: 0
      get files_path(folder: shelf.node_id, selected: last, page: 2)
      assert_select ".library.has-inspector"
    end

    test "the selection rides along on the listing's own links" do
      get files_path(folder: @dir.node_id, selected: @stl.node_id, view: "list")
      assert_select "th a[href*='selected=#{@stl.node_id}']", minimum: 1
      assert_select ".view-toggle a[href*='selected=#{@stl.node_id}']", count: 2
      # An ignored selection rides along nowhere.
      get files_path(folder: @dir.node_id, selected: @sub.node_id, view: "list")
      assert_select "a[href*='selected=']", count: 0
    end

    test "a photo tile crops and a screenshot keeps contain" do
      get files_path(view: "grid")
      assert_select ".grid-card[data-selection-id=?] .thumb.photo", @jpg.node_id
      assert_select ".grid-card[data-selection-id=?] .thumb", @root_png.node_id
      assert_select ".grid-card[data-selection-id=?] .thumb.photo", @root_png.node_id, count: 0
    end
  end
end
