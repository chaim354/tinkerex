require "test_helper"

module Web
  # Folder navigation in the web file browser. The library was dumped FLAT — every node at every
  # depth in one list, basename only — so same-named files in different folders looked like
  # duplicates and the tree was invisible. This exercises the fix: #index scopes to one folder's
  # children by parent_node_id, folder rows are links, and a breadcrumb walks back up.
  #
  # DELIBERATELY NOT PINNED TO A BACKEND. The whole feature reads `nodes.parent_node_id`, which all
  # three backends populate identically, and stat_all answers from `nodes` alone on each (see
  # Chunk/Share/S3#stat_all) — so seeding bare nodes and running on the ambient LIBRARY_BACKEND is
  # what proves it is backend-neutral. This file must stay green on `bin/rails test`,
  # `LIBRARY_BACKEND=share`, and `LIBRARY_BACKEND=s3` without touching a share disk or a bucket.
  class FolderNavTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "nav-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)

      # A small nested tree:
      #   /root-file.txt
      #   /shared.stl                      <- same basename as cad/shared.stl (the duplicate look)
      #   /cad/                            (dir-cad)
      #   /cad/nested.stl
      #   /cad/shared.stl
      #   /cad/sub/                        (dir-sub)
      #   /cad/sub/deep.stl
      node("root-file.txt", "file", nil)
      node("shared.stl",    "file", nil)
      node("cad",           "dir",  nil,       id: "dir-cad")
      node("nested.stl",    "file", "dir-cad")
      node("shared.stl",    "file", "dir-cad")
      node("cad-sub",       "dir",  "dir-cad", id: "dir-sub", display: "sub")
      node("deep.stl",      "file", "dir-sub")
    end

    # `display` lets a dir carry a node_id-friendly seed name while presenting a real folder name;
    # only `name` is what the UI shows, so the breadcrumb assertions read the display name.
    def node(name, kind, parent, id: SecureRandom.uuid, display: nil)
      @user.nodes.create!(node_id: id, name: display || name, kind:, parent_node_id: parent)
      id
    end

    test "root lists only root children, not nested files" do
      get files_path
      assert_response :success

      # Root children are present…
      assert_select "a", text: "root-file.txt"
      assert_select "a.dir", text: "cad"
      # The folder glyph is the rail's line icon, never an emoji (design system: no emoji in the
      # interface).
      assert_select "a.dir svg.folder-glyph"
      assert_no_match "📁", response.body
      # …and the nested files are NOT — the flat-dump bug. THIS is the mutation-sensitive
      # assertion: revert #index to `current_user.nodes.present` (all nodes) and this goes red,
      # because nested.stl and deep.stl would be dumped here too.
      assert_select "a", text: "nested.stl", count: 0
      assert_select "a", text: "deep.stl", count: 0
      # The duplicate-look: shared.stl exists at root AND under cad, but only root's shows here.
      assert_select "a", text: "shared.stl", count: 1
    end

    test "a folder row links into the folder" do
      get files_path
      assert_select "a[href=?]", files_path(folder: "dir-cad")
      # A folder does NOT link to the file preview.
      assert_select "a[href=?]", file_path("dir-cad"), count: 0
    end

    test "opening a folder lists only that folder's children" do
      get files_path(folder: "dir-cad")
      assert_response :success

      assert_select "a", text: "nested.stl"
      assert_select "a.dir", text: "sub"
      assert_select "a", text: "shared.stl", count: 1     # cad/shared.stl, not root's
      # The parent's siblings and the grandchild are both off this page.
      assert_select "a", text: "root-file.txt", count: 0
      assert_select "a", text: "deep.stl", count: 0
    end

    test "breadcrumb reflects depth and each segment links to its folder" do
      get files_path(folder: "dir-sub")
      assert_response :success

      # root -> cad -> sub, each a link to the right ?folder= (or files_path for the root).
      assert_select "nav.breadcrumb a[href=?]", files_path,                  text: "Files"
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-cad"), text: "cad"
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-sub"), text: "sub"
    end

    test "at the root the breadcrumb is just Files" do
      get files_path
      assert_select "nav.breadcrumb a", text: "Files", count: 1
      # No folder segments at the root.
      assert_select "nav.breadcrumb a[href=?]", files_path(folder: "dir-cad"), count: 0
    end

    # --- params[:folder] is user input in a URL: validate ownership + kind, fall back to root ---

    test "a nonexistent folder id falls back to root, does not 500" do
      get files_path(folder: "no-such-node")
      assert_response :success
      # Fell back to root: root children shown, nested hidden.
      assert_select "a", text: "root-file.txt"
      assert_select "a", text: "nested.stl", count: 0
      assert_select "nav.breadcrumb a", text: "Files", count: 1
    end

    test "a file's node_id is not accepted as a folder (kind guard) -> root" do
      file_id = @user.nodes.find_by!(name: "root-file.txt", parent_node_id: nil).node_id
      get files_path(folder: file_id)
      assert_response :success
      # A file has no children, so if it were accepted the page would be empty; instead we render
      # root (root-file.txt present), proving the kind guard rejected it rather than scoping to it.
      assert_select "a", text: "root-file.txt"
      assert_select "nav.breadcrumb a", text: "Files", count: 1
    end

    test "another user's folder id does not leak and falls back to root" do
      other = User.create!(email: "o-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      foreign = other.nodes.create!(node_id: "foreign-dir", name: "theirs", kind: "dir").node_id

      get files_path(folder: foreign)
      assert_response :success
      # Renders OUR root, never their folder's contents, never their folder name in the breadcrumb.
      assert_select "a", text: "root-file.txt"
      assert_no_match(/theirs/, response.body, "a foreign folder must not leak into our view")
      assert_select "nav.breadcrumb a", text: "Files", count: 1
    end

    # A deleted directory must not be navigable — `present` scope everywhere.
    test "a tombstoned folder id falls back to root" do
      @user.nodes.find_by!(node_id: "dir-cad").update!(deleted: true)
      get files_path(folder: "dir-cad")
      assert_response :success
      assert_select "nav.breadcrumb a", text: "Files", count: 1
    end
  end
end
