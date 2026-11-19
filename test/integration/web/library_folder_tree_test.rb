require "test_helper"

module Web
  # THE LIBRARY COLUMN'S FOLDER TREE (Shop manual spec §9; Maker::FolderTree, ShellHelper#folder_tree_item,
  # LibraryBrowseController#tree). What the server draws on the first byte: the library root's folders,
  # the chain to the folder on screen open with each level's siblings, every folder the `library_tree`
  # cookie names open too, a disclosure only where a folder has subfolders, and exactly one lit row.
  # And what it refuses: a cookie id that is malformed, past the newest fifty, someone else's or a
  # tombstone opens nothing, and the frame a closed folder opens into lists only this user's live,
  # visible folders. Catalog rows only, so every backend leg runs the same tests (the tree reads
  # `nodes`, which all three populate).
  #
  # MUTATION-CHECKED (2026-11-19; each reverted and the file re-run green), with the red each gave:
  #   1. Maker::FolderTree#load_children keeping every row (`kids` for `kids.first(CAP)`): "Expected
  #      exactly 40 elements matching …turbo-frame#column-tree-d-laser a.column-row[href^=…d-f], found
  #      41" (and shell_layout_test.rb's cap test, found 41).
  #   2. FolderTree.open_ids without `.grep(ID)`: "a malformed cookie id opened a folder" (the rows
  #      held "inside odd").
  #   3. FolderTree.open_ids without `.last(OPEN_MAX)`: "the oldest id past the newest 50 still opened
  #      its folder".
  #   4. FolderTree#dirs from `Node.present` (no user): the disclosures read [["elsewhere", "false"],
  #      ["laser", "false"], ["Projects", "false"]], another user's root folder drawn at the root.
  #   5. FolderTree#dirs without `.present`: [["laser", "false"], ["Projects", "false"], ["trashed", "false"]].
  #   6. FolderTree#dirs without `visible_entries`: five tests red, the root reading
  #      ["Library", ".cache", "laser", "Projects"].
  #   7. FolderTree#keep_chain not called: the folder past the cut lit nothing (Expected ["zz last"],
  #      Actual []).
  #   8. LibraryBrowseController#tree's parent lookup without `visible_entries`: "the frame for d-git
  #      listed rows".
  #   9. The closed frame without `target: "_top"` (ShellHelper#folder_tree_item): "Expected at least 1
  #      element matching …turbo-frame#column-tree-d-design[hidden][target='_top'], found 0".
  class LibraryFolderTreeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tree-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      dir!("d-projects", "Projects")
      dir!("d-laser", "laser")
      dir!("d-dotroot", ".cache")
      dir!("d-catan", "catan", parent: "d-projects")
      dir!("d-cutlist", "cutlist", parent: "d-projects")
      dir!("d-lamp", "Desk Lamp", parent: "d-projects")
      dir!("d-parts", "parts", parent: "d-cutlist")
      dir!("d-cnc", "cnc", parent: "d-catan")
      dir!("d-design", "design", parent: "d-catan")
      dir!("d-git", Library::RepoMetadata::DIR_NAME, parent: "d-catan")
      dir!("d-modules", "node_modules", parent: "d-catan")
      dir!("d-old", "old", parent: "d-design")
      @user.nodes.create!(node_id: "n-board", name: "board.svg", kind: "file", parent_node_id: "d-catan",
                          mtime: 1, size: 10, content_hash: "h-board", current_version_id: "v-board")
    end

    def dir!(id, name, parent: nil, user: @user, deleted: false)
      user.nodes.create!(node_id: id, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0, deleted:)
    end

    def tree_rows = css_select("aside.column .column-tree .column-row .column-row-name").map { |e| e.text.strip }
    def lit_rows = css_select("aside.column .column-row[aria-current]").map { |a| a.css(".column-row-name").text.strip }

    # [name, aria-expanded] for every disclosure the tree draws.
    def toggles(scope = "aside.column")
      css_select("#{scope} button.column-tree-toggle").map do |b|
        [ b["aria-label"].delete_prefix("Folders in "), b["aria-expanded"] ]
      end
    end

    def remember(*ids) = cookies[Maker::FolderTree::COOKIE] = ids.join(".")

    # THE FIRST PAINT. Siblings at every level of the chain (laser beside Projects, cutlist and Desk
    # Lamp beside catan), the folder on screen open, `.git`, a dot-folder and build output hidden as the
    # Library hides them, and a disclosure on exactly the folders with subfolders: open on the chain,
    # closed on design and cutlist, none on the leaves.
    test "a folder's page draws the tree open down to it, each level's siblings beside it" do
      get files_path(folder: "d-catan")
      assert_response :success
      assert_equal [ "Library", "laser", "Projects", "catan", "cnc", "design", "cutlist", "Desk Lamp" ], tree_rows
      assert_equal [ "catan" ], lit_rows
      assert_equal [ [ "Projects", "true" ], [ "catan", "true" ], [ "design", "false" ], [ "cutlist", "false" ] ], toggles
      assert_select "aside.column li.column-tree-item[style=?] > a.column-row[href=?]", "--depth: 3", files_path(folder: "d-cnc")

      # A closed folder's level is an empty, hidden frame naming where its rows come from, one level
      # deeper, and a link inside it opens the page rather than the frame.
      assert_select "aside.column button.column-tree-toggle[aria-controls=?]", "column-tree-d-design"
      assert_select "aside.column turbo-frame#column-tree-d-design[hidden][target='_top']" do |frames|
        assert_equal library_tree_path(parent: "d-design", depth: 4), frames.first["data-src"]
        assert_empty frames.first.css(".column-row")
      end
      # An open one holds its level now, and names nothing to load.
      assert_select "aside.column turbo-frame#column-tree-d-catan:not([hidden]):not([data-src])[target='_top'] .column-row", count: 2
    end

    test "the library root draws its own folders closed, and a file's page opens to the file's folder" do
      get files_path
      assert_equal [ "Library", "laser", "Projects" ], tree_rows
      assert_equal [ "Library" ], lit_rows
      assert_equal [ [ "Projects", "false" ] ], toggles

      get file_path("n-board")
      assert_equal [ "Library", "laser", "Projects", "catan", "cnc", "design", "cutlist", "Desk Lamp" ], tree_rows
      assert_equal [ "catan" ], lit_rows

      # Trash and the 3D models view are Library pages with no folder on screen: the root's folders.
      get trash_index_path
      assert_equal [ "Library", "laser", "Projects" ], tree_rows
      assert_equal [ "Trash" ], lit_rows
    end

    # REMEMBERING WHAT IS OPEN. The cookie's folders are drawn open on any Library page, nested ones
    # too, but only where the tree reaches them: cutlist inside a closed Projects opens nothing.
    test "the folders the cookie names are drawn open, wherever the tree reaches them" do
      remember("d-cutlist")
      get files_path
      assert_equal [ "Library", "laser", "Projects" ], tree_rows

      remember("d-projects", "d-cutlist")
      get trash_index_path
      assert_equal [ "Library", "laser", "Projects", "catan", "cutlist", "parts", "Desk Lamp" ], tree_rows
      assert_equal [ [ "Projects", "true" ], [ "catan", "false" ], [ "cutlist", "true" ] ], toggles
      assert_select "aside.column turbo-frame#column-tree-d-projects:not([hidden]) turbo-frame#column-tree-d-cutlist:not([hidden]) .column-row", text: "parts"

      # A folder opened with no subfolders of its own is drawn as a leaf, not an empty open level.
      remember("d-laser")
      get files_path
      assert_equal [ [ "Projects", "false" ] ], toggles
    end

    # THE COOKIE IS CLIENT-WRITTEN, SO THE SERVER TRUSTS NOTHING IN IT BEYOND WELL-FORMED IDS, THE
    # NEWEST FIFTY: a real folder named by an id outside the form stays closed, and so does one pushed
    # past the fifty by newer ids.
    test "the cookie's ids are honoured only when well-formed and among the newest fifty" do
      dir!("we!rd", "odd", parent: nil)
      dir!("d-odd-child", "inside odd", parent: "we!rd")
      remember("we!rd")
      get files_path
      assert_not_includes tree_rows, "inside odd", "a malformed cookie id opened a folder"
      assert_response :success

      fillers = (0...Maker::FolderTree::OPEN_MAX).map { |i| "x#{i}" }
      remember("d-projects", *fillers)
      get files_path
      assert_not_includes tree_rows, "catan", "the oldest id past the newest #{Maker::FolderTree::OPEN_MAX} still opened its folder"

      remember(*fillers, "d-projects")
      get files_path
      assert_includes tree_rows, "catan"
    end

    # SOMEONE ELSE'S ROWS AND TOMBSTONES NEVER REACH THE TREE. node_ids are unique per user, not
    # globally, so another user's folder can name one of this user's ids as its parent: opening laser
    # must not list it, nor give laser a disclosure for it. A trashed subfolder is not drawn either,
    # and a cookie naming another user's folder or a tombstone opens nothing.
    test "another user's folders and tombstones never reach the tree" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      dir!("d-theirs", "theirs", parent: "d-laser", user: other)
      dir!("d-other-root", "elsewhere", user: other)
      dir!("d-other-child", "their child", parent: "d-other-root", user: other)
      dir!("d-gone", "gone", parent: "d-laser", deleted: true)
      dir!("d-gone-root", "trashed", deleted: true)
      dir!("d-gone-child", "trashed child", parent: "d-gone-root")

      get files_path
      assert_equal [ [ "Projects", "false" ] ], toggles, "laser drew a disclosure for a folder that is not this user's or not live"

      remember("d-laser", "d-other-root", "d-gone-root")
      get files_path(folder: "d-laser")
      rows = tree_rows
      %w[theirs gone elsewhere their\ child trashed trashed\ child].each do |name|
        assert_not_includes rows, name, "the tree drew #{name.inspect}"
      end
      assert_equal [ "laser" ], lit_rows
    end

    # THE FOLDER ON SCREEN IS ALWAYS DRAWN, and lit: past the cut of its folder's list (with "All
    # folders here" still offered), and inside a hidden folder reached with hidden files shown.
    test "the folder on screen is drawn and lit even past the cut or inside a hidden folder" do
      (Maker::FolderTree::CAP + 1).times { |i| dir!(format("d-f%03d", i), format("f%03d", i), parent: "d-laser") }
      dir!("d-last", "zz last", parent: "d-laser")
      get files_path(folder: "d-last")
      assert_equal [ "zz last" ], lit_rows
      assert_select "aside.column turbo-frame#column-tree-d-laser a.column-row[href^=?]", "#{files_path}?folder=d-f", count: Maker::FolderTree::CAP
      assert_select "aside.column turbo-frame#column-tree-d-laser a.column-row.column-row--more[href=?]", files_path(folder: "d-laser"),
                    text: "All folders here"

      dir!("d-inner", "inner", parent: "d-dotroot")
      get files_path(folder: "d-inner", hidden: 1)
      assert_equal [ "inner" ], lit_rows
      assert_includes tree_rows, ".cache"
    end

    # OPENING A CLOSED FOLDER IN PLACE: the frame its row names, holding its level at the depth the
    # page asked for, drawn by the same method, with the cookie's folders inside it open too, and no
    # layout around it.
    test "a closed folder's frame answers its level, one deeper, with the cookie's folders open" do
      get library_tree_path(parent: "d-catan", depth: 3)
      assert_response :success
      assert_select "header.strip", count: 0
      assert_select "turbo-frame#column-tree-d-catan[target='_top']" do
        assert_equal [ "cnc", "design" ], css_select(".column-row-name").map { |e| e.text.strip }
        assert_select "li.column-tree-item[style=?] > a.column-row[href=?]", "--depth: 3", files_path(folder: "d-design")
        assert_select "turbo-frame#column-tree-d-design[hidden][data-src=?]", library_tree_path(parent: "d-design", depth: 4)
      end
      assert_equal [ [ "design", "false" ] ], toggles("turbo-frame#column-tree-d-catan")
      assert_select ".column-row[aria-current]", count: 0

      remember("d-design")
      get library_tree_path(parent: "d-catan", depth: 3)
      assert_equal [ "cnc", "design", "old" ], css_select(".column-row-name").map { |e| e.text.strip }
      assert_equal [ [ "design", "true" ] ], toggles("turbo-frame#column-tree-d-catan")
    end

    # The frame's parent is checked as the tree checks its rows: this user's live, visible folders
    # only. Anything else answers the same frame, empty, never a 500 and never their rows.
    test "a closed folder's frame lists nothing for a folder that is not this user's live, visible folder" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      dir!("d-their-root", "theirs", user: other)
      dir!("d-their-child", "their child", parent: "d-their-root", user: other)
      dir!("d-gone", "gone", deleted: true)
      dir!("d-gone-child", "gone child", parent: "d-gone")
      dir!("d-git-child", "refs", parent: "d-git")

      %w[d-their-root d-gone d-git n-board nope].each do |parent|
        get library_tree_path(parent:, depth: 2)
        assert_response :success
        assert_select "turbo-frame#column-tree-#{parent}"
        assert_select ".column-row", { count: 0 }, "the frame for #{parent} listed rows"
      end

      get library_tree_path(parent: [ "d-catan" ], depth: [ "9" ])
      assert_response :success
      assert_select ".column-row", count: 0
      get library_tree_path(parent: "d-catan", depth: "999")
      assert_select "li.column-tree-item[style=?]", "--depth: 64", count: 2
    end
  end
end
