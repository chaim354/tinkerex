require "test_helper"

module Web
  # A file uploaded INTO a project folder attaches and files itself in the same request, rather than
  # waiting for the next sweep — which would read as broken.
  #
  # BOTH DOORS, because they are different flows: chunk drives the two-phase presigned upload
  # (begin_upload/finalize_upload) and share drives a multipart POST to #create. s3 shares share's
  # port_writable branch.
  class ProjectFolderIntakeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper # an upload enqueues a preview job; keep it recorded, not run
    PASSWORD = "correct horse battery staple".freeze

    class ShareTest < ProjectFolderIntakeTest
      setup do
        @root = Dir.mktmpdir("pfi-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "pfi-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      # `parent:` defaults to the project folder; pass nil to upload to the library root.
      def upload(name, content = "x", parent: @folder.node_id)
        path = File.join(Dir.tmpdir, name)
        File.binwrite(path, content)
        post files_path, params: { parent_node_id: parent,
                                   file: Rack::Test::UploadedFile.new(path, "application/octet-stream") }
      ensure
        FileUtils.rm_f(path)
      end

      test "a file uploaded into the project folder is attached and filed in the same request" do
        upload("panel.svg", "<svg/>")
        assert_response :redirect

        att = @project.file_attachments.sole
        node = @user.nodes.find_by!(node_id: att.node_id)
        assert_equal "vector", att.role
        assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name
      end

      test "a file uploaded to the library root is untouched" do
        upload("loose.svg", "<svg/>", parent: nil)
        assert_response :redirect
        assert_equal 0, @project.file_attachments.count
      end

      # BEST-EFFORT: the upload already succeeded, so a failing intake must not turn it into an
      # error (the same rule enqueue_preview follows immediately above it).
      #
      # Hand-rolled override — `stub` does not exist in this suite (minitest 6 dropped
      # minitest/mock). The ensure-restore is load-bearing: a leak would break every later test in
      # this process.
      test "an intake failure does not fail the upload" do
        original = Maker::ProjectIntake.method(:for_node)
        Maker::ProjectIntake.define_singleton_method(:for_node) { |**| raise "intake exploded" }
        begin
          upload("panel.svg", "<svg/>")
          assert_response :redirect
          assert @user.nodes.present.exists?(name: "panel.svg"), "the file is uploaded either way"
        ensure
          Maker::ProjectIntake.define_singleton_method(:for_node, original)
        end
      end
    end

    class ChunkTest < ProjectFolderIntakeTest
      setup do
        pin_file_layer_backend("chunk")
        Storage::ChunkStore.reset!
        @user = User.create!(email: "pfic-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      test "a two-phase upload into the project folder is attached and filed on finalize" do
        content = "<svg/>"
        hash = Digest::SHA256.hexdigest(content)
        post begin_upload_files_path, as: :json, params: {
          name: "panel.svg", size: content.bytesize, parent_node_id: @folder.node_id,
          manifest: [ { hash:, offset: 0, length: content.bytesize } ]
        }
        assert_response :success
        commit_id = response.parsed_body["commit_id"]
        # THREE ARGS: ChunkStore#put is (user_id, hash, bytes) — chunk storage is per-user, which is
        # what makes cross-user chunk access impossible (CLAUDE.md §8). A two-arg call raises
        # ArgumentError.
        Storage::ChunkStore.current.put(@user.id, hash, content)

        post finalize_upload_files_path, as: :json, params: { commit_id: }
        assert_response :success

        att = @project.file_attachments.sole
        node = @user.nodes.find_by!(node_id: att.node_id)
        assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name
      end
    end
  end
end
