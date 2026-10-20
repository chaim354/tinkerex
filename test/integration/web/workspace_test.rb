require "test_helper"

module Web
  # THE WORKSPACE (structural redesign spec §5.3, slice 3): the file page goes full width, the viewer
  # takes the main column and the file's facts sit beside it, and the top bar's breadcrumb walks back
  # to the file's folder — whose link reselects the file there, which is what "back to folder" means
  # in a Library with an inspector.
  #
  # PINNED TO A FRESH SHARE LIBRARY for inspector_test.rb's reason: these are web-layer tests, and on
  # the ambient s3 or chunk_remote leg a bare row would reach real Aws calls or a live sync server.
  class WorkspaceTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "ws-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @dir = @user.nodes.create!(node_id: "dir-legs", name: "legs", kind: "dir", mtime: 1, size: 0)
      @file = @user.nodes.create!(node_id: "n-leg", name: "leg.lbrn2", kind: "file", mtime: 1, size: 5,
                                  parent_node_id: @dir.node_id)
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    test "the file page is a workspace: the viewer in the main column, the facts beside it" do
      get file_path(@file.node_id)
      assert_response :success
      assert_select "main.container.container-wide"
      assert_select ".workspace .workspace-main .preview-row"
      assert_select ".workspace .workspace-side dl.meta"
      assert_select ".workspace .workspace-side section.connections-panel"
      assert_select ".workspace .workspace-side section.notes-panel#notes"
      # The page head stays ABOVE the wrapper, unchanged.
      assert_select ".workspace .page-head", count: 0
    end

    # The side column reads facts, the rename/move composer under the facts it changes (F,
    # 2026-10-13 — a file outside a git working tree only), projects, connections, notes —
    # outward-in, the order the page already had. A project exists so the attach block renders at
    # all (it is absent with none).
    test "the side column holds its five blocks in order" do
      @user.maker_projects.create!(name: "Shop Stool")

      get file_path(@file.node_id)
      side = css_select(".workspace-side > *").map { |el| el["class"].to_s.split.first }
      assert_equal %w[meta rename-move attach-to-project connections-panel notes-panel], side
    end

    test "the breadcrumb walks to the file's folder and that link reselects the file" do
      get file_path(@file.node_id)
      assert_select "header.topbar nav.breadcrumb" do
        assert_select "a[href=?]", files_path, text: "Files"
        assert_select "a[href=?]", files_path(folder: @dir.node_id, selected: @file.node_id), text: "legs"
        assert_select "[aria-current='page']", text: "leg.lbrn2"
      end
    end

    # Only the LAST crumb is the file's folder; an ancestor above it is a plain folder link, because
    # the file is not in that listing to be selected.
    test "only the file's own folder carries the selection, not the folders above it" do
      shop = @user.nodes.create!(node_id: "dir-shop", name: "shop", kind: "dir", mtime: 1, size: 0)
      @dir.update!(parent_node_id: shop.node_id)

      get file_path(@file.node_id)
      assert_select "header.topbar nav.breadcrumb" do
        assert_select "a[href=?]", files_path(folder: shop.node_id), text: "shop"
        assert_select "a[href=?]", files_path(folder: @dir.node_id, selected: @file.node_id), text: "legs"
      end
    end

    # A file at the library root has no folder crumb, so "Files" IS its folder and carries the
    # selection itself.
    test "a file at the library root reselects itself from the Files crumb" do
      loose = @user.nodes.create!(node_id: "n-loose", name: "loose.stl", kind: "file", mtime: 1, size: 3)

      get file_path(loose.node_id)
      assert_select "header.topbar nav.breadcrumb" do
        assert_select "a[href=?]", files_path(selected: loose.node_id), text: "Files"
        assert_select "a", count: 1
      end
    end

    # NOW INTENDED: @crumbs on the file page is the same ancestor chain #index sets, and
    # ShellHelper#sidebar_current reads it, so a file inside a pinned folder lights that pin — the
    # same answer the folder's own listing gives. Exactly one lit link, as everywhere.
    test "a file inside a pinned folder lights the pin" do
      @user.maker_pins.create!(node_id: @dir.node_id)

      get file_path(@file.node_id)
      assert_select "aside.rail a.rail-link[aria-current='page']", count: 1, text: "legs"
    end
  end
end
