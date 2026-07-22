require "test_helper"

module Web
  class ProjectUploadAttachTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    # chunk: the two-phase browser flow lands the node (existing, tested); the NEW behavior is the
    # attach step answering JSON so uploader_controller can finish it.
    class ChunkTest < ProjectUploadAttachTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "upc-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      end

      def upload_to_library(name, bytes)
        hash = Digest::SHA256.hexdigest(bytes)
        manifest = [ { hash:, offset: 0, length: bytes.bytesize } ]
        post begin_upload_files_path, params: { name:, size: bytes.bytesize, manifest: }, as: :json
        begun = JSON.parse(response.body)
        (begun["put_urls"] || {}).each_value do |url|
          put url, params: bytes, headers: { "CONTENT_TYPE" => "application/octet-stream" }
        end
        post finalize_upload_files_path, params: { commit_id: begun["commit_id"] }, as: :json
        begun["node_id"]
      end

      test "attach answers JSON with the created reference" do
        project = @user.maker_projects.create!(name: "Lamp")
        node_id = upload_to_library("bracket.stl", "solid\n".b)
        assert_difference "project.file_attachments.count", 1 do
          post project_attachments_path(project), params: { node_id: }, as: :json
        end
        assert_response :created
        body = JSON.parse(response.body)
        assert_equal node_id, body["node_id"]
        assert_equal "model", body["role"]
      end

      test "attach a photo to a build-log entry answers JSON" do
        project = @user.maker_projects.create!(name: "Lamp")
        entry = project.build_log_entries.create!(user: @user, body: "glued")
        node_id = upload_to_library("clamp.png", "\x89PNG".b)
        assert_difference "entry.file_attachments.count", 1 do
          post entry_photos_path(entry), params: { node_id: }, as: :json
        end
        assert_response :created
        assert_equal "image", entry.file_attachments.last.role
      end
    end

    # share: one multipart POST writes the bytes to the port AND attaches.
    class ShareTest < ProjectUploadAttachTest
      setup do
        @root = Pathname.new(Dir.mktmpdir("proj-upload"))
        @user = User.create!(email: "ups-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        FileLayer.current = FileLayer::Share.new(root: @root.to_s)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      end
      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root&.exist?
      end

      test "multipart upload writes the file and attaches it" do
        project = @user.maker_projects.create!(name: "Lamp")
        file = Rack::Test::UploadedFile.new(StringIO.new("solid cube".b),
                                            "application/octet-stream", original_filename: "cube.stl")
        assert_difference "project.file_attachments.count", 1 do
          post project_uploads_path(project), params: { file: }
        end
        att = project.file_attachments.last
        assert_equal "model", att.role
        assert FileLayer.current.stat(@user, node_id: att.node_id).present?, "bytes must land in the share"
        assert_redirected_to project_path(project)
      end

      test "multipart photo upload writes and attaches to the entry as image" do
        project = @user.maker_projects.create!(name: "Lamp")
        entry = project.build_log_entries.create!(user: @user, body: "x")
        file = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG".b), "image/png", original_filename: "p.png")
        assert_difference "entry.file_attachments.count", 1 do
          post build_log_entry_uploads_path(entry), params: { file: }
        end
        assert_equal "image", entry.file_attachments.last.role
      end

      test "a duplicate filename is refused with a flash, not a 500" do
        project = @user.maker_projects.create!(name: "Lamp")
        make = -> { Rack::Test::UploadedFile.new(StringIO.new(SecureRandom.hex.b),
                                                 "application/octet-stream", original_filename: "dup.stl") }
        post project_uploads_path(project), params: { file: make.call }
        assert_response :redirect
        assert_equal 1, project.file_attachments.count

        post project_uploads_path(project), params: { file: make.call }  # same name -> clobber refused
        assert_response :redirect                       # rescued, NOT a 500
        assert flash[:alert].present?, "the clobber must surface a flash alert"
        assert_equal 1, project.file_attachments.count, "no second attachment on a refused upload"
      end
    end
  end
end
