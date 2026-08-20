require "test_helper"

module Web
  # The Files-page upload defaults into the current project (folder + attach) by reusing the project
  # upload/attach control. Chunk drives the two-phase uploader (data-* wiring); share drives a
  # multipart form. s3 shares share's port_writable branch, so those two cover both view branches.
  class CurrentProjectFilesUploadTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper # a port upload enqueues a preview job; keep it recorded, not run
    PASSWORD = "correct horse battery staple".freeze

    class ChunkTest < CurrentProjectFilesUploadTest
      setup do
        pin_file_layer_backend("chunk")
        Sync::Storage::ChunkStore.reset!
        @user = User.create!(email: "fu-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      test "with a current project the uploader is wired to upload into it and attach" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path
        assert_response :success
        assert_select "[data-uploader-parent-node-id-value=?]", @folder.node_id
        assert_select "[data-uploader-attach-url-value=?]", project_attachments_path(@project)
        assert_select "[data-uploader-redirect-url-value=?]", files_path(folder: @folder.node_id)
        assert_select "a", text: /library root instead/i
      end

      test "the override link preserves the browsed folder, not the project folder" do
        other = @user.nodes.create!(node_id: SecureRandom.uuid, name: "Loose", kind: "dir")
        patch current_project_path, params: { project_id: @project.id }
        get files_path(folder: other.node_id)
        assert_response :success
        assert_select "a[href=?]", files_path(folder: other.node_id, upload: "library"),
                      text: /library root instead/i
      end

      test "the ?upload=library override renders the plain (root) uploader" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path(upload: "library")
        # plain uploader has no attach-url wiring
        assert_select "[data-uploader-attach-url-value]", count: 0
        assert_select "[data-controller='uploader']"
      end

      test "with no current project the plain uploader renders" do
        get files_path
        assert_select "[data-uploader-attach-url-value]", count: 0
        assert_select "[data-controller='uploader']"
      end
    end

    class ShareTest < CurrentProjectFilesUploadTest
      setup do
        @root = Pathname.new(Dir.mktmpdir("files-upload"))
        @user = User.create!(email: "fus-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        FileLayer.current = FileLayer::Share.new(root: @root.to_s)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root&.exist?
      end

      test "with a current project the multipart form posts to the project upload path" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path
        assert_select "form.uploader[action=?]", project_uploads_path(@project)
        assert_select "a", text: /library root instead/i
      end

      test "with no current project the multipart form posts to the plain files path" do
        get files_path
        assert_select "form.uploader[action=?]", files_path
      end

      test "the ?upload=library override renders the plain multipart form" do
        patch current_project_path, params: { project_id: @project.id }
        get files_path(upload: "library")
        assert_select "form.uploader[action=?]", files_path
        assert_select "form.uploader[action=?]", project_uploads_path(@project), count: 0
      end

      # The chunk branch already sends the browser back to Files after the upload (its
      # data-uploader-redirect-url-value, honored by uploader_controller.js). The share/s3 multipart
      # branch must reach the same place, so the form carries redirect_url as a hidden field and
      # Projects::UploadsController redirects there instead of to the project page.
      test "the multipart form carries a hidden redirect_url back to the files folder" do
        patch current_project_path, params: { project_id: @project.id }
        folder = @project.ensure_library_folder!(@user) # idempotent: the node_id the view computes
        get files_path
        assert_select "form.uploader[action=?]", project_uploads_path(@project) do
          assert_select "input[type=hidden][name=redirect_url][value=?]",
                        files_path(folder: folder.node_id)
        end
      end

      test "a current-project upload lands the user back in Files, not on the project page" do
        patch current_project_path, params: { project_id: @project.id }
        folder = @project.ensure_library_folder!(@user)
        file = Rack::Test::UploadedFile.new(StringIO.new("solid cube".b),
                                            "application/octet-stream", original_filename: "cube.stl")
        assert_difference "@project.file_attachments.count", 1 do
          post project_uploads_path(@project),
               params: { file:, redirect_url: files_path(folder: folder.node_id) }
        end
        assert_redirected_to files_path(folder: folder.node_id)
      end

      # An open-redirect guard: a tampered redirect_url pointing off-site must never send the user
      # away from this app. url_from returns nil for anything non-relative, so the controller falls
      # back to the project page. (The upload itself still succeeds.)
      test "an off-site redirect_url is refused — the upload falls back to the project page" do
        file = Rack::Test::UploadedFile.new(StringIO.new("cube".b),
                                            "application/octet-stream", original_filename: "cube.stl")
        post project_uploads_path(@project),
             params: { file:, redirect_url: "https://evil.example.com/phish" }
        assert_redirected_to project_path(@project)
      end
    end
  end
end
