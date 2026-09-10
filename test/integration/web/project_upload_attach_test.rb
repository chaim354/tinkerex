require "test_helper"

module Web
  class ProjectUploadAttachTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

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
        assert_equal "Uploaded cube.stl. Filed cube.stl into models/.", flash[:notice],
                     "the sweep filed it and the flash says where (stage 4, S4-2)"
      end

      # --- A BATCH THROUGH THIS DOOR (slice 0, 2026-09-10) --------------------------------
      #
      # This is the door with the extra step: every file must be ATTACHED as well as written, and
      # the attach has to keep its position relative to the write and the intake sweep (the
      # ordering the controller's own comment is about). So the batch is pinned here, not only on
      # the Files page.

      test "a selection attaches every file, not just the first" do
        project = @user.maker_projects.create!(name: "Stool")
        files = [ [ "seat.dxf", "0\nSECTION" ], [ "cap.stl", "solid" ], [ "notes.md", "# hi" ] ].map do |name, body|
          Rack::Test::UploadedFile.new(StringIO.new(body.b), "application/octet-stream",
                                       original_filename: name)
        end

        assert_difference "project.file_attachments.count", 3 do
          post project_uploads_path(project), params: { file: files }
        end
        assert_equal %w[cap.stl notes.md seat.dxf],
                     project.file_attachments.map { |a| @user.nodes.find_by(node_id: a.node_id).name }.sort
        assert_match(/Uploaded 3 files/, flash[:notice].to_s)
      end

      # THE COLLISION HAS TO HAPPEN INSIDE ONE BATCH. Uploading the name twice in two separate
      # requests does NOT collide: the intake sweep files the first one into models/ between them,
      # which frees the project root again — measured, the second upload succeeded and all three
      # attached. Two files of the same name in ONE selection is the case that genuinely refuses,
      # and it is also the one a maker hits (two folders on disk, both holding `part.stl`).
      test "a name repeated inside one selection refuses the second and keeps the rest" do
        project = @user.maker_projects.create!(name: "Stool")
        batch = [ "before.stl", "dupe.stl", "dupe.stl", "after.stl" ].map do |name|
          Rack::Test::UploadedFile.new(StringIO.new("x".b), "application/octet-stream",
                                       original_filename: name)
        end

        assert_difference "project.file_attachments.count", 3 do
          post project_uploads_path(project), params: { file: batch }
        end
        names = project.file_attachments.map { |a| @user.nodes.find_by(node_id: a.node_id).name }
        assert_includes names, "after.stl", "a file AFTER the refusal must still attach"
        assert_equal 1, names.count("dupe.stl"), "the repeated name must not attach twice"
        assert_match(/not uploaded: dupe\.stl/, flash[:notice].to_s)
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

      # TASK 11's EAGER NUDGE NARROWED THIS GUARANTEE, AND THAT WAS A KNOWN, DELIBERATE TRADE-OFF —
      # not silently dropped, not a crash, but genuinely weaker than before. FOR A WHILE, THOUGH, IT
      # WAS ALSO A REGRESSION THIS TEST DID NOT CATCH: the mechanism below is unchanged (still worth
      # recording precisely, since the fix does not touch it) but the FEEDBACK it left behind briefly
      # went missing, and this test's old `assert_nil flash[:alert]` for the second upload could not
      # tell "no error, and the user was told what happened" apart from "no error, and the user was
      # told NOTHING unusual happened" — both make that assertion pass.
      #
      # BEFORE Task 11: the SECOND same-named upload collided with the FIRST at the exact path
      # FileLayer::Share#write checks (the project folder ROOT), and was refused with a flash.
      #
      # AFTER Task 11, BEFORE THIS FIX: the first upload's eager nudge FILES it into "models/" within
      # the SAME request, which VACATES the root before the second upload's write ever runs its own
      # clobber check — so the second upload's WRITE now succeeds too. Its own eager nudge then tries
      # to file IT into "models/" as well, collides with the first file already sitting there
      # (Maker::MoveNode::Collision), and leaves it un-filed at the project root instead — the SAME
      # :conflict outcome a later periodic sweep already produces for any other same-named collision
      # (Maker::ProjectIntake#place), just reached one upload sooner than before. NEITHER upload was
      # ever silently lost or corrupted: two distinct nodes exist, with distinct bytes, both attached
      # to the project — one filed, one not. What WAS genuinely gone was the immediate "that name is
      # taken" flash this test used to pin: Projects::UploadsController called
      # Maker::ProjectIntake.for_node (via #intake_project_folder) purely for its side effect and
      # threw away what it answered, so the user saw a bare "Uploaded dup.stl." and had no sign two
      # files now shared a name until they went looking.
      #
      # THIS FIX RESTORES THE FEEDBACK WITHOUT TOUCHING ANY OF THE MECHANISM ABOVE. No project-wide
      # pre-write duplicate check was added; FileLayer#write, Maker::MoveNode and
      # Maker::ProjectIntake#place are all untouched; the second upload still succeeds and both nodes
      # still exist. ProjectFolderIntake#left_unfiled_by_conflict? reads the SAME
      # Maker::ProjectIntake::Result#skips the service already produced and matches this upload's own
      # filename against a `:conflict` entry; #project_intake_notice turns a true match into a flash
      # that says what actually happened instead of staying silent about it. Whether a project-scoped
      # upload should duplicate-check across the WHOLE project rather than just the immediate write
      # path is still a real product question, and still not decided here — only the feedback gap is
      # closed.
      test "a duplicate filename is no longer refused, and the flash now says where the second copy landed" do
        project = @user.maker_projects.create!(name: "Lamp")
        make = -> { Rack::Test::UploadedFile.new(StringIO.new(SecureRandom.hex.b),
                                                 "application/octet-stream", original_filename: "dup.stl") }
        post project_uploads_path(project), params: { file: make.call }
        assert_response :redirect
        assert_nil flash[:alert]
        assert_equal "Uploaded dup.stl. Filed dup.stl into models/.", flash[:notice],
                     "the ordinary, non-colliding case now names the folder the sweep used"
        assert_equal 1, project.file_attachments.count

        post project_uploads_path(project), params: { file: make.call }  # same name -> NOT refused now
        assert_response :redirect                                       # still never a 500
        assert_nil flash[:alert],
                   "this is not an error — the upload succeeded and the file IS attached"
        assert_equal "Uploaded dup.stl, but a file of that name is already in models/, " \
                     "so this one stayed at the project root.", flash[:notice],
                     "the restored feedback: what happened, not just that nothing crashed"
        assert_equal 2, project.file_attachments.count, "two distinct files, not a clobber"

        nodes = project.file_attachments.reload.map { |a| @user.nodes.find_by!(node_id: a.node_id) }
        assert_equal [ "dup.stl", "dup.stl" ], nodes.map(&:name).sort
        assert_equal 2, nodes.map(&:node_id).uniq.size, "distinct nodes, no bytes overwritten"
        filed, stuck = nodes.partition { |n| n.storage_path == "Projects/lamp/models/dup.stl" }
        assert_equal 1, filed.size, "the first upload's eager nudge files it"
        assert_equal 1, stuck.size, "the second collides at the destination and stays at the project root"
        assert_equal "Projects/lamp/dup.stl", stuck.first.storage_path
      end

      # UPDATED FOR TASK 11's EAGER NUDGE, matching the identical rename on the chunk side above: a
      # share/s3 upload straight into a project folder no longer stays loose at the root — it lands
      # one hop deeper, in its category subfolder, in the SAME request.
      test "a project-view share upload is filed under Projects/<slug>/<category>" do
        project = @user.maker_projects.create!(name: "Lamp")
        file = Rack::Test::UploadedFile.new(StringIO.new("cube".b), "application/octet-stream", original_filename: "cube.stl")
        post project_uploads_path(project), params: { file: }
        node = @user.nodes.find_by!(node_id: project.file_attachments.last.node_id)
        assert_equal "Projects/lamp/models/cube.stl", node.storage_path
      end
    end
  end
end
