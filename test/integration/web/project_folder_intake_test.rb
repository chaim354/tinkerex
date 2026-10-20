require "test_helper"

module Web
  # A file uploaded INTO a project folder attaches and files itself in the same request, rather than
  # waiting for the next sweep — which would read as broken.
  #
  # TWO UPLOAD DOORS CAN LAND A FILE IN A PROJECT FOLDER, one per flow, and both are the top bar's.
  # share/s3 POST the bytes to FilesController#create (ShareTest below; s3 shares share's
  # port_writable branch). chunk_remote drives the two-phase presigned upload, whose
  # #finalize_upload runs the same nudge. This file has had no request test for that door since the
  # ChunkTest that drove it here left with embedded chunk (Arc D Part 2).
  #
  # A third door, Projects::UploadsController's project-level route, was the project page's own
  # uploader until redesign slice 4 moved Upload into the top bar, and was retired in F-S21-1. What
  # is left of that controller is the build-log photo upload, which writes at the library root, so
  # nothing there is under a project folder (BuildLogUploadTest below).
  class ProjectFolderIntakeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper # an upload enqueues a preview job; keep it recorded, not run
    PASSWORD = "correct horse battery staple".freeze

    class ShareTest < ProjectFolderIntakeTest
      setup do
        @root = Dir.mktmpdir("pfi-share")
        FileLayer.current = FileLayer::Share.new(root: @root)
        @user = User.create!(email: "pfi-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        sign_in_web!(@user, password: PASSWORD)
        @project = @user.maker_projects.create!(name: "Desk Lamp")
        @folder = @project.ensure_library_folder!(@user)
      end

      teardown do
        FileLayer.reset!
        FileUtils.remove_entry(@root) if @root && File.exist?(@root)
      end

      # `parent:` defaults to the project folder; pass nil to upload to the library root.
      #
      # BUILT FROM A StringIO, NOT A FILE ON DISK, and that is a fix rather than a style choice.
      # This helper used to write `File.join(Dir.tmpdir, name)` and `rm_f` it in an `ensure` — a
      # FIXED path, shared by every parallel worker, for a name several tests here reuse
      # ("panel.svg"). Under the suite's 10 workers two of them raced: one finished and deleted the
      # file while another was still opening it, and Rack::Test raised
      # `RuntimeError: /var/folders/.../panel.svg file does not exist`. It passed locally and failed
      # on CI — a timing-dependent flake, not a backend difference, which is why the share leg was
      # the one that happened to catch it.
      #
      # A StringIO has no path to collide on, so the race cannot be reconstructed, and
      # `original_filename:` still carries the name the app derives its role and folder from — the
      # only thing these tests actually need from the fixture. Same shape
      # project_upload_attach_test.rb already uses.
      def upload(name, content = "x", parent: @folder.node_id)
        post files_path,
             params: { parent_node_id: parent,
                       file: Rack::Test::UploadedFile.new(StringIO.new(content.b),
                                                          "application/octet-stream",
                                                          original_filename: name) }
      end

      test "a file uploaded into the project folder is attached and filed in the same request" do
        upload("panel.svg", "<svg/>")
        assert_response :redirect

        att = @project.file_attachments.sole
        node = @user.nodes.find_by!(node_id: att.node_id)
        assert_equal "vector", att.role
        assert_equal "design", @user.nodes.find_by(node_id: node.parent_node_id).name
        assert_equal "Uploaded panel.svg. Filed panel.svg into design/.", flash[:notice],
                     "a non-colliding upload is told where the sweep put it (stage 4, S4-2)"
      end

      # STORY 4.1: the sweep filed it and the flash says where. The folder comes off Result#plan, so
      # this asserts the SENTENCE and project_intake_test.rb asserts the MOVE; neither stands in for
      # the other.
      test "the flash names the file and the folder the sweep filed it into" do
        upload("panel.svg", "<svg/>")
        assert_response :redirect
        assert_match(/Filed panel\.svg into design\//, flash[:notice].to_s)
      end

      # THE COLLIDING FOLDER IS THE ONE THE SWEEP TRIED, AND FOR A BOARD ZIP THAT IS NOT WHAT THE
      # NAME SAYS (stage 4, S4-2; story 2.8). `zip` is role `source_archive` -> `archives/`, but
      # Maker::ProjectIntake#place reads the bytes and files a Gerber export into `pcb/`. Before the
      # conflict carried the folder it tried (its Filing, since F-S06-1), the sentence re-derived the
      # folder from the NAME and named `archives/` — a folder the file had never been near. This is
      # the one case that tells the two apart.
      test "a board zip that collides is told about pcb, the folder the sweep actually tried" do
        board = File.binread(Rails.root.join("test/fixtures/files/gerber-export.zip"))
        upload("Gerber_lamp.zip", board)
        assert_match(/Filed Gerber_lamp\.zip into pcb\//, flash[:notice].to_s,
                     "the first copy is filed by CONTENT, not by the zip extension")

        upload("Gerber_lamp.zip", board)  # the root is vacant again, so the write succeeds
        assert_nil flash[:alert]
        assert_match(/already in pcb\//, flash[:notice].to_s)
        assert_no_match(/already in archives\//, flash[:notice].to_s)
      end

      test "a file uploaded to the library root is untouched" do
        upload("loose.svg", "<svg/>", parent: nil)
        assert_response :redirect
        assert_equal 0, @project.file_attachments.count
        assert_equal "Uploaded loose.svg.", flash[:notice],
                     "no owning project -> #intake_project_folder answers nil -> a clean message"
      end

      # A SECOND COPY OF A NAME IS NO LONGER REFUSED HERE, AND THE FLASH SAYS WHERE IT LANDED. The
      # eager nudge (Task 11) narrowed a guarantee on purpose. Before it, the second same-named upload
      # collided with the first at the project root, where FileLayer::Share#write checks, and was
      # refused with a flash. Now the first upload's nudge files it into models/ within its own
      # request, which vacates the root, so the second write succeeds too. Its own nudge then collides
      # in models/ and leaves it at the root: the :conflict outcome a later sweep gives any same-named
      # collision (Maker::ProjectIntake#place), reached one upload sooner. Nothing is lost. Two nodes
      # with distinct bytes both attach, one filed and one not.
      #
      # What briefly went missing was the FEEDBACK: the door threw the nudge's Result away and said a
      # bare "Uploaded dup.stl.". ProjectFolderIntake#left_unfiled_by_conflict? reads the Result's
      # `:conflict` skip for this filename, and #project_intake_notice says where the copy stayed. No
      # write, move or sweep was changed for it. Whether an upload into a project should check the
      # WHOLE project for a name is still open (§12 item 11). This was pinned on
      # Projects::UploadsController's project-level route as well, until F-S21-1 retired the route.
      test "a duplicate filename via the Files-page uploader is filed apart, and the flash says where the second copy landed" do
        upload("dup.stl")
        assert_response :redirect
        assert_equal "Uploaded dup.stl. Filed dup.stl into models/.", flash[:notice]

        upload("dup.stl")  # same name -> the first upload's own nudge already vacated the root
        assert_response :redirect
        assert_nil flash[:alert], "this is not an error — the upload succeeded and IS attached"
        assert_equal "Uploaded dup.stl, but a file of that name is already in models/, " \
                     "so this one stayed at the project root.", flash[:notice]

        nodes = @user.nodes.present.where(name: "dup.stl").to_a
        assert_equal 2, nodes.size, "distinct nodes, no bytes overwritten"
        filed, stuck = nodes.partition { |n| @user.nodes.find_by(node_id: n.parent_node_id)&.name == "models" }
        assert_equal 1, filed.size, "the first upload's eager nudge files it into models/"
        assert_equal 1, stuck.size, "the second collides at the destination and stays at the project root"
        assert_equal @folder.node_id, stuck.first.parent_node_id
        # FilesController#create makes no `file_attachments.create!` of its own -- BOTH rows here
        # exist only because #intake_project_folder's own #attach step made them, and attach is the
        # durable half regardless of whether filing succeeded (Maker::AttachToProject's rule, applied
        # by Maker::ProjectIntake#call).
        assert_equal 2, @project.file_attachments.count
      end

      # BEST-EFFORT: the upload already succeeded, so a failing intake must not turn it into an
      # error (the same rule the preview enqueue before it follows) -- AND it must not turn
      # into a misleading flash either: a rescued failure has nothing true to report about a
      # conflict, so the message must read exactly like the ordinary, nothing-unusual-happened case.
      #
      # Hand-rolled override — `stub` does not exist in this suite (minitest 6 dropped
      # minitest/mock). The ensure-restore is load-bearing: a leak would break every later test in
      # this process.
      test "an intake failure does not fail the upload, and the flash stays clean" do
        original = Maker::ProjectIntake.method(:for_node)
        Maker::ProjectIntake.define_singleton_method(:for_node) { |**| raise "intake exploded" }
        begin
          upload("panel.svg", "<svg/>")
          assert_response :redirect
          assert @user.nodes.present.exists?(name: "panel.svg"), "the file is uploaded either way"
          assert_nil flash[:alert], "a rescued failure here must never surface as an error"
          assert_equal "Uploaded panel.svg.", flash[:notice],
                       "a rescued failure must read exactly like the ordinary, no-conflict case"
        ensure
          Maker::ProjectIntake.define_singleton_method(:for_node, original)
        end
      end
    end

    # THE BUILD-LOG PHOTO UPLOAD: Projects::UploadsController#create, share/s3 only
    # (before_action :require_port_writable! keeps chunk mode off it). It writes at the library
    # ROOT (v1 scope, spec "Out of scope"), and no project owns the root. So a photo attaches to its
    # entry and never to the project, and the door calls no nudge, which would answer nil for every
    # file it writes. ShareTest's library-root test pins the same guarantee for the other door. See
    # project_upload_attach_test.rb for the rest of this controller's behaviour.
    class BuildLogUploadTest < ProjectFolderIntakeTest
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "pfip-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        sign_in_web!(@user, password: PASSWORD)
        @project = @user.maker_projects.create!(name: "Desk Lamp")
      end

      test "a build-log-entry photo lands at the library root and attaches to the entry, never the project" do
        entry = @project.build_log_entries.create!(user: @user, body: "glued")
        file = Rack::Test::UploadedFile.new(StringIO.new("\x89PNG".b), "image/png",
                                            original_filename: "clamp.png")
        post build_log_entry_uploads_path(entry), params: { file: }
        assert_response :redirect
        assert_nil @user.nodes.present.find_by!(name: "clamp.png").parent_node_id, "the photo is at the root"
        assert_equal 0, @project.file_attachments.count
        assert_equal 1, entry.file_attachments.count
      end
    end
  end
end
