require "test_helper"

module Web
  # Projects::UploadsController: a build-log entry's inline photo upload on share/s3. One multipart
  # POST writes the bytes to the port at the library root and attaches each file to the entry as an
  # image.
  #
  # ONE TARGET SINCE F-S21-1 (2026-10-19). This file also pinned a project-level route
  # (POST /projects/:slug/uploads) until it was retired. Redesign slice 4 had moved the hub's Upload
  # into the top bar, so the route had no caller in the app. Everything it did for a project
  # (attach, file, name the folder in the flash, a second copy of a name) is pinned through the top
  # bar's door, FilesController#create, in project_folder_intake_test.rb.
  class ProjectUploadAttachTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper
    PASSWORD = "correct horse battery staple".freeze

    # share: one multipart POST writes the bytes to the port AND attaches.
    class ShareTest < ProjectUploadAttachTest
      setup do
        @root = use_fresh_share_library!
        @user = User.create!(email: "ups-#{SecureRandom.hex(4)}@example.com",
                             password: PASSWORD, confirmed_at: Time.current)
        sign_in_web!(@user, password: PASSWORD)
        @project = @user.maker_projects.create!(name: "Lamp")
        @entry = @project.build_log_entries.create!(user: @user, body: "glued the base")
      end

      def photo(name, body = "\x89PNG-#{name}")
        Rack::Test::UploadedFile.new(StringIO.new(body.b), "image/png", original_filename: name)
      end

      def entry_photo_names = @entry.file_attachments.reload.map { |a| @user.nodes.find_by!(node_id: a.node_id).name }

      test "multipart photo upload writes and attaches to the entry as image" do
        assert_difference "@entry.file_attachments.count", 1 do
          post build_log_entry_uploads_path(@entry), params: { file: photo("p.png") }
        end
        assert_equal "image", @entry.file_attachments.last.role
        assert_path_exists @root.join("p.png"), "a build-log photo lands at the library root"
        assert_redirected_to project_path(@project)
        assert_equal "Uploaded p.png.", flash[:notice]
      end

      # --- A BATCH THROUGH THIS DOOR (slice 0, 2026-09-10) --------------------------------
      #
      # This door has an extra step: every file must be ATTACHED as well as written. So the batch is
      # pinned here, not only on the Files page.

      test "a selection attaches every photo to the entry, not just the first" do
        assert_difference "@entry.file_attachments.count", 3 do
          post build_log_entry_uploads_path(@entry),
               params: { file: [ photo("front.png"), photo("side.jpg"), photo("detail.jpeg") ] }
        end
        assert_equal %w[detail.jpeg front.png side.jpg], entry_photo_names.sort
        assert_equal %w[image], @entry.file_attachments.map(&:role).uniq
        assert_equal "Uploaded 3 files.", flash[:notice]
      end

      # The repeated name collides at the library root, where this door writes and where no intake
      # sweep moves the first copy away.
      test "a name repeated inside one selection refuses the second and keeps the rest" do
        batch = %w[before.png dupe.png dupe.png after.png].map { |name| photo(name) }

        assert_difference "@entry.file_attachments.count", 3 do
          post build_log_entry_uploads_path(@entry), params: { file: batch }
        end
        names = entry_photo_names
        assert_includes names, "after.png", "a file AFTER the refusal must still attach"
        assert_equal 1, names.count("dupe.png"), "the repeated name must not attach twice"
        assert_match(/not uploaded: dupe\.png \(a file of that name already exists\)/, flash[:notice].to_s)
      end

      # --- WHAT THE PORT REFUSES BY NAME (F-S21-2) -------------------------------------------
      #
      # Both writable adapters raise FileLayer::NotFound for a condition that belongs to ONE file:
      # a name the library reserves (`._x`, `.DS_Store`, `.git`), a name that is not a leaf, or a
      # file over FileLayer::MAX_BYTES. The batch caught only UnsupportedOperation and FetchError,
      # and this door had no NotFound arm, so each of the two tests below was a 500, the first one
      # after the earlier photos had already been written and attached.

      test "a reserved name in the middle of a selection refuses only that file, and the photos around it attach" do
        assert_difference "@entry.file_attachments.count", 2 do
          post build_log_entry_uploads_path(@entry),
               params: { file: [ photo("before.png"), photo("._before.png"), photo("after.png") ] }
        end
        assert_equal %w[after.png before.png], entry_photo_names.sort
        assert_not @user.nodes.exists?(name: "._before.png"), "the refused file has no node"
        assert_not @root.join("._before.png").exist?, "and no bytes"
        assert_redirected_to project_path(@project)
        assert_nil flash[:alert]
        assert_equal "Uploaded 2 files. This one was not uploaded: ._before.png (the library cannot store it).",
                     flash[:notice]
      end

      test "a single photo the port refuses answers an alert, never a 500" do
        assert_no_difference "@entry.file_attachments.count" do
          post build_log_entry_uploads_path(@entry), params: { file: photo("._photo.png") }
        end
        assert_response :redirect
        assert_equal "Couldn't upload that file — the library cannot store a file with that name or size.",
                     flash[:alert]
        assert_not @root.join("._photo.png").exist?
      end

      # UNCHANGED BY F-S21-2, and pinned because the refusal now passes through the batch's loop: a
      # single file still re-raises so this controller's own `rescue_from` answers it in its own
      # words, rather than in the batch's sentence.
      test "a second upload of the same name is still the clobber refusal" do
        post build_log_entry_uploads_path(@entry), params: { file: photo("p.png", "first") }
        follow_redirect!

        post build_log_entry_uploads_path(@entry), params: { file: photo("p.png", "second") }

        assert_response :redirect
        assert_equal "Couldn't upload that file — a file with the same name may already exist.", flash[:alert]
        assert_equal 1, @entry.file_attachments.count, "the refused copy attaches nothing"
        assert_equal "first", @root.join("p.png").binread, "the original bytes survive the refusal"
      end

      # --- WHERE THE BROWSER LANDS (Projects::UploadsController#after_upload_url) --------------
      #
      # The chunk branch honors data-uploader-redirect-url-value in uploader_controller.js. The
      # multipart branch must reach the same place, so a hidden redirect_url is followed instead of
      # the project page.
      test "an upload carrying a redirect_url lands there, not on the project page" do
        assert_difference "@entry.file_attachments.count", 1 do
          post build_log_entry_uploads_path(@entry), params: { file: photo("p.png"), redirect_url: files_path }
        end
        assert_redirected_to files_path
      end

      # An open-redirect guard: a tampered redirect_url pointing off-site must never send the user
      # away from this app. url_from returns nil for anything non-relative, so the controller falls
      # back to the project page. (The upload itself still succeeds.)
      test "an off-site redirect_url is refused — the upload falls back to the project page" do
        post build_log_entry_uploads_path(@entry),
             params: { file: photo("p.png"), redirect_url: "https://evil.example.com/phish" }
        assert_redirected_to project_path(@project)
        assert_equal 1, @entry.file_attachments.count
      end

      # THE PROJECT-LEVEL ROUTE IS GONE (F-S21-1): a hand-made POST to it is a 404 that writes
      # nothing. The body carries a REAL build_log_entry_id on purpose. This controller finds its
      # entry from that param, so if the route were restored, the request would reach a controller
      # that writes. The 404 can then only come from the route table, never from an entry lookup
      # that happened to miss.
      test "POST /projects/:slug/uploads is not routed and writes nothing" do
        before = @user.nodes.count

        post "/projects/#{@project.slug}/uploads",
             params: { file: photo("cube.png"), build_log_entry_id: @entry.id }

        assert_response :not_found
        assert_equal before, @user.nodes.count, "no file was written"
        assert_not @root.join("cube.png").exist?
        assert_empty @entry.file_attachments
        assert_empty @project.file_attachments
      end
    end
  end
end
