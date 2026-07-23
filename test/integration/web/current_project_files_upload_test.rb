require "test_helper"

module Web
  # The Files-page upload defaults into the current project (folder + attach) by reusing the project
  # upload/attach control. Chunk drives the two-phase uploader (data-* wiring); share drives a
  # multipart form. s3 shares share's port_writable branch, so those two cover both view branches.
  class CurrentProjectFilesUploadTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    class ChunkTest < CurrentProjectFilesUploadTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
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
        assert_select "a", text: /library root instead/i
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
    end
  end
end
