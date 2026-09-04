require "test_helper"

module Web
  # The Files page's controls (spec §8, PR 2): Upload is the primary action in the page head,
  # rescan and the upload-destination switch live in an overflow menu, and everything else —
  # the type filter, the dot-file switch, the count, the view toggle and the sort — sits on ONE
  # toolbar row in both views. Nodes are created directly, as files_type_filter_test.rb does.
  class FilesToolbarTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "tb-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "dir-cad", name: "cad", kind: "dir")
      file("root.stl", nil)
      file("plate.dxf", nil)
      file("firmware.bin", nil)   # no preview renderer: the generic card
      file("notes.pdf", "dir-cad")
    end

    # BOTH content columns, and both are load-bearing: the tile prints a size only when stat_all
    # reports a content token, and that token is `content_hash` on share/s3 but `current_version_id`
    # on chunk_remote. Setting one would render the size on two legs and not the third.
    def file(name, parent)
      @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file",
                          parent_node_id: parent, mtime: 1_000_000_000, size: 2_400,
                          content_hash: "h-#{name}", current_version_id: "v-#{name}")
    end

    test "upload is the primary action in the page head and the dashed panel is gone" do
      get files_path
      assert_response :success
      assert_select ".page-head .page-actions label.upload-btn span", text: "Upload a file"
      assert_select ".page-head .page-actions form.uploader[action=?]", files_path
      assert_select "main .uploader", count: 1
    end

    test "rescan lives in the overflow menu on a scannable backend" do
      get files_path
      if FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu[data-controller='menu'] summary.btn"
        assert_select ".page-actions details.menu form[action=?] button.menu-item", rescan_files_path, text: /rescan/i
      else
        assert_select "form[action=?]", rescan_files_path, count: 0
      end
    end

    test "the toolbar carries the filter, the dot-file switch, the count, the view toggle and the sort, in both views" do
      %w[list grid].each do |view|
        get files_path(view:)
        assert_select ".toolbar.files-toolbar", count: 1
        assert_select ".files-toolbar .ext-picker select#ext-add"
        assert_select ".files-toolbar p.hidden-toggle a.chip[href*=?]", "hidden=1", text: "Show dot-files"
        assert_select ".files-toolbar .toolbar-count", text: "4 items"
        assert_select ".files-toolbar .view-toggle a.toggle.active", text: view.capitalize
        assert_select ".files-toolbar form.sort-form select[name='sort']"
        assert_select ".files-toolbar form.sort-form select[name='dir']"
      end
    end

    test "the count says matches when the view is flat, and keeps the truncation sentence" do
      get files_path(ext: "stl")
      assert_select ".files-toolbar .toolbar-count", text: "1 match"
      get files_path(q: "e")
      assert_select ".files-toolbar .toolbar-count", text: "3 matches"
    end

    test "a current project turns the head's upload into the project's, with a caption and a menu switch" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      patch current_project_path, params: { project_id: project.id }
      get files_path
      assert_select ".page-actions label.upload-btn span", text: /Upload/
      assert_select ".page-actions form.uploader[action=?]", project_uploads_path(project)
      assert_select ".upload-to-project.upload-caption", text: /Uploads go to Desk Lamp/
      assert_select ".page-actions details.menu a.menu-item.upload-alt[href=?]",
                    files_path(upload: "library"), text: "Upload to library root instead"

      get files_path(upload: "library")
      assert_select ".page-actions form.uploader[action=?]", files_path
      assert_select ".upload-caption", count: 0
      assert_select ".page-actions details.menu a.menu-item.upload-alt[href=?]", files_path,
                    text: "Upload to project “Desk Lamp” instead"
    end

    # The scannable arm is asserted too, so this run is not a test that reports success having
    # asserted nothing on the backend it happens to be running against (§15).
    test "no menu renders when it would be empty" do
      get files_path
      if FileLayer.current.capabilities.scannable?
        assert_select ".page-actions details.menu", count: 1
      else
        assert_select ".page-actions details.menu", count: 0
      end
    end

    test "grid tiles carry a size-and-type line" do
      get files_path(view: "grid")
      assert_select ".files-grid .grid-card.file-cell .grid-sub", text: "2.34 KB · STL"
      assert_select ".files-grid .grid-card:not(.file-cell):not(.grid-folder) .grid-sub", text: "2.34 KB · BIN"
      assert_select ".files-grid .grid-folder .grid-sub", count: 0
    end
  end
end
