require "test_helper"

module Web
  # THE TOP BAR'S UPLOAD (structural redesign spec §4.2 and §8, slice 4): it uploads into the folder the
  # page shows and says which, and on a page that shows no folder it asks with the folder chooser
  # instead of guessing. Both flows carry the destination, so every assertion branches on the flow
  # this leg renders (`port_writable?`): asserting the form alone is red on chunk_remote.
  class TopbarUploadTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "up-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "d-jigs", name: "jigs", kind: "dir", parent_node_id: "d-cad", mtime: 1, size: 0)
      @user.nodes.create!(node_id: "n-plate", name: "plate.dxf", kind: "file", parent_node_id: "d-jigs",
                          mtime: 1_000_000_000, size: 10, content_hash: "h-plate", current_version_id: "v-plate")
    end

    def assert_destination(node_id)
      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar .topbar-upload form.uploader[action=?] input[type=hidden][name='parent_node_id'][value=?]",
                      files_path, node_id
      else
        assert_select "header.topbar .topbar-upload section.uploader[data-controller='uploader'][data-uploader-parent-node-id-value=?]",
                      node_id
      end
    end

    def assert_caption(text)
      assert_select "header.topbar .topbar-upload-caption", text: "Saves to #{text}"
    end

    test "on a folder, Upload carries that folder, is the page's primary, and names it" do
      get files_path(folder: "d-jigs")
      assert_response :success
      assert_destination "d-jigs"
      assert_select "header.topbar .topbar-upload label.upload-btn.primary span", text: "Upload"
      assert_caption "cad/jigs"
      # The page head's own uploader moved here; one Upload, not two.
      assert_select "main .uploader", count: 0
    end

    test "at the top of the Library it saves to the library root" do
      get files_path
      assert_destination ""
      assert_caption "the library root"
    end

    # The validated folder, never the raw param: a stale ?folder= renders the root's listing, so it
    # must not leave the stale id in the form.
    test "a stale ?folder= uploads to the root it shows, and New creates there too" do
      get files_path(folder: "gone")
      assert_destination ""
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]", library_folders_path, ""
    end

    test "the workspace saves beside its file, quietly" do
      get file_path("n-plate")
      assert_destination "d-jigs"
      assert_select "header.topbar .topbar-upload label.upload-btn:not(.primary)"
      assert_caption "cad/jigs"
    end

    test "the project hub saves to the project's folder and its Files panel has no second uploader" do
      project = @user.maker_projects.create!(name: "Desk Lamp")
      folder = project_folder_rows!(@user, project)
      get project_path(project)
      assert_destination folder.node_id
      assert_select "header.topbar .topbar-upload label.upload-btn.primary"
      assert_caption "Projects/desk-lamp"
      assert_select ".attachments-panel .uploader", count: 0
    end

    # The chunk arm asserts the `uploader` target on the section ITSELF, not a rendered string: the
    # chooser writes the chosen folder into that element's `data-uploader-parent-node-id-value`, so a
    # target landing anywhere else would leave the chunk flow uploading to the root.
    test "a page with no folder asks with the chooser, quietly, and names nothing yet" do
      get settings_path
      assert_select "header.topbar .topbar-upload[data-controller='upload-pick'][data-upload-pick-children-url-value=?][data-upload-pick-create-url-value=?]",
                    library_children_path, library_folders_path
      assert_destination ""
      assert_select "header.topbar .topbar-upload label.upload-btn:not(.primary)[data-action=?]", "click->upload-pick#pick"
      assert_select "header.topbar .topbar-upload input[type=file][data-upload-pick-target='input']", 1
      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar .topbar-upload form.uploader input[type=hidden][name='parent_node_id'][data-upload-pick-target='parent']", 1
      else
        assert_select "header.topbar .topbar-upload section.uploader[data-controller='uploader'][data-upload-pick-target='uploader']", 1
      end
      assert_select "header.topbar .topbar-upload-caption[hidden][data-upload-pick-target='caption']"
    end

    # RECENT IS THE ONE PAGE WITH NO FOLDER WHOSE UPLOAD IS ITS ACCENT (slice 6; FolderDestination's
    # upload_primary!). Both halves in one selector: the weight changed (`primary`) and the destination
    # did not — it still asks with the chooser, because Recent has no folder to name. The settings test
    # above is the other half: the flag must not leak to every page without a folder.
    test "Recent's Upload is its primary, and still asks with the chooser" do
      get root_path
      assert_select "header.topbar .topbar-upload[data-controller='upload-pick'] label.upload-btn.primary[data-action=?]",
                    "click->upload-pick#pick"
      assert_destination ""
      assert_select "header.topbar .topbar-upload-caption[hidden][data-upload-pick-target='caption']"
    end

    # A page WITH a folder wires none of the chooser: no controller, no targets, no action. Asked so
    # a refactor that always rendered the chooser step would have to say so here.
    test "a page with a folder renders no chooser step" do
      get files_path(folder: "d-jigs")
      assert_select "header.topbar .topbar-upload[data-controller]", 0
      assert_select "header.topbar [data-upload-pick-target]", 0
      assert_select "header.topbar [data-action*='upload-pick']", 0
    end

    test "New creates where Upload saves, and its tools open there" do
      get file_path("n-plate")
      assert_select "header.topbar form[action=?] input[name='parent_node_id'][value=?]", library_folders_path, "d-jigs"
      assert_select "header.topbar a.menu-item[href=?]", new_files_text_file_path(parent_node_id: "d-jigs")
      assert_select "header.topbar turbo-frame#new-menu-tools[src=?]", tools_new_menu_path(in: "d-jigs")
    end
  end
end
